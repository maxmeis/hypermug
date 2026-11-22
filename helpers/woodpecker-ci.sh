#!/usr/bin/env bash
# Woodpecker CI helpers for the Linux `ci` workflow. Woodpecker passes the change range as CI_*
# variables instead of GitHub event fields, so this maps them onto the existing Make targets.
#
#   helpers/woodpecker-ci.sh scope         print the native-check decision for the change range
#   helpers/woodpecker-ci.sh lint-commits  lint every commit this pull request or push adds
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CI_PIPELINE_EVENT:?}" "${CI_COMMIT_SHA:?}" "${CI_REPO_DEFAULT_BRANCH:?}"

# commitlint and the scope check need the complete history, not the clone's shallow tip.
full_history() {
  if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then git fetch -q --unshallow origin; fi
  git fetch -q origin "+refs/heads/${CI_REPO_DEFAULT_BRANCH}:refs/remotes/origin/${CI_REPO_DEFAULT_BRANCH}"
}

# The first commit this run compares against: the pull request target's tip, or the commit of the
# previous pipeline on this branch. Empty when there is none.
base() {
  if [[ "$CI_PIPELINE_EVENT" == pull_request ]]; then
    : "${CI_COMMIT_TARGET_BRANCH:?}"
    git fetch -q origin "+refs/heads/${CI_COMMIT_TARGET_BRANCH}:refs/remotes/origin/${CI_COMMIT_TARGET_BRANCH}"
    git rev-parse "refs/remotes/origin/${CI_COMMIT_TARGET_BRANCH}"
  else
    printf '%s\n' "${CI_PREV_COMMIT_SHA:-}"
  fi
}

case "${1:-}" in
  scope)
    full_history
    # Informational: the ci-macos workflow's path filter makes the same conservative choice.
    python3 helpers/ci_scope.py --event "$CI_PIPELINE_EVENT" --base "$(base)" --head "$CI_COMMIT_SHA"
    ;;
  lint-commits)
    full_history
    from="$(base)"
    if [[ "$CI_PIPELINE_EVENT" != pull_request ]]; then
      # New branch, first pipeline, or a force-push over a commit this clone does not have: lint
      # everything since the default branch instead. A release-casks/* candidate is rebuilt on the
      # current default branch, so its previous tip can predate commits that are already on the
      # default branch; lint only the commits it adds on top of it.
      if [[ "${CI_COMMIT_BRANCH:-}" != "$CI_REPO_DEFAULT_BRANCH" || -z "$from" ]] ||
        ! git cat-file -e "${from}^{commit}" 2>/dev/null ||
        ! git merge-base --is-ancestor "$from" "$CI_COMMIT_SHA"; then
        from="$(git merge-base "origin/$CI_REPO_DEFAULT_BRANCH" "$CI_COMMIT_SHA" 2>/dev/null || true)"
      fi
    fi
    if [[ -z "$from" || "$(git rev-list --count "$from..$CI_COMMIT_SHA")" == 0 ]]; then
      echo "No new commits to lint."
    else
      FROM="$from" TO="$CI_COMMIT_SHA" make lint-commits
    fi
    ;;
  *)
    echo "usage: $0 scope|lint-commits" >&2
    exit 2
    ;;
esac
