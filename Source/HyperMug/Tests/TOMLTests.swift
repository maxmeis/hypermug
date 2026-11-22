import Foundation
@testable import HyperMugCore

private func parse(_ text: String) -> Result<[String: ConfigValue], ConfigError> { parseConfigTOML(Data(text.utf8)) }

private func parsed(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [String: ConfigValue] {
    switch parse(text) {
    case .success(let table): return table
    case .failure(let error):
        expect(false, "valid TOML rejected: \(error.reason)\n\(text)", file: file, line: line)
        return [:]
    }
}

private func expectTOMLError(_ text: String, _ reason: String, file: StaticString = #filePath, line: UInt = #line) {
    switch parse(text) {
    case .success: expect(false, "invalid TOML accepted: \(text)", file: file, line: line)
    case .failure(let error): expectEqual(error.reason, reason, text, file: file, line: line)
    }
}

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

private let schemaURL = URL(fileURLWithPath: "/Applications/HyperMug.app/Contents/Resources/hypermug.schema.json")

/// Issue #42's proposal. Its `thumb.shortcut = "cmd+shift+4"` uses the retired string form; shortcuts are arrays.
let issueExampleTOML = #"""
"$schema" = "file:///Applications/HyperMug.app/Contents/Resources/hypermug.schema.json"

autoUpdate = true
caffeineOnLaunch = true
launchAtLogin = false
capsLock = "meh"

[helpers]
nextWindow = "/opt/homebrew/bin/aerospace focus --wrap-around dfs-next"
previousWindow = "/opt/homebrew/bin/aerospace focus --wrap-around dfs-prev"
nextWorkspace = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around next"
previousWorkspace = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around prev"

[mouse.buttons]
back.helper = "previousWorkspace"
forward.helper = "nextWorkspace"
thumb.shortcut = ["cmd", "shift", "4"]

[mouse.invertScroll]
horizontal = false
vertical = false

[trackpad.fourFingerSwipe]
left.helper = "nextWindow"
right.helper = "previousWindow"

[trackpad.threeFingerSwipe]
left.helper = "nextWorkspace"
right.helper = "previousWorkspace"
"""#

/// Issue #39 ("My config"), the owner's settings written by hand as TOML.
let issue39TOML = #"""
"$schema" = "file:///Applications/HyperMug.app/Contents/Resources/hypermug.schema.json"
autoUpdate = true
caffeineOnLaunch = true
capsLock = "meh"
launchAtLogin = false

[helpers]
nextWindow = "/opt/homebrew/bin/aerospace focus --wrap-around dfs-next"
nextWorkspace = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around next"
previousWindow = "/opt/homebrew/bin/aerospace focus --wrap-around dfs-prev"
previousWorkspace = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around prev"

[mouse.buttons]
back = { helper = "previousWorkspace" }
forward = { helper = "nextWorkspace" }
thumb = {}

[mouse.invertScroll]
horizontal = false
vertical = false

[trackpad.fourFingerSwipe]
left = { helper = "nextWindow" }
right = { helper = "previousWindow" }

[trackpad.threeFingerSwipe]
left = { helper = "nextWorkspace" }
right = { helper = "previousWorkspace" }
"""#

func tomlTests() {
    exampleTests()
    stringTests()
    keyAndTableTests()
    valueTests()
    errorPositionTests()
    serializerTests()
    bridgeTests()
    schemaLinkTests()
    horizontalWheelTests()
}

// MARK: - Examples

private func exampleTests() {
    // The issue example decodes to the intended model.
    let decoded = try? validateConfigTOML(Data(issueExampleTOML.utf8)).get()
    let next = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around next"
    expectEqual(decoded?.config.capsLock, .meh)
    expectEqual(try? validateConfigTOML(Data("capsLock = \"threeMod\"\n".utf8)).get().config.capsLock, .threeMod)
    expectEqual(decoded?.config.launchAtLogin, false)
    expectEqual(decoded?.config.helpers["nextWorkspace"], next)
    expectEqual(decoded?.config.mouse.buttons.back, .helper("previousWorkspace"))
    expectEqual(decoded?.config.mouse.buttons.thumb, .shortcut(try! parseShortcut(["cmd", "shift", "4"]).get()))
    expectEqual(decoded?.config.trackpad.fourFingerSwipe.left, .helper("nextWindow"))
    expectEqual(decoded?.config.trackpad.threeFingerSwipe.right, .helper("previousWorkspace"))
    expectEqual(decoded?.config.resolvedActions().trackpad.threeFingerSwipe.left, .shell(next))
    expectEqual(decoded?.unknownKeys, [])

    // The issue's string shortcut names the setting and the expected type.
    let stringForm = issueExampleTOML.replacingOccurrences(of: #"["cmd", "shift", "4"]"#, with: #""cmd+shift+4""#)
    expectEqual(validateConfigTOML(Data(stringForm.utf8)).failureReason, "mouse.buttons.thumb.shortcut: expected array",
                "string shortcuts are rejected")

    // The documented setup keeps the owner's workspace bindings and adds the horizontal wheel.
    let docsExample = try? Data(contentsOf: URL(fileURLWithPath: "docs/examples/aerospace.toml"))
    expect(docsExample != nil, "docs/examples/aerospace.toml exists (tests run from the repository root)")
    let fromDocs = docsExample.flatMap { try? validateConfigTOML($0).get() }
    let fromIssue = try? validateConfigTOML(Data(issue39TOML.utf8)).get()
    expect(fromIssue != nil, "the #39 configuration is valid")
    expectEqual(fromDocs?.config.mouse.buttons, fromIssue?.config.mouse.buttons)
    expectEqual(fromDocs?.config.trackpad.threeFingerSwipe, fromIssue?.config.trackpad.threeFingerSwipe)
    expectEqual(fromDocs?.config.mouse.horizontalWheel,
                WheelMap(left: .helper("aerospaceWindowNext"), right: .helper("aerospaceWindowPrev")))
    expectEqual(fromDocs?.config.trackpad.fourFingerSwipe.left, .helper("aerospaceWindowNext"))
    expectEqual(fromDocs?.config.trackpad.fourFingerSwipe.right, .helper("aerospaceWindowPrev"))
    expectEqual(fromDocs?.config.resolvedActions().mouse.horizontalWheel.left,
                .shell("/opt/homebrew/bin/aerospace focus --wrap-around dfs-next"))
    expectEqual(fromDocs?.unknownKeys, [])
    expectEqual(fromDocs?.config.mouse.buttons.thumb, nil, "the thumb slot is unassigned")

    // Empty and comment-only documents mean all defaults.
    for empty in ["", "\n", "# only a comment\n", "\u{FEFF}"] {
        expectEqual(try? validateConfigTOML(Data(empty.utf8)).get().config, AppConfig(), "defaults for \(empty.debugDescription)")
    }
}

private extension Result where Failure == ConfigError {
    var failureReason: String? {
        if case .failure(let e) = self { return e.reason }
        return nil
    }
}

// MARK: - Parser

private func stringTests() {
    expectEqual(parsed(#"a = "tab\tnl\nq\"bs\\b\bf\fcr\r""#)["a"], .string("tab\tnl\nq\"bs\\b\u{8}f\u{C}cr\r"))
    expectEqual(parsed(#"a = "\u00E9 \U0001F600""#)["a"], .string("é 😀"))
    expectEqual(parsed(#"a = 'C:\path\no "escapes"'"#)["a"], .string(#"C:\path\no "escapes""#))
    expectEqual(parsed("a = \"tab\tinside\"")["a"], .string("tab\tinside"), "a literal tab is allowed")
    // Multi-line basic: the first newline is trimmed, a line-ending backslash joins lines, quotes may end it.
    expectEqual(parsed("a = \"\"\"\nline one\nline two\"\"\"")["a"], .string("line one\nline two"))
    expectEqual(parsed("a = \"\"\"one \\  \n   \n  two\"\"\"")["a"], .string("one two"))
    expectEqual(parsed("a = \"\"\"say \"hi\"\"\"\"\"")["a"], .string("say \"hi\"\""))
    expectEqual(parsed("a = \"\"\"a \"\" b\"\"\"")["a"], .string("a \"\" b"))
    expectEqual(parsed("a = \"\"\"\r\ncrlf\r\nend\"\"\"")["a"], .string("crlf\nend"))
    expectEqual(parsed("a = \"\"\"x\\ty\"\"\"")["a"], .string("x\ty"))
    // Multi-line literal.
    expectEqual(parsed("a = '''\nraw \\n 'quoted'\n'''")["a"], .string("raw \\n 'quoted'\n"))
    expectEqual(parsed("a = ''''one'''")["a"], .string("'one"))
    expectEqual(parsed("a = \"\"")["a"], .string(""))
    expectEqual(parsed("a = ''")["a"], .string(""))
}

private func keyAndTableTests() {
    let table = parsed(#"""
    # comment
    bare_key-1 = 1   # trailing comment
    "quoted key" = 2
    'literal key' = 3
    "" = 4
    site . "google.com" . ok = true
    site.other = false

    [ dog . "tater.man" ]
    type.name = "pug"

    [x.y.z]
    [x]
    w = 1
    [fruit]
    apple.color = "red"
    [fruit.apple.texture]
    smooth = true
    """#)
    expectEqual(table["bare_key-1"], .integer(1))
    expectEqual(table["quoted key"], .integer(2))
    expectEqual(table["literal key"], .integer(3))
    expectEqual(table[""], .integer(4))
    expectEqual(table["site"], .table(["google.com": .table(["ok": .boolean(true)]), "other": .boolean(false)]))
    expectEqual(table["dog"], .table(["tater.man": .table(["type": .table(["name": .string("pug")])])]))
    expectEqual(table["x"], .table(["y": .table(["z": .table([:])]), "w": .integer(1)]), "a super-table may follow its sub-table")
    expectEqual(table["fruit"], .table(["apple": .table(["color": .string("red"), "texture": .table(["smooth": .boolean(true)])])]),
                "a [header] may add a sub-table to a dotted table")
    expectEqual(parsed("a = 1\r\nb = 2\r\n"), ["a": .integer(1), "b": .integer(2)], "CRLF line endings")
    expectEqual(parsed("\u{FEFF}a = 1"), ["a": .integer(1)], "a leading BOM is ignored")
}

private func valueTests() {
    let table = parsed(#"""
    int = [+99, 42, 0, -17, 1_000, 0xDEAD_beef, 0o755, 0b1101]
    float = [1.5, -0.01, 5e+22, 1e06, -2E-2, 6.626e-34, 224_617.445_991]
    bool = [true, false]
    nested = [[1, 2], ["a"], []]
    multi = [
      "one",   # comment
      "two",
    ]
    empty = []
    inline = { a = 1, b.c = "x", d = { e = [] } }
    none = {}
    tables = [{ a = 1 }, { b = 2 }]
    """#)
    expectEqual(table["int"], .array([99, 42, 0, -17, 1000, 0xDEADBEEF, 0o755, 0b1101].map { .integer($0) }))
    expectEqual(table["float"], .array([1.5, -0.01, 5e22, 1e6, -0.02, 6.626e-34, 224617.445991].map { .float($0) }))
    expectEqual(table["bool"], .array([.boolean(true), .boolean(false)]))
    expectEqual(table["nested"], .array([.array([.integer(1), .integer(2)]), .array([.string("a")]), .array([])]))
    expectEqual(table["multi"], .array([.string("one"), .string("two")]))
    expectEqual(table["empty"], .array([]))
    expectEqual(table["inline"], .table(["a": .integer(1), "b": .table(["c": .string("x")]), "d": .table(["e": .array([])])]))
    expectEqual(table["none"], .table([:]))
    expectEqual(table["tables"], .array([.table(["a": .integer(1)]), .table(["b": .integer(2)])]))
    expectEqual(parsed("a = 9_223_372_036_854_775_807")["a"], .integer(Int64.max))
    expectEqual(parsed("a = -9223372036854775808")["a"], .integer(Int64.min))
}

private func errorPositionTests() {
    // Structure.
    expectTOMLError("a = 1\na = 2", "invalid TOML at line 2, column 1: duplicate key a")
    expectTOMLError("a.b = 1\na.b = 2", "invalid TOML at line 2, column 3: duplicate key a.b")
    expectTOMLError("\"a\" = 1\na = 2", "invalid TOML at line 2, column 1: duplicate key a")
    expectTOMLError("[a]\n[a]", "invalid TOML at line 2, column 1: table [a] is defined more than once")
    expectTOMLError("[a]\nb.c = 1\n[a.b]", "invalid TOML at line 3, column 1: table [a.b] is defined more than once")
    expectTOMLError("[a.b]\n[a]\nb.c = 1", "invalid TOML at line 3, column 1: b is already defined and cannot be extended with dotted keys")
    expectTOMLError("a = 1\na.b = 2", "invalid TOML at line 2, column 1: a is already defined and cannot be extended with dotted keys")
    expectTOMLError("a = {}\n[a]", "invalid TOML at line 2, column 2: a is already defined as a value")
    expectTOMLError("a = {}\n[a.b]", "invalid TOML at line 2, column 2: a is already defined as a value")
    expectTOMLError("a = { b = 1 }\na.c = 2", "invalid TOML at line 2, column 1: a is already defined and cannot be extended with dotted keys")
    expectTOMLError("a = { b = 1, b = 2 }", "invalid TOML at line 1, column 14: duplicate key b")
    expectTOMLError("[[items]]", "invalid TOML at line 1, column 1: arrays of tables ([[...]]) are not supported in the configuration")
    expectTOMLError("[a", "invalid TOML at line 1, column 3: expected ] to close the table header")
    expectTOMLError("[]", "invalid TOML at line 1, column 2: expected a key")
    expectTOMLError("= 1", "invalid TOML at line 1, column 1: expected a key")
    expectTOMLError("a.= 1", "invalid TOML at line 1, column 3: expected a key")
    expectTOMLError("a 1", "invalid TOML at line 1, column 3: expected = after the key")
    expectTOMLError("a = 1 b = 2", "invalid TOML at line 1, column 7: expected the end of the line")
    expectTOMLError("[a] b = 1", "invalid TOML at line 1, column 5: expected the end of the line")
    expectTOMLError("a = 1\rb = 2", "invalid TOML at line 1, column 6: expected the end of the line")
    expectTOMLError("\r", "invalid TOML at line 1, column 1: expected the end of the line")
    expectTOMLError("# bell \u{7}", "invalid TOML at line 1, column 8: control characters are not allowed in comments")
    // Values.
    expectTOMLError("a =", "invalid TOML at line 1, column 4: expected a value")
    expectTOMLError("a = ?", "invalid TOML at line 1, column 5: expected a value")
    expectTOMLError("a = yes", "invalid TOML at line 1, column 5: invalid value yes")
    expectTOMLError("a = 01", "invalid TOML at line 1, column 5: invalid value 01")
    expectTOMLError("a = 1__0", "invalid TOML at line 1, column 5: invalid value 1__0")
    expectTOMLError("a = 1.", "invalid TOML at line 1, column 5: invalid value 1.")
    expectTOMLError("a = 9223372036854775808", "invalid TOML at line 1, column 5: integer 9223372036854775808 is out of range")
    expectTOMLError("a = 0xFFFFFFFFFFFFFFFFF", "invalid TOML at line 1, column 5: integer 0xFFFFFFFFFFFFFFFFF is out of range")
    expectTOMLError("a = 1e400", "invalid TOML at line 1, column 5: number 1e400 is out of range")
    expectTOMLError("a = inf", "invalid TOML at line 1, column 5: inf and nan are not supported in the configuration")
    expectTOMLError("a = -nan", "invalid TOML at line 1, column 5: inf and nan are not supported in the configuration")
    expectTOMLError("a = 1979-05-27T07:32:00Z", "invalid TOML at line 1, column 5: dates and times are not supported in the configuration")
    expectTOMLError("a = 1979-05-27 07:32:00", "invalid TOML at line 1, column 5: dates and times are not supported in the configuration")
    expectTOMLError("a = 07:32:00", "invalid TOML at line 1, column 5: dates and times are not supported in the configuration")
    expectTOMLError("a = [1, \"x\"]", "invalid TOML at line 1, column 9: arrays cannot mix value types (integer and string)")
    expectTOMLError("a = [1, 2.0]", "invalid TOML at line 1, column 9: arrays cannot mix value types (integer and float)")
    expectTOMLError("a = [{}, []]", "invalid TOML at line 1, column 10: arrays cannot mix value types (table and array)")
    expectTOMLError("a = [true, false, 1]", "invalid TOML at line 1, column 19: arrays cannot mix value types (boolean and integer)")
    expectTOMLError("a = [1 2]", "invalid TOML at line 1, column 8: expected , or ] in the array")
    expectTOMLError("a = [1,\n2", "invalid TOML at line 2, column 2: expected , or ] in the array")
    expectTOMLError("a = { b = 1\n}", "invalid TOML at line 1, column 12: expected , or } in the inline table (inline tables stay on one line)")
    expectTOMLError("a = { b = 1, }", "invalid TOML at line 1, column 14: expected a key")
    // Strings.
    expectTOMLError("a = \"open", "invalid TOML at line 1, column 5: unterminated string")
    expectTOMLError("a = '''open\n", "invalid TOML at line 1, column 5: unterminated string")
    expectTOMLError("a = \"one\ntwo\"", "invalid TOML at line 1, column 9: strings cannot span lines; use triple quotes for a multi-line string")
    expectTOMLError("a = 'one\ntwo'", "invalid TOML at line 1, column 9: strings cannot span lines; use triple quotes for a multi-line string")
    expectTOMLError("a = \"bell \u{7}\"", "invalid TOML at line 1, column 11: control characters must be escaped in strings")
    expectTOMLError("a = \"del \u{7F}\"", "invalid TOML at line 1, column 10: control characters must be escaped in strings")
    expectTOMLError(#"a = "\x41""#, #"invalid TOML at line 1, column 6: invalid escape \x"#)
    expectTOMLError(#"a = "\u12""#, "invalid TOML at line 1, column 6: invalid Unicode escape")
    expectTOMLError(#"a = "\u12G4""#, "invalid TOML at line 1, column 6: invalid Unicode escape")
    expectTOMLError(#"a = "\uD800""#, "invalid TOML at line 1, column 6: invalid Unicode escape")
    expectTOMLError(#"a = "\U00110000""#, "invalid TOML at line 1, column 6: invalid Unicode escape")
    expectTOMLError("a = \"\\", "invalid TOML at line 1, column 6: unterminated string")
    expectTOMLError("a = \"\"\"x \\ y\"\"\"", #"invalid TOML at line 1, column 10: invalid escape \ "#)
    expectTOMLError("a = \"\"\"x\"\"\"\"\"\"", "invalid TOML at line 1, column 9: too many quotes at the end of a multi-line string")
    expectTOMLError("\"\"\"a\"\"\" = 1", "invalid TOML at line 1, column 3: expected = after the key")
    // Positions count lines and Unicode scalars.
    expectTOMLError("# héllo\n\n  ok = 1\n  é = 2", "invalid TOML at line 4, column 3: expected a key")
    expectEqual(parseConfigTOML(Data([0x61, 0x20, 0x3D, 0x20, 0xFF])).failureReason, "invalid TOML: the file is not UTF-8 text")
}

// MARK: - Serializer

private func serializerTests() {
    // Canonical output for the issue example: sorted keys, directive, dotted single-key tables, sections.
    let issue = parsed(issueExampleTOML)
    let canonical = text(renderConfigTOML(issue))
    expectEqual(canonical, #"""
    #:schema file:///Applications/HyperMug.app/Contents/Resources/hypermug.schema.json
    "$schema" = "file:///Applications/HyperMug.app/Contents/Resources/hypermug.schema.json"

    autoUpdate = true
    caffeineOnLaunch = true
    capsLock = "meh"
    launchAtLogin = false

    [helpers]
    nextWindow = "/opt/homebrew/bin/aerospace focus --wrap-around dfs-next"
    nextWorkspace = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around next"
    previousWindow = "/opt/homebrew/bin/aerospace focus --wrap-around dfs-prev"
    previousWorkspace = "/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around prev"

    [mouse.buttons]
    back.helper = "previousWorkspace"
    forward.helper = "nextWorkspace"
    thumb.shortcut = ["cmd", "shift", "4"]

    [mouse.invertScroll]
    horizontal = false
    vertical = false

    [trackpad.fourFingerSwipe]
    left.helper = "nextWindow"
    right.helper = "previousWindow"

    [trackpad.threeFingerSwipe]
    left.helper = "nextWorkspace"
    right.helper = "previousWorkspace"

    """#)
    expectEqual(parsed(canonical), issue, "canonical TOML parses back to the same tree")
    expectEqual(text(renderConfigTOML(parsed(canonical))), canonical, "rendering is stable")

    // Every value kind and awkward keys round-trip.
    let tree: [String: ConfigValue] = [
        "plain": .string("quote \" backslash \\ nl \n tab \t cr \r bs \u{8} ff \u{C} bell \u{1} del \u{7F} é"),
        "a b": .integer(-3), "": .boolean(true), "dotted.key": .float(2.5), "tiny": .float(1e-7), "huge": .float(5e22),
        "list": .array([.table(["x": .integer(1), "y": .table([:])]), .table([:])]),
        "deep": .table(["only": .table(["leaf": .table([:])])]),
        "chain": .table(["to": .table(["section": .table(["a": .integer(1), "b": .integer(2)])])]),
        "mixed": .table(["value": .integer(1), "sub": .table(["a": .integer(1), "b": .integer(2)])]),
        "empty": .table([:]), "strings": .array([.string("a"), .string("b")]),
    ]
    let rendered = text(renderConfigTOML(tree))
    expectEqual(parsed(rendered), tree, "round trip:\n\(rendered)")
    expectEqual(text(renderConfigTOML(parsed(rendered))), rendered, "stable")
    expect(rendered.contains("\n\"a b\" = -3\n") && rendered.hasPrefix("\"\" = true\n") && rendered.contains("\n\"dotted.key\" = 2.5\n"),
           "keys that are not bare are quoted")
    expect(rendered.contains(#"bell \u0001 del \u007F"#), "control characters are escaped")
    expect(rendered.contains("deep.only.leaf = {}") && rendered.contains("\n[chain.to.section]\n") && rendered.contains("\n[mixed]\nvalue = 1\n\n[mixed.sub]\n"),
           "single-key chains are dotted, wider tables are sections")
    expect(rendered.contains("list = [{ x = 1, y = {} }, {}]"), "tables inside arrays are inline")
    expect(!rendered.hasPrefix("#:schema") && !rendered.hasPrefix("\n"), "no directive without $schema")
    expectEqual(text(renderConfigTOML([:])), "\n")

    // A $schema that is not a plain URL keeps the key but no directive.
    let odd = text(renderConfigTOML(["$schema": .string("a\nb"), "x": .integer(1)]))
    expectEqual(odd, "\"$schema\" = \"a\\nb\"\n\nx = 1\n")
    expectEqual(text(renderConfigTOML(["$schema": .integer(1)])), "\"$schema\" = 1\n")

    // The new-file defaults show every slot and decode back to the model.
    let defaults = encodeConfigTOML(.newFileDefaults, schemaURL: schemaURL, includeEmptyKeys: true)
    expectEqual(try? validateConfigTOML(defaults).get().config, .newFileDefaults)
    let defaultText = text(defaults)
    expect(defaultText.contains("\ncapsLock = \"threeMod\"\n"), "new files select Three Mod")
    expect(defaultText.hasPrefix("#:schema \(schemaURL.absoluteString)\n\"$schema\" = \"\(schemaURL.absoluteString)\"\n\nautoUpdate = "), defaultText)
    expect(defaultText.contains("\nhelpers = {}\n") && defaultText.contains("\nthumb = {}\n") && defaultText.contains("\nshellTimeoutSeconds = 10\n")
           && defaultText.contains("\n[trackpad.threeFingerSwipe]\ndown = {}\n"), defaultText)
    for config in [AppConfig(), .newFileDefaults, AppConfig(capsLock: .meh), AppConfig(capsLock: .hyper), AppConfig(shellTimeoutSeconds: 2.5),
                   AppConfig(mouse: MouseConfig(buttons: ButtonMap(thumb: .shortcut(try! parseShortcut(["meh", "\\"]).get()))))] {
        let data = encodeConfigTOML(config)
        expectEqual(try? validateConfigTOML(data).get().config, config, "TOML encoding round-trips \(text(data))")
        expectEqual(encodeConfigTOML(config), data, "deterministic")
    }
}

// MARK: - Model bridge

private func bridgeTests() {
    // The model's encoding becomes the value tree; number kinds are kept, and null has no TOML form.
    let object: [String: Any] = ["f": 10.0, "i": 10, "b": true, "a": ["x"]]
    expectEqual(try? ConfigValue(jsonObject: object, path: ""),
                .table(["f": .float(10), "i": .integer(10), "b": .boolean(true), "a": .array([.string("x")])]))
    do { _ = try ConfigValue(jsonObject: ["a": ["b": [1, NSNull()]]], path: ""); expect(false, "null converted") }
    catch { expectEqual((error as? ConfigError)?.reason, "a.b[1]: null has no TOML equivalent") }
    do { _ = try ConfigValue(jsonObject: NSNull(), path: ""); expect(false, "null converted") }
    catch { expectEqual((error as? ConfigError)?.reason, "config: null has no TOML equivalent") }
}

private extension Data {
    var string: String { String(decoding: self, as: UTF8.self) }
}

// MARK: - Schema link

private func schemaLinkTests() {
    let url = schemaURL.absoluteString
    func link(_ source: String) -> String? { (try? tomlConfigDataLinkingSchema(Data(source.utf8), schemaURL: schemaURL)).map(text) }

    // Missing metadata is added at the top; comments and layout stay.
    expectEqual(link("# mine\ncapsLock = \"hyper\" # keep\n"),
                "#:schema \(url)\n\"$schema\" = \"\(url)\"\n# mine\ncapsLock = \"hyper\" # keep\n")
    // An outdated value and directive are replaced in place.
    let old = "#:schema file:///old.json\n# note\n'$schema' = 'file:///old.json' # where\n\n[mouse.invertScroll] # wheel\nvertical = true\n"
    expectEqual(link(old), "#:schema \(url)\n# note\n'$schema' = \"\(url)\" # where\n\n[mouse.invertScroll] # wheel\nvertical = true\n")
    // A current file is unchanged; a missing directive is added.
    let current = "#:schema \(url)\n\"$schema\" = \"\(url)\"\n"
    expectEqual(link(current), current)
    expectEqual(link("\"$schema\" = \"\(url)\"\n"), current)
    expectEqual(link("\u{FEFF}\"$schema\" = \"x\"\n"), current, "a BOM is dropped")
    expectEqual(link("#:schema x"), "#:schema \(url)\n\"$schema\" = \"\(url)\"\n", "a directive without a newline")
    // Only the root $schema string is metadata.
    expectEqual(link("[mouse]\n\"$schema\" = \"x\"\n"), "#:schema \(url)\n\"$schema\" = \"\(url)\"\n[mouse]\n\"$schema\" = \"x\"\n")
    expectEqual(link("a.\"$schema\" = \"x\"\n"), "#:schema \(url)\n\"$schema\" = \"\(url)\"\na.\"$schema\" = \"x\"\n")
    expect(link("a = ") == nil, "invalid TOML is not rewritten")
    for source in [old, "capsLock = \"meh\"\n", issueExampleTOML] {
        let linked = link(source)!
        expectEqual(link(linked), linked, "linking is idempotent")
        expectEqual(try? validateConfigTOML(Data(linked.utf8)).get().config, try? validateConfigTOML(Data(source.utf8)).get().config,
                    "linking changes no setting")
    }
}

// MARK: - mouse.horizontalWheel

private let wheelTOML = """
[helpers]
nextWindow = "/opt/homebrew/bin/aerospace focus --boundaries-action wrap-around-the-workspace right"
previousWindow = "/opt/homebrew/bin/aerospace focus --boundaries-action wrap-around-the-workspace left"

[mouse.horizontalWheel]
left.helper = "nextWindow"
right.helper = "previousWindow"

"""

private func horizontalWheelTests() {
    // Parses, validates and resolves like any other mapping.
    let decoded = try? validateConfigTOML(Data(wheelTOML.utf8)).get()
    expectEqual(decoded?.config.mouse.horizontalWheel.left, .helper("nextWindow"))
    expectEqual(decoded?.config.mouse.horizontalWheel.right, .helper("previousWindow"))
    expectEqual(decoded?.unknownKeys, [])
    expectEqual(decoded?.config.resolvedActions().mouse.horizontalWheel.left,
                .shell("/opt/homebrew/bin/aerospace focus --boundaries-action wrap-around-the-workspace right"))
    // The serializer writes exactly this canonical TOML.
    expectEqual(text(renderConfigTOML(parsed(wheelTOML))), wheelTOML, "canonical output")
    // Round trips through the model and the serializer.
    let encoded = encodeConfigTOML(decoded!.config)
    expectEqual(try? validateConfigTOML(encoded).get().config, decoded?.config)
    expectEqual(text(renderConfigTOML(parsed(text(encoded)))), text(encoded), "stable")
    // The schema covers the slots: unknown keys and bad values fail and name the setting.
    for toml in ["mouse.horizontalWheel.up.helper = \"x\"", "mouse.horizontalWheel.left.helper = \"missing\"",
                 "mouse.horizontalWheel.left = { shell = \"a\", helper = \"b\" }"] {
        let reason = validateConfigTOML(Data(toml.utf8)).failureReason
        expect(reason?.hasPrefix("mouse.horizontalWheel.") == true, "rejected: \(toml) (\(reason ?? "accepted"))")
    }
    let schema = try! JSONSerialization.jsonObject(with: Data(configSchemaJSON.utf8)) as! [String: Any]
    let mouse = (schema["properties"] as! [String: Any])["mouse"] as! [String: Any]
    let wheel = (mouse["properties"] as! [String: Any])["horizontalWheel"] as? [String: Any]
    expectEqual((wheel?["properties"] as? [String: Any]).map { Set($0.keys) }, ["left", "right"], "the schema describes both directions")
    // New files show the empty slots.
    expect(text(encodeConfigTOML(.newFileDefaults, includeEmptyKeys: true)).contains("\n[mouse.horizontalWheel]\nleft = {}\nright = {}\n"))
}
