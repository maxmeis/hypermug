# Development

App source and Core tests live in `Source/HyperMug/`. Build and automation helpers live in `helpers/`. Use the root Makefile for project commands.

## Build and run

On macOS with Xcode Command Line Tools installed, one command builds the local app:

```sh
make dev
```

This produces `build/HyperMug Dev.app` with an ad-hoc signature (`codesign -s -`). It needs no Apple Developer account, certificate or notarization. `make run` builds and launches Dev; `make restart` launches its existing build. `make setup` installs the repository's Node development tools when you need commit hooks and their checks.

Run `make help` for other commands. Set `BUILD_ROOT=/path/to/disposable-output` to isolate build products. The builder generates the variant's schema into `Contents/Resources` before signing. `make clean` removes the root build output.

Local **HyperMug Dev** uses bundle ID `com.maxmeis.hypermug.dev`, `~/.config/hypermug-dev.toml`, and `~/Library/Logs/HyperMug Dev/`. Production keeps its own name, bundle ID, settings, permissions and logs. Both apps are independently installable. The local launcher copies Production settings only on the first run, disables local login launch, and restarts only Dev. Avoid enabling conflicting input mappings in two running instances.

Ad-hoc signatures can require Accessibility or Input Monitoring grants again after rebuilding. They do not require a local signing identity or Apple credentials. Production signing and notarization run only in release CI; Dev builds have no update feed and never check for updates; rebuild with `make dev`.

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

CI runs on Woodpecker at `ci.nest42.de`. Pull requests and `main` pushes run it; a branch without a pull request can be checked through a manual pipeline. The Linux workflow `.woodpecker/ci.yaml` (status `ci/woodpecker/pr/ci`) always runs the layer, release-metadata, shell, automation, content and commit-message checks. The macOS workflow `.woodpecker/ci-macos.yaml` runs Core tests, runtime checks, the compile check and the Dev bundle check unless every changed file is content: README/CONTRIBUTING, `docs/` (except examples used by Core tests and new subdirectories), website, skills and the Production cask. App sources, branding, build scripts, workflows, dependencies and unknown paths require native checks; manual runs always include them. `helpers/ci_scope.py` holds the same rule for the complete change range, including both paths of a rename, and `make test-ci` keeps it in sync with the path filter. Only `.github/workflows/issues.yml` stays on GitHub Actions, because Woodpecker cannot receive `issues` events.

Container images and the remaining Actions are pinned to digests or full commit SHAs. The macOS agent uses Woodpecker's local backend: steps take Xcode and Homebrew tools from the host through `helpers/woodpecker-macos-env.sh`. PR tests use ad-hoc signing without production credentials. There is no external release-bot checkout. The Production release workflows independently test the pushed source before signing and publishing; see [Release process](releases.md) for credentials and repository settings.

## Issue-first planning

Plan work through GitHub issues with one of three types: **Feature**, **Bug**, or **Misc**. Use the matching `feature`, `bug`, or `misc` label and the corresponding issue form when available. Only issues authored by the verified repository owner, `maxmeis`, enter the actionable backlog and can authorize automated work. Outside issues and comments are welcome as public discussion and reports, but they do not automatically authorize triage work or implementation. No automatic triage or implementation is promised for external reports.

Public pull requests are welcome. For substantial changes, first check whether an owner-authored issue describes the work; if it does not, discuss it in an issue and let the owner decide whether to create backlog work. See [Contributing](../CONTRIBUTING.md).

The [file configuration/macOS/Swift audit](audits/file-config-macos-swift.md) records the requested skills, scope, findings and validation limits.
