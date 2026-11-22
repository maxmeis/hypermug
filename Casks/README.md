# Homebrew cask

This repository is also the public Homebrew tap. Install Production with:

```sh
brew tap maxmeis/hypermug https://github.com/maxmeis/hypermug
brew install --cask maxmeis/hypermug/hypermug
```

The app updates itself through its daily in-app check, so the cask declares `auto_updates true`. To update through Homebrew instead, name the cask: `brew upgrade --cask maxmeis/hypermug/hypermug` (a bare `brew upgrade` skips it). Then quit and reopen the app. Users of 0.3.0 or 0.3.1 must do this once.

`Casks/hypermug.rb` points to a versioned, signed and notarized `HyperMug.app` ZIP in this repository's GitHub Releases. Its SHA-256 is calculated from the final archive. A macOS application belongs in `Casks/`; `Formula/` is used for source-built tools. No separate `homebrew-*` repository is needed.

The Production release workflow commits the verified cask directly to `main` after publishing the release. It uses a repository-scoped SSH deploy key when protected-main writes require one, with the `github_token` Woodpecker secret as the default for branches that allow it. It needs the direct-push permission described in the [release process](../docs/releases.md#repository-configuration). Cask-only commits do not produce another release. The previous Canary cask is retired; historical releases are preserved.

**HyperMug Dev** is built locally with `make dev` and has its own app identity, configuration and permissions. It is not distributed by this tap.
