#!/usr/bin/env bash
# Publish only verified immutable bytes; retry safely after interrupted runs.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
: "${VERSION:?}" "${BUILD_NUMBER:?}" "${GITHUB_SHA:?}" "${GITHUB_REPOSITORY:?}" "${GH_TOKEN:?}" "${APPLE_TEAM_ID:?}" "${RELEASE_NOTES_FILE:?}"
[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || { echo 'SPARKLE_ED_PRIVATE_KEY is required to sign the appcast' >&2; exit 1; }
[[ "$GITHUB_REPOSITORY" == maxmeis/hypermug && "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ && "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid production release identity' >&2; exit 1; }
[[ "$(git rev-parse HEAD)" == "$GITHUB_SHA" ]] || { echo 'Release checkout differs from source commit' >&2; exit 1; }
test -s "$RELEASE_NOTES_FILE"
tag="v$VERSION"; asset="HyperMug-${VERSION}.zip"; local_archive="build/release/$asset"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
. helpers/sparkle.sh
sparkle_prepare
marker="HyperMug $VERSION; source $GITHUB_SHA; build $BUILD_NUMBER"
{ printf '%s\n\n' "$marker"; cat "$RELEASE_NOTES_FILE"; } > "$work/notes.md"

# Use a scoped deploy key for protected main where configured. Otherwise pass
# the token as process-local Git configuration, never as a URL or repository file.
if [[ -n "${HOMEBREW_SSH_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' "$HOMEBREW_SSH_PRIVATE_KEY" > "$work/homebrew-key"
  gh api meta --jq '.ssh_keys[]' | sed 's/^/github.com /' > "$work/known-hosts"
  test -s "$work/known-hosts"
  export GIT_SSH_COMMAND="ssh -F /dev/null -i $work/homebrew-key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$work/known-hosts"
  origin_url="git@github.com:${GITHUB_REPOSITORY}.git"
else
  origin_url="$(git remote get-url origin)"
  export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-0}"
  slot="$GIT_CONFIG_COUNT"
  export GIT_CONFIG_COUNT="$((slot + 1))"
  export "GIT_CONFIG_KEY_${slot}=http.https://github.com/.extraheader"
  export "GIT_CONFIG_VALUE_${slot}=AUTHORIZATION: basic $(printf 'x-access-token:%s' "${HOMEBREW_TOKEN:-$GH_TOKEN}" | base64 | tr -d '\n')"
fi

exists=false
if gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json body >/dev/null 2>&1; then
  exists=true
  body="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json body --jq .body)"
  [[ "$body" == "$marker"$'\n\n'* || "$body" == "HyperMug $VERSION; source $GITHUB_SHA" ]] || { echo 'Existing release belongs to a different source or build' >&2; exit 1; }
  is_draft="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft)"
fi
remote_tag="$(git ls-remote "$origin_url" "refs/tags/$tag^{}" | awk '{print $1}')"
if [[ -z "$remote_tag" ]]; then remote_tag="$(git ls-remote "$origin_url" "refs/tags/$tag" | awk '{print $1}')"; fi
if [[ -n "$remote_tag" ]]; then
  [[ "$remote_tag" == "$GITHUB_SHA" ]] || { echo 'Release tag points to a different commit' >&2; exit 1; }
elif [[ "$exists" == true ]]; then
  echo 'Existing release is missing its source tag' >&2; exit 1
fi
has_archive=false
if [[ "$exists" == true ]] && gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' | grep -Fxq "$asset"; then
  has_archive=true
else
  [[ "$exists" != true || "$is_draft" == true ]] || { echo 'Published release is missing its immutable archive' >&2; exit 1; }
  test -s "$local_archive"
  ./helpers/verify_release_archive.sh "$local_archive" "$VERSION" "$APPLE_TEAM_ID" "$BUILD_NUMBER"
  cp "$local_archive" "$work/$asset"
  preflight_signature="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_ROOT/bin/sign_update" --ed-key-file - -p "$work/$asset")"
  python3 helpers/release_metadata.py appcast --version "$VERSION" --build-number "$BUILD_NUMBER" --zip "$work/$asset" --signature "$preflight_signature" --output "$work/preflight-appcast.xml"
  preflight_digest="$(shasum -a 256 "$work/$asset" | awk '{print $1}')"
  python3 helpers/release_metadata.py cask --version "$VERSION" --zip "$work/$asset" --output "$work/preflight-hypermug.rb"
  ./helpers/validate-cask.sh "$work/preflight-hypermug.rb" "$VERSION" "$preflight_digest"
fi

# No tag or release is created until local final archive verification succeeds.
if [[ -z "$remote_tag" ]]; then
  git tag "$tag" "$GITHUB_SHA"
  git push "$origin_url" "refs/tags/$tag:refs/tags/$tag"
fi
if [[ "$exists" == false ]]; then
  gh release create "$tag" "$work/$asset" --repo "$GITHUB_REPOSITORY" --verify-tag --draft --title "HyperMug $VERSION" --notes-file "$work/notes.md"
  is_draft=true
elif [[ "$has_archive" == false ]]; then
  gh release upload "$tag" "$work/$asset" --repo "$GITHUB_REPOSITORY"
fi

mkdir -p "$work/download"
gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern "$asset" --dir "$work/download"
archive="$work/download/$asset"
test -s "$archive"
./helpers/verify_release_archive.sh "$archive" "$VERSION" "$APPLE_TEAM_ID" "$BUILD_NUMBER"
digest="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$has_archive" == false ]]; then
  [[ "$digest" == "$(shasum -a 256 "$work/$asset" | awk '{print $1}')" ]] || { echo 'Uploaded archive bytes changed' >&2; exit 1; }
fi
printf '%s  %s\n' "$digest" "$asset" > "$work/SHA256SUMS"
python3 helpers/release_metadata.py cask --version "$VERSION" --zip "$archive" --output "$work/hypermug.rb"
[[ "$(sed -n 's/^  sha256 "\([0-9a-f]*\)"$/\1/p' "$work/hypermug.rb")" == "$digest" ]]
ruby -c "$work/hypermug.rb" >/dev/null
./helpers/validate-cask.sh "$work/hypermug.rb" "$VERSION" "$digest"
signature="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_ROOT/bin/sign_update" --ed-key-file - -p "$archive")"
unset SPARKLE_ED_PRIVATE_KEY
python3 helpers/release_metadata.py appcast --version "$VERSION" --build-number "$BUILD_NUMBER" --zip "$archive" --signature "$signature" --output "$work/appcast.xml"

