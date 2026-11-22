# Permissions and troubleshooting

## Permissions

- **Accessibility** supports the keyboard and mouse event tap used by Caps Lock modifier modes, side-button and wheel mappings, and scroll inversion.
- **Input Monitoring** supports raw Caps Lock detection and access to the MX Master 3S thumb button.

Use **Doctor… → Permissions** in the menu to see or grant permissions. Relaunch HyperMug after granting Input Monitoring. Release builds use a stable Developer ID signature; normal local builds reuse a developer's persistent self-signed identity after `make setup-dev`. macOS may still require renewed grants in some circumstances; see [Signing and permission persistence](signing.md) for verification and TCC limitations.

## Common issues

### Caps Lock or mouse input is not remapped

Confirm Accessibility and Input Monitoring are granted, then relaunch after granting Input Monitoring. In `"default"` Caps Lock mode, HyperMug does not handle Caps Lock. If using Meh, Three Mod, or Hyper mode, quit other Caps Lock remappers such as Hyperkey to avoid competing input handling.

### A trackpad swipe does not run its action

Check that the direction is configured in `trackpad`, then follow [Trackpad setup](installation.md#trackpad-setup) to disable conflicting native macOS gestures. HyperMug reads raw contacts from supported Apple trackpads; hardware-specific gesture behavior can vary.

### MX Master 3S thumb button is unavailable

Thumb-button remapping supports the MX Master 3S over Bluetooth. Do not run Logi Options+ or OpenLogi at the same time; they can compete for control of the button. If HyperMug crashes while the button is diverted, reconnect or power-cycle the mouse to restore it.

### Configuration error

HyperMug keeps the last valid configuration when a file contains invalid TOML, an unsupported value, an invalid action, or a reference to a missing helper. Use the native notification’s **Open Configuration** action or **Configuration Error…** in the menu, repair the file in HyperMug, and save it again. TOML syntax errors name the line and column. HyperMug does not overwrite a non-empty invalid file. See [Configuration](configuration.md#validation-and-recovery).

### Shell action fails or times out

A nonzero exit, start failure, or the default 10-second deadline sends a native notification. Inspect Doctor activity for the status/action ID, check the configured absolute executable paths, and adjust `shellTimeoutSeconds` (1–300) only when a longer action is intentional. Timed-out process groups are terminated. If notifications are disabled, use **System Settings → Notifications → HyperMug** to enable them; HyperMug does not change that permission for you.

### View logs

Stream HyperMug's unified log from Terminal:

```sh
log stream --predicate 'subsystem == "com.maxmeis.hypermug"'
```

Logs include configuration errors, input diversion, and permission problems. Review output before sharing it and remove personal data.

## Secure Input

When macOS Secure Input is active, the system blocks keyboard event taps. Caps Lock Meh, Three Mod, and Hyper will not work during that period. HyperMug shows a lock icon and identifies the reported holder in its menu. This is a macOS restriction and is not controlled by a HyperMug setting.

The menu's **Blocked by Secure Input** item opens a reusable status panel. It refreshes while visible and shows the reported app and process details, including whether it is frontmost. **Bring to Front** activates the reported app. **Quit** and **Force Quit** ask for confirmation and are disabled for HyperMug itself, system processes, invalid process IDs, and processes owned by another user. macOS may report that Secure Input is active without identifying an owner; in that case HyperMug reports an unknown app.

macOS can keep an old holder PID after that process exits. HyperMug verifies that the PID still exists before it shows process actions. It reports a stale holder as an unknown app. The Secure Input on/off state remains independent of this holder metadata.

## Doctor and activity

Doctor opens the Overview page of the shared HyperMug window. It summarizes permissions, capture state, configuration errors and binding counts. Configuration edits the raw TOML file; Permissions, Conflicts and Activity diagnose the running setup. Checks update while its window is open. Conflicts lists possible overlaps with macOS gestures and other input apps. Unknown keys are schema errors; remove or correct them in the configuration file.

Activity shows detected swipes, shell action IDs and failure statuses; successful actions send no failure notice. It supports filtering and pause. Each launch keeps the last session as `previous.log` beside `debug.log`. Dev logs use `~/Library/Logs/HyperMug Dev/`. Typed keys and command contents are not written to these files.

In a Caps Lock modifier mode, HyperMug clears the macOS Caps Lock latch after every Caps Lock press and whenever a key event shows it latched, then verifies it stayed off. It also strips Caps Lock flags from key events. Shift keeps its normal function. Default mode leaves Caps Lock unchanged.
