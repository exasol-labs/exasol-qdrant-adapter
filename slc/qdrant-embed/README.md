# `qdrant-embed` — Custom Script-Languages-Container Flavor

This flavor adds `sentence-transformers`, `torch` (CPU), `transformers`, and
`huggingface-hub` to an Exasol Python 3.10 SLC so that
`ADAPTER.EMBED_AND_PUSH_LOCAL` can run an embedding model in-process inside a
UDF VM — no Ollama HTTP hop on the ingest path.

The committed scaffold is the **customization overlay only**. The full base
flavor lives in
[`exasol/script-languages-release`](https://github.com/exasol/script-languages-release)
and is too large (and too version-sensitive) to vendor here. The
`build_and_upload_slc.sh` helper in `scripts/` handles the bootstrap:
clone `script-languages-release`, copy the upstream base flavor, overlay this
directory's `flavor_customization/`, run `exaslct export`, then upload the
tarball to BucketFS.

## What's committed here

- `flavor_info.yaml` — flavor name and base flavor reference
- `flavor_customization/packages/python3_pip_packages` — pinned pip
  packages added on top of the base flavor

## What gets generated at build time (not committed)

- `out/` — exaslct output directory
- `*.tar.gz` — built SLC archive (3–5 GB)
- exaslct's local Docker layer cache (in the user's home dir, managed by
  exaslct itself)

## One-time build

Building the flavor requires a Linux Docker host with ≥ 20 GB free disk,
4+ cores, and `exaslct` installed (`pip install exasol-script-languages-container-tool`).
The first build is 30–90 minutes; subsequent rebuilds reuse the Docker layer
cache and are minutes.

```bash
# From the repo root, after script-languages-release has been bootstrapped
# alongside this flavor (the helper script does this automatically):
exaslct export \
    --flavor-path slc/qdrant-embed \
    --export-path ./out
```

The helper script `scripts/build_and_upload_slc.sh` wraps this command and
handles the clone + overlay + upload.

## Why a separate flavor

The default `standard-EXASOL-all-python-3.10` flavor ships with stdlib only.
`sentence-transformers` and `torch` cannot be installed at UDF runtime — the
sandbox has no internet and a read-only filesystem — so they must be baked
into the language container.

## Sizing

Each UDF VM that loads the model holds roughly **600 MB resident** for
`nomic-embed-text-v1.5`. Cluster sizing rule of thumb: `cores × 600 MB`
headroom per Exasol node. See `docs/local-embeddings.md` for full operational
guidance.
