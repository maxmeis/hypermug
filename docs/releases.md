# Release process

Every valid Conventional Commit PR merged into `main` receives a production version, including documentation, maintenance and dependency updates. No release PR, manual version bump, canary channel or normal manual publishing step is required. The repository already enforces squash-only merging, PR-title squash commit titles, PR-body commit messages, owner review and the required `ci` check.

## Pull request CI

`.github/workflows/ci.yml` validates the PR title and runs locked dependency installation, layer/shell/release checks, tests and build validation. Titles are passed as data, never pasted into a shell command. PR jobs have read-only repository access and no production secrets. Native checks use explicit ad-hoc signing on disposable runners, verify bundle identity and signing configuration, and require the Dev update feed to be absent. They do not create a developer certificate or publish a release.

## Automatic production releases

`.github/workflows/release.yml` runs on `main` pushes and reconciles missed work on a schedule. Release jobs are serialized with `queue: max` and never cancel a running publisher. Queue order alone is insufficient: the reconciler processes outstanding main source commits oldest first. Two quick merges therefore receive separate versions and archives even if workflow runs start out of order. Generated cask-only publishing commits do not recursively release; ordinary documentation and maintenance merges remain candidates.

Scheduled recovery covers merges made with `GITHUB_TOKEN`, whose push events do not start another workflow. Partial releases are repaired before newer versions advance. Each run processes one source; after success it automatically dispatches the next run if work remains. The hourly schedule is a fallback for suppressed events and failed runs. Recovery dispatch has no version input; normal publishing requires only merging a PR.

`release.config.mjs` and `helpers/semantic_plugins.mjs` configure semantic-release's Conventional Commit analysis and changelog generation:

| Commit | Version change |
| --- | --- |
| `fix:` | Patch |
| `feat:` | Minor |
| `feat!:` or a `BREAKING CHANGE:` footer | Major |
| Other valid Conventional Commit types | Patch |

The planner uses semantic-release's JavaScript API in dry-run mode against an isolated local Git snapshot for each source. It never lets semantic-release publish live tags before the app is verified. This avoids semantic-release skipping a historical source when remote main has advanced. Each analysis covers its individual source change rather than batching several queued PRs. `CFBundleShortVersionString` gets the semantic version; `CFBundleVersion` gets a deterministic, increasing main-history build number. No production version is manually maintained in source.

For migration entries that predate the new helpers, the orchestrator uses trusted workflow build tooling while preserving each historical app source. Provenance identifies both commits. It never substitutes a newer app implementation for the source being released.

The pipeline performs these steps:

1. Select the exact source, install locked tooling and run tests.
2. Calculate its semantic version and generate changelog notes.
3. Build with the calculated marketing/build versions; import the Developer ID identity into a temporary Keychain.
4. Sign nested components and the app, require notarization acceptance, staple, and verify signatures, requirement, entitlements and Gatekeeper assessment.
5. Package the final bytes and calculate checksums. Only then create or resume a source-bound draft release and version tag.
6. Download and verify the exact archive, sign it with Sparkle's EdDSA key, validate the appcast and cask, and publish the release with changelog and checksums.
7. Advance the signed appcast on `updates` and commit the verified cask directly to the existing tap's default branch.

A failed test, build, signing operation or notarization prevents public publication. Credentials and temporary Keychain state are cleaned up on exit.

## Retries and partial publication

A tag/release belongs to one source SHA, version and build number. Retries reuse existing verified archive bytes, never replacing a published archive with a rebuild. Published tags/assets are not moved, overwritten or deleted. Wrong source, build, signature, metadata or digest stops the run.

A public release followed by a failed feed/tap write is a partial release. Automatic reconciliation retries metadata for those exact bytes before advancing. Existing valid pointers remain installable. Feed and cask publication reject rollback and conflicting same-version bytes. Bounded Git retries never force-push `main`; a completed identical retry is a no-op. Repair the failed credential or policy and let reconciliation resume rather than editing an immutable release.

## Homebrew

