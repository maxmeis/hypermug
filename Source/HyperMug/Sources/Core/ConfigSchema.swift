import Foundation

/// A JSON-escaped, case-insensitive pattern derived from the parser's token table.
/// JSON Schema patterns have no case-insensitive flag, so use portable character classes.
private let shortcutTokenPatternJSON: String = {
    let escaped: [String] = shortcutTokenNames.map { token in
        token.map { character -> String in
            let value = String(character)
            if character.isASCII && character.isLetter { return "[\(value.lowercased())\(value.uppercased())]" }
            if "\\.^$|?*+()[]{}".contains(character) { return "\\" + value }
            return value
        }.joined()
    }
    let pattern = "^(?:" + escaped.joined(separator: "|") + ")$"
    let data = try! JSONSerialization.data(withJSONObject: pattern, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}()

private func buttonSchema(_ description: String) -> String {
    #"""
{
          "type": "object",
          "description": "\#(description) Use an empty object for an unassigned slot, or set exactly one of shell, shortcut or helper. An omitted mapping also runs no HyperMug action.",
          "additionalProperties": false,
          "properties": {
            "shell": {
              "type": "string",
              "pattern": "\\S",
              "description": "Command run via /bin/sh -c in the background, output discarded (minimal PATH: /usr/bin:/bin:/usr/sbin:/sbin). Must not be empty."
            },
            "helper": {
              "type": "string",
              "minLength": 1,
              "pattern": "\\S",
              "description": "Name of a shell command in the top-level helpers object."
            },
            "shortcut": {
              "type": "array",
              "description": "Keyboard shortcut to send, as an array of key names: any modifiers plus exactly one key, e.g. [\"cmd\", \"[\"], [\"threemod\", \"k\"] or [\"ctrl\", \"left\"]. Modifiers: cmd, ctrl, alt (opt, option), shift, meh (ctrl+alt+shift), threemod (ctrl+alt+cmd), hyper (ctrl+alt+shift+cmd). Keys: a-z, 0-9, [ ] ; ' , . / \\ - = `, f1-f20, left, right, up, down, escape (esc), return (enter), tab, space, delete (backspace), forwarddelete, home, end, pageup, pagedown. The names are listed in lowercase; \#(AppIdentity.appName) also accepts other letter case.",
              "minItems": 1,
              "items": {
                "type": "string",
                "pattern": \#(shortcutTokenPatternJSON)
              }
            }
          },
          "oneOf": [
            {
              "required": ["shell"],
              "properties": {
                "shell": { "minLength": 1 }
              }
            },
            {
              "required": ["shortcut"]
            },
            {
              "required": ["helper"]
            },
            {
              "maxProperties": 0
            }
          ]
        }
"""#
}

/// JSON Schema (draft-07) for `~/.config/hypermug.toml`: the single source of truth, compiled into the binary.
/// The tests check it against `encodeConfig` and the model.
public let configSchemaJSON: String = #"""
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "\#(AppIdentity.appName) configuration",
  "description": "Settings for \#(AppIdentity.appName) (~/.config/\#(AppIdentity.configFileName)). Edits apply within about a second; an invalid file is reported and the last good settings stay active.",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "$schema": {
      "type": "string",
      "description": "File URL of the schema inside the signed \#(AppIdentity.appName) bundle; used by editors."
    },
    "caffeineOnLaunch": {
      "type": "boolean",
      "description": "Whether Caffeine (keep the Mac awake) is on when \#(AppIdentity.appName) starts. Selecting Stay Awake in the menu toggles Caffeine for the running session only and never changes this file; changing this value while \#(AppIdentity.appName) runs sets Caffeine to it."
    },
    "capsLock": {
      "type": "string",
      "description": "What Caps Lock does. default = unchanged; meh = hold for Ctrl+Opt+Shift; threeMod = hold for Ctrl+Opt+Cmd; hyper = hold for Ctrl+Opt+Shift+Cmd. Each modifier mode taps for Escape.",
      "enum": ["default", "meh", "threeMod", "hyper"]
    },
    "launchAtLogin": {
      "type": "boolean",
      "description": "Start \#(AppIdentity.appName) when you log in (Start with Machine)."
    },
    "autoUpdate": {
      "type": "boolean",
      "description": "Check for updates automatically with Sparkle. Defaults to true when omitted."
    },
    "shellTimeoutSeconds": {
      "type": "number",
      "minimum": 1,
      "maximum": 300,
      "default": 10,
      "description": "Maximum seconds for a shell action before its process group is terminated and a native notification is sent. Defaults to 10."
    },
    "helpers": {
      "type": "object",
      "description": "Named shell commands shared by mouse and trackpad mappings.",
      "propertyNames": { "minLength": 1, "pattern": "\\S" },
      "additionalProperties": { "type": "string", "minLength": 1, "pattern": "\\S" }
    },
    "trackpad": {
      "type": "object",
      "description": "Optional three- and four-finger swipe mappings. Before enabling mappings, disable the matching native macOS trackpad gestures once in System Settings so they do not conflict. Only swipes are mapped; taps are unaffected.",
      "additionalProperties": false,
      "properties": {
        "threeFingerSwipe": {
          "type": "object",
          "description": "Actions for three-finger swipes. Omitted directions run no HyperMug action. Native assignments disabled in System Settings remain disabled.",
          "additionalProperties": false,
          "properties": {
            "up": \#(buttonSchema("Three-finger swipe up.")),
            "down": \#(buttonSchema("Three-finger swipe down.")),
            "left": \#(buttonSchema("Three-finger swipe left.")),
            "right": \#(buttonSchema("Three-finger swipe right."))
          }
        },
        "fourFingerSwipe": {
          "type": "object",
          "description": "Actions for four-finger swipes. Omitted directions run no HyperMug action. Native assignments disabled in System Settings remain disabled.",
          "additionalProperties": false,
          "properties": {
            "up": \#(buttonSchema("Four-finger swipe up.")),
            "down": \#(buttonSchema("Four-finger swipe down.")),
            "left": \#(buttonSchema("Four-finger swipe left.")),
            "right": \#(buttonSchema("Four-finger swipe right."))
          }
        }
      }
    },
    "mouse": {
      "type": "object",
      "description": "Mouse settings (wheel mice such as the MX Master; trackpad and Magic Mouse scrolling is never changed).",
      "additionalProperties": false,
      "properties": {
        "invertScroll": {
          "type": "object",
          "description": "Reverse the scroll direction of a mouse wheel, relative to the system's current Natural Scrolling setting.",
          "additionalProperties": false,
          "properties": {
            "vertical": {
              "type": "boolean",
              "description": "Reverse the vertical (main) wheel."
            },
            "horizontal": {
              "type": "boolean",
              "description": "Reverse the horizontal (thumb) wheel."
            }
          }
        },
        "buttons": {
          "type": "object",
          "description": "Button remapping. List only the buttons you remap; a button that is not listed keeps its normal behavior.",
          "additionalProperties": false,
          "properties": {
            "back": \#(buttonSchema("Back side button (mouse button 4).")),
            "forward": \#(buttonSchema("Forward side button (mouse button 5).")),
            "thumb": \#(buttonSchema("Thumb button of the MX Master 3S over Bluetooth (needs Input Monitoring permission)."))
          }
        },
        "horizontalWheel": {
          "type": "object",
          "description": "Actions for physical horizontal (thumb) wheel steps of a mouse wheel. A mapped direction is consumed and runs its action once per wheel step; fast or free-spinning rolls are limited. An unmapped direction keeps normal scrolling. Directions refer to the physical wheel, independent of Natural Scrolling and invertScroll.horizontal. Trackpad and Magic Mouse scrolling is never bound.",
          "additionalProperties": false,
          "properties": {
            "left": \#(buttonSchema("Wheel rolled left.")),
            "right": \#(buttonSchema("Wheel rolled right."))
          }
        }
      }
    }
  }
}

"""#
