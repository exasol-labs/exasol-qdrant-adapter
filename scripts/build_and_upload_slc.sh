#!/usr/bin/env bash
# Build the qdrant-embed SLC and upload it (plus the embedding model
# weights) to BucketFS, ready for ADAPTER.EMBED_AND_PUSH_LOCAL to use.
#
# Run on a Linux Docker host with:
#   - exaslct installed       (pip install exasol-script-languages-container-tool)
#   - python3 + pip available (for huggingface-hub snapshot_download)
#   - git, curl, tar          (standard)
#   - >= 20 GB free disk, 4+ cores
#
# Required env vars (or pass via flags):
#   BUCKETFS_URL    e.g. http://10.0.0.5:2580/default
#   BUCKETFS_USER   e.g. w
#   BUCKETFS_PASS   the BucketFS write password
#
# Optional:
#   MODEL_NAME      default: nomic-embed-text-v1.5
#   MODEL_REPO      default: nomic-ai/nomic-embed-text-v1.5
#   FLAVOR_DIR      default: slc/qdrant-embed
#   OUT_DIR         default: ./out
#   SLR_REF         default: read from flavor_info.yaml; e.g. 8.4.0
#   HF_TOKEN        only needed for gated models; not committed anywhere
#
# Flags:
#   --skip-build    re-upload the existing SLC tarball without rebuilding
#   --skip-model    skip model download + upload (rebuild SLC only)
#   --skip-upload   build artefacts only; do not PUT to BucketFS
#   --help          show this message
#
# Secrets: this script never hard-codes BUCKETFS_PASS, HF_TOKEN, or any
# Qdrant key. Inspect with `grep -nE 'pass|token|key' scripts/build_and_upload_slc.sh`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

FLAVOR_DIR="${FLAVOR_DIR:-slc/qdrant-embed}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/out}"
MODEL_NAME="${MODEL_NAME:-nomic-embed-text-v1.5}"
MODEL_REPO="${MODEL_REPO:-nomic-ai/nomic-embed-text-v1.5}"

SKIP_BUILD=0
SKIP_MODEL=0
SKIP_UPLOAD=0

usage() {
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)  SKIP_BUILD=1 ;;
        --skip-model)  SKIP_MODEL=1 ;;
        --skip-upload) SKIP_UPLOAD=1 ;;
        --help|-h)     usage 0 ;;
        *) echo "unknown flag: $1" >&2; usage 1 ;;
    esac
    shift
done

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "error: environment variable $name is not set" >&2
        exit 2
    fi
}

if [[ "$SKIP_UPLOAD" -eq 0 ]]; then
    require_env BUCKETFS_URL
    require_env BUCKETFS_USER
    require_env BUCKETFS_PASS
fi

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# 1. Build SLC (unless --skip-build)
# ---------------------------------------------------------------------------

