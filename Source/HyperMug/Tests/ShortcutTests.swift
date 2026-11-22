import Foundation
import CoreGraphics
import Carbon.HIToolbox   // only to cross-check the keycode literals in Core against kVK_*
@testable import HyperMugCore

private func parsed(_ tokens: [String]) -> Shortcut? {
    if case .success(let s) = parseShortcut(tokens) { return s }
    return nil
}

private func failure(_ tokens: [String]) -> String? {
    if case .failure(let e) = parseShortcut(tokens) { return e.reason }
    return nil
}

private func expectShortcut(_ tokens: [String], _ code: Int, _ flags: CGEventFlags,
                            file: StaticString = #filePath, line: UInt = #line) {
    guard let s = parsed(tokens) else {
        expect(false, "shortcut \(tokens) should parse: \(failure(tokens) ?? "")", file: file, line: line)
        return
    }
    expectEqual(s.keyCode, CGKeyCode(code), "key code of \(tokens)", file: file, line: line)
    expectEqual(s.flags, flags, "flags of \(tokens)", file: file, line: line)
    expectEqual(s.tokens, tokens, "tokens are kept as written for \(tokens)", file: file, line: line)
}

/// Every key token with the Carbon constant it must equal. Independent of the table in Core.
private let carbonKeys: [(String, Int)] = [
    ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
    ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
    ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
    ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
    ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
    ("z", kVK_ANSI_Z),
    ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
    ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
    ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket), (";", kVK_ANSI_Semicolon),
    ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period), ("/", kVK_ANSI_Slash),
    ("\\", kVK_ANSI_Backslash), ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("`", kVK_ANSI_Grave),
    ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4), ("f5", kVK_F5),
    ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8), ("f9", kVK_F9), ("f10", kVK_F10),
    ("f11", kVK_F11), ("f12", kVK_F12), ("f13", kVK_F13), ("f14", kVK_F14), ("f15", kVK_F15),
    ("f16", kVK_F16), ("f17", kVK_F17), ("f18", kVK_F18), ("f19", kVK_F19), ("f20", kVK_F20),
    ("left", kVK_LeftArrow), ("right", kVK_RightArrow), ("up", kVK_UpArrow), ("down", kVK_DownArrow),
    ("escape", kVK_Escape), ("esc", kVK_Escape),
    ("return", kVK_Return), ("enter", kVK_Return),
    ("tab", kVK_Tab), ("space", kVK_Space),
    ("delete", kVK_Delete), ("backspace", kVK_Delete), ("forwarddelete", kVK_ForwardDelete),
    ("home", kVK_Home), ("end", kVK_End), ("pageup", kVK_PageUp), ("pagedown", kVK_PageDown),
]

private let modifierTokens = ["cmd", "ctrl", "alt", "opt", "option", "shift", "meh", "threemod", "hyper"]

