#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/omi-mobile-wrapper.XXXXXX")"
trap 'find "$fixture_dir" -depth -delete' EXIT

mkdir -p "$fixture_dir/scripts" "$fixture_dir/ios/Runner"
cp "$ROOT_DIR/setup.sh" "$fixture_dir/setup.sh"
cp "$ROOT_DIR/scripts/validate_mobile_build_config.sh" "$fixture_dir/scripts/validate_mobile_build_config.sh"
# Like Flutter and CocoaPods below, the native overlay is outside this wrapper
# contract. A fresh checkout has no generated iOS registrant to copy.
cat >"$fixture_dir/scripts/apply_personal_ios_plugin_overlay.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'native-plugin-overlay\n' >>flutter.log
SH
chmod +x "$fixture_dir/scripts/validate_mobile_build_config.sh"

log_file="$fixture_dir/flutter.log"
(
  cd "$fixture_dir"
  export OMI_DEV_HOST=192.168.1.50
  source ./setup.sh >/dev/null

  flutter() {
    {
      printf 'flutter'
      printf ' %s' "$@"
      printf '\n'
    } >>"$log_file"
  }
  pod() {
    {
      printf 'pod'
      printf ' %s' "$@"
      printf '\n'
    } >>"$log_file"
  }
  dart() {
    {
      printf 'dart'
      printf ' %s' "$@"
      printf '\n'
    } >>"$log_file"
  }
  check_ios_prerequisites() { :; }
  select_ios_device() { printf 'TEST-DEVICE\n'; }
  _ios_device_is_physical() { :; }
  _ios_device_is_iphone_17_pro() { :; }
  prepare_personal_ios_build_dir() { :; }

  OMI_APPLE_TEAM_ID=ABCDEFGHIJ OMI_RUNTIME_MODE=offline run_build_ios dev
  grep -Fx 'native-plugin-overlay' "$log_file" >/dev/null
  grep -F 'flutter run --profile --flavor dev -d TEST-DEVICE --dart-define=OMI_APP_PROFILE=local_dev --dart-define=OMI_RUNTIME_MODE=offline --dart-define=OMI_LOCAL_TEST_USER=alice' "$log_file" >/dev/null
  [[ "$(grep -F 'OMI_APP_PROFILE=local_dev' "$log_file" | tr ' ' '\n' | grep -c '^--dart-define=OMI_APP_PROFILE=')" == 1 ]]
  [[ "$(grep -F 'OMI_RUNTIME_MODE=offline' "$log_file" | tr ' ' '\n' | grep -c '^--dart-define=OMI_RUNTIME_MODE=')" == 1 ]]

  _ios_device_is_iphone_17_pro() { return 1; }
  if OMI_APPLE_TEAM_ID=ABCDEFGHIJ OMI_RUNTIME_MODE=offline run_build_ios dev 2>"$fixture_dir/wrong-device.err"; then
    echo 'FAIL: wrapper accepted an iOS device other than iPhone 17 Pro' >&2
    exit 1
  fi
  grep -F 'only on the connected physical iPhone 17 Pro' "$fixture_dir/wrong-device.err" >/dev/null
  _ios_device_is_iphone_17_pro() { :; }

  unset OMI_DEV_HOST
  if OMI_APPLE_TEAM_ID=ABCDEFGHIJ OMI_RUNTIME_MODE=offline run_build_ios dev 2>"$fixture_dir/missing-host.err"; then
    echo 'FAIL: wrapper accepted a physical-device build without OMI_DEV_HOST' >&2
    exit 1
  fi
  grep -F 'set OMI_DEV_HOST' "$fixture_dir/missing-host.err" >/dev/null
  export OMI_DEV_HOST=192.168.1.50

  if OMI_APPLE_TEAM_ID=ABCDEFGHIJ OMI_RUNTIME_MODE=offline run_build_ios prod; then
    echo 'FAIL: wrapper accepted a production iOS build' >&2
    exit 1
  fi

  if OMI_APPLE_TEAM_ID=ABCDEFGHIJ OMI_RUNTIME_MODE=standard run_build_ios dev; then
    echo 'FAIL: wrapper accepted a non-offline iOS build' >&2
    exit 1
  fi
)

echo 'Personal Team wrapper injects the offline profile and rejects non-offline iOS builds'
