#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/macos-runtime.sh
omi_require_apple_silicon "$PWD/scripts/install-local-live.sh" "$@"
omi_macos_path
if [[ ! -x backend/.venv/bin/python ]]; then
  echo 'Сначала подготовьте Mac через start.command.' >&2
  exit 1
fi
export PYTHONPATH="$PWD/scripts/dev-harness"
exec backend/.venv/bin/python -m dev_harness.local_live_install "$@"
