import Foundation
import CoreGraphics
@testable import HyperMugCore

private func decode(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> DecodedConfig? {
    switch decodeConfig(Data(json.utf8)) {
    case .success(let d): return d
    case .failure(let e):
        expect(false, "expected \(json) to decode, got: \(e.reason)", file: file, line: line)
        return nil
    }
}

private func expectConfig(_ json: String, _ expected: AppConfig, file: StaticString = #filePath, line: UInt = #line) {
    expectEqual(decode(json, file: file, line: line)?.config, expected, "config for \(json)", file: file, line: line)
}

/// The decoder must reject `json` with exactly `reason`.
private func expectRejected(_ json: String, _ reason: String, file: StaticString = #filePath, line: UInt = #line) {
    switch decodeConfig(Data(json.utf8)) {
    case .success: expect(false, "expected \(json) to be rejected", file: file, line: line)
    case .failure(let e): expectEqual(e.reason, reason, "reason for \(json)", file: file, line: line)
    }
}

private func rejectionReason(_ json: String) -> String? {
    if case .failure(let e) = decodeConfig(Data(json.utf8)) { return e.reason }
    return nil
}

private func shortcut(_ tokens: [String]) -> ButtonAction {
    if case .success(let s) = parseShortcut(tokens) { return .shortcut(s) }
    preconditionFailure("test shortcut \(tokens) must parse")
}

/// JSON for a config whose `back` button is `body`.
private func withBack(_ body: String) -> String { "{\"mouse\":{\"buttons\":{\"back\":\(body)}}}" }

private func jsonObject(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

private func text(_ config: AppConfig) -> String { String(decoding: encodeConfig(config), as: UTF8.self) }

func configTests() {
    helperTests()
    decodeDefaultsTests()
    decodeActionTests()
    decodeRejectionTests()
    unknownKeyTests()
    encodeTests()
    anyKeyTests()
    trackpadTests()
    horizontalWheelTests()
}

private func horizontalWheelTests() {
    for json in [#"{"mouse":{"horizontalWheel":null}}"#, #"{"mouse":{"horizontalWheel":{}}}"#,
                 #"{"mouse":{"horizontalWheel":{"left":{},"right":null}}}"#] {
        expectConfig(json, AppConfig())
    }
    expect(AppConfig().mouse.horizontalWheel.isEmpty && AppConfig.newFileDefaults.mouse.horizontalWheel.isEmpty,
           "wheel directions are unbound by default")
    let json = #"{"helpers":{"previousWindow":"aerospace focus left"},"mouse":{"horizontalWheel":{"left":{"helper":"previousWindow"},"right":{"shortcut":["ctrl","down"]}}}}"#
    let config = decode(json)!.config
    expectEqual(config.mouse.horizontalWheel, WheelMap(left: .helper("previousWindow"), right: shortcut(["ctrl", "down"])))
    expectEqual(config.mouse.horizontalWheel.action(for: .left), .helper("previousWindow"))
    expectEqual(config.mouse.horizontalWheel.action(for: .right), shortcut(["ctrl", "down"]))
    expectEqual(config.resolvedActions().mouse.horizontalWheel.left, .shell("aerospace focus left"), "wheel helpers resolve")
    expectConfig(text(config), config)

    // Only mapped directions are written; an empty map is omitted.
    let single = AppConfig(mouse: MouseConfig(horizontalWheel: WheelMap(right: .shell("next"))))
    let wheel = (jsonObject(encodeConfig(single))["mouse"] as? [String: Any])?["horizontalWheel"] as? [String: Any]
    expectEqual(Set(wheel?.keys.map { $0 } ?? []), ["right"], "unmapped left is omitted")
    expect((jsonObject(encodeConfig(AppConfig()))["mouse"] as? [String: Any])?["horizontalWheel"] == nil, "empty wheel map omitted")

    expectEqual(decode(#"{"mouse":{"horizontalWheel":{"up":{},"left":{"open":"x","shell":"a"}}}}"#)?.unknownKeys,
                ["mouse.horizontalWheel.up", "mouse.horizontalWheel.left.open"], "unknown wheel keys are reported")
    expectRejected(#"{"mouse":{"horizontalWheel":{"left":{"helper":"missing"}}}}"#, "mouse.horizontalWheel.left.helper: unknown helper \"missing\"")
    expectRejected(#"{"mouse":{"horizontalWheel":{"right":{"helper":"missing"}}}}"#, "mouse.horizontalWheel.right.helper: unknown helper \"missing\"")
    expectRejected(#"{"mouse":{"horizontalWheel":{"left":{"shell":"a","shortcut":["cmd","a"]}}}}"#,
                   "mouse.horizontalWheel.left: needs exactly one of shortcut/shell/helper")
    expectRejected(#"{"mouse":{"horizontalWheel":{"right":{"shortcut":["cmd"]}}}}"#,
                   "mouse.horizontalWheel.right.shortcut: shortcut [\"cmd\"] needs exactly one key besides modifiers")
    expectRejected(#"{"mouse":{"horizontalWheel":{"left":"next"}}}"#, "mouse.horizontalWheel.left: expected an object")
    expectRejected(#"{"mouse":{"horizontalWheel":[]}}"#, "mouse.horizontalWheel: expected an object")
}

private func helperTests() {
    let json = #"{"helpers":{"shared":"echo hi"},"mouse":{"buttons":{"back":{"helper":"shared"},"forward":{"helper":"shared"},"thumb":{"helper":"shared"}}},"trackpad":{"threeFingerSwipe":{"up":{"helper":"shared"},"down":{"helper":"shared"},"left":{"helper":"shared"},"right":{"helper":"shared"}},"fourFingerSwipe":{"up":{"helper":"shared"},"down":{"helper":"shared"},"left":{"helper":"shared"},"right":{"helper":"shared"}}}}"#
    let config = decode(json)!.config
    expectEqual(config.helpers, ["shared": "echo hi"])
    expectEqual(config.mouse.buttons.back, .helper("shared"))
    let encoded = jsonObject(encodeConfig(config))
    expectEqual(encoded["helpers"] as? [String: String], ["shared": "echo hi"])
    let buttons = (encoded["mouse"] as! [String: Any])["buttons"] as! [String: Any]
    expectEqual((buttons["back"] as! [String: String])["helper"], "shared")
    expectEqual(decode(String(decoding: encodeConfig(config), as: UTF8.self))?.config, config)
    let effective = config.resolvedActions()
    for action in [effective.mouse.buttons.back, effective.mouse.buttons.forward, effective.mouse.buttons.thumb] {
        expectEqual(action, .shell("echo hi"))
    }
    for fingers in [3, 4] {
        for direction in SwipeDirection.allCases {
            expectEqual(effective.trackpad.action(fingers: fingers, direction: direction), .shell("echo hi"))
        }
    }
    var changed = config
    changed.helpers["shared"] = "echo changed"
    expectEqual(changed.resolvedActions().trackpad.threeFingerSwipe, SwipeMap(up: .shell("echo changed"), down: .shell("echo changed"), left: .shell("echo changed"), right: .shell("echo changed")))
    expectRejected(#"{"helpers":{"shared":" "}}"#, "helpers.shared: command cannot be empty")
    expectRejected(#"{"helpers":{" ":"echo"}}"#, "helpers: name cannot be empty")
    expectRejected(#"{"mouse":{"buttons":{"back":{"helper":"missing"}}}}"#, "mouse.buttons.back.helper: unknown helper \"missing\"")
    expectRejected(#"{"mouse":{"buttons":{"back":{"helper":" "}}}}"#, "mouse.buttons.back.helper: name cannot be empty")
    expectRejected(#"{"helpers":{"shared":"echo"},"mouse":{"buttons":{"back":{"helper":"shared","shell":"echo"}}}}"#, "mouse.buttons.back: needs exactly one of shortcut/shell/helper")
}

private func trackpadTests() {
    expectEqual(SwipeDirection.allCases.map(\.rawValue), ["up", "down", "left", "right"], "swipe directions")
    for json in ["{\"trackpad\":null}", "{\"trackpad\":{}}", "{\"trackpad\":{\"threeFingerSwipe\":null,\"fourFingerSwipe\":{}}}"] {
        expectConfig(json, AppConfig())
    }
    let three = SwipeMap(up: .shell("echo up"), down: shortcut(["cmd", "a"]),
                         left: .shell("echo left"), right: shortcut(["cmd", "b"]))
    let four = SwipeMap(up: shortcut(["cmd", "c"]), down: .shell("echo down"),
                        left: shortcut(["cmd", "d"]), right: .shell("echo right"))
    let config = AppConfig(trackpad: TrackpadConfig(threeFingerSwipe: three, fourFingerSwipe: four))
    expectConfig(text(config), config)
    let root = jsonObject(encodeConfig(config))
    let trackpad = root["trackpad"] as? [String: Any]
    expectEqual(Set(trackpad?.keys.map { $0 } ?? []), ["threeFingerSwipe", "fourFingerSwipe"], "both groups encoded")
    for fingers in [3, 4] {
        let map = fingers == 3 ? three : four
        let group = trackpad?[fingers == 3 ? "threeFingerSwipe" : "fourFingerSwipe"] as? [String: Any]
        expectEqual(Set(group?.keys.map { $0 } ?? []), Set(SwipeDirection.allCases.map(\.rawValue)), "all directions encoded")
        expect(config.trackpad.hasMappings(fingers: fingers), "mapped finger count")
        for direction in SwipeDirection.allCases {
            expectEqual(config.trackpad.action(fingers: fingers, direction: direction), map.action(for: direction), "action lookup")
        }
    }
    expect(config.trackpad.hasMappings, "has mappings")
    expect(!config.trackpad.hasMappings(fingers: 2) && !config.trackpad.hasMappings(fingers: 5), "unsupported fingers")
    expect(config.trackpad.action(fingers: 2, direction: .up) == nil && config.trackpad.action(fingers: 5, direction: .right) == nil,
           "unsupported finger actions")
    expect(!TrackpadConfig().hasMappings && !TrackpadConfig().hasMappings(fingers: 3) && !TrackpadConfig().hasMappings(fingers: 4), "empty mappings")
    expectEqual(SwipeMap().action(for: .up), nil, "empty direction")
    let single = AppConfig(trackpad: TrackpadConfig(threeFingerSwipe: SwipeMap(left: .shell("x"))))
    let singleTrackpad = jsonObject(encodeConfig(single))["trackpad"] as? [String: Any]
    expectEqual(Set(singleTrackpad?.keys.map { $0 } ?? []), ["threeFingerSwipe"], "empty group omitted")
    expectEqual(Set((singleTrackpad?["threeFingerSwipe"] as? [String: Any])?.keys.map { $0 } ?? []), ["left"], "nil directions omitted")
    expectConfig(text(single), single)
    let onlyFour = AppConfig(trackpad: TrackpadConfig(fourFingerSwipe: SwipeMap(right: .shell("x"))))
    expectEqual(Set((jsonObject(encodeConfig(onlyFour))["trackpad"] as? [String: Any])?.keys.map { $0 } ?? []),
                ["fourFingerSwipe"], "empty three-finger group omitted")
    expectConfig(text(onlyFour), onlyFour)
    expectEqual(decode("{\"trackpad\":{\"extra\":1,\"threeFingerSwipe\":{\"diagonal\":1,\"left\":{\"open\":\"x\",\"shell\":\"a\"}}}}")?.unknownKeys,
                ["trackpad.extra", "trackpad.threeFingerSwipe.diagonal", "trackpad.threeFingerSwipe.left.open"], "nested unknown paths")
    expectRejected("{\"trackpad\":[]}", "trackpad: expected an object")
    expectRejected("{\"trackpad\":{\"threeFingerSwipe\":1}}", "trackpad.threeFingerSwipe: expected an object")
    expectRejected("{\"trackpad\":{\"fourFingerSwipe\":{\"up\":true}}}", "trackpad.fourFingerSwipe.up: expected an object")
    expectRejected("{\"trackpad\":{\"threeFingerSwipe\":{\"left\":{\"shortcut\":[\"cmd\",5]}}}}",
                   "trackpad.threeFingerSwipe.left.shortcut[1]: expected a string")
    expectRejected("{\"trackpad\":{\"fourFingerSwipe\":{\"right\":{\"shell\":\"x\",\"shortcut\":[\"cmd\",\"a\"]}}}}",
                   "trackpad.fourFingerSwipe.right: needs exactly one of shortcut/shell/helper")
    expectRejected("{\"trackpad\":{\"threeFingerSwipe\":{\"down\":{\"shortcut\":[\"cmd\"]}}}}",
                   "trackpad.threeFingerSwipe.down.shortcut: shortcut [\"cmd\"] needs exactly one key besides modifiers")
}

private func anyKeyTests() {
    // Object keys are strings only: an array position is never a key.
    expect(AnyKey(intValue: 3) == nil, "integer keys are rejected")
    let key = AnyKey(stringValue: "mouse")
    expectEqual(key?.stringValue, "mouse", "string keys are kept")
    expect(key?.intValue == nil && AnyKey("x").intValue == nil, "string keys have no integer value")
}

private func decodeDefaultsTests() {
    expectConfig("{}", AppConfig())
    expectEqual(AppConfig(), AppConfig(capsLock: .threeMod, caffeineOnLaunch: true, launchAtLogin: false, autoUpdate: true, mouse: MouseConfig()),
                "documented defaults")
    expectConfig("{\"autoUpdate\":true}", AppConfig(autoUpdate: true))
    expectConfig("{\"autoUpdate\":false}", AppConfig(autoUpdate: false))
    expectConfig("{\"autoUpdate\":null}", AppConfig())
    expectConfig("{\"caffeineOnLaunch\":false}", AppConfig(caffeineOnLaunch: false))
    expectConfig("{\"caffeineOnLaunch\":null}", AppConfig())
    expectConfig("{\"launchAtLogin\":true}", AppConfig(launchAtLogin: true))
    expectConfig("{\"capsLock\":null}", AppConfig())
    expectConfig("{\"capsLock\":\"default\"}", AppConfig(capsLock: .default))
    expectConfig("{\"capsLock\":\"hyper\"}", AppConfig(capsLock: .hyper))
    expectConfig("{\"capsLock\":\"meh\"}", AppConfig(capsLock: .meh))
    expectConfig("{\"capsLock\":\"threeMod\"}", AppConfig(capsLock: .threeMod))
    expectConfig("{\"mouse\":{\"invertScroll\":{\"vertical\":true}}}",
                 AppConfig(mouse: MouseConfig(invertScroll: InvertScroll(vertical: true))))
    expectConfig("{\"mouse\":{\"invertScroll\":{\"horizontal\":true}}}",
                 AppConfig(mouse: MouseConfig(invertScroll: InvertScroll(horizontal: true))))
    expectConfig("{\"mouse\":{\"buttons\":{}}}", AppConfig())
    expectConfig("{\"mouse\":null}", AppConfig())
    expectConfig("{\"mouse\":{\"invertScroll\":null}}", AppConfig())

    // Empty or whitespace-only data is "all defaults" without a decoder run.
    for blank in ["", "  \n\t ", "\n"] {
        expectEqual(decode(blank), DecodedConfig(config: AppConfig(), unknownKeys: []), "blank data \(blank.debugDescription)")
    }
    expect(isBlankConfigData(Data()) && isBlankConfigData(Data("  \n".utf8)) && isBlankConfigData(Data("\n".utf8)),
           "empty and whitespace-only data is blank")
    expect(!isBlankConfigData(Data("{}".utf8)), "{} is not blank")

    expect(!CapsMode.default.isModifier && CapsMode.meh.isModifier && CapsMode.threeMod.isModifier && CapsMode.hyper.isModifier,
           "all non-default modes are modifiers")
    expectEqual(CapsMode.allCases.map { $0.rawValue }, ["default", "meh", "threeMod", "hyper"], "capsLock vocabulary")
}

private func decodeActionTests() {
    let full = decode("""
    {
      "$schema": "./hypermug.schema.json",
      "capsLock": "hyper",
      "caffeineOnLaunch": false,
      "launchAtLogin": true,
      "mouse": {
        "invertScroll": { "vertical": false, "horizontal": true },
        "buttons": {
          "back":    { "shortcut": ["cmd", "["] },
          "forward": { "shortcut": ["cmd", "]"] },
          "thumb":   { "shell": "open -a 'Mission Control'" }
        }
      }
    }
    """)
    let expectedFull = AppConfig(
        capsLock: .hyper, caffeineOnLaunch: false, launchAtLogin: true,
        mouse: MouseConfig(
            invertScroll: InvertScroll(vertical: false, horizontal: true),
            buttons: ButtonMap(back: shortcut(["cmd", "["]), forward: shortcut(["cmd", "]"]),
                               thumb: .shell("open -a 'Mission Control'"))))
    expectEqual(full?.config, expectedFull, "full example")
    expectEqual(full?.unknownKeys, [], "$schema is a known key")
    if case .shortcut(let back)? = full?.config.mouse.buttons.back {
        expect(back.keyCode == 33 && back.flags == .maskCommand && back.tokens == ["cmd", "["], "back is cmd+[ with tokens kept")
    } else {
        expect(false, "back must be a shortcut")
    }

    // Unmapped: absent, null, {}, blank values, empty arrays.
    expectConfig("{\"mouse\":{\"buttons\":{\"thumb\":null}}}", AppConfig())
    expectConfig(withBack("{}"), AppConfig())
    expectConfig(withBack("null"), AppConfig())
    expectConfig(withBack("{\"shortcut\":null}"), AppConfig())
    expectConfig(withBack("{\"shell\":null}"), AppConfig())
    expectConfig(withBack("{\"shell\":\"\"}"), AppConfig())
    expectConfig(withBack("{\"shell\":\"  \\n \"}"), AppConfig())
    expectConfig(withBack("{\"shortcut\":[]}"), AppConfig())
    expectConfig(withBack("{\"shortcut\":\"\"}"), AppConfig())
    expectConfig(withBack("{\"shortcut\":\"  \"}"), AppConfig())
    expectConfig(withBack("{\"shell\":\"\",\"shortcut\":\"\"}"), AppConfig())
    // The `open` action kind is gone: a button holding only it is unmapped.
    expectConfig(withBack("{\"open\":\"/x\"}"), AppConfig())

    // A blank kind next to a real one is ignored.
    let back = { (action: ButtonAction) in AppConfig(mouse: MouseConfig(buttons: ButtonMap(back: action))) }
    expectConfig(withBack("{\"shell\":\"\",\"shortcut\":[\"cmd\",\"[\"]}"), back(shortcut(["cmd", "["])))
    expectConfig(withBack("{\"shell\":\"a\",\"shortcut\":[]}"), back(.shell("a")))
    expectConfig(withBack("{\"shell\":\"a\",\"shortcut\":\"\"}"), back(.shell("a")))
    expectConfig(withBack("{\"shell\":\"a\",\"shortcut\":null}"), back(.shell("a")))
    expectConfig(withBack("{\"shell\":\"a\",\"open\":\"y\"}"), back(.shell("a")))
    // Shell text is kept verbatim, including surrounding spaces.
    expectConfig(withBack("{\"shell\":\" echo hi \"}"), back(.shell(" echo hi ")))
    // The decoder is case-insensitive and keeps the tokens as written.
    expectConfig(withBack("{\"shortcut\":[\"CMD\",\"Opt\",\"Esc\"]}"), back(shortcut(["CMD", "Opt", "Esc"])))
    // Each button decodes on its own.
    expectConfig("{\"mouse\":{\"buttons\":{\"forward\":{\"shell\":\"f\"},\"thumb\":{\"shell\":\"t\"}}}}",
                 AppConfig(mouse: MouseConfig(buttons: ButtonMap(forward: .shell("f"), thumb: .shell("t")))))
}

private func decodeRejectionTests() {
    expectRejected("{\"capsLock\":\"upper\"}", "capsLock must be \"default\", \"meh\", \"threeMod\" or \"hyper\" (got \"upper\")")
    expectRejected("{\"capsLock\":5}", "capsLock: expected a string")
    expectRejected("{\"caffeineOnLaunch\":\"yes\"}", "caffeineOnLaunch: expected true or false")
    expectRejected("{\"launchAtLogin\":1}", "launchAtLogin: expected true or false")
    expectRejected("{\"autoUpdate\":\"false\"}", "autoUpdate: expected true or false")
    expectRejected("{\"autoUpdate\":1}", "autoUpdate: expected true or false")
    expectRejected("{\"mouse\":\"x\"}", "mouse: expected an object")
    expectRejected("{\"mouse\":{\"invertScroll\":{\"vertical\":\"yes\"}}}", "mouse.invertScroll.vertical: expected true or false")
    expectRejected("{\"mouse\":{\"buttons\":[]}}", "mouse.buttons: expected an object")
    expectRejected("[]", "config must be a JSON object")
    expectRejected("null", "config must be a JSON object")
    expectRejected("5", "config must be a JSON object")

    // Broken JSON: the parser's own detail (with its position) is shown.
    for broken in ["{", "{\"a\":}", "nul", "{\"capsLock\":\"meh\"} x"] {
        let reason = rejectionReason(broken) ?? ""
        expect(reason.hasPrefix("invalid JSON: ") && reason.count > "invalid JSON: ".count, "JSON error for \(broken): \(reason)")
    }
    expect((rejectionReason("{\"a\":}") ?? "").contains("column 6"), "the JSON error names the position")

    // Actions
    expectRejected("{\"mouse\":{\"buttons\":{\"thumb\":{\"shell\":\"x\",\"shortcut\":[\"cmd\",\"k\"]}}}}",
                   "mouse.buttons.thumb: needs exactly one of shortcut/shell/helper")
    expectRejected(withBack("{\"shortcut\":[\"cmd\",\"nope\"]}"),
                   "mouse.buttons.back.shortcut: unknown key or modifier \"nope\" in shortcut [\"cmd\", \"nope\"]")
    expectRejected(withBack("{\"shortcut\":[\"cmd\"]}"),
                   "mouse.buttons.back.shortcut: shortcut [\"cmd\"] needs exactly one key besides modifiers")
    expectRejected(withBack("{\"shortcut\":[\"a\",\"b\"]}"),
                   "mouse.buttons.back.shortcut: shortcut [\"a\", \"b\"] has more than one key (\"a\" and \"b\")")
    expectRejected(withBack("{\"shortcut\":[\"cmd\",\"\"]}"),
                   "mouse.buttons.back.shortcut: empty key in shortcut [\"cmd\", \"\"]")
    expect((rejectionReason(withBack("{\"shortcut\":[\"cmd+k\"]}")) ?? "").contains("write each key as its own array item"),
           "a plus-joined token gets the array hint")
    expectRejected(withBack("{\"shortcut\":[\"cmd\",5]}"), "mouse.buttons.back.shortcut[1]: expected a string")
    expectRejected(withBack("{\"shortcut\":[\"cmd\",null]}"), "mouse.buttons.back.shortcut[1]: expected a string")
    expectRejected(withBack("{\"shortcut\":5}"), "mouse.buttons.back.shortcut: expected an array")
    expectRejected(withBack("{\"shell\":5}"), "mouse.buttons.back.shell: expected a string")
    expectRejected("{\"mouse\":{\"buttons\":{\"back\":\"cmd+[\"}}}", "mouse.buttons.back: expected an object")
    // The old string form is gone; the error tells the user to use an array.
    let hint = "mouse.buttons.back.shortcut must be an array of keys, e.g. [\"cmd\", \"[\"]"
    expectRejected(withBack("{\"shortcut\":\"cmd+[\"}"), hint)
    expectRejected(withBack("{\"shortcut\":\"cmd+[\",\"shell\":\"\"}"), hint)
    // Two real kinds is the error, reported before the shortcut itself is looked at.
    expectRejected(withBack("{\"shell\":\"a\",\"shortcut\":[\"nope\"]}"), "mouse.buttons.back: needs exactly one of shortcut/shell/helper")
}

private func unknownKeyTests() {
    expectEqual(decode("{\"caffeine\":true}")?.unknownKeys, ["caffeine"], "a leftover caffeine key is unknown")
    expectConfig("{\"caffeine\":true}", AppConfig())
    expectConfig("{\"caffeine\":\"yes\"}", AppConfig())   // whatever its value
    expectConfig("{\"capslock\":\"hyper\"}", AppConfig())
    let letters = ["z", "y", "x", "w", "v", "u", "t", "s", "r", "q"]
    let unsorted = "{" + letters.map { "\"\($0)\":1" }.joined(separator: ",") + "}"
    expectEqual(decode(unsorted)?.unknownKeys, letters.sorted(), "unknown keys of one object are sorted")
    expectEqual(
        decode("""
        {"capslock":"x","mouse":{"foo":1,"invertScroll":{"diagonal":true},"buttons":{"zzz":1,"back":{"open":"x","shell":"s"}}}}
        """)?.unknownKeys,
        ["capslock", "mouse.foo", "mouse.invertScroll.diagonal", "mouse.buttons.zzz", "mouse.buttons.back.open"],
        "unknown keys are reported as dotted paths")
    expectEqual(decode("{\"capsLock\":\"meh\",\"autoUpdate\":false,\"$schema\":\"x\"}")?.unknownKeys, [], "known keys are not reported")
    expectEqual(decode(withBack("{\"shell\":\"a\"}"))?.unknownKeys, [], "no unknown keys in a plain mapping")
}

private func encodeTests() {
    // Default write shape (R7): no caffeine key, no buttons key, no empty entries, exactly this text.
    let expectedDefault = """
    {
      "autoUpdate" : true,
      "caffeineOnLaunch" : true,
      "capsLock" : "threeMod",
      "launchAtLogin" : false,
      "mouse" : {
        "invertScroll" : {
          "horizontal" : false,
          "vertical" : false
        }
      },
      "shellTimeoutSeconds" : 10
    }

    """
    expectEqual(text(AppConfig()), expectedDefault, "default encoding")
    let next = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around next"
    let prev = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around prev"
    let expectedNewFile: [String: Any] = [
        "shellTimeoutSeconds": 10,
        "autoUpdate": true, "caffeineOnLaunch": true, "capsLock": "threeMod", "launchAtLogin": true,
        "mouse": ["invertScroll": ["horizontal": false, "vertical": false],
                  "buttons": ["back": ["shell": next], "forward": ["shell": prev]]],
        "trackpad": ["threeFingerSwipe": ["left": ["shell": next], "right": ["shell": prev]],
                     "fourFingerSwipe": ["left": ["shell": next], "right": ["shell": prev]]]
    ]
    expectEqual(jsonObject(encodeConfig(.newFileDefaults)) as NSDictionary,
                expectedNewFile as NSDictionary, "new-file JSON matches requested behavior")
    expectConfig(text(.newFileDefaults), .newFileDefaults)
    expectConfig(text(AppConfig()), AppConfig())
    expectConfig(text(AppConfig(autoUpdate: false)), AppConfig(autoUpdate: false))
    expectEqual(jsonObject(encodeConfig(AppConfig(autoUpdate: false)))["autoUpdate"] as? Bool, false,
                "disabled automatic updates are encoded")

    // Only mapped buttons are written; a mapped button has only its one action key.
    let mapped = AppConfig(mouse: MouseConfig(buttons: ButtonMap(back: shortcut(["cmd", "["]), thumb: .shell("echo hi"))))
    let mouse = jsonObject(encodeConfig(mapped))["mouse"] as? [String: Any]
    let buttons = mouse?["buttons"] as? [String: Any]
    expectEqual(Set(buttons?.keys.map { $0 } ?? []), ["back", "thumb"], "unmapped forward is omitted")
    expectEqual((buttons?["back"] as? NSDictionary), ["shortcut": ["cmd", "["]] as NSDictionary, "back = {shortcut}")
    expectEqual((buttons?["thumb"] as? NSDictionary), ["shell": "echo hi"] as NSDictionary, "thumb = {shell}")
    expect(!text(mapped).contains("\"\"") && !text(mapped).contains("null"), "no empty strings or nulls are written")
    expectConfig(text(mapped), mapped)

    // Full round trip, shortcut tokens verbatim, slashes unescaped, trailing newline, $schema first.
    let all = AppConfig(
        capsLock: .hyper, caffeineOnLaunch: false, launchAtLogin: true,
        mouse: MouseConfig(
            invertScroll: InvertScroll(vertical: true, horizontal: true),
            buttons: ButtonMap(back: shortcut(["CMD", "Shift", "["]), forward: shortcut(["cmd", "]"]),
                               thumb: .shell("echo \"hi\" >> /tmp/x"))))
    let allText = text(all)
    expectConfig(allText, all)
    expect(allText.contains("/tmp/x\""), "slashes are not escaped")
    expect(allText.contains("\"CMD\""), "shortcut tokens are written back as written")
    expect(allText.hasSuffix("}\n"), "encoded config ends with a newline")
    expect(!allText.contains("$schema"), "plain model encoding has no filesystem reference")
    expectEqual(text(all), allText, "encoding is deterministic")
}
