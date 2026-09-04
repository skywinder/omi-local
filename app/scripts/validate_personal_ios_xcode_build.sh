#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: Personal Team overlay build refused: $1" >&2
  exit 1
}

[[ "${CONFIGURATION:-}" == *-dev ]] || fail "only the dev flavor is available (got '${CONFIGURATION:-<unset>}')."
[[ "${OMI_PERSONAL_LOCAL:-}" == 'YES' ]] || fail "run 'bash setup.sh ios personal' before building."
[[ "${OMI_RUNTIME_MODE:-}" == 'offline' ]] || fail "OMI_RUNTIME_MODE must be offline."
[[ "${DEVELOPMENT_TEAM:-}" =~ ^[A-Z0-9]{10}$ ]] || fail "a valid OMI_APPLE_TEAM_ID is required."
[[ -n "${PRODUCT_BUNDLE_IDENTIFIER:-}" ]] || fail "the bundle identifier is missing."

registrant="${SRCROOT:-$(cd "$(dirname "$0")/../ios" && pwd)}/Runner/GeneratedPluginRegistrant.m"
grep -q 'OMI_PERSONAL_EXTERNAL_PLUGINS_DISABLED' "$registrant" \
  || fail "the generated plugin registrant lost the Personal Team cloud-plugin guard; rerun or restore the overlay."
ruby -e '
  text = File.read(ARGV.fetch(0))
  %w[FLTFirebaseCrashlyticsPlugin FLTFirebaseMessagingPlugin FLTGoogleSignInPlugin IntercomFlutterPlugin PosthogFlutterPlugin SignInWithApplePlugin].each do |plugin|
    registration = text.index("[#{plugin} registerWithRegistrar") or abort "plugin registration missing: #{plugin}"
    guard = text.rindex("#if !OMI_PERSONAL_LOCAL", registration) or abort "plugin guard missing: #{plugin}"
    close = text.index("#endif", guard) or abort "plugin guard not closed: #{plugin}"
    abort "plugin registration outside guard: #{plugin}" unless registration < close
  end
' "$registrant" || fail "the generated plugin registrant has an incomplete cloud-plugin guard."

case "${PRODUCT_BUNDLE_IDENTIFIER}" in
  com.friend-app-with-wearable.ios12|com.friend-app-with-wearable.ios12.*)
    fail "the upstream bundle namespace is forbidden."
    ;;
esac

echo "Personal Team offline build policy valid for ${CONFIGURATION}."
