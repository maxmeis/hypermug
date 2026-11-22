#!/usr/bin/env bash
set -euo pipefail

app="${1:-build/HyperMug Dev.app}"
id='com.maxmeis.hypermug.dev'
test -d "$app" || { echo "error: app not found: $app" >&2; exit 1; }
actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
[ "$actual" = "$id" ] || { echo "error: expected $id, found $actual" >&2; exit 1; }
if /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist" >/dev/null 2>&1; then
  echo 'error: Dev app must not have an update feed' >&2
  exit 1
fi
identity="$("$(dirname "$0")/dev-signing.sh" identity)"
requirement="identifier \"$id\" and certificate leaf = H\"$identity\""
codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict -R="$requirement" "$app"
designated="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
python3 - "$designated" "$requirement" <<'PY'
import sys
actual, expected = (' '.join(value.split()).casefold() for value in sys.argv[1:])
if actual != expected:
    raise SystemExit('Dev designated requirement is not pinned to the expected identifier and certificate')
PY
framework="$app/Contents/Frameworks/Sparkle.framework"
for nested in \
  "$framework/Versions/B/XPCServices/Installer.xpc" \
  "$framework/Versions/B/XPCServices/Downloader.xpc" \
  "$framework/Versions/B/Autoupdate" \
  "$framework/Versions/B/Updater.app" \
  "$framework"; do
  codesign --verify --strict -R="certificate leaf = H\"$identity\"" "$nested"
done
printf 'designated => %s\n' "$designated"
echo 'Dev signature and designated requirement verified.'
