# HyperMug

HyperMug is a macOS menu bar utility that combines a Hyperkey, Caffeine, trackpad swipe shortcuts, and mouse-button remapping.

## Install

Requires macOS 14 Sonoma or later on Apple Silicon. Install the signed, notarized **Production** app with:

```sh
brew tap maxmeis/hypermug https://github.com/maxmeis/hypermug
brew install maxmeis/hypermug/hypermug
```

HyperMug checks for updates once a day and offers to install them; **Check for Updates…** in the menu checks immediately. Releases after 0.3.1 are signed with a new update key. HyperMug 0.3.0 and 0.3.1 never see them in the app, so if you have either, run `brew upgrade --cask maxmeis/hypermug/hypermug` once; later updates arrive in the app. A bare `brew upgrade` skips casks that declare `auto_updates true`, so name the cask. See [Installation](docs/installation.md) for permissions and first-run setup. For an independent local app, clone this repository, run `make setup-dev` once, then `make dev`; see [Development](docs/development.md).

## Features

- **Caps Lock as Three Mod, Meh, or Hyper:** Three Mod is Control+Option+Command (⌃⌥⌘); Meh is Control+Option+Shift (⌃⌥⇧); Hyper uses all four (⌃⌥⇧⌘). Tap Caps Lock for Escape.
- **Stay Awake:** open the mug menu with a left or right click and use its checked **Stay Awake** item for this session; the next launch uses your saved preference.
- **Trackpad swipes:** bind three- and four-finger swipes to shortcuts, shell commands, or shared named helpers.
- **Mouse remapping:** map back/forward buttons, the MX Master 3S thumb button and horizontal wheel steps to the same actions, and invert wheel scrolling.
- **Secure Input status:** see when macOS blocks keyboard monitoring and which app holds Secure Input.
- **One native window:** **Settings…** (⌘,) opens the TOML editor alongside overview, permissions, conflicts and activity. Validate and save in HyperMug; the TOML file stays the single source of settings. Native notifications report invalid configuration and failed shell actions.

HyperMug requires macOS Accessibility and Input Monitoring permissions for its input features. The app explains each permission in **Doctor… → Permissions**. See [Permissions and troubleshooting](docs/troubleshooting.md).

## Configuration

Settings are stored in `~/.config/hypermug.toml`, the only configuration format. The file links to a schema inside the signed app bundle, so TOML editors such as Taplo or Even Better TOML can validate and complete it. See [Configuration](docs/configuration.md) for defaults, shared helpers, validation and the default 10-second shell deadline.

```toml
capsLock = "threeMod"

[helpers]
nextWorkspace = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around next"
previousWorkspace = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around prev"

[mouse.buttons]
back.helper = "previousWorkspace"
forward.helper = "nextWorkspace"

[trackpad.threeFingerSwipe]
left.helper = "nextWorkspace"
right.helper = "previousWorkspace"
```

## Development and contributions

Swift app sources and tests live under `Source/HyperMug/`; repository commit hooks use the root npm tooling. See [Development](docs/development.md) to build, test, and check layer rules, and [CONTRIBUTING.md](CONTRIBUTING.md) for reports and pull requests.

## Releases

Source pushes to protected `main` automatically run tests, increment the patch version, build and notarize the Production app, publish a GitHub Release, and update the signed in-app update feed and the Homebrew cask in this repository. There is one production channel. See [Release process](docs/releases.md).
