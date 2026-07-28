#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
export LOCK_FILE="${LOCK_FILE:-$REPO_ROOT/locks/build-wr3000.lock}"
export BUILDER_ID="${BUILDER_ID:-direct-host}"

exec "$SCRIPT_DIR/build-image.sh" "$@"
