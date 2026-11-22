#!/usr/bin/env bash
# Build the exact production source, sign with an ephemeral CI keychain, and notarize.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?}" "${GITHUB_SHA:?}" "${GITHUB_REPOSITORY:?}" "${SIGN_ID:?}" "${DEVELOPER_ID_P12_BASE64:?}" "${DEVELOPER_ID_P12_PASSWORD:?}" "${APPLE_TEAM_ID:?}"
[[ "$GITHUB_REPOSITORY" == maxmeis/hypermug && "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo 'Invalid release repository or version' >&2; exit 1; }
[[ "$(git rev-parse HEAD)" == "$GITHUB_SHA" ]] || { echo 'Release checkout differs from the push commit' >&2; exit 1; }
[[ "$SIGN_ID" == 'Developer ID Application: '* ]] || { echo 'Production requires a Developer ID Application identity' >&2; exit 1; }
. helpers/notary_auth.sh
umask 077
work="$(mktemp -d)"
keychain="$work/release.keychain-db"
created=false
cleanup() {
  local status="$?"
  trap - EXIT INT TERM
  if [[ "$created" == true ]]; then
    if ! security delete-keychain "$keychain" >/dev/null; then
      echo 'Could not delete the temporary release keychain' >&2
      status=1
    fi
  fi
  rm -rf "$work" || status=1
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
password="$(openssl rand -hex 32)"
security create-keychain -p "$password" "$keychain"
created=true
security unlock-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 -D > "$work/certificate.p12"
security import "$work/certificate.p12" -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain"
security find-identity -v -p codesigning "$keychain" | grep -Fq "\"$SIGN_ID\"" || { echo 'Developer ID signing identity missing from imported certificate' >&2; exit 1; }
configure_notary_auth "$work"
REQUIRE_SIGNING=1 APP_VARIANT=production APP_VERSION="$VERSION" BUILD_NUMBER="$VERSION" RELEASE_CHANNEL=production SIGN_KEYCHAIN="$keychain" make build
app=build/HyperMug.app
plist="$app/Contents/Info.plist"
python3 helpers/check-bundle-schema.py "$app"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" == "$VERSION" ]]
[[ "$(plutil -extract CFBundleVersion raw -o - "$plist")" == "$VERSION" ]]
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" == com.maxmeis.hypermug ]]
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2> "$work/signature.txt"
grep -Fqx "TeamIdentifier=$APPLE_TEAM_ID" "$work/signature.txt" || { echo 'Signed app has unexpected Apple Team ID' >&2; exit 1; }
grep -Eq 'flags=.*\(runtime\)' "$work/signature.txt" || { echo 'Signed app lacks hardened runtime' >&2; exit 1; }
grep -Eq '^Timestamp=' "$work/signature.txt" || { echo 'Signed app lacks secure timestamp' >&2; exit 1; }
./helpers/verify_sparkle_bundle.sh "$app" "$APPLE_TEAM_ID"
mkdir -p build/release
submission="$work/for-notary.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$submission"
submit_for_notarization "$submission" > "$work/notary-result.json"
python3 - "$work/notary-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1], encoding='utf-8'))
if result.get('status') != 'Accepted':
    raise SystemExit(f"Notarization was not accepted: {result.get('status')}")
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict --verbose=2 "$app"
spctl --assess --type execute --verbose=4 "$app"
archive="build/release/HyperMug-${VERSION}.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
shasum -a 256 "$archive" | awk '{print $1}' > build/release/sha256.txt
python3 helpers/release_metadata.py cask --version "$VERSION" --zip "$archive" --output build/release/hypermug.rb
