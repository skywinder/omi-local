#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mode="${OMI_DOCKER_DEVICE:-auto}"
transport="${OMI_LOCAL_TRANSPORT:-local}"
command="${1:-up}"
[[ $# == 0 ]] || shift
if [[ "$command" == tailscale ]]; then
  transport=tailscale
  command="${1:-up}"
  [[ $# == 0 ]] || shift
fi
files=(-f compose.yaml)
case "$transport" in
  local|ngrok|tailscale) ;;
  *) echo 'OMI_LOCAL_TRANSPORT must be tailscale or ngrok (unset for a local library)' >&2; exit 2 ;;
esac

tailscale_address() {
  local cli="${OMI_TAILSCALE_CLI:-}" status own selected a b c d
  if [[ -z "$cli" ]]; then
    cli=$(command -v tailscale || true)
    if [[ -z "$cli" && -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
      cli=/Applications/Tailscale.app/Contents/MacOS/Tailscale
    fi
  fi
  [[ -n "$cli" ]] || { echo 'Install and connect Tailscale on the Docker host first.' >&2; return 1; }
  status=$("$cli" status --json --peers=false 2>/dev/null) || {
    echo 'Cannot inspect Tailscale on the Docker host.' >&2; return 1;
  }
  # The CLI emits indented JSON. Inspect top-level state and Self, never peers.
  if ! awk '
    /^  "BackendState": "Running",?$/ { running=1 }
    /^  "Self": \{$/ { self=1; next }
    /^  },?$/ { self=0 }
    self && /^    "Online": true,?$/ { online=1 }
    END { exit !(running && online) }
  ' <<< "$status"; then
    echo 'Connect Tailscale on the Docker host before starting phone access.' >&2; return 1
  fi
  own=$("$cli" ip -4 2>/dev/null) || { echo 'Tailscale IPv4 is unavailable.' >&2; return 1; }
  selected="${OMI_TAILSCALE_IP:-$own}"
  if [[ ! "$selected" =~ ^100\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    echo 'OMI_TAILSCALE_IP must be the host Tailscale IPv4 in 100.64.0.0/10.' >&2; return 1
  fi
  IFS=. read -r a b c d <<< "$selected"
  if (( 10#$b < 64 || 10#$b > 127 || 10#$c > 255 || 10#$d > 255 )) || [[ "$selected" != "$own" ]]; then
    echo 'OMI_TAILSCALE_IP must match this Docker host, not the phone or another device.' >&2; return 1
  fi
  export OMI_TAILSCALE_IP="$selected"
}

require_local_docker() {
  local endpoint
  if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
    endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
  elif [[ -n "${DOCKER_HOST:-}" ]]; then
    endpoint="$DOCKER_HOST"
  else
    endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
  fi
  case "$endpoint" in
    unix://*|npipe://*) ;;
    *) echo 'Run Tailscale Docker startup on the Docker host with its local context.' >&2; return 1 ;;
  esac
}

# Diagnostics and shutdown must still work after the host leaves Tailscale.
case "$command" in
  up|dev|config)
    if [[ "$transport" == tailscale ]]; then
      tailscale_address
      require_local_docker
      files+=(-f compose.tailscale.yaml)
    fi ;;
  tunnel)
    [[ "$transport" != tailscale ]] || { echo 'Tailscale connects directly; no ngrok tunnel is needed.' >&2; exit 2; } ;;
esac
case "$mode" in
  auto)
    # Probe the Docker server, not the client machine or an unrelated nvidia-smi.
    runtimes=$(docker info --format '{{json .Runtimes}}')
    if [[ "$runtimes" == *'"nvidia"'* ]]; then mode=cuda; else mode=cpu; fi ;;
  cpu|cuda) ;;
  *) echo 'OMI_DOCKER_DEVICE must be auto, cpu or cuda' >&2; exit 2 ;;
esac
[[ "$mode" != cuda ]] || files+=(-f compose.gpu.yaml)
echo "Docker STT device: $mode"
case "$command" in
  up|dev)
    docker compose "${files[@]}" build app stt download
    docker compose "${files[@]}" run --rm --no-deps download
    if [[ "$transport" == tailscale ]]; then
      # Excluding a Compose profile does not stop an already-running service.
      docker compose "${files[@]}" --profile tunnel stop tunnel
    fi
    if [[ "$command" == dev ]]; then
      exec docker compose "${files[@]}" -f compose.dev.yaml up --watch "$@"
    fi
    exec docker compose "${files[@]}" up -d --wait "$@" ;;
  down) exec docker compose "${files[@]}" --profile tunnel down "$@" ;;
  status) exec docker compose "${files[@]}" --profile tunnel ps "$@" ;;
  logs) exec docker compose "${files[@]}" logs --tail 80 -f "$@" ;;
  config) exec docker compose "${files[@]}" config "$@" ;;
  configure) exec docker compose "${files[@]}" exec app python docker/runtime.py configure ;;
  tunnel) exec docker compose "${files[@]}" --profile tunnel up -d tunnel ;;
  *) echo 'Usage: ./docker.sh [tailscale] [up|dev|down|status|logs|config|configure|tunnel]' >&2; exit 2 ;;
esac
