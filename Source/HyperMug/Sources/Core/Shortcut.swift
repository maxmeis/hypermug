import Foundation
import CoreGraphics

// MARK: - Model

/// Parsed chord. `flags` contains ONLY the modifier bits (.maskCommand/.maskControl/.maskAlternate/.maskShift).
/// `tokens` are the original array items as written, written back verbatim on encode.
public struct Shortcut: Equatable {
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags
    public let tokens: [String]

    public init(keyCode: CGKeyCode, flags: CGEventFlags, tokens: [String]) {
        self.keyCode = keyCode
        self.flags = flags
        self.tokens = tokens
    }
}

// MARK: - Grammar tables

// Ordered tables: the order is the order of the JSON Schema token enum. Names are lowercase.
private let shortcutModifierTable: [(String, CGEventFlags)] = [
    ("cmd", .maskCommand),
    ("ctrl", .maskControl),
    ("alt", .maskAlternate),
    ("opt", .maskAlternate),
    ("option", .maskAlternate),
    ("shift", .maskShift),
    ("meh", [.maskControl, .maskAlternate, .maskShift]),
    ("threemod", [.maskControl, .maskAlternate, .maskCommand]),
    ("hyper", [.maskControl, .maskAlternate, .maskShift, .maskCommand]),
]

/// US-layout virtual key codes (the values of Carbon's `kVK_*`; Core cannot import Carbon,
/// the tests cross-check every entry against it).
private let shortcutKeyTable: [(String, CGKeyCode)] = [
    ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14),
    ("f", 3), ("g", 5), ("h", 4), ("i", 34), ("j", 38),
    ("k", 40), ("l", 37), ("m", 46), ("n", 45), ("o", 31),
    ("p", 35), ("q", 12), ("r", 15), ("s", 1), ("t", 17),
    ("u", 32), ("v", 9), ("w", 13), ("x", 7), ("y", 16),
    ("z", 6),
    ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
    ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25),
    ("[", 33), ("]", 30), (";", 41),
    ("'", 39), (",", 43), (".", 47), ("/", 44),
    ("\\", 42), ("-", 27), ("=", 24), ("`", 50),
    ("f1", 122), ("f2", 120), ("f3", 99), ("f4", 118), ("f5", 96),
    ("f6", 97), ("f7", 98), ("f8", 100), ("f9", 101), ("f10", 109),
    ("f11", 103), ("f12", 111), ("f13", 105), ("f14", 107), ("f15", 113),
    ("f16", 106), ("f17", 64), ("f18", 79), ("f19", 80), ("f20", 90),
    ("left", 123), ("right", 124), ("up", 126), ("down", 125),
    ("escape", 53), ("esc", 53),
    ("return", 36), ("enter", 36),
    ("tab", 48), ("space", 49),
    ("delete", 51), ("backspace", 51), ("forwarddelete", 117),
    ("home", 115), ("end", 119), ("pageup", 116), ("pagedown", 121),
]

// `uniqueKeysWithValues` traps on a duplicated name, which keeps the tables honest.
private let shortcutModifiers = Dictionary(uniqueKeysWithValues: shortcutModifierTable)
private let shortcutKeys = Dictionary(uniqueKeysWithValues: shortcutKeyTable)

/// Every token `parseShortcut` accepts (lowercase; the parser also accepts other letter case), modifiers first.
/// The JSON Schema `enum` is built from this list.
public let shortcutTokenNames: [String] = shortcutModifierTable.map { $0.0 } + shortcutKeyTable.map { $0.0 }

/// Hint appended to errors about a shortcut that is not an array.
let shortcutArrayHint = "must be an array of keys, e.g. [\"cmd\", \"[\"]"

// MARK: - Parsing

/// Array of key tokens, case-insensitive: any number of modifiers plus exactly one key.
public func parseShortcut(_ tokens: [String]) -> Result<Shortcut, ConfigError> {
    let shown = "[" + tokens.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    var flags: CGEventFlags = []
    var keyCode: CGKeyCode?
    var keyToken = ""
    for raw in tokens {
        let token = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if token.isEmpty {
            return .failure(ConfigError(reason: "empty key in shortcut \(shown)"))
        }
        if let m = shortcutModifiers[token] {
            flags.formUnion(m)
        } else if let code = shortcutKeys[token] {
            if keyCode != nil {
                return .failure(ConfigError(reason: "shortcut \(shown) has more than one key (\"\(keyToken)\" and \"\(token)\")"))
            }
            keyCode = code
            keyToken = token
        } else {
            let hint = token.count > 1 && token.contains("+") ? "; write each key as its own array item" : ""
            return .failure(ConfigError(reason: "unknown key or modifier \"\(token)\" in shortcut \(shown)\(hint)"))
        }
    }
    guard let keyCode else {
        return .failure(ConfigError(reason: "shortcut \(shown) needs exactly one key besides modifiers"))
    }
    return .success(Shortcut(keyCode: keyCode, flags: flags, tokens: tokens))
}

// MARK: - Posting flags

/// Keys a real keyboard reports with the fn bit (F-keys, navigation cluster, arrows).
private let fnKeyCodes: Set<CGKeyCode> = Set(
    ((1...20).map { "f\($0)" } + ["left", "right", "up", "down", "home", "end", "pageup", "pagedown", "forwarddelete"])
        .map { shortcutKeys[$0]! })
private let arrowKeyCodes: Set<CGKeyCode> = Set(["left", "right", "up", "down"].map { shortcutKeys[$0]! })

/// Modifier flags plus the extra bits a physical keyboard sets for this key, so system hotkeys (e.g. ⌃← for Spaces) fire.
public func postedFlags(for shortcut: Shortcut) -> CGEventFlags {
    var flags = shortcut.flags
    if fnKeyCodes.contains(shortcut.keyCode) { flags.insert(.maskSecondaryFn) }
    if arrowKeyCodes.contains(shortcut.keyCode) { flags.insert(.maskNumericPad) }
    return flags
}
