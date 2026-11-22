#!/usr/bin/env bash
# Woodpecker CI helpers for the Linux and macOS CI workflows. Woodpecker passes the change range as CI_*
# variables instead of GitHub event fields, so this maps them onto the existing Make targets.
#
#   helpers/woodpecker-ci.sh scope         print the native-check decision for the change range
#   helpers/woodpecker-ci.sh native-checks  run native checks unless the change is content-only
#   helpers/woodpecker-ci.sh lint-commits  lint every commit this pull request or push adds
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CI_PIPELINE_EVENT:?}" "${CI_COMMIT_SHA:?}" "${CI_REPO_DEFAULT_BRANCH:?}"

# commitlint and the scope check need the complete history, not the clone's shallow tip.
full_history() {
  if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then git fetch -q --unshallow origin || return 1; fi
  git fetch -q origin "+refs/heads/${CI_REPO_DEFAULT_BRANCH}:refs/remotes/origin/${CI_REPO_DEFAULT_BRANCH}"
}

# The first commit this run compares against: the pull request target's tip, or the commit of the
# previous pipeline on this branch. Empty when there is none.
base() {
  if [[ "$CI_PIPELINE_EVENT" == pull_request ]]; then
    [[ -n "${CI_COMMIT_TARGET_BRANCH:-}" ]] || return 1
    git fetch -q origin "+refs/heads/${CI_COMMIT_TARGET_BRANCH}:refs/remotes/origin/${CI_COMMIT_TARGET_BRANCH}" || return 1
    git rev-parse "refs/remotes/origin/${CI_COMMIT_TARGET_BRANCH}"
  else
    printf '%s\n' "${CI_PREV_COMMIT_SHA:-}"
  fi
}

scope() {
  local from
  full_history || return 1
  from="$(base)" || return 1
  python3 helpers/ci_scope.py --event "$CI_PIPELINE_EVENT" --base "$from" --head "$CI_COMMIT_SHA"
}

case "${1:-}" in
  scope)
    scope
    ;;
  native-checks)
    if decision="$(scope)" && [[ "$decision" == native=false ]]; then
      echo 'Content-only change. Native checks are skipped.'
      exit 0
    fi
    . helpers/woodpecker-macos-env.sh
    make test
    make test-runtime
    make compile-check
    make dev
    ./helpers/check-dev-bundle.sh "build/HyperMug Dev.app"
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
    echo "usage: $0 scope|native-checks|lint-commits" >&2
    exit 2
    ;;
esac
