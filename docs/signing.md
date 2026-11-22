# Signing and permission persistence

HyperMug keeps local development and production identities separate. It uses the existing Swift compiler and Makefile; local builds need no Apple Developer account.

| Task | Command |
| --- | --- |
| One-time setup | `make setup-dev` |
| Rebuild with your persistent local identity | `make dev` |
| Build and run Dev | `make run` |
| Verify the Dev signature | `make verify-signing` |
| Query permissions across two rebuilds | `make verify-permission-persistence` |
| Build the production variant without publishing | `make build-production` |
| Inspect entitlements | `codesign --display --entitlements - --xml "build/HyperMug Dev.app"` |
| Inspect designated requirement | `codesign --display --requirements - "build/HyperMug Dev.app"` |

## Local signing identity

Setup creates a self-signed certificate and private key for this developer in the macOS login Keychain. Keychain authorization and certificate trust remain system decisions: run setup interactively when macOS asks for consent. Temporary export files have private permissions and are removed on exit. Private keys and passwords are never committed or uploaded. Other developers create their own identities independently.

Later builds reuse that identity. A missing or unavailable identity stops the build with setup guidance instead of silently replacing it. Keep the Keychain entry when cleaning build products. Back it up through your normal secure Mac backup process: changing or losing the key creates a new identity for local privacy decisions.

Dev uses `com.maxmeis.hypermug.dev`, separate settings and separate logs; production retains `com.maxmeis.hypermug`. The local designated requirement binds the Dev identifier to the certificate fingerprint, rather than each build's changing code hash. Production retains its existing Apple team and Developer ID requirement. Neither Dev nor the local production packaging-test build has a Sparkle feed. Use Dev for normal running alongside production.

A self-signed identity is a local identity, not Apple Development or Developer ID: it cannot notarize an app or enable Apple-managed capabilities that require provisioning. HyperMug's current unsandboxed input APIs rely on normal user consent, rather than a production certificate distributed to developers.

## Permissions belong to macOS

Accessibility and Input Monitoring are needed for input features. Normal HyperMug operation does not capture the screen. Screen Recording applies to the optional window screenshot fixture and diagnostic preflight; normal startup and developer setup do not request it.

TCC decisions depend on code identity, the responsible process, launch path, existing grants, OS release and policy. A stable certificate and designated requirement provide identity continuity, not a guarantee of permission retention. First use still needs user consent. Moving the app, changing identities or bundle IDs, migration from ad-hoc builds, OS policy changes, privacy resets and managed-device policy can require new consent. Some grants require restarting the app. Screen Recording can also show system reminders. Do not disable SIP or Gatekeeper, edit TCC databases, strip quarantine or silently grant permissions.

The explicit diagnostic mode exits before configuration, input capture, login-item registration, sleep assertions and updater startup. It queries `AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess` and Input Monitoring access without requesting grants. The helper launches the actual bundle through LaunchServices; it refuses older apps without the diagnostic capability marker.

`make verify-permission-persistence` compares two signed rebuilds at the same Dev path, their designated requirements and their actual permission results. Different signed build metadata exercises a changed code hash. A grant is reported as retained only if it was granted before and stays granted afterwards. If it was absent on the first build, the result is **not verified**, even if both preflights return the same denial. The helper never issues a grant or prompt. To test retention, grant the permission normally in System Settings, then rerun the check on that Mac.

For production updates, compare the old/new designated requirements, team, identifier and entitlements, then query actual permissions after a real Sparkle install. A valid signature alone does not prove a successful update or retained grants.

## Production signing

The protected release job uses a temporary Keychain on a GitHub-hosted macOS runner. It imports the Developer ID identity and passes the App Store Connect API private key to `notarytool` through a private temporary file. It signs Sparkle components inside out, preserves the Downloader service's own entitlements, enables Hardened Runtime and secure timestamps, and signs the outer app last. `--deep` is for verification, never a signing shortcut.

The main application is unsandboxed and currently needs no additional entitlements. Privacy grants are not entitlements. Release verification checks the bundle identifier, signing team, Developer ID requirement, Hardened Runtime, timestamp and entitlement policy, rejecting debugger grants and unnecessary runtime relaxations. Notarization must return Accepted. The app is stapled, verified and archived with symlinks intact. Temporary credentials and Keychain state are cleaned up on exit. Production private keys never enter local setup.

## Evidence and limits

On 2026-11-19 the existing public `v0.3.3` archive was downloaded: its checksum matched GitHub's digest, its nested signatures and designated requirement verified, its stapled ticket validated, and Gatekeeper accepted it as Notarized Developer ID. This verifies the existing distribution identity and artifact, not a future run of modified workflow code.

Isolated fixtures and local builds test the implementation. Granted TCC persistence requires an interactive Mac with grants already present. A new Developer ID build/notarization, protected-main publication and real production-to-production Sparkle installation must be verified after the implementation is merged. See [Release process](releases.md) for credentials, policy and recovery.

The new diagnostic was run through LaunchServices in the actual Dev bundle on 2026-11-19 without starting the input engine. Accessibility and Screen Recording returned false and Input Monitoring was unknown. This verifies the read-only diagnostic path, not grant retention. The persistent signer still requires interactive Keychain setup on a developer Mac.

Primary references: [Apple code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), [Apple TCC guidance](https://developer.apple.com/forums/thread/730043), [ScreenCaptureKit signing discussion](https://developer.apple.com/forums/thread/819406), [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), and [Sparkle publishing](https://sparkle-project.org/documentation/publishing/).
