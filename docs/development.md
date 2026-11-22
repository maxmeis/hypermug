# Development

App source and Core tests live in `Source/HyperMug/`. Build and automation helpers live in `helpers/`. Use the root Makefile for project commands.

## Build and run

On macOS with Xcode Command Line Tools installed, set up your local signing identity once, then build:

```sh
make setup-dev
make dev
```

`make setup-dev` installs the locked Node tools and creates a persistent, self-signed code-signing identity in your login Keychain. macOS may require a one-time Keychain authorization. The private key stays on your Mac; no Apple Developer account or production certificate is needed. Repeating setup reuses the identity. Normal builds never generate a new certificate. `make dev` produces `build/HyperMug Dev.app` with that identity; `make run` builds and launches Dev, and `make restart` launches its existing build. `make setup` retains the Node-tooling-only setup command.

Run `make help` for other commands. Set `BUILD_ROOT=/path/to/disposable-output` to isolate build products. The builder generates the variant's schema into `Contents/Resources` before signing. `make clean` removes the root build output.

Local **HyperMug Dev** uses bundle ID `com.maxmeis.hypermug.dev`, `~/.config/hypermug-dev.toml`, and `~/Library/Logs/HyperMug Dev/`. Production keeps its own name, bundle ID, settings, permissions and logs. Both apps are independently installable. The local launcher copies Production settings only on the first run, disables local login launch, and restarts only Dev. Avoid enabling conflicting input mappings in two running instances.

The development signature pins the stable bundle ID and your certificate fingerprint in its designated requirement. Keep the certificate and bundle path stable. Rotating/deleting the identity or switching from earlier ad-hoc builds can require permission grants again. A stable requirement improves identity continuity but does not guarantee TCC permission retention on every macOS version. See [Signing and permission persistence](signing.md) for actual API checks and limitations.

PR CI deliberately uses `SIGN_ID=- make dev`: its disposable runner needs no persistent identity or Apple credentials. This explicit ad-hoc override does not demonstrate local permission persistence. Development and local production-test builds have no update feed and cannot update themselves into production.

```sh
make verify-signing                 # Verify the Dev signature and designated requirement
make verify-permission-persistence  # Rebuild twice; compare identity and actual permissions
make build-production              # Build the production variant locally without publishing
```

The production-test command creates `build/HyperMug.app` but does not install, launch, notarize or publish it. Its production bundle ID is for packaging validation; use Dev for running alongside a production installation.

## Architecture and checks

The layer rules use `make check-layers`:

- `Source/HyperMug/Sources/Core`: pure logic with injected OS services.
- `Source/HyperMug/Sources/Platform`: OS adapters; may depend on Core, not App.
- `Source/HyperMug/Sources/App`: native UI and composition root.
- `Source/HyperMug/Tests`: Core tests.

`make test-runtime` runs actual subprocess isolation/exit/timeout/cleanup checks and fake native-notification delivery and in-app configuration-editor model adapters, without requesting macOS notification permissions or launching HyperMug.

`make test-window` opens an isolated native window fixture on a logged-in Mac. It tests window reuse, resizing, raw TOML editing, Undo/Redo, Command-S, invalid saves and discard confirmation with a temporary file and no input engine or permission requests. It is intentionally excluded from headless CI. Optional `HYPERMUG_TEST_CAPTURE_DIRECTORY=/tmp/hypermug-ui-evidence make test-window` captures only the fixture window, using existing Screen Recording permission; it never requests that permission.

`make test` requires 100% executable-line coverage. `make compile-check` type-checks the app. `make test-release` checks release metadata and publication with temporary repositories. `make check-automation` and `make check-website` check repository automation and website assets. CI and Git hooks use these Makefile targets.

Run `make ci-tools` to install the locked Node tooling. Run `make hooks` to install Git hooks again if npm scripts were disabled. Commits follow [Conventional Commits](../CONTRIBUTING.md#commit-messages).

## CI scope and workflow dependencies

The required GitHub Actions check remains `ci`. Pull requests and `main` pushes run CI; a branch without a pull request can be checked through manual CI dispatch. An Ubuntu job inspects the complete change range. README/CONTRIBUTING, `docs/`, website, skills and the Production cask qualify for Linux checks. Examples used by Core tests, app sources, branding, build scripts, workflows, dependencies and unknown paths require native macOS checks. Missing or empty ranges select native checks conservatively. Renames inspect both paths. Run `make test-ci` for Git-history regression tests.

Actions are pinned to full commit SHAs. PR tests use ad-hoc signing without production credentials. There is no external release-bot checkout. The single Production workflow independently tests the pushed source before signing and publishing; see [Release process](releases.md) for credentials and repository settings.

## Issue-first planning

Plan work through GitHub issues with one of three types: **Feature**, **Bug**, or **Misc**. Use the matching `feature`, `bug`, or `misc` label and the corresponding issue form when available. Only issues authored by the verified repository owner, `maxmeis`, enter the actionable backlog and can authorize automated work. Outside issues and comments are welcome as public discussion and reports, but they do not automatically authorize triage work or implementation. No automatic triage or implementation is promised for external reports.

Public pull requests are welcome. For substantial changes, first check whether an owner-authored issue describes the work; if it does not, discuss it in an issue and let the owner decide whether to create backlog work. See [Contributing](../CONTRIBUTING.md).

The [file configuration/macOS/Swift audit](audits/file-config-macos-swift.md) records the requested skills, scope, findings and validation limits.
