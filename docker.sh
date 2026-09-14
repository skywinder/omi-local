#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mode="${OMI_DOCKER_DEVICE:-auto}"
command="${1:-up}"
[[ $# == 0 ]] || shift
files=(-f compose.yaml)
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
    if [[ "$command" == dev ]]; then
      exec docker compose "${files[@]}" -f compose.dev.yaml up --watch "$@"
    fi
    exec docker compose "${files[@]}" up -d --wait "$@" ;;
  down) exec docker compose "${files[@]}" --profile tunnel down "$@" ;;
  status) exec docker compose "${files[@]}" --profile tunnel ps "$@" ;;
  logs) exec docker compose "${files[@]}" logs --tail 80 -f "$@" ;;
  configure) exec docker compose "${files[@]}" exec app python docker/runtime.py configure ;;
  tunnel) exec docker compose "${files[@]}" --profile tunnel up -d tunnel ;;
  *) echo 'Usage: ./docker.sh [up|dev|down|status|logs|configure|tunnel]' >&2; exit 2 ;;
esac
