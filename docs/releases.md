# Release process

HyperMug has one Production release, the Woodpecker CI workflows `.woodpecker/release-check.yaml` and `.woodpecker/release.yaml` on the macOS agent at `ci.nest42.de`. Source pushes to protected `main` automatically test the exact pushed commit, select the next patch version, create its immutable `vX.Y.Z` tag, build and sign the app with Developer ID, notarize and staple it, publish a GitHub Release, commit the signed Sparkle feed `appcast.xml` to the `updates` branch, and commit `Casks/hypermug.rb` directly to `main`. There are no release PRs or manual version/tag inputs.

## Production publication

App sources, branding, build helpers, the Makefile and release workflows trigger releases. Documentation, website, skills and generated cask-only changes do not. `release-check` runs `make check` on the exact pushed commit; `release` starts only after it succeeds. Publication runs are serialized without canceling a running release because the macOS agent runs one workflow at a time (`WOODPECKER_MAX_WORKFLOWS=1`); keep Woodpecker's automatic cancellation off for pushes. The migration baseline is the existing `v0.3.0` release. GitHub Actions run numbers 1-3 published `v0.3.1`-`v0.3.3`; Woodpecker pipeline `N` allocates `v0.3.(N+3)`. A restarted pipeline gets a new number, so the version step reuses the `v0.3.*` tag that already points to the source SHA, and every tag must point to the same source SHA. Failed runs can leave version gaps. A queued older run keeps its lower version even if it executes later, and cannot move the latest release or cask backward.

The release workflow checks out the tested push SHA and uses the `github_token` Woodpecker secret, a fine-grained token with Contents write on this repository, to publish tags and releases. It imports the Developer ID certificate into a temporary keychain, builds the Production bundle, requires Apple's notarization result to be Accepted, staples the app and verifies its signature and Gatekeeper assessment. It then packages the final stapled app as `HyperMug-X.Y.Z.zip`. Temporary signing credentials and keychain state are cleaned up on exit.

The publisher creates a draft with its artifact before publishing. Published tags and artifact bytes are never replaced. The Homebrew cask version, URL and SHA-256 refer to the release archive. Retrying a publication reuses existing published bytes. The cask commit changes only `Casks/hypermug.rb`, fetches current `main` to preserve intervening source changes, and never force-pushes. An older retry cannot move the cask backward.

## In-app updates

Production bundles embed Sparkle 2. `helpers/sparkle.sh` downloads one pinned Sparkle release and refuses it unless its SHA-256 matches. The build copies `Sparkle.framework` with `ditto` so its symlinks survive, then re-signs its nested `Installer.xpc`, `Downloader.xpc`, `Autoupdate` and `Updater.app`, and then the framework, from the inside out, with the app's identity and, for releases, Developer ID with hardened runtime and a secure timestamp, before notarization. Release checks fail if any of those parts has the wrong team, no hardened runtime, no timestamp, or a broken framework symlink, both before notarization and again in the downloaded ZIP.

The Info.plist template carries `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval` (86400 seconds, so one check a day) and `SUVerifyUpdateBeforeExtraction`. Only the Production variant gets `SUFeedURL`, `https://raw.githubusercontent.com/maxmeis/hypermug/updates/appcast.xml`; CI asserts that Dev builds have no feed. The `autoUpdate` setting turns scheduled checks on or off.

After the publisher downloads and verifies the published ZIP, `sign_update` signs those exact bytes with the `SPARKLE_ED_PRIVATE_KEY` environment secret. The key goes to `sign_update` on standard input and is never printed. `helpers/release_metadata.py appcast` then checks that the signature verifies with the `SUPublicEDKey` inside that ZIP, and writes a one-item feed: `sparkle:version` is the bundle's `CFBundleVersion`, plus `sparkle:shortVersionString`, the enclosure length, `sparkle:edSignature` and the release URL. If the secret is missing, the publisher fails before it touches the release. If the key does not match the app, the release stays a draft. The feed commit uses the same deploy key and GitHub SSH known-hosts setup as the cask commit, retries on races, and never force-pushes. A rerun of the same version is a no-op, and a feed that already lists a newer `sparkle:version` is left alone, so the feed never moves backward.

The update key was rotated for the first release after 0.3.1 because the original private key was lost. HyperMug 0.3.0 checks downloads against the old key before extracting them, so it cannot accept updates signed with the new key. It reads `appcast-stable.xml` on the `updates` branch, which stays frozen at 0.3.0: the publisher writes only `appcast.xml` and refuses a feed commit that changes any other file. 0.3.0 installs therefore see no update instead of Sparkle's "improperly signed" error. 0.3.1 has no updater. Users of either version run `brew upgrade --cask maxmeis/hypermug/hypermug` once; the cask must be named, because `auto_updates true` makes a bare `brew upgrade` skip it. Never delete or rewrite `appcast-stable.xml`. The new key also lives in the release maintainer's login keychain under the Sparkle account `hypermug-production`; export it with `generate_keys --account hypermug-production -x <file>` only into a private temporary file.

