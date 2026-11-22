#!/usr/bin/env bash
# Verify the downloaded bytes that Homebrew will install.
set -euo pipefail
cd "$(dirname "$0")/.."
archive="${1:?archive}"; version="${2:?version}"; team="${3:?Apple team}"; build="${4:?build number}"
[[ "$archive" = /* ]] || archive="$PWD/$archive"
test -s "$archive"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$archive" "$work"
app="$work/HyperMug.app"
test -d "$app"
plist="$app/Contents/Info.plist"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" == "$version" ]]
[[ "$(plutil -extract CFBundleVersion raw -o - "$plist")" == "$build" ]]
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" == com.maxmeis.hypermug ]]
python3 helpers/check-bundle-schema.py "$app"
codesign --verify --deep --strict --verbose=2 "$app"
./helpers/verify_production_signature.sh "$app" "$team"
./helpers/verify_sparkle_bundle.sh "$app" "$team"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"
