#!/usr/bin/env bash
# Woodpecker steps of the Production release. Each phase is one step of .woodpecker/release.yaml;
# they share the workspace, so the selected version and reuse decision travel in build/woodpecker/.
#
#   helpers/woodpecker-release.sh version   select the version and create its immutable source tag
#   helpers/woodpecker-release.sh existing  reuse and verify an archive an earlier attempt published
#   helpers/woodpecker-release.sh build     build, sign and notarize unless the archive is reused
#   helpers/woodpecker-release.sh publish   publish the release, Sparkle appcast and Homebrew cask
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CI_PIPELINE_EVENT:?}" "${CI_COMMIT_BRANCH:?}" "${CI_COMMIT_SHA:?}" "${CI_REPO:?}" "${CI_PIPELINE_NUMBER:?}"
[[ "$CI_PIPELINE_EVENT" == push && "$CI_COMMIT_BRANCH" == main && "$CI_REPO" == maxmeis/hypermug ]] ||
  { echo 'Production releases run only for pushes to maxmeis/hypermug main' >&2; exit 1; }
# The release helpers keep their GitHub Actions variable names.
export GITHUB_SHA="$CI_COMMIT_SHA" GITHUB_REPOSITORY="$CI_REPO"
# GitHub Actions run numbers 1-3 published v0.3.1-v0.3.3; Woodpecker pipeline N releases v0.3.(N+3).
RUN_NUMBER_OFFSET=3
state=build/woodpecker
mkdir -p "$state"

release_version() { cat "$state/version"; }

case "${1:-}" in
  version)
    test "$(git rev-parse HEAD)" = "$GITHUB_SHA"
    for name in GH_TOKEN APPLE_TEAM_ID SIGN_ID DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD \
      APP_STORE_CONNECT_PRIVATE_KEY APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID \
      HOMEBREW_SSH_PRIVATE_KEY SPARKLE_ED_PRIVATE_KEY; do
      if [[ -z "${!name:-}" ]]; then
        echo "Release preflight requires $name" >&2
        exit 1
      fi
    done
    PYTHONPATH=helpers python3 - <<'KEY_CHECK'
import base64
import binascii
import os
import plistlib

from ed25519 import public_key

try:
    seed = base64.b64decode(os.environ["SPARKLE_ED_PRIVATE_KEY"], validate=True)
except binascii.Error:
    raise SystemExit("Release preflight requires a base64 Sparkle Ed25519 seed") from None
if len(seed) != 32:
    raise SystemExit("Release preflight requires a 32-byte Sparkle Ed25519 seed")
with open("Source/HyperMug/Info.plist", "rb") as plist:
    expected = plistlib.load(plist)["SUPublicEDKey"]
if base64.b64encode(public_key(seed)).decode("ascii") != expected:
    raise SystemExit("Release preflight: Sparkle key does not match the app's SUPublicEDKey")
KEY_CHECK
    if [[ "$(gh api "repos/$GITHUB_REPOSITORY" --jq '.permissions.push')" != true ]]; then
      echo 'Release preflight requires a GitHub token with repository write access' >&2
      exit 1
    fi
    if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then git fetch -q --unshallow origin; fi
    git fetch -q origin --tags --force
    tags="$state/production-tags"
    : > "$tags"
    run_number="$((CI_PIPELINE_NUMBER + RUN_NUMBER_OFFSET))"
    while IFS= read -r tag; do
      sha="$(git rev-parse "${tag}^{commit}")"
      printf '%s %s\n' "$tag" "$sha" >> "$tags"
      # A restarted Woodpecker pipeline gets a new number; keep the version of this source's tag.
      if [[ "$sha" == "$GITHUB_SHA" && "$tag" =~ ^v0\.3\.([1-9][0-9]*)$ ]]; then run_number="${BASH_REMATCH[1]}"; fi
    done < <(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sort -V)
    version="$(python3 helpers/release_metadata.py version --tags "$tags" --source-sha "$GITHUB_SHA" --run-number "$run_number")"
    tag="v$version"
    if ! git show-ref --verify --quiet "refs/tags/$tag"; then
      object="$(gh api -X POST "repos/$GITHUB_REPOSITORY/git/tags" -f tag="$tag" -f message="HyperMug $version; source $GITHUB_SHA" -f object="$GITHUB_SHA" -f type=commit --jq .sha)"
      gh api -X POST "repos/$GITHUB_REPOSITORY/git/refs" -f ref="refs/tags/$tag" -f sha="$object" >/dev/null
      git fetch -q origin "refs/tags/$tag:refs/tags/$tag"
    fi
    test "$(git rev-parse "${tag}^{commit}")" = "$GITHUB_SHA"
    printf '%s\n' "$version" > "$state/version"
    echo "Releasing HyperMug $version"
    ;;
  existing)
    : "${GH_TOKEN:?}" "${APPLE_TEAM_ID:?}"
    version="$(release_version)"
    tag="v$version"
    asset="HyperMug-$version.zip"
    echo false > "$state/reuse"
    if gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json body >/dev/null 2>&1; then
      body="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json body --jq .body)"
      test "$body" = "HyperMug $version; source $GITHUB_SHA"
      draft="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft)"
      if gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' | grep -Fxq "$asset"; then
        mkdir -p build/release
        gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern "$asset" --dir build/release --clobber
        ./helpers/verify_release_archive.sh "build/release/$asset" "$version" "$APPLE_TEAM_ID"
        echo true > "$state/reuse"
      elif test "$draft" = false; then
        echo 'Published release has no immutable app archive' >&2
        exit 1
      fi
    fi
    ;;
  build)
    if [[ "$(cat "$state/reuse")" == true ]]; then echo 'Reusing the verified published archive'; exit 0; fi
    VERSION="$(release_version)" ./helpers/release.sh
    ;;
  publish)
    VERSION="$(release_version)" ./helpers/publish_release.sh
    ;;
  *)
    echo "usage: $0 version|existing|build|publish" >&2
    exit 2
    ;;
esac