## Homebrew

Homebrew lives in this repository; no external tap, release service or GitHub App is required. The publisher supports a repository-scoped SSH deploy key for protected-main cask writes; it uses the `github_token` secret for cask writes when the branch permits that token. Either push runs ordinary CI, while cask-only updates are excluded from release paths to prevent another release; appcast pushes to `updates` match no workflow. The cask declares `auto_updates true` because the app updates itself.

## Repository configuration

Production is active on protected `main`: the release workflows run only for pushes to `main` of `maxmeis/hypermug`, and their Woodpecker secrets are limited to the `push` event, so source pushes release automatically. Woodpecker secret event filters apply across branches. Before provisioning credentials, enforce trusted configuration or restrict who can initiate secret-bearing push and manual pipelines at the server. Branch conditions in repository YAML are editable by a branch author. Source pull requests retain required CODEOWNERS review. The repository-scoped SSH deploy key is stored as the Woodpecker secret `homebrew_ssh_private_key`; its ruleset exception permits the generated cask commit to bypass pull-request and required-check rules. Force-push and deletion protections are separate and have no deploy-key bypass. The `github_token` secret has Contents write for tags and releases.

The repository has no GitHub Actions workflows or Actions dependencies for Dependabot to update. Keep pull request pipelines free of repository secrets because Woodpecker reads the pipeline from the PR commit. Review dependency updates with the ordinary PR checks. Update pinned Woodpecker images in reviewed PRs.

For a new repository using these workflows, limit the release secrets to the `push` event. Install a repository-scoped write deploy key and save its private key as the `homebrew_ssh_private_key` secret. Add a narrow PR and required-check ruleset bypass for that key, while keeping source CODEOWNERS review and force-push/deletion protections in rulesets without the bypass. Inspect all applicable branch protections and rulesets together: `contents: write` and CODEOWNERS alone do not grant direct-push permission. Alternatively, omit the deploy key only when the repository's rules explicitly allow the `github_token` secret to update the cask directly.

The website workflow `.woodpecker/website.yaml` checks `Source/Website` and commits it to the `gh-pages` branch with the `github_token` secret. GitHub Pages must serve "Deploy from a branch", `gh-pages`, `/ (root)`.

## Issue triage

Configure an `issue-triage` Woodpecker cron job on `main` (for example, `@hourly`) after merge. It polls open and closed owner bug reports and reconciles their version labels and managed comments. A new report or edit is processed on the next run, or immediately through a manual run of the `issues` workflow on `main`. Avoid overlapping manual and scheduled runs. The token’s GitHub account authors new comments and needs permission to remove obsolete comments left by GitHub Actions.

## Production credentials

Keep Apple credentials in Woodpecker repository secrets limited to the `push` event; only release steps reference them. Woodpecker has no separate variables, so the non-secret identifiers are secrets too. No credential is needed for local development or PR tests.

| Type | Name | Purpose |
| --- | --- | --- |
| Secret | `issue_triage_token` | Fine-grained token for this repository with Issues write and Contents read. Restrict to `cron` and `manual`. |
| Secret | `github_token` | Fine-grained token, this repository, Contents write: tags, releases, cask and appcast commits, `gh-pages` (also `manual`) |
| Secret | `developer_id_p12_base64` | Base64-encoded Developer ID certificate and private key |
| Secret | `developer_id_p12_password` | Export password for the certificate |
| Secret | `app_store_connect_private_key` | App Store Connect API private key for notarization |
| Secret | `homebrew_ssh_private_key` | Repository-scoped key for the cask and appcast commits when branch rules require it |
| Secret | `sparkle_ed_private_key` | Sparkle EdDSA private key (base64 seed) that signs the appcast; must match `SUPublicEDKey` in `Source/HyperMug/Info.plist` |
| Secret | `sign_id` | Full Developer ID Application signing identity |
| Secret | `apple_team_id` | Apple team identifier |
| Secret | `app_store_connect_key_id` | Notarization API key identifier |
| Secret | `app_store_connect_issuer_id` | Notarization API issuer identifier |

After the first Woodpecker production release, verify notarization, the Sparkle update, and the cask update before retiring the GitHub Actions credentials. Retire old release-bot and external-tap credentials only after every dependent project has completed a real production publication and Homebrew update. Existing historical releases remain unchanged.

## Validation

`make test-release` uses isolated fixtures to test version selection, publication retries, signing and notarization errors, appcast generation and signature checks, feed reruns and rollback protection, that only `appcast.xml` is ever written, and the missing-secret failure. `make check` also runs Core coverage, native subprocess checks, compilation, workflow helper and content checks. These local checks do not prove Developer ID credentials, Apple's notarization service, protected-branch publication or a clean-Mac install; verify those through an actual production release before announcing the migration complete. The same applies to a real Sparkle update from one release to the next.
