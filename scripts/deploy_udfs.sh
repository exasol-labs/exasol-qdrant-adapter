#!/usr/bin/env bash
# Deploy UDFs to Exasol:
#   1. Upload the chosen SLC tarball to BucketFS
#   2. Print the ALTER SESSION statement to activate the SLC
#   3. Run scripts/create_udfs.sql to create the UDF scripts in Exasol
#
# Prerequisites: curl, exapump (or the Exasol CLI client)
#
# Usage:
#   ./scripts/deploy_udfs.sh [options]
#
# Options:
#   --exasol-host   HOST       Exasol host (default: localhost)
#   --exasol-port   PORT       Exasol port (default: 8563)
#   --exasol-user   USER       Exasol user (default: sys)
#   --exasol-pass   PASS       Exasol password (required)
#   --bucketfs-host HOST       BucketFS host (default: same as --exasol-host)
#   --bucketfs-port PORT       BucketFS HTTPS port (default: 2581)
#   --bucketfs-user USER       BucketFS write user (default: w)
#   --bucketfs-pass PASS       BucketFS write password (required)
#   --bucket        NAME       BucketFS bucket name (default: default)
#   --slc-path      PATH       Path to SLC .tar.gz (default: dist/qdrant-udf-slim.tar.gz)
#   --schema        NAME       Exasol schema for UDF scripts (default: ADAPTER)
#   --dry-run                  Print commands without executing them

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Defaults
EXASOL_HOST="localhost"
EXASOL_PORT="8563"
EXASOL_USER="sys"
EXASOL_PASS=""
BUCKETFS_HOST=""
BUCKETFS_PORT="2581"
BUCKETFS_USER="w"
BUCKETFS_PASS=""
BUCKET="default"
SLC_PATH="$PROJECT_ROOT/dist/qdrant-udf-slim.tar.gz"
UDF_SCHEMA="ADAPTER"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --exasol-host)   EXASOL_HOST="$2";   shift 2 ;;
        --exasol-port)   EXASOL_PORT="$2";   shift 2 ;;
        --exasol-user)   EXASOL_USER="$2";   shift 2 ;;
        --exasol-pass)   EXASOL_PASS="$2";   shift 2 ;;
        --bucketfs-host) BUCKETFS_HOST="$2"; shift 2 ;;
        --bucketfs-port) BUCKETFS_PORT="$2"; shift 2 ;;
        --bucketfs-user) BUCKETFS_USER="$2"; shift 2 ;;
        --bucketfs-pass) BUCKETFS_PASS="$2"; shift 2 ;;
        --bucket)        BUCKET="$2";        shift 2 ;;
        --slc-path)      SLC_PATH="$2";      shift 2 ;;
        --schema)        UDF_SCHEMA="$2";    shift 2 ;;
        --dry-run)       DRY_RUN=true;       shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

BUCKETFS_HOST="${BUCKETFS_HOST:-$EXASOL_HOST}"
SLC_NAME="$(basename "$SLC_PATH" .tar.gz)"
BUCKETFS_PATH="udfs/${SLC_NAME}.tar.gz"

if [[ -z "$BUCKETFS_PASS" && "$DRY_RUN" == "false" ]]; then
    echo "ERROR: --bucketfs-pass is required (use --dry-run to skip actual upload)"
    exit 1
fi

run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# Step 1: Upload SLC to BucketFS
echo "==> Uploading $SLC_PATH to BucketFS..."
run curl -k -X PUT \
    -T "$SLC_PATH" \
    "https://${BUCKETFS_USER}:${BUCKETFS_PASS}@${BUCKETFS_HOST}:${BUCKETFS_PORT}/${BUCKET}/${BUCKETFS_PATH}"
echo ""

# Step 2: Print ALTER SESSION statement
SCRIPT_LANGUAGES_VALUE="PYTHON3=localzmq+bucketfs:///bfsdefault/${BUCKET}/${BUCKETFS_PATH}?${SLC_NAME}/exaudf/exaudfclient.py"
echo "==> Run this in Exasol to activate the SLC:"
echo ""
echo "    ALTER SESSION SET SCRIPT_LANGUAGES = '${SCRIPT_LANGUAGES_VALUE}';"
echo ""

# Step 3: Create UDF scripts via create_udfs.sql
# Substitute the schema name into the SQL file and execute via exapump
SQL_FILE="$SCRIPT_DIR/create_udfs.sql"
if [[ ! -f "$SQL_FILE" ]]; then
    echo "WARNING: $SQL_FILE not found — skipping UDF script creation."
    echo "         Run it manually after the ALTER SESSION above."
    exit 0
fi

echo "==> Creating UDF scripts in schema ${UDF_SCHEMA}..."
if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would execute $SQL_FILE against $EXASOL_HOST:$EXASOL_PORT as $EXASOL_USER"
else
    if ! command -v exapump &>/dev/null; then
        echo "WARNING: 'exapump' not found. Run $SQL_FILE manually in your SQL client."
        exit 0
    fi
    # Replace placeholder schema in a temp copy and execute
    TMP_SQL="$(mktemp /tmp/create_udfs_XXXX.sql)"
    sed "s/\${UDF_SCHEMA}/${UDF_SCHEMA}/g" "$SQL_FILE" > "$TMP_SQL"
    exapump --host "$EXASOL_HOST" --port "$EXASOL_PORT" \
            --user "$EXASOL_USER" --password "$EXASOL_PASS" \
            --sql "$TMP_SQL"
    rm -f "$TMP_SQL"
fi

echo "==> Deployment complete."
echo "    You can now call SELECT ${UDF_SCHEMA}.CREATE_QDRANT_COLLECTION(...) and SELECT ${UDF_SCHEMA}.EMBED_AND_PUSH(...)"
