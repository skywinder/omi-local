#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo=${1:?Pass the local BasedHardware/omi clone}
app="$(python3 "$here/prepare.py" "$repo" --source-only)"
cd "$app"
expected="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["flutter"])' "$here/upstream.json")"
actual="$(flutter --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')"
if [[ "$actual" != "$expected" ]]; then
  echo "Omi Local Next requires Flutter $expected; found $actual" >&2
  exit 1
fi
flutter pub get --enforce-lockfile
flutter analyze --no-pub lib/main_local_next.dart lib/local_next test/local_next
flutter test --no-pub test/local_next
