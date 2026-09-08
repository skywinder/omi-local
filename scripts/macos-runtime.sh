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
