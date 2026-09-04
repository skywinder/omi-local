#!/usr/bin/env bash
#
# Behavioral test for the ATS policy generate_ios_dev_info_plist.sh writes into
# Info-Dev.plist.
#
# Personal Team offline builds must not grant an application-wide ATS bypass.
# Local HTTP is admitted by the narrow local-network entitlement and then
# restricted to the configured API/Auth authorities by OfflineNetworkPolicy.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/../.."
GENERATOR="${APP_DIR}/scripts/generate_ios_dev_info_plist.sh"

failures=0
pass() { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1" >&2; failures=$((failures + 1)); }

[[ -f "$GENERATOR" ]] || { echo "FAIL: missing $GENERATOR" >&2; exit 1; }

work=$(mktemp -d -t omi_ios_dev_ats_XXXXXX)
cat > "$work/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Runner</string>
</dict>
</plist>
PLIST

bash "$GENERATOR" "$work/Info.plist" "$work/Info-Dev.plist" >/dev/null 2>&1

echo "generate_ios_dev_info_plist.sh ATS output:"

if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$work/Info-Dev.plist" 2>/dev/null; then
  fail "output declares forbidden NSAllowsArbitraryLoads"
else
  pass "output does not declare NSAllowsArbitraryLoads"
fi

if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsLocalNetworking' "$work/Info-Dev.plist" 2>/dev/null | grep -qi true; then
  pass "output declares NSAllowsLocalNetworking=true"
else
  fail "output is missing NSAllowsLocalNetworking=true"
fi

rm -rf "$work"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "$failures shell test(s) failed" >&2
  exit 1
fi
echo "all iOS dev ATS config shell tests passed"