SLC_TARBALL="$OUT_DIR/${FLAVOR_DIR##*/}.tar.gz"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "==> Building SLC at $FLAVOR_DIR"
    if ! command -v exaslct >/dev/null 2>&1; then
        echo "error: exaslct not on PATH. pip install exasol-script-languages-container-tool" >&2
        exit 3
    fi

    # The committed flavor in $FLAVOR_DIR is overlay-only. Bootstrap by cloning
    # script-languages-release at the pinned ref, copying the base flavor,
    # then overlaying our customization.
    SLR_REF_DEFAULT="$(awk -F': ' '/^script_languages_release_ref/ {gsub(/"/,"",$2); print $2}' "$PROJECT_ROOT/$FLAVOR_DIR/flavor_info.yaml")"
    SLR_REF="${SLR_REF:-$SLR_REF_DEFAULT}"
    BASE_FLAVOR="$(awk -F': ' '/^base_flavor/ {print $2}' "$PROJECT_ROOT/$FLAVOR_DIR/flavor_info.yaml")"
    FLAVOR_NAME="$(awk -F': ' '/^flavor_name/ {print $2}' "$PROJECT_ROOT/$FLAVOR_DIR/flavor_info.yaml")"

    BOOT_DIR="$OUT_DIR/_bootstrap"
    rm -rf "$BOOT_DIR"
    mkdir -p "$BOOT_DIR"
    # script-languages-release uses a submodule (`script-languages`) for the
    # bulk of the build context. Many top-level paths (e.g. `ext`) are
    # symlinks into it, so we must clone with submodules or the build
    # context hash step fails with "Could not find file or directory ext/01_nodoc".
    git clone --depth 1 --branch "$SLR_REF" \
        --recurse-submodules --shallow-submodules \
        https://github.com/exasol/script-languages-release.git \
        "$BOOT_DIR/script-languages-release"

    # Overlay our customization onto the cloned flavor in-place. We can't `cp -r`
    # the flavor out of the repo first because the upstream flavor uses relative
    # symlinks (e.g. top-level `ext` -> `script-languages/ext/`) that break once
    # the flavor leaves its original parent.
    SLR_DIR="$BOOT_DIR/script-languages-release"
    BUILT_FLAVOR_DIR="$SLR_DIR/flavors/$BASE_FLAVOR"
    cp -r "$PROJECT_ROOT/$FLAVOR_DIR/flavor_customization/." "$BUILT_FLAVOR_DIR/flavor_customization/"

    # SLR 11.1.1 does NOT auto-merge `flavor_customization/packages/python3_pip_packages`
    # into the build context — only `flavor_base/<step>/packages/...` is consumed.
    # We could append our packages to `language_deps/packages/python3_pip_packages`,
    # but that invalidates the cache key for everything downstream (including
    # `flavor_base_deps`) and forces a from-scratch rebuild. `flavor_base_deps`
    # has stale apt pins (e.g. `openssl=3.0.2-0ubuntu1.21` is no longer in
    # archive.ubuntu.com), so it then fails — pinning whack-a-mole.
    #
    # Cheaper: inject a `pip install` for our extras into the `release`
    # Dockerfile, which is the LAST build step. This only invalidates the
    # `release` image hash; `flavor_base_deps`, `build_run`, etc. stay cached
    # from the public registry.
    RELEASE_DOCKERFILE="$BUILT_FLAVOR_DIR/flavor_base/release/Dockerfile"
    if [[ ! -f "$RELEASE_DOCKERFILE" ]]; then
        echo "error: $RELEASE_DOCKERFILE missing — flavor layout changed?" >&2
        exit 7
    fi
    PIP_RUN_LINE="RUN python3.10 -m pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/cpu sentence-transformers==2.7.0 transformers==4.40.0 huggingface-hub==0.22.2 torch==2.2.0+cpu einops==0.8.0"
    if ! grep -q "qdrant-embed pip extras" "$RELEASE_DOCKERFILE"; then
        # Insert before the `RUN mkdir -p /build_info/actual_installed_packages/release`
        # line so the inventory captures our packages too.
        awk -v pip_run="$PIP_RUN_LINE" '
            /^RUN mkdir -p \/build_info\/actual_installed_packages\/release/ && !inserted {
                print "# qdrant-embed pip extras (sentence-transformers + torch CPU)"
                print pip_run
                print ""
                inserted = 1
            }
            { print }
        ' "$RELEASE_DOCKERFILE" > "$RELEASE_DOCKERFILE.tmp"
        mv "$RELEASE_DOCKERFILE.tmp" "$RELEASE_DOCKERFILE"
        echo "==> Patched release/Dockerfile with qdrant-embed pip extras"
    fi

    # exaslct must be invoked from the script-languages-release repo root because
    # the flavor's build steps reference paths like `ext/01_nodoc` relative to
    # CWD (where `ext` is a symlink into the `script-languages` submodule).
    (
        cd "$SLR_DIR"
        exaslct export \
            --flavor-path "$BUILT_FLAVOR_DIR" \
            --export-path "$OUT_DIR"
    )

    # exaslct names the tarball after the base flavor; rename to a stable path
    EXPORTED="$(ls "$OUT_DIR"/*"$BASE_FLAVOR"*.tar.gz 2>/dev/null | head -n 1)"
    if [[ -z "$EXPORTED" ]]; then
        echo "error: exaslct export produced no tarball in $OUT_DIR" >&2
        exit 4
    fi
    mv "$EXPORTED" "$SLC_TARBALL"
    echo "==> Built SLC: $SLC_TARBALL ($(du -h "$SLC_TARBALL" | cut -f1))"
