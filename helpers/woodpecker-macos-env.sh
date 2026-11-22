#!/usr/bin/env bash
# Sourced by Woodpecker steps on the macOS agent. Its local backend runs steps in a host shell with
# the agent's minimal PATH, so take tools from Xcode and Homebrew.
#
#   . helpers/woodpecker-macos-env.sh [formula...]
[[ "$(uname -s)" == Darwin ]] || { echo 'This step must run on the macOS agent' >&2; return 1; }
xcode-select -p >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1 || { echo 'Xcode is required on the macOS agent' >&2; return 1; }
# Keep tool caches and files created through HOME inside the disposable checkout.
mkdir -p "$PWD/build/woodpecker/home" "$PWD/build/woodpecker/cache" || return 1
export HOME="$PWD/build/woodpecker/home"
export XDG_CACHE_HOME="$PWD/build/woodpecker/cache"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
export CLANG_MODULE_CACHE_PATH="$XDG_CACHE_HOME/clang"
export npm_config_cache="$XDG_CACHE_HOME/npm"
for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [[ -x "$brew" ]]; then eval "$("$brew" shellenv)"; break; fi
done
command -v brew >/dev/null || { echo 'Homebrew is required on the macOS agent' >&2; return 1; }
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
for formula in "$@"; do
  brew list --formula "$formula" >/dev/null 2>&1 || {
    echo "The macOS agent needs the Homebrew formula $formula installed" >&2
    return 1
  }
  # Versioned formulae such as node@24 are keg-only; put them first on PATH.
  if [[ "$formula" == *@* ]]; then export PATH="$(brew --prefix "$formula")/bin:$PATH"; fi
done
unset brew formula
