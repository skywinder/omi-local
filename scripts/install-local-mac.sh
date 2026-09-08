#!/usr/bin/env bash
# Backend/runtime only. App generation and iOS builds are separate operations.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/macos-runtime.sh
omi_require_apple_silicon "$PWD/scripts/install-local-mac.sh" "$@"
for input in backend/.python-version backend/pylock.macos.toml package.json package-lock.json; do
  test -s "$input" || { echo "Missing installer input: $input" >&2; exit 1; }
done
quiet=false
case "${1:-}" in
  '') ;;
  --quiet) quiet=true ;;
  *) echo 'Usage: install-local-mac.sh [--quiet]' >&2; exit 1 ;;
esac
# Only dependency installation is logged; pairing and keys are handled later.
[[ ! -L .local && ! -L .local/install.log ]] || { echo 'Unsafe installer log path.' >&2; exit 1; }
mkdir -p .local
install_log="$PWD/.local/install.log"
: >>"$install_log"
chmod 600 "$install_log"
printf '\nInstallation started: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$install_log"
installer_file=''
finish_install() {
  local result=$?
  printf 'Installation exit status: %s\n' "$result" >>"$install_log"
  [[ -z "$installer_file" ]] || rm -f "$installer_file"
  return "$result"
}
trap finish_install EXIT
run_step() {
  if [[ "$quiet" == true ]]; then
    "$@" >>"$install_log" 2>&1
  else
    "$@" 2>&1 | tee -a "$install_log"
  fi
}
omi_macos_path
if ! command -v brew >/dev/null 2>&1; then
  installer_file="$(mktemp -t omi-homebrew)"
  run_step curl --fail --location --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer_file"
  # Preserve the terminal and record output; do not enable input recording (-k).
  /usr/bin/script -q -a "$install_log" /bin/bash "$installer_file"
  omi_macos_path
fi
for formula in uv node@22 openjdk@21 redis opus ffmpeg jq; do
  if ! brew list --versions "$formula" >/dev/null 2>&1; then run_step brew install "$formula"; fi
done
if ! command -v ngrok >/dev/null 2>&1; then run_step brew install --cask ngrok; fi
omi_macos_path
run_step bash backend/scripts/sync-python-deps.sh
# npm ci is skipped only when the complete install was attested to these inputs.
npm_inputs="$(shasum -a 256 package.json package-lock.json)"
if [ ! -f node_modules/.omi-install-inputs ] || [ "$(cat node_modules/.omi-install-inputs)" != "$npm_inputs" ]; then
  run_step npm ci --no-audit --no-fund
  printf '%s\n' "$npm_inputs" > node_modules/.omi-install-inputs
fi
export PYTHON="$PWD/backend/.venv/bin/python"
PYTHONPATH=scripts/dev-harness run_step "$PYTHON" -m dev_harness.local_mac prepare-emulator
run_step bash scripts/local-mac.sh check
if [[ "$quiet" != true ]]; then echo 'Installation checked. Log: .local/install.log'; fi
