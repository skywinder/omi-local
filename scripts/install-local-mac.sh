#!/usr/bin/env bash
# Backend/runtime only. App generation and iOS builds are separate operations.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]; then
  echo 'This installer supports macOS on Apple Silicon.' >&2
  exit 1
fi
for input in backend/.python-version backend/pylock.macos.toml package-lock.json; do
  test -s "$input" || { echo "Missing installer input: $input" >&2; exit 1; }
done
export PATH="/opt/homebrew/bin:$PATH"
if ! command -v brew >/dev/null 2>&1; then
  installer_file="$(mktemp -t omi-homebrew)"
  trap 'rm -f "$installer_file"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer_file"
  /bin/bash "$installer_file"
fi
for formula in uv node@22 openjdk@21 redis opus ffmpeg jq; do
  if ! brew list --versions "$formula" >/dev/null 2>&1; then brew install "$formula"; fi
done
if ! command -v ngrok >/dev/null 2>&1; then brew install --cask ngrok; fi
export PATH="$PWD/node_modules/.bin:/opt/homebrew/opt/node@22/bin:/opt/homebrew/opt/openjdk@21/bin:$PATH"
bash backend/scripts/sync-python-deps.sh
# npm ci is skipped only when the complete install was attested to these inputs.
npm_inputs="$(shasum -a 256 package.json package-lock.json)"
if [ ! -f node_modules/.omi-install-inputs ] || [ "$(cat node_modules/.omi-install-inputs)" != "$npm_inputs" ]; then
  npm ci --no-audit --no-fund
  printf '%s\n' "$npm_inputs" > node_modules/.omi-install-inputs
fi
export PYTHON="$PWD/backend/.venv/bin/python"
PYTHONPATH=scripts/dev-harness "$PYTHON" -m dev_harness.local_mac prepare-emulator
bash scripts/local-mac.sh check
echo 'Installation checked. Next: bash scripts/local-mac.sh configure'
