#!/usr/bin/env bash
# Check a production bundle's updater: feed keys, framework symlinks, and every
# nested Sparkle component signed by the release team with hardened runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?app}"; team="${2:?Apple team}"
plist="$app/Contents/Info.plist"
value() { plutil -extract "$1" raw -o - "$plist"; }
[[ "$(value SUFeedURL)" == https://raw.githubusercontent.com/maxmeis/hypermug/updates/appcast.xml ]] || { echo 'Unexpected SUFeedURL' >&2; exit 1; }
[[ "$(value SUPublicEDKey)" == "$(plutil -extract SUPublicEDKey raw -o - Source/HyperMug/Info.plist)" ]] || { echo 'SUPublicEDKey differs from the source template' >&2; exit 1; }
[[ "$(value SUEnableAutomaticChecks)" == true && "$(value SUVerifyUpdateBeforeExtraction)" == true ]] || { echo 'Sparkle checks are not enabled' >&2; exit 1; }
[[ "$(value SUScheduledCheckInterval)" == 86400 ]] || { echo 'Sparkle must check daily' >&2; exit 1; }
framework="$app/Contents/Frameworks/Sparkle.framework"
for link in Versions/Current Sparkle Resources XPCServices Autoupdate Updater.app; do
  test -L "$framework/$link" || { echo "Sparkle.framework/$link is not a symlink" >&2; exit 1; }
done
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
version="$framework/Versions/B"
for code in "$version/XPCServices/Installer.xpc" "$version/XPCServices/Downloader.xpc" "$version/Autoupdate" "$version/Updater.app" "$framework"; do
  codesign --verify --strict --verbose=2 "$code"
  codesign --verify --strict -R="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = $team" "$code"
  codesign -dv --verbose=4 "$code" 2> "$work/signature.txt"
  grep -Fqx "TeamIdentifier=$team" "$work/signature.txt" || { echo "Unexpected signing team: $code" >&2; exit 1; }
  grep -Eq 'flags=.*\(runtime\)' "$work/signature.txt" || { echo "Missing hardened runtime: $code" >&2; exit 1; }
  grep -Eq '^Timestamp=' "$work/signature.txt" || { echo "Missing secure timestamp: $code" >&2; exit 1; }
  codesign -d --entitlements - --xml "$code" > "$work/entitlements.plist"
  if [[ -s "$work/entitlements.plist" ]]; then
    python3 - "$work/entitlements.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as stream:
    entitlements = plistlib.load(stream)
if entitlements.get('com.apple.security.get-task-allow') is True:
    raise SystemExit('Sparkle component has a development-only get-task-allow entitlement')
PY
  fi
done