func shortcutTests() {
    // Grammar: modifiers + exactly one key, case-insensitive, tokens kept as written.
    expectShortcut(["meh", "k"], kVK_ANSI_K, [.maskControl, .maskAlternate, .maskShift])
    expectShortcut(["threeMod", "k"], kVK_ANSI_K, [.maskControl, .maskAlternate, .maskCommand])
    expectShortcut(["THREEMOD", "k"], kVK_ANSI_K, [.maskControl, .maskAlternate, .maskCommand])
    expectShortcut(["hyper", "f13"], kVK_F13, [.maskControl, .maskAlternate, .maskShift, .maskCommand])
    expectShortcut(["cmd", "shift", "["], kVK_ANSI_LeftBracket, [.maskCommand, .maskShift])
    expectShortcut(["ctrl", "left"], kVK_LeftArrow, .maskControl)
    expectShortcut(["CMD", "Opt", "Esc"], kVK_Escape, [.maskCommand, .maskAlternate])
    expectShortcut(["option", "\\"], kVK_ANSI_Backslash, .maskAlternate)
    expectShortcut([" cmd ", "]"], kVK_ANSI_RightBracket, .maskCommand)
    expectShortcut(["f20"], kVK_F20, [])
    expectShortcut(["cmd", "="], kVK_ANSI_Equal, .maskCommand)
    expectShortcut(["shift", "pagedown"], kVK_PageDown, .maskShift)
    expectShortcut(["ctrl", "`"], kVK_ANSI_Grave, .maskControl)
    expectShortcut(["k", "cmd"], kVK_ANSI_K, .maskCommand)   // order does not matter
    expectShortcut(["alt", "opt", "option", "k"], kVK_ANSI_K, .maskAlternate)   // aliases are the same bit
    expectShortcut(["cmd", "meh", "k"], kVK_ANSI_K, [.maskControl, .maskAlternate, .maskCommand, .maskShift])   // modifiers union

    // Bad lists
    for bad in [[], [""], ["+"], ["cmd", ""], ["cmd", "nope"], ["cmd"], ["meh"], ["threemod"], ["a", "b"], ["cmd", "f21"],
                ["cmd+k"], ["cmd", "k", "esc"], ["  "]] {
        expect(parsed(bad) == nil, "shortcut \(bad) must be rejected")
    }
    expectEqual(failure([]), "shortcut [] needs exactly one key besides modifiers", "no tokens")
    expectEqual(failure(["cmd"]), "shortcut [\"cmd\"] needs exactly one key besides modifiers", "modifier only")
    expectEqual(failure(["cmd", ""]), "empty key in shortcut [\"cmd\", \"\"]", "empty token")
    expectEqual(failure(["a", "B"]), "shortcut [\"a\", \"B\"] has more than one key (\"a\" and \"b\")", "two keys")
    expectEqual(failure(["cmd", "Nope"]), "unknown key or modifier \"nope\" in shortcut [\"cmd\", \"Nope\"]", "unknown token")
    expectEqual(failure(["cmd+k"]),
                "unknown key or modifier \"cmd+k\" in shortcut [\"cmd+k\"]; write each key as its own array item",
                "plus-joined string hint")
    expect(!(failure(["+"]) ?? "").contains("own array item"), "a lone plus is not the joined-string mistake")

    // The key table agrees with Carbon for every key token, and nothing is untested.
    for (token, code) in carbonKeys {
        expectEqual(parsed([token])?.keyCode, CGKeyCode(code), "key code of \"\(token)\"")
    }
    expectEqual(Set(carbonKeys.map { $0.0 }).union(modifierTokens), Set(shortcutTokenNames),
                "cross-check covers exactly the tokens the parser knows")
    expectEqual(shortcutTokenNames.count, Set(shortcutTokenNames).count, "token names are unique")
    expect(shortcutTokenNames.allSatisfy { $0 == $0.lowercased() }, "token names are lowercase")
    for token in modifierTokens {
        expect(parsed([token, "a"]) != nil && parsed([token]) == nil, "\(token) is a modifier, not a key")
    }

    // Posted flags: the extra bits a real keyboard reports.
    func posted(_ tokens: [String]) -> CGEventFlags {
        guard let s = parsed(tokens) else { return [.maskAlphaShift] }   // impossible flag set fails the comparison
        return postedFlags(for: s)
    }
    expectEqual(posted(["cmd", "k"]), .maskCommand, "a letter adds nothing")
    expectEqual(posted(["hyper", "escape"]), [.maskControl, .maskAlternate, .maskShift, .maskCommand], "escape adds nothing")
    let fnTokens = (1...20).map { "f\($0)" } + ["home", "end", "pageup", "pagedown", "forwarddelete"]
    let arrowTokens = ["left", "right", "up", "down"]
    for token in fnTokens {
        expectEqual(posted([token]), .maskSecondaryFn, "\(token) is reported with fn")
    }
    for token in arrowTokens {
        expectEqual(posted([token]), [.maskSecondaryFn, .maskNumericPad], "\(token) is reported with fn and numpad")
    }
    expectEqual(posted(["ctrl", "left"]), [.maskControl, .maskSecondaryFn, .maskNumericPad], "modifiers are kept")
    for (token, _) in carbonKeys where !fnTokens.contains(token) && !arrowTokens.contains(token) {
        expectEqual(posted([token]), [], "\(token) adds no extra flags")
    }
}