# The checksum must describe the final public ZIP. An existing checksum is
# immutable and checked rather than overwritten.
if gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' | grep -Fxq SHA256SUMS; then
  gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern SHA256SUMS --dir "$work/download"
  cmp -s "$work/SHA256SUMS" "$work/download/SHA256SUMS" || { echo 'Checksum asset differs from immutable archive' >&2; exit 1; }
elif [[ "$is_draft" == true ]]; then
  gh release upload "$tag" "$work/SHA256SUMS" --repo "$GITHUB_REPOSITORY"
else
  echo 'Published release is missing checksum asset' >&2; exit 1
fi
if [[ "$is_draft" == true ]]; then
  latest_tag="$(gh api "repos/$GITHUB_REPOSITORY/releases/latest" --jq .tag_name 2> "$work/latest-error")" || {
    if grep -q 'HTTP 404' "$work/latest-error"; then latest_tag=''; else cat "$work/latest-error" >&2; exit 1; fi
  }
  latest_flag="$(python3 - "$latest_tag" "$VERSION" <<'PY'
import re, sys
latest, candidate = sys.argv[1:]
match = re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', latest)
print('--latest=false' if match and tuple(map(int, match.groups())) > tuple(map(int, candidate.split('.'))) else '--latest')
PY
)"
  gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false "$latest_flag"
fi

# The original 0.3.0 appcast-stable.xml trusts a lost key and stays frozen.
feed="$work/updates"
for attempt in 1 2 3; do
  rm -rf "$feed"; git init -q "$feed"; git -C "$feed" remote add origin "$origin_url"
  if git -C "$feed" ls-remote --exit-code origin refs/heads/updates >/dev/null; then
    git -C "$feed" fetch -q origin updates
    git -C "$feed" checkout -q --detach FETCH_HEAD
  else
    status=$?
    [[ "$status" == 2 ]] || { echo 'Cannot read updates branch' >&2; exit 1; }
  fi
  decision="$(python3 helpers/release_metadata.py feed-decision --current "$feed/appcast.xml" --candidate "$work/appcast.xml")"
  if [[ "$decision" == newer ]]; then echo 'A newer production appcast is already published'; break; fi
  if [[ "$decision" == current ]]; then break; fi
  cp "$work/appcast.xml" "$feed/appcast.xml"
  git -C "$feed" add appcast.xml
  [[ "$(git -C "$feed" diff --cached --name-only)" == appcast.xml ]] || { echo 'Feed commit may only change appcast.xml' >&2; exit 1; }
  git -C "$feed" -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit -qm "chore: update production appcast to $VERSION"
  if git -C "$feed" push origin HEAD:refs/heads/updates; then break; fi
  [[ "$attempt" != 3 ]] || { echo 'Cannot commit appcast to updates' >&2; exit 1; }
done

# Update Homebrew from a scratch clone; never change the running source tree.
tap="$work/tap"
for attempt in 1 2 3; do
  rm -rf "$tap"; git clone -q --single-branch --branch main "$origin_url" "$tap"
  old=''
  if [[ -f "$tap/Casks/hypermug.rb" ]]; then old="$(sed -n 's/^  version "\([0-9.]*\)"$/\1/p' "$tap/Casks/hypermug.rb")"; fi
  decision="$(python3 - "$old" "$VERSION" <<'PY'
import re, sys
old, new = sys.argv[1:]
if old and not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', old):
    raise SystemExit('invalid current cask version')
print('newer' if old and tuple(map(int, old.split('.'))) > tuple(map(int, new.split('.'))) else 'proceed')
PY
)"
  if [[ "$decision" == newer ]]; then echo 'A newer production cask is already published'; exit 0; fi
  if cmp -s "$work/hypermug.rb" "$tap/Casks/hypermug.rb"; then exit 0; fi
  [[ "$old" != "$VERSION" ]] || { echo 'Current cask version has different immutable asset bytes' >&2; exit 1; }
  mkdir -p "$tap/Casks"; cp "$work/hypermug.rb" "$tap/Casks/hypermug.rb"
  ruby -c "$tap/Casks/hypermug.rb" >/dev/null
  git -C "$tap" add Casks/hypermug.rb
  git -C "$tap" -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit -qm "chore: update Homebrew cask to $VERSION [skip release]"
  if git -C "$tap" push origin HEAD:main; then exit 0; fi
  [[ "$attempt" != 3 ]] || { echo 'Cannot commit cask to protected main; check publishing credential and branch rules' >&2; exit 1; }
done
