#!/usr/bin/env bash
# Build Exasol Script Language Containers (SLCs) for the UDF ingestion pipeline.
#
# Requires: exaslct (https://github.com/exasol/script-languages-release)
#   pip install exaslct
#
# Usage:
#   ./scripts/build_slc.sh            # build both flavours
#   ./scripts/build_slc.sh slim       # build slim (OpenAI-only) flavour only
#   ./scripts/build_slc.sh full       # build full (with sentence-transformers + torch) only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
UDF_DIR="$PROJECT_ROOT/exasol_udfs"
BUILD_DIR="$PROJECT_ROOT/slc_build"

FLAVOUR="${1:-both}"

build_slim() {
    echo "==> Building slim SLC (OpenAI + qdrant-client only)..."
    mkdir -p "$BUILD_DIR/slim/flavor_base/dependencies/python"
    cp "$UDF_DIR/requirements-slim.txt" "$BUILD_DIR/slim/flavor_base/dependencies/python/requirements.txt"
    cp "$UDF_DIR/create_collection.py"  "$BUILD_DIR/slim/flavor_base/dependencies/python/"
    cp "$UDF_DIR/embed_and_push.py"     "$BUILD_DIR/slim/flavor_base/dependencies/python/"

    exaslct export \
        --flavor-path "$BUILD_DIR/slim" \
        --export-path "$PROJECT_ROOT/dist" \
        --name "qdrant-udf-slim"

    echo "==> Slim SLC written to $PROJECT_ROOT/dist/qdrant-udf-slim.tar.gz"
}

build_full() {
    echo "==> Building full SLC (includes sentence-transformers + torch CPU)..."
    mkdir -p "$BUILD_DIR/full/flavor_base/dependencies/python"
    cp "$UDF_DIR/requirements.txt"     "$BUILD_DIR/full/flavor_base/dependencies/python/requirements.txt"
    cp "$UDF_DIR/create_collection.py" "$BUILD_DIR/full/flavor_base/dependencies/python/"
    cp "$UDF_DIR/embed_and_push.py"    "$BUILD_DIR/full/flavor_base/dependencies/python/"

    exaslct export \
        --flavor-path "$BUILD_DIR/full" \
        --export-path "$PROJECT_ROOT/dist" \
        --name "qdrant-udf-full"

    echo "==> Full SLC written to $PROJECT_ROOT/dist/qdrant-udf-full.tar.gz"
}

case "$FLAVOUR" in
    slim)  build_slim ;;
    full)  build_full ;;
    both)  build_slim; build_full ;;
    *) echo "Unknown flavour: $FLAVOUR. Use slim, full, or both."; exit 1 ;;
esac

echo "==> Build complete."
