import Foundation
@testable import HyperMugCore

private typealias JSON = [String: Any]

private func jsonObject(_ text: String) -> JSON {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? JSON ?? [:]
}

private func shortcut(_ tokens: [String]) -> ButtonAction {
    if case .success(let s) = parseShortcut(tokens) { return .shortcut(s) }
    preconditionFailure("test shortcut \(tokens) must parse")
}

private func accepts(_ tokens: [String]) -> Bool {
    if case .success = parseShortcut(tokens) { return true }
    return false
}

func schemaTests() {
    schemaStructureTests()
    schemaReferenceTests()
}

private func schemaStructureTests() {
    let schema = jsonObject(configSchemaJSON)
    expectEqual(schema["$schema"] as? String, "http://json-schema.org/draft-07/schema#", "draft-07")
    expectEqual(schema["title"] as? String, "HyperMug configuration", "title")
    expect(!schema.isEmpty, "the schema is valid JSON")

    func child(_ node: JSON, _ key: String) -> JSON {
        guard let next = (node["properties"] as? JSON)?[key] as? JSON else {
            expect(false, "schema has no property \(key)")
            return [:]
        }
        return next
    }
    func node(_ path: [String]) -> JSON { path.reduce(schema) { child($0, $1) } }
    func propertyPaths(_ node: JSON, _ path: String) -> [String] {
        var paths = [path]
        for key in ((node["properties"] as? JSON) ?? [:]).keys.sorted() {
            paths += propertyPaths(child(node, key), path.isEmpty ? key : "\(path).\(key)")
        }
        return paths
    }

    // Encoded configs validate structurally against the schema: every key is known, required keys are present,
    // types match, a button satisfies exactly one `oneOf` branch, and every schema property gets exercised.
    var seen = Set<String>()
    func validate(_ node: JSON, _ value: Any, _ path: String) {
        let label = path.isEmpty ? "<root>" : path
        seen.insert(path)
        expect((node["description"] as? String)?.isEmpty == false, "schema \(label) needs a description")
        if let object = value as? JSON {
            expectEqual(node["type"] as? String, "object", "schema \(label) is an object")
            if path == "helpers" {
                expect(object.values.allSatisfy { $0 is String }, "helper values are commands")
                return
            }
            expectEqual(node["additionalProperties"] as? Bool, false, "schema \(label) forbids additional properties")
            let properties = node["properties"] as? JSON ?? [:]
            let keys = Set(object.keys)
            expect(keys.isSubset(of: Set(properties.keys)), "encoded \(label) keys \(keys.sorted()) are not all in the schema")
            let required = Set(node["required"] as? [String] ?? [])
            expect(required.isSubset(of: keys), "schema \(label) requires \(required.sorted()), encoded has \(keys.sorted())")
            if let oneOf = node["oneOf"] as? [JSON] {
                let matching = oneOf.filter { branch in
                    guard Set(branch["required"] as? [String] ?? []).isSubset(of: keys) else { return false }
                    if let maximum = branch["maxProperties"] as? Int, object.count > maximum { return false }
                    for (name, rule) in (branch["properties"] as? [String: JSON]) ?? [:] {
                        if let s = object[name] as? String, let minLength = rule["minLength"] as? Int, s.count < minLength { return false }
                    }
                    return true
                }
                expectEqual(matching.count, 1, "schema \(label) oneOf matches exactly one branch")
            }
            for (key, inner) in object {
                validate(child(node, key), inner, path.isEmpty ? key : "\(path).\(key)")
            }
        } else if let array = value as? [Any] {
            expectEqual(node["type"] as? String, "array", "schema \(label) is an array")
            expect(array.count >= (node["minItems"] as? Int ?? 0), "schema \(label) minItems")
            let pattern = (node["items"] as? JSON)?["pattern"] as? String ?? "(?!)"
            for token in array {
                expect((token as? String)?.range(of: pattern, options: .regularExpression) != nil, "schema token matches native parser")
            }
        } else if value is String {
            expectEqual(node["type"] as? String, "string", "schema \(label) is a string")
        } else if let number = value as? NSNumber, String(cString: number.objCType) != "c" {
            expectEqual(node["type"] as? String, "number", "schema \(label) is numeric")
        } else {
            expectEqual(node["type"] as? String, "boolean", "schema \(label) is a boolean")
        }
    }
    func encoded(_ config: AppConfig) -> Any { jsonObject(String(decoding: encodeConfig(config, schemaURL: URL(fileURLWithPath: "/Applications/HyperMug.app/Contents/Resources/hypermug.schema.json")), as: UTF8.self)) }

    let mapped = AppConfig(mouse: MouseConfig(buttons: ButtonMap(back: shortcut(["cmd", "["]), thumb: .shell("echo hi"))))
    let fullyMapped = AppConfig(
        capsLock: .hyper, caffeineOnLaunch: false, launchAtLogin: true,
        mouse: MouseConfig(invertScroll: InvertScroll(vertical: true, horizontal: true),
                           buttons: ButtonMap(back: shortcut(["cmd", "["]), forward: shortcut(["cmd", "]"]), thumb: .shell("echo hi")),
                           horizontalWheel: WheelMap(left: shortcut(["ctrl", "up"]), right: .shell("echo down"))))
    let swapped = AppConfig(mouse: MouseConfig(buttons: ButtonMap(
        back: .shell("echo back"), forward: .shell("echo forward"), thumb: shortcut(["meh", "k"])),
        horizontalWheel: WheelMap(left: .shell("echo up"), right: shortcut(["ctrl", "down"]))))
    let swipes = AppConfig(trackpad: TrackpadConfig(
        threeFingerSwipe: SwipeMap(up: .shell("up"), down: shortcut(["cmd", "a"]),
                                   left: .shell("left"), right: shortcut(["cmd", "b"])),
        fourFingerSwipe: SwipeMap(up: shortcut(["cmd", "c"]), down: .shell("down"),
                                  left: shortcut(["cmd", "d"]), right: .shell("right"))))
    let swappedSwipes = AppConfig(trackpad: TrackpadConfig(
        threeFingerSwipe: SwipeMap(up: shortcut(["cmd", "a"]), down: .shell("down"),
                                   left: shortcut(["cmd", "b"]), right: .shell("right")),
        fourFingerSwipe: SwipeMap(up: .shell("up"), down: shortcut(["cmd", "c"]),
                                  left: .shell("left"), right: shortcut(["cmd", "d"]))))
    let helperMap = SwipeMap(up: .helper("shared"), down: .helper("shared"),
                             left: .helper("shared"), right: .helper("shared"))
    let helper = AppConfig(mouse: MouseConfig(buttons: ButtonMap(back: .helper("shared"),
                                                                 forward: .helper("shared"), thumb: .helper("shared")),
                                              horizontalWheel: WheelMap(left: .helper("shared"), right: .helper("shared"))),
                           trackpad: TrackpadConfig(threeFingerSwipe: helperMap,
                                                    fourFingerSwipe: helperMap),
                           helpers: ["shared": "echo shared"])
    for sample in [AppConfig(), .newFileDefaults, mapped, fullyMapped, swapped, swipes, swappedSwipes, helper] {
        validate(schema, encoded(sample), "")
    }
    expectEqual(Set(propertyPaths(schema, "")).subtracting(seen), [], "schema properties without an encoded counterpart")

    // Required keys: exactly as decided, and every one is in the encoded default.
    let rootRequired = Set(schema["required"] as? [String] ?? [])
    expectEqual(rootRequired, [], "sparse existing files use native defaults")
    expect(rootRequired.isSubset(of: Set((encoded(AppConfig()) as? JSON ?? [:]).keys)), "encoded default has every required root key")
    expectEqual(Set(node(["mouse"])["required"] as? [String] ?? []), [], "mouse keys are optional")
    expectEqual(Set(node(["mouse", "invertScroll"])["required"] as? [String] ?? []), [], "scroll keys are optional")
    expect(node(["mouse", "buttons"])["required"] == nil, "buttons has no required keys")
    expect(((schema["properties"] as? JSON) ?? [:])["caffeine"] == nil, "the schema does not know the removed caffeine key")
    expectEqual(Set(node(["capsLock"])["enum"] as? [String] ?? []), Set(CapsMode.allCases.map { $0.rawValue }), "capsLock enum == CapsMode cases")
    expectEqual(Set((node(["mouse"])["properties"] as? JSON ?? [:]).keys), ["invertScroll", "buttons", "horizontalWheel"], "mouse properties")
    expect(node(["mouse", "horizontalWheel"])["required"] == nil, "wheel directions are optional")
    expectEqual(Set((node(["mouse", "horizontalWheel"])["properties"] as? JSON ?? [:]).keys),
                Set(WheelDirection.allCases.map(\.rawValue)), "wheel directions")
    expect((node(["mouse", "horizontalWheel"])["description"] as? String)?.contains("Natural Scrolling") == true,
           "schema explains that wheel bindings use the physical direction")
    expect(!rootRequired.contains("trackpad"), "trackpad is optional for old configs")
    expect(!rootRequired.contains("autoUpdate"), "autoUpdate is optional for old configs")
    expectEqual(node(["autoUpdate"])["type"] as? String, "boolean", "autoUpdate schema type")
    expectEqual((encoded(AppConfig()) as? JSON)?["autoUpdate"] as? Bool, true, "new defaults encode autoUpdate")
    expectEqual((encoded(AppConfig(autoUpdate: false)) as? JSON)?["autoUpdate"] as? Bool, false,
                "disabled autoUpdate encodes as false")
    expectEqual(try? decodeConfig(Data("{\"capsLock\":\"meh\"}".utf8)).get().config.autoUpdate, true,
                "legacy config without autoUpdate keeps automatic checks enabled")
    expect((node(["trackpad"])["description"] as? String)?.contains("System Settings") == true,
           "schema explains one-time native gesture setup")
    expectEqual(Set((node(["trackpad"])["properties"] as? JSON ?? [:]).keys), ["threeFingerSwipe", "fourFingerSwipe"], "trackpad groups")
    for group in ["threeFingerSwipe", "fourFingerSwipe"] {
        expect(node(["trackpad", group])["required"] == nil, "swipe group has no required directions")
        expectEqual(Set((node(["trackpad", group])["properties"] as? JSON ?? [:]).keys),
                    Set(SwipeDirection.allCases.map(\.rawValue)), "four directions")
    }

    // Buttons: one shell string or one non-empty shortcut array of known tokens.
    let tokenSet = Set(shortcutTokenNames)
    for path in (["back", "forward", "thumb"].map { ["mouse", "buttons", $0] } +
                 ["left", "right"].map { ["mouse", "horizontalWheel", $0] } +
                 ["threeFingerSwipe", "fourFingerSwipe"].flatMap { group in
                     SwipeDirection.allCases.map { ["trackpad", group, $0.rawValue] }
                 }) {
        let button = path.joined(separator: ".")
        let b = node(path)
        expect(b["required"] == nil, "\(button) is not required to contain a particular key itself")
        expectEqual(Set((b["properties"] as? JSON ?? [:]).keys), ["shell", "shortcut", "helper"], "\(button) properties")
        expectEqual(child(b, "shell")["type"] as? String, "string", "\(button).shell is a string")
        let branches = b["oneOf"] as? [JSON] ?? []
        expectEqual(branches.count, 4, "\(button) accepts an empty slot or exactly one action")
        expect(branches.contains { $0["maxProperties"] as? Int == 0 }, "empty slot branch is present")
        let shellBranch = branches.first { ($0["required"] as? [String]) == ["shell"] }
        let shellRule = (shellBranch?["properties"] as? JSON)?["shell"] as? JSON
        expectEqual(shellRule?["minLength"] as? Int, 1, "\(button).shell must be non-empty")
        expect(branches.contains { ($0["required"] as? [String]) == ["shortcut"] }, "\(button) oneOf has a shortcut branch")
        let sc = child(b, "shortcut")
        expect(sc["type"] as? String == "array" && sc["minItems"] as? Int == 1, "\(button).shortcut is a non-empty array")
    }

    // The enum and the parser agree in both directions, and the parser is case-insensitive for every token.
    for token in shortcutTokenNames {
        let asKey = accepts([token]), asModifier = accepts([token, "a"])
        expect(asKey != asModifier, "token \(token) is exactly one of key / modifier")
        expect(accepts([token.uppercased()] + (asModifier ? ["a"] : [])), "token \(token) is accepted in upper case")
    }
    var candidates = (0x20...0x7E).map { String(UnicodeScalar(UInt8($0))) }
    candidates += (1...30).map { "f\($0)" }
    candidates += ["esc", "escape", "pgup", "pageup", "capslock", "fn", "command", "control", "plus", "minus", "return", "enter", "del",
                   "backspace", "forwarddelete", "insert", "menu", "super", "win", "alt", "opt", "option", "meh", "threemod", "hyper"]
    for candidate in candidates.map({ $0.lowercased() }) where accepts([candidate]) || accepts([candidate, "a"]) {
        expect(tokenSet.contains(candidate), "parser accepts \"\(candidate)\" but the schema enum lacks it")
    }
}

private func schemaReferenceTests() {
    let schema = URL(fileURLWithPath: "/Applications/HyperMug Dev.app/Contents/Resources/hypermug-dev.schema.json")
    expectEqual(jsonObject(String(decoding: encodeConfig(.newFileDefaults, schemaURL: schema), as: UTF8.self))["$schema"] as? String,
                schema.absoluteString, "new files link directly into the bundle")
    expect(jsonObject(String(decoding: encodeConfig(.newFileDefaults), as: UTF8.self))["$schema"] == nil,
           "model encoding does not invent an adjacent schema")
}
