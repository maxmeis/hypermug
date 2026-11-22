#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
repo="$PWD"
mode="${1:---report}"
case "$mode" in
  --report)
    [[ $# -le 2 ]] || { echo 'usage: helpers/check-permissions.sh --report [app.bundle]' >&2; exit 2; }
    build_root="${BUILD_ROOT:-build}"
    [[ "$build_root" = /* ]] || build_root="$repo/$build_root"
    app="${2:-$build_root/HyperMug Dev.app}"
    ;;
  --verify-dev-rebuilds)
    [[ $# -eq 1 ]] || { echo 'usage: helpers/check-permissions.sh --verify-dev-rebuilds' >&2; exit 2; }
    [[ ! -L "$repo/build" ]] || { echo 'Refusing to rebuild through a symlinked build directory.' >&2; exit 1; }
    app="$repo/build/HyperMug Dev.app"
    ;;
  *) echo 'usage: helpers/check-permissions.sh [--report [app.bundle] | --verify-dev-rebuilds]' >&2; exit 2;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

check_bundle() {
  local identifier marker
  [[ -d "$app" ]] || { echo "App bundle does not exist: $app" >&2; exit 1; }
  marker="$(/usr/libexec/PlistBuddy -c 'Print :HyperMugPermissionDiagnosticsVersion' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$marker" = 1 ]] || { echo 'This app does not advertise the safe permission diagnostic; refusing to launch it.' >&2; exit 1; }
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
  case "$identifier" in
    com.maxmeis.hypermug|com.maxmeis.hypermug.dev) ;;
    *) echo "Unexpected app bundle identifier: $identifier" >&2; exit 1;;
  esac
  if [[ "$mode" = --verify-dev-rebuilds && "$identifier" != com.maxmeis.hypermug.dev ]]; then
    echo 'Rebuild verification is restricted to the development bundle.' >&2
    exit 1
  fi
  codesign --verify --deep --strict "$app"
}

signature() {
  local details requirement
  details="$(codesign -dv --verbose=4 "$app" 2>&1)"
  requirement="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
  if [[ -z "$requirement" ]]; then
    [[ "$mode" = --report ]] || { echo 'No designated signing requirement found.' >&2; exit 1; }
    requirement='none (ad-hoc build; permission persistence is not established)'
  fi
  printf '%s\n' "$requirement" > "$tmp/requirement.$1"
  printf '%s\n' "$details" | sed -n 's/^CDHash=//p' > "$tmp/cdhash.$1"
  [[ -s "$tmp/cdhash.$1" ]] || { echo 'No CDHash found.' >&2; exit 1; }
  printf 'Signing requirement: %s\nCDHash: %s\n' "$requirement" "$(cat "$tmp/cdhash.$1")"
}

diagnose() {
  local label="$1"
  : > "$tmp/$label.stdout"
  : > "$tmp/$label.stderr"
  # LaunchServices starts the bundle itself, so TCC checks its identity rather than Terminal's.
  /usr/bin/open -n -W --stdout "$tmp/$label.stdout" --stderr "$tmp/$label.stderr" "$app" --args --diagnose-permissions || {
    cat "$tmp/$label.stderr" >&2
    echo 'LaunchServices permission diagnostic failed.' >&2
    exit 1
  }
  /usr/bin/python3 - "$tmp/$label.stdout" "$app" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding='utf-8') as stream:
    data = json.load(stream)
required = {'bundleIdentifier', 'bundlePath', 'executablePath',
            'accessibilityGranted', 'screenRecordingGranted', 'inputMonitoring'}
if not required.issubset(data) or os.path.realpath(data['bundlePath']) != os.path.realpath(sys.argv[2]):
    raise SystemExit('Diagnostic did not run from the requested app bundle.')
if not isinstance(data['accessibilityGranted'], bool) or not isinstance(data['screenRecordingGranted'], bool):
    raise SystemExit('Invalid permission diagnostic result.')
if data['inputMonitoring'] not in ('granted', 'denied', 'unknown'):
    raise SystemExit('Invalid Input Monitoring state.')
print(json.dumps(data, indent=2, sort_keys=True))
PY
  cp "$tmp/$label.stdout" "$tmp/$label.json"
}

if [[ "$mode" = --report ]]; then
  check_bundle
  signature report
  diagnose report
  exit 0
fi

# This mode intentionally rebuilds only the known Dev bundle in this checkout.
build_number="$(date +%s)"
make dev BUILD_ROOT=build BUILD_NUMBER="$build_number"
check_bundle
signature first
grep -Eq 'certificate leaf = H"[[:xdigit:]]{40}"' "$tmp/requirement.first" || {
  echo 'FAILED: Dev signing requirement does not bind the signing certificate.' >&2
  exit 1
}
diagnose first
make dev BUILD_ROOT=build BUILD_NUMBER="$((build_number + 1))"
check_bundle
signature second
diagnose second

cmp -s "$tmp/requirement.first" "$tmp/requirement.second" || {
  echo 'FAILED: designated signing requirement changed between builds.' >&2
  exit 1
}
cmp -s "$tmp/cdhash.first" "$tmp/cdhash.second" && {
  echo 'FAILED: signed bytes did not change between builds.' >&2
  exit 1
}

/usr/bin/python3 - "$tmp/first.json" "$tmp/second.json" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding='utf-8') as stream:
    first = json.load(stream)
with open(sys.argv[2], encoding='utf-8') as stream:
    second = json.load(stream)
for key in ('bundleIdentifier', 'bundlePath', 'executablePath'):
    if os.path.realpath(first[key]) != os.path.realpath(second[key]):
        raise SystemExit(f'FAILED: {key} changed between builds.')
if first['bundleIdentifier'] != 'com.maxmeis.hypermug.dev':
    raise SystemExit('FAILED: rebuild test did not run the Dev app.')
print('PASS: same Dev bundle, executable path, signing requirement; changed CDHash.')
lost = False
for label, key in (('Accessibility', 'accessibilityGranted'),
                   ('Screen Recording', 'screenRecordingGranted')):
    if not first[key]:
        print(f'NOT VERIFIED: {label} was not granted in the first build.')
    elif second[key]:
        print(f'PASS: {label} grant persisted across rebuild.')
    else:
        print(f'FAILED: {label} grant was lost across rebuild.')
        lost = True
if first['inputMonitoring'] != 'granted':
    print('NOT VERIFIED: Input Monitoring was not granted in the first build.')
elif second['inputMonitoring'] == 'granted':
    print('PASS: Input Monitoring grant persisted across rebuild.')
else:
    print('FAILED: Input Monitoring grant was lost across rebuild.')
    lost = True
sys.exit(1 if lost else 0)
PY
