#!/usr/bin/env bash
# Verify a Dev bundle from `make dev`: icon, local channel, Sparkle framework and no update feed.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?usage: $0 <app>}"
plist="$app/Contents/Info.plist"
test "$(plutil -extract CFBundleIconFile raw -o - "$plist")" = HyperMug.icns
test "$(plutil -extract HyperMugReleaseChannel raw -o - "$plist")" = local
test "$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" = 0.1.0
test "$(plutil -extract CFBundleVersion raw -o - "$plist")" = 1
# A bare `! cmd` never trips set -e, so fail explicitly.
if plutil -extract SUFeedURL raw -o - "$plist" >/dev/null 2>&1; then echo 'Dev bundle has an update feed' >&2; exit 1; fi
test -L "$app/Contents/Frameworks/Sparkle.framework/Versions/Current"
test -L "$app/Contents/Frameworks/Sparkle.framework/Sparkle"
test -s "$app/Contents/Resources/HyperMug.icns"
python3 helpers/check-bundle-schema.py "$app"
codesign --verify --deep --strict "$app"
