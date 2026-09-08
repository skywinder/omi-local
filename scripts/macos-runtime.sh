#!/usr/bin/env bash
# Re-enter the same command natively when Terminal runs under Rosetta.
omi_require_apple_silicon() {
  if [[ "$(uname -s)" == Darwin ]]; then
    case "$(uname -m)" in
      arm64) return 0 ;;
      x86_64)
        if [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null)" == 1 ]]; then
          exec /usr/bin/arch -arm64 /bin/bash "$@"
        fi
        ;;
    esac
  fi
  echo 'Этот запуск рассчитан на Mac с Apple Silicon.' >&2
  return 1
}

# Prefer the native default installation, otherwise use the brew on PATH.
omi_macos_path() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
  fi
  local brew_prefix
  if command -v brew >/dev/null 2>&1; then
    brew_prefix=$(brew --prefix) || return 1
    export PATH="$PWD/node_modules/.bin:$brew_prefix/opt/node@22/bin:$brew_prefix/opt/openjdk@21/bin:$brew_prefix/bin:$PATH"
  else
    export PATH="$PWD/node_modules/.bin:$PATH"
  fi
}
