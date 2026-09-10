#!/usr/bin/env bash
# Debug session for a previously prepared local iPhone checkout.
set -euo pipefail
cd "$(dirname "$0")"
source scripts/macos-runtime.sh
omi_require_apple_silicon "$PWD/dev-iphone.command" "$@"
omi_macos_path
export PYTHONPATH="$PWD/scripts/dev-harness"
exec "${PYTHON:-$PWD/backend/.venv/bin/python}" -m dev_harness.ios_debug "$@"
