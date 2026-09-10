#!/usr/bin/env bash
# Retain the familiar Debug entry point with the shared session guard.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/iphone.command" debug "$@"
