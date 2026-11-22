#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./helpers/check-layers.sh
. helpers/swift-env.sh
. helpers/sparkle.sh
sparkle_prepare

RELEASE="${REQUIRE_SIGNING:-0}"
VARIANT="${APP_VARIANT:-dev}"
BUILD_ROOT="${BUILD_ROOT:-build}"
if [ "$RELEASE" = 1 ]; then VARIANT=production; fi
case "$VARIANT" in
  dev)
    APP="$BUILD_ROOT/HyperMug Dev.app"
    CORE="$BUILD_ROOT/core-dev"
    APP_NAME="HyperMug Dev"
    BUNDLE_ID=com.maxmeis.hypermug.dev
    SWIFT_BASE_FLAGS+=(-D HYPERMUG_DEV)
    ;;
  production)
    APP="$BUILD_ROOT/HyperMug.app"
    CORE="$BUILD_ROOT/core"
    APP_NAME=HyperMug
    BUNDLE_ID=com.maxmeis.hypermug
    ;;
  *) echo "error: APP_VARIANT must be dev or production" >&2; exit 1;;
esac
VERSION="${APP_VERSION:-0.1.0}"
NUMBER="${BUILD_NUMBER:-1}"
CHANNEL_META="${RELEASE_CHANNEL:-local}"
# Only production bundles get a feed; Dev and local test builds never check for updates.
FEED="https://raw.githubusercontent.com/maxmeis/hypermug/updates/appcast.xml"
if [ "$VARIANT" = dev ]; then CHANNEL_META=local; fi
case "$CHANNEL_META" in local|production) ;; *) echo "error: invalid RELEASE_CHANNEL" >&2; exit 1;; esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: invalid APP_VERSION" >&2; exit 1; }
[[ "$NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "error: invalid BUILD_NUMBER" >&2; exit 1; }
if [ "$RELEASE" = 1 ]; then
  [ "$VARIANT" = production ] && [ "$CHANNEL_META" = production ] || { echo "error: release requires production variant" >&2; exit 1; }
  [[ "${SIGN_ID:-}" == Developer\ ID\ Application:* ]] || { echo "error: release requires SIGN_ID=Developer ID Application: ..." >&2; exit 1; }
  security find-identity -v -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} | grep -Fq "\"$SIGN_ID\"" || { echo "error: Developer ID identity unavailable" >&2; exit 1; }
fi
if [ "$VARIANT" = dev ] && [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID="$(./helpers/dev-signing.sh identity)"
  DEV_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SIGN_ID\""
fi
SIGN_ID="${SIGN_ID:--}"
if [ "$SIGN_ID" != - ]; then
  if [[ "$SIGN_ID" =~ ^[[:xdigit:]]{40}$ ]]; then
    security find-identity -v -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} | grep -Fq "$SIGN_ID" || { echo "error: signing identity $SIGN_ID not found." >&2; exit 1; }
  else
    security find-identity -v -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} | grep -Fq "\"$SIGN_ID\"" || { echo "error: signing identity $SIGN_ID not found." >&2; exit 1; }
  fi
fi
rm -rf "$APP" "$CORE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp Source/Branding/HyperMug.icns "$APP/Contents/Resources/HyperMug.icns"
compile_core_module "$CORE"
# Generate the editor schema from the exact same model/variant as the app, before signing.
swiftc -O -parse-as-library "${SWIFT_BASE_FLAGS[@]}" -I "$CORE" \
  helpers/schema-main.swift "$CORE/HyperMugCore.o" -o "$CORE/render-schema"
"$CORE/render-schema" "$APP/Contents/Resources"
swiftc -O -parse-as-library "${SWIFT_BASE_FLAGS[@]}" -module-name HyperMug \
  -I "$CORE" -F "$SPARKLE_FRAMEWORK_DIR" Source/HyperMug/Sources/Platform/*.swift Source/HyperMug/Sources/App/*.swift "$CORE/HyperMugCore.o" \
  -o "$APP/Contents/MacOS/HyperMug" -framework IOKit -framework Carbon -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks
# ditto keeps the framework's Versions/Current symlinks intact.
ditto "$SPARKLE_FRAMEWORK_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Source/HyperMug/Info.plist "$APP/Contents/"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NUMBER" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :HyperMugReleaseChannel $CHANNEL_META" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$PLIST"
if [ "$VARIANT" = production ] && [ "$CHANNEL_META" = production ]; then
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED" "$PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED" "$PLIST"
else
  /usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' "$PLIST" 2>/dev/null || true
fi
KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST")"
[[ "$KEY" =~ ^[A-Za-z0-9+/]{43}=$ && "$(printf '%s' "$KEY" | base64 -D | wc -c | tr -d ' ')" = 32 ]] || { echo "error: SUPublicEDKey must be a 32-byte base64 Ed25519 key" >&2; exit 1; }
SIGN_OPTIONS=(--force --sign "$SIGN_ID")
if [ "$RELEASE" = 1 ]; then SIGN_OPTIONS+=(--options runtime --timestamp); fi
if [ -n "${SIGN_KEYCHAIN:-}" ]; then SIGN_OPTIONS+=(--keychain "$SIGN_KEYCHAIN"); fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
VERSION_DIR="$FRAMEWORK/Versions/B"
# Re-sign Sparkle's nested code inside-out with this identity. Never use --deep:
# the Downloader service carries its own entitlements.
for nested in "$VERSION_DIR/XPCServices/Installer.xpc" "$VERSION_DIR/XPCServices/Downloader.xpc" "$VERSION_DIR/Autoupdate" "$VERSION_DIR/Updater.app"; do
  test -e "$nested" || { echo "error: Sparkle component missing: $nested" >&2; exit 1; }
  if [[ "$nested" == *Downloader.xpc ]]; then
    codesign "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$nested"
  else
    codesign "${SIGN_OPTIONS[@]}" "$nested"
  fi
done
codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK"
if [ -n "${DEV_REQUIREMENT:-}" ]; then
  codesign "${SIGN_OPTIONS[@]}" --identifier "$BUNDLE_ID" --requirements "$DEV_REQUIREMENT" "$APP"
else
  codesign "${SIGN_OPTIONS[@]}" --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
if [ -n "${DEV_REQUIREMENT:-}" ]; then
  codesign --verify --strict -R="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SIGN_ID\"" "$APP"
fi
echo "Built: $APP"
