#!/usr/bin/env bash
# Verify the Developer ID identity, designated requirement, hardened runtime,
# secure timestamp, and entitlements of the main app executable.
set -euo pipefail
app="${1:?app}"; team="${2:?Apple team}"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Invalid Apple Team ID' >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
codesign --verify --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2> "$work/signature.txt"
grep -Fqx "TeamIdentifier=$team" "$work/signature.txt" || { echo 'Unexpected production signing team' >&2; exit 1; }
grep -Eq 'flags=.*\(runtime\)' "$work/signature.txt" || { echo 'Production app lacks hardened runtime' >&2; exit 1; }
grep -Eq '^Timestamp=' "$work/signature.txt" || { echo 'Production app lacks secure timestamp' >&2; exit 1; }
codesign -dr - "$app" > "$work/requirement.txt" 2>&1
grep -Fq 'identifier "com.maxmeis.hypermug"' "$work/requirement.txt" || { echo 'Unexpected production designated identifier' >&2; exit 1; }
grep -Fq 'anchor apple generic' "$work/requirement.txt" || { echo 'Production designated requirement lacks Apple anchor' >&2; exit 1; }
grep -Eq 'certificate leaf\[subject\.OU\] = "?'"$team"'"?' "$work/requirement.txt" || { echo 'Production designated requirement lacks expected team' >&2; exit 1; }
codesign --verify --strict -R="anchor apple generic and identifier \"com.maxmeis.hypermug\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = $team" "$app"
codesign -d --entitlements - --xml "$app" > "$work/entitlements.plist"
if [[ -s "$work/entitlements.plist" ]]; then
  python3 - "$work/entitlements.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as stream:
    entitlements = plistlib.load(stream)
# The app is an unsandboxed Developer ID utility. None of these runtime
# relaxations are needed by its macOS permission or Sparkle integrations.
if entitlements:
    raise SystemExit(f'Unexpected app entitlements: {sorted(entitlements)}')
PY
fi