else
    if [[ ! -f "$SLC_TARBALL" ]]; then
        echo "error: --skip-build set but $SLC_TARBALL does not exist" >&2
        exit 5
    fi
    echo "==> Reusing existing SLC: $SLC_TARBALL"
fi

# ---------------------------------------------------------------------------
# 2. Download + tar-gzip the embedding model (unless --skip-model)
# ---------------------------------------------------------------------------

MODEL_TARBALL="$OUT_DIR/$MODEL_NAME.tar.gz"

if [[ "$SKIP_MODEL" -eq 0 ]]; then
    echo "==> Downloading model $MODEL_REPO"
    MODEL_LOCAL_DIR="$OUT_DIR/$MODEL_NAME"
    rm -rf "$MODEL_LOCAL_DIR"

    HF_TOKEN_LINE=""
    if [[ -n "${HF_TOKEN:-}" ]]; then
        HF_TOKEN_LINE="token=os.environ.get('HF_TOKEN'),"
    fi
    python3 - <<PY
import os
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="$MODEL_REPO",
    local_dir="$MODEL_LOCAL_DIR",
    local_dir_use_symlinks=False,
    $HF_TOKEN_LINE
)
PY

    # Sanity check the downloaded files match what SentenceTransformer needs
    for f in config.json; do
        [[ -f "$MODEL_LOCAL_DIR/$f" ]] || { echo "error: missing $f in $MODEL_LOCAL_DIR" >&2; exit 6; }
    done
    if [[ ! -f "$MODEL_LOCAL_DIR/tokenizer.json" && ! -f "$MODEL_LOCAL_DIR/tokenizer.model" ]]; then
        echo "error: missing tokenizer.json/tokenizer.model in $MODEL_LOCAL_DIR" >&2
        exit 6
    fi
    if [[ ! -f "$MODEL_LOCAL_DIR/model.safetensors" && ! -f "$MODEL_LOCAL_DIR/pytorch_model.bin" ]]; then
        echo "error: missing model weights (model.safetensors or pytorch_model.bin) in $MODEL_LOCAL_DIR" >&2
        exit 6
    fi

    echo "==> Tar-gzipping model"
    # Tar contents at the top level (no enclosing directory) so BucketFS
    # auto-extracts to models/<MODEL_NAME>/<file> rather than nesting twice.
    # Skip the multi-GB ONNX variants and HF cache; only safetensors is loaded.
    tar -C "$OUT_DIR/$MODEL_NAME" --exclude=onnx --exclude=.cache -czf "$MODEL_TARBALL" .
    echo "==> Built model tarball: $MODEL_TARBALL ($(du -h "$MODEL_TARBALL" | cut -f1))"
fi

# ---------------------------------------------------------------------------
# 3. Upload to BucketFS (unless --skip-upload)
# ---------------------------------------------------------------------------

if [[ "$SKIP_UPLOAD" -eq 1 ]]; then
    echo "==> Skipping BucketFS upload (artefacts in $OUT_DIR)"
    exit 0
fi

upload() {
    local tarball="$1"
    local remote_path="$2"
    echo "==> Uploading $(basename "$tarball") -> $BUCKETFS_URL/$remote_path"
    curl -sS --fail -X PUT \
        -u "$BUCKETFS_USER:$BUCKETFS_PASS" \
        -T "$tarball" \
        "$BUCKETFS_URL/$remote_path"
    echo
}

upload "$SLC_TARBALL" "slc/${FLAVOR_DIR##*/}.tar.gz"

if [[ "$SKIP_MODEL" -eq 0 ]]; then
    upload "$MODEL_TARBALL" "models/$MODEL_NAME.tar.gz"
fi

echo "==> Done. SLC and model are in BucketFS. Next: run scripts/install_local_embeddings.sql"
