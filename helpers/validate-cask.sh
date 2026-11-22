#!/usr/bin/env bash
set -euo pipefail
: "${1:?Cask path}" "${2:?version}" "${3:?SHA-256}"
command -v brew >/dev/null || { echo 'Homebrew is required to validate a release Cask' >&2; exit 1; }
# Keep Homebrew's startup files inside CI's temporary directory. This command
# evaluates the Cask DSL but does not download or install release artifacts.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_CACHE="${HOMEBREW_CACHE:-${RUNNER_TEMP:-/tmp}/hypermug-homebrew-cache}"
export HOMEBREW_TEMP="${HOMEBREW_TEMP:-${RUNNER_TEMP:-/tmp}/hypermug-homebrew-temp}"
brew ruby "$(dirname "$0")/validate_cask.rb" "$1" "$2" "$3"
