# Configuration

HyperMug stores settings only in `~/.config/hypermug.toml` ([TOML 1.0](https://toml.io/en/v1.0.0)). **Settings…** (⌘,) opens the TOML editor inside HyperMug's single native window. **Doctor…** opens its Overview page; Configuration, Permissions, Conflicts and Activity share that same window. There is no second preferences form or separate settings app. The menu's **Stay Awake** checkmark remains a session-only control.

Edit TOML directly, choose **Validate** to check without applying, and **Save** (⌘S) to validate, write atomically and apply. Saving writes your text as typed, so comments and layout are kept; only the schema metadata at the top is updated. Standard copy/paste, undo/redo and Find (⌘F) work in the native text editor; smart quotes and text substitutions are disabled. **Reveal File** locates the actual document in Finder. You can also edit the same file with an external editor; saved external changes reload automatically, including atomic saves.

An open clean editor follows external changes. An unsaved draft is never replaced by background refresh. If disk bytes changed since editing began, Save refuses to overwrite them. Copy your draft if needed, then use **Reload**; discarding a modified draft requires confirmation. Closing, quitting or restarting HyperMug also protects unsaved changes. Invalid drafts stay in the editor for repair and never replace the last valid file.

## Example

This is the configuration HyperMug writes on first launch:

```toml
#:schema file:///Applications/HyperMug.app/Contents/Resources/hypermug.schema.json
"$schema" = "file:///Applications/HyperMug.app/Contents/Resources/hypermug.schema.json"

autoUpdate = true
caffeineOnLaunch = true
capsLock = "threeMod"
helpers = {}
launchAtLogin = true
shellTimeoutSeconds = 10

[mouse.buttons]
back.shell = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around next"
forward.shell = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around prev"
thumb = {}

[mouse.horizontalWheel]
left = {}
right = {}

[mouse.invertScroll]
horizontal = false
vertical = false

[trackpad.fourFingerSwipe]
down = {}
left.shell = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around next"
right.shell = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around prev"
up = {}

[trackpad.threeFingerSwipe]
down = {}
left.shell = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around next"
right.shell = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around prev"
up = {}
```

`back.shell = "…"` is TOML's dotted-key form of the table `back = { shell = "…" }`; both spellings mean the same thing. A `[mouse.buttons]` header opens the `buttons` table inside `mouse`.

On a new or empty file, HyperMug shows every button, wheel and swipe direction, including unassigned slots as `{}` and an empty `helpers` table. These placeholders run no action; they make available keys visible while editing. The defaults are `capsLock = "threeMod"`, `caffeineOnLaunch = true`, `autoUpdate = true`, `launchAtLogin = true`, both scroll inversions off, and the six AeroSpace mappings shown. These shell actions require AeroSpace at the specified path to work. Existing preferences are preserved; only the `$schema` metadata is updated when the installed bundle location changes. Missing keys in an existing file retain their previous fallback values; in particular, omitted `launchAtLogin` remains `false` and omitted mappings remain unmapped.

### AeroSpace example

[`docs/examples/aerospace.toml`](examples/aerospace.toml) is the owner's own setup: Caps Lock as Three Mod, the mouse side buttons and three-finger swipes switch AeroSpace workspaces, and horizontal wheel steps and four-finger swipes switch windows. It uses shared helpers and needs AeroSpace at `/opt/homebrew/bin/aerospace`. The test suite checks that this file stays valid.

```toml
#:schema file:///Applications/HyperMug.app/Contents/Resources/hypermug.schema.json
"$schema" = "file:///Applications/HyperMug.app/Contents/Resources/hypermug.schema.json"

autoUpdate = true
caffeineOnLaunch = true
capsLock = "threeMod"
launchAtLogin = false

[helpers]
aerospaceWindowNext = "/opt/homebrew/bin/aerospace focus --wrap-around dfs-next"
aerospaceWindowPrev = "/opt/homebrew/bin/aerospace focus --wrap-around dfs-prev"
nextWorkspace = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around next"
previousWorkspace = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around prev"

[mouse.buttons]
back.helper = "previousWorkspace"
forward.helper = "nextWorkspace"
thumb = {}

[mouse.horizontalWheel]
left.helper = "aerospaceWindowNext"
right.helper = "aerospaceWindowPrev"

[mouse.invertScroll]
horizontal = false
vertical = false

[trackpad.fourFingerSwipe]
left.helper = "aerospaceWindowNext"
right.helper = "aerospaceWindowPrev"

[trackpad.threeFingerSwipe]
left.helper = "nextWorkspace"
right.helper = "previousWorkspace"
```

## Schema and editor support

The schema is generated from the same Core model into the signed app’s `Contents/Resources/hypermug.schema.json` before signing. It is a JSON Schema file only because that is the format TOML editors accept for validation; it is editor tooling, not a configuration format. HyperMug writes the schema’s actual `file://` URL twice at the top of the file:

- `#:schema <url>` on the first line, the directive used by [Taplo](https://taplo.tamasfe.dev) and the **Even Better TOML** extension for VS Code, Zed and other editors.
- `"$schema" = "<url>"`, a quoted key that stays valid TOML and that other schema-aware editors recognize.

The URL includes URL escaping when the app path contains spaces. The example assumes `/Applications/HyperMug.app`; Homebrew or a custom app location can produce a different URL. Dev uses its own bundled `hypermug-dev.schema.json`. No schema sidecar is created beside your config.

Editors can use this local resource for validation and autocomplete. Runtime validation uses the same compiled schema and native shortcut/helper checks; it never downloads a user-supplied `$schema` URL. After moving or upgrading the app, launch it to refresh an outdated reference. Both schema lines are optional when writing a file yourself.

HyperMug reads TOML 1.0 except for the features the configuration has no use for: dates and times, arrays of tables (`[[name]]`), arrays that mix value types, and `inf`/`nan` are rejected with a clear error. Errors name the line and column, for example `invalid TOML at line 3, column 9: duplicate key capsLock`.

## Earlier JSON configuration

TOML is the only configuration format. Earlier versions stored settings in `~/.config/hypermug.json`; HyperMug no longer reads that file. If it exists, HyperMug starts from the TOML defaults, leaves the JSON file untouched, and Doctor shows “hypermug.json is no longer supported; settings now live in hypermug.toml.” until you move or delete it. Copy any settings you want to keep into `hypermug.toml` by hand.

## Settings

| Key | Values and behavior |
| --- | --- |
| `capsLock` | `"default"` leaves Caps Lock alone; `"meh"` maps hold to ⌃⌥⇧; `"threeMod"` maps hold to ⌃⌥⌘; `"hyper"` maps hold to ⌃⌥⇧⌘. Each modifier mode sends Escape on tap. |
| `caffeineOnLaunch` | Whether Stay Awake starts enabled. The menu's checked **Stay Awake** item changes the running session only; it does not edit this preference. |
| `autoUpdate` | Whether the Production app checks its update feed automatically, once a day. Defaults to `true`; **Check for Updates…** in the menu works either way. Dev builds have no update feed. |
| `launchAtLogin` | Registers HyperMug as a login item when true. |
| `shellTimeoutSeconds` | Shell action deadline in seconds, from `1` through `300`; defaults to `10`. At the deadline HyperMug terminates the action’s process group and sends a native notification. |
| `helpers` | Optional names mapped to non-empty shell commands. Mouse buttons, wheel directions and three- or four-finger swipes may reference a name; a command is defined once and shared. |
| `mouse.invertScroll.vertical` | Inverts mouse wheel vertical scrolling relative to the current macOS direction. |
| `mouse.invertScroll.horizontal` | Inverts the MX Master 3S horizontal/thumb wheel relative to the current macOS direction. |
| `mouse.buttons` | Actions for `back`, `forward`, and `thumb` buttons. |
| `mouse.horizontalWheel` | Actions for physical horizontal wheel steps, `left` and `right`. Unbound by default; see [Wheel bindings](#wheel-bindings). |
| `trackpad` | Optional `threeFingerSwipe` and `fourFingerSwipe` actions in each of `left`, `right`, `up`, and `down`. |

Scroll inversion affects mouse wheels only, not trackpads or Magic Mouse scrolling.

## Wheel bindings

`mouse.horizontalWheel.left` and `.right` bind horizontal/thumb wheel steps to the same actions as buttons and swipes. For example, with the side buttons switching AeroSpace workspaces, the horizontal wheel can move focus between windows:

```toml
[helpers]
aerospaceWindowNext = "/opt/homebrew/bin/aerospace focus --wrap-around dfs-next"
aerospaceWindowPrev = "/opt/homebrew/bin/aerospace focus --wrap-around dfs-prev"

[mouse.horizontalWheel]
left.helper = "aerospaceWindowNext"
right.helper = "aerospaceWindowPrev"
```

Older configurations may contain an empty `[mouse.verticalWheel]` table with `up = {}` and `down = {}`. HyperMug ignores those unassigned placeholders, so your other settings keep working; you can remove that table. Configured vertical wheel actions are no longer supported and must be replaced with horizontal `left`/`right` bindings.

- A mapped horizontal direction is consumed: it no longer scrolls horizontally, and each wheel step runs the action once. An unmapped direction and vertical scrolling keep scrolling normally. Vertical wheel action bindings are not supported.
- `left` and `right` refer to the physical horizontal wheel direction, whatever the Natural Scrolling setting. `invertScroll.horizontal` does not swap bindings; it only reverses the scrolling of an unmapped direction.
- Clicky wheels count one step per notch. High-resolution or smooth-scrolling wheels accumulate their pixel travel into steps. Steps are at least 150 ms apart, and one continuous roll, such as a free-spinning flick, runs at most three actions; pause for about 0.3 s to continue.
- Only mouse wheels are bound. Trackpad and Magic Mouse scrolling is never consumed.
- Wheel bindings use the Accessibility event tap. Other tools that rewrite scroll events, such as smooth-scrolling utilities, can change what HyperMug sees.

## Actions and shortcuts

An empty action table (`{}`) leaves that slot unassigned. To assign an action, set exactly one non-empty key:

- `shortcut`: an array with any number of modifiers and exactly one key, such as `back.shortcut = ["cmd", "shift", "["]`. A string such as `"cmd+shift+["` is not accepted.
- `shell`: a supervised command run by `/bin/sh -c`; output is discarded. GUI apps receive a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), so use absolute paths for other tools. Use `open` to launch an app, file, or URL. TOML literal strings (`'...'`) need no escaping for backslashes and double quotes.
- `helper`: the name of a command in top-level `helpers`, such as `up.helper = "mission-control"`. A helper always resolves to a shell command; nested helper aliases are not supported. An unknown name makes the configuration invalid.

Shortcut tokens are case-insensitive. Modifiers: `cmd`, `ctrl`, `alt` (`opt` and `option` aliases), `shift`, `meh` (ctrl+alt+shift), `threemod` (ctrl+alt+cmd), and `hyper` (ctrl+alt+shift+cmd). Keys: `a`–`z`, `0`–`9`, `[ ] ; ' , . / \\ - = \``, `f1`–`f20`, `left`, `right`, `up`, `down`, `escape` (`esc`), `return` (`enter`), `tab`, `space`, `delete` (`backspace`), `forwarddelete`, `home`, `end`, `pageup`, and `pagedown`.

`meh` now means the standard Meh chord, Control+Option+Shift (⌃⌥⇧). Older configurations that explicitly set `capsLock = "meh"` previously received Control+Option+Command (⌃⌥⌘); they now receive the corrected Meh chord. To keep the old behavior, change that setting to `capsLock = "threeMod"`. Shortcut arrays using `"meh"` likewise now send ⌃⌥⇧; use `"threemod"` for ⌃⌥⌘.

For example, trackpad mappings can be added alongside `mouse`:

```toml
[helpers]
mission-control = "open -a 'Mission Control'"

[trackpad.threeFingerSwipe]
left.shortcut = ["cmd", "shift", "["]
right.shortcut = ["cmd", "shift", "]"]
up.helper = "mission-control"

[trackpad.fourFingerSwipe]
down.shell = "open -a Finder"
```

Omitted directions run no action. Each configured swipe fires once; lift all fingers before the next swipe. Taps, pinches, rotation, and normal two-finger scrolling are not bindings. Configure the conflicting native macOS swipe assignments as described in [Installation](installation.md#trackpad-setup).

## Validation and recovery

Omit a button, wheel or swipe direction, or set it to `{}`, to leave it unmapped. Optional settings may be omitted to use their fallback values; unknown keys and invalid action values are errors. Empty action values such as `back.shell = ""` or `back.shortcut = []` are errors; an empty table is the explicit unassigned form. A mapped back/forward button is swallowed and its action runs once on press; thumb also runs once per press. Wheel and trackpad actions use the same action format.

If the TOML syntax or the bundled schema rules fail, a shortcut is invalid, or a helper reference is missing, HyperMug keeps the last valid settings. It never overwrites a non-empty invalid file. A native notification offers **Open Configuration**, opening the same in-app editor; the menu also shows **Configuration Error…** while the file is invalid. Doctor activity records the validation path and reason. Fix and save the file to recover automatically. Renaming or deleting a helper requires updating every reference in the same save; names, including surrounding spaces, remain exact.

## Shell failures and notifications

A command that cannot start, exits nonzero, or exceeds `shellTimeoutSeconds` triggers a native notification. At the deadline HyperMug sends `SIGTERM` to its dedicated process group, then `SIGKILL` after a 0.5-second grace period if necessary, including children still in that group. No unrelated process group is signaled. At most eight shell actions run concurrently; excess actions report a busy error. Quitting HyperMug stops its running groups. Deliberately detached daemons are outside this supervision contract; commands should run their work in the foreground.

Notifications ask for macOS permission when the first problem occurs. Denial is respected: errors still appear in Doctor activity/logs, and invalid configuration remains visible in the menu. Repeated notifications are limited to one per category every 30 seconds; configuration recovery resets that category. Success is silent. Native notification text and shell activity logs contain status and an action ID, never command contents, environment values or shell output. Configuration validation logs can include setting names; review them before sharing.

The in-app editor writes through the running configuration store, so only the actual TOML document persists settings. Save checks schema/action validity and compares the disk bytes with the opened baseline before replacing a symlink target atomically. Editing a draft alone has no effect on input handling or permissions.