The tap remains this repository's `Casks/hypermug.rb` on `main`, installed as `maxmeis/hypermug/hypermug`. No standalone CLI/Formula is distributed. The generator writes the version, immutable release URL and actual ZIP SHA-256 and validates before publishing. A scratch checkout commits only the permitted cask path; it never mutates the running source checkout. `auto_updates true` remains enabled for Sparkle.

The existing scoped deploy key remains supported as `HOMEBREW_SSH_PRIVATE_KEY`, with its configured protected-main publishing exception. A scoped token is usable where branch policy permits. No broad admin credential or protection weakening is required. Publishing does not open a PR or recursively create another application release. Historical cask-token conflicts may remain for existing installations; there is one active production channel.

## Sparkle

Production embeds the pinned, checksum-verified Sparkle 2 framework. Nested components are signed inside out and verified before/after notarization. The feed stays `https://raw.githubusercontent.com/maxmeis/hypermug/updates/appcast.xml`, with the existing `SUPublicEDKey`. Automatic checks run daily unless the user disables `autoUpdate`; **Check for Updates…** supports checking and installing within the app. Development and local packaging-test builds have no feed.

The publisher sends the private EdDSA key to `sign_update` on stdin and checks the resulting signature against the public key inside the downloaded final archive. The appcast includes the immutable enclosure URL, size, signature, build/marketing versions and minimum OS version. No pointer advances to an unverified download. Updates preserve production identity and entitlement policy; actual permission continuity still needs testing on a granted Mac.

The old `appcast-stable.xml` remains frozen because its original private key was lost. 0.3.0/0.3.1 users need a one-time `brew upgrade --cask maxmeis/hypermug/hypermug`; later releases use the current feed/key. Never delete or rewrite that historical feed or pretend a new key signs for old clients.

## Repository configuration

The `production` environment is already restricted to `main`, with no required release approval or wait timer. Keep credentials there, away from PR jobs:

| Type | Name | Purpose |
| --- | --- | --- |
| Secret | `DEVELOPER_ID_P12_BASE64` | Developer ID Application certificate and private-key export |
| Secret | `DEVELOPER_ID_P12_PASSWORD` | Password protecting that PKCS#12 export |
| Secret | `APP_STORE_CONNECT_PRIVATE_KEY` | Notarization API private key |
| Secret | `HOMEBREW_SSH_PRIVATE_KEY` | Existing scoped deploy key for tap/feed writes |
| Secret | `SPARKLE_ED_PRIVATE_KEY` | Sparkle key matching the embedded public key |
| Variable | `SIGN_ID` | Full Developer ID Application identity |
| Variable | `APPLE_TEAM_ID` | Expected signing team |
| Variable | `APP_STORE_CONNECT_KEY_ID` | API key identifier |
| Variable | `APP_STORE_CONNECT_ISSUER_ID` | API issuer identifier |

An Apple account holder creates a Developer ID Application certificate, exports its certificate/private-key pair as password-protected PKCS#12, and stores the base64 export and password separately as environment secrets. Create an App Store Connect API key with notarization access; store its private key separately from its identifiers. Never commit or print either private key. Developers use only their independent local identities.

Retain owner review, the required `ci` check, squash history, no-force-push/deletion rules and the narrow publishing exception. Inspect all applicable rulesets before changing credentials. `GITHUB_TOKEN` needs Contents write for tags/releases; tap/feed credentials must be repository-scoped. Signing runs only on trusted main code in the protected environment.

## Validation

```sh
make test-release
make test-ci
npm run test:release-queue
make check
```

Tests cover version rules, rapid merges, backlog ordering, partial retries, source/tag identity, signing/notarization failures, checksums, EdDSA validation and feed/cask boundaries. See [Signing and permission persistence](signing.md) for setup, diagnostics and explicit TCC limits. Fixtures do not prove live Apple credentials, GitHub publication, Homebrew installation or a real Sparkle update; verify and record those after a production run.

Primary references: [semantic-release API](https://semantic-release.gitbook.io/semantic-release/developer-guide/js-api), [commit analysis](https://github.com/semantic-release/commit-analyzer), [GitHub concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency), [token trigger rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow), [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), and [Sparkle publishing](https://sparkle-project.org/documentation/publishing/).
