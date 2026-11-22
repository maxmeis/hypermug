#!/usr/bin/env bash
# Publish Source/Website to the gh-pages branch, which GitHub Pages serves ("Deploy from a branch",
# gh-pages, /). The token stays process-local, never in Git remotes or on disk.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CI_REPO:?}" "${CI_COMMIT_SHA:?}" "${GH_TOKEN:?}"
[[ "$CI_REPO" == maxmeis/hypermug ]] || { echo 'The website deploys only from maxmeis/hypermug' >&2; exit 1; }
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
export GIT_CONFIG_VALUE_0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
site="$work/site"
git init -q "$site"
git -C "$site" remote add origin "https://github.com/${CI_REPO}.git"
if git -C "$site" ls-remote --exit-code origin refs/heads/gh-pages >/dev/null; then
  git -C "$site" fetch -q --depth 1 origin gh-pages
  git -C "$site" checkout -q --detach FETCH_HEAD
else
  status=$?
  [[ "$status" == 2 ]] || { echo 'Cannot read the gh-pages branch' >&2; exit 1; }
fi
find "$site" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -R Source/Website/. "$site/"
# The site is plain static files; Pages must serve them as-is instead of running Jekyll.
touch "$site/.nojekyll"
git -C "$site" add --all
if git -C "$site" diff --cached --quiet && git -C "$site" rev-parse -q --verify HEAD >/dev/null; then
  echo 'Website is already up to date'
  exit 0
fi
git -C "$site" -c user.name='Woodpecker CI' -c user.email='ci@ci.nest42.de' commit -qm "chore: publish website from $CI_COMMIT_SHA"
git -C "$site" push -q origin HEAD:refs/heads/gh-pages
echo 'Published https://maxmeis.github.io/hypermug/'
