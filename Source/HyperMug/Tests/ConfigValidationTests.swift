import Foundation
@testable import HyperMugCore

private func validateReason(_ text: String) -> String? {
    if case .failure(let error) = validateConfigTOML(Data(text.utf8)) { return error.reason }
    return nil
}

func configValidationTests() {
    let schema = URL(fileURLWithPath: "/Applications/HyperMug.app/Contents/Resources/hypermug.schema.json")
    for config in [AppConfig(), .newFileDefaults, AppConfig(shellTimeoutSeconds: 1), AppConfig(shellTimeoutSeconds: 300)] {
        expectEqual(try? validateConfigTOML(encodeConfigTOML(config, schemaURL: schema)).get().config, config)
    }
    for text in ["", #"capsLock = "hyper""#, "mouse.invertScroll.vertical = true",
                 "helpers.\" spaced \" = \"echo ok\"\nmouse.buttons.back.helper = \" spaced \"",
                 #"mouse.buttons.back.shortcut = ["CMD", "Shift", "["]"#,
                 "mouse.buttons = { back = {}, forward = {}, thumb = {} }\ntrackpad.threeFingerSwipe.up = {}",
                 "helpers.next = \"echo next\"\nmouse.horizontalWheel.left.shortcut = [\"ctrl\", \"up\"]\nmouse.horizontalWheel.right.helper = \"next\""] {
        if case .success = validateConfigTOML(Data(text.utf8)) { expect(true) }
        else { expect(false, "valid sparse/native config rejected: \(text)") }
    }
    for config in [AppConfig(), .newFileDefaults] {
        let initialized = encodeConfigTOML(config, schemaURL: schema, includeEmptyKeys: true)
        expectEqual(try? validateConfigTOML(initialized).get().config, config, "empty slots do not enable actions")
        let root = ConfigValue.table(try! parseConfigTOML(initialized).get()).jsonObject as! [String: Any]
        expectEqual((root["helpers"] as? [String: String])?.count, 0, "empty helpers remain visible")
        let mouse = root["mouse"] as! [String: Any]
        let buttons = mouse["buttons"] as! [String: Any]
        expectEqual(Set(buttons.keys), ["back", "forward", "thumb"], "all button slots are discoverable")
        expectEqual((buttons["thumb"] as? [String: Any])?.count, 0, "unassigned thumb is an empty object")
        let wheel = mouse["horizontalWheel"] as! [String: Any]
        expectEqual(Set(wheel.keys), Set(WheelDirection.allCases.map(\.rawValue)), "all wheel slots are discoverable")
        expectEqual((wheel["left"] as? [String: Any])?.count, 0, "unassigned wheel direction is an empty object")
        let trackpad = root["trackpad"] as! [String: Any]
        for group in ["threeFingerSwipe", "fourFingerSwipe"] {
            let directions = trackpad[group] as! [String: Any]
            expectEqual(Set(directions.keys), Set(SwipeDirection.allCases.map(\.rawValue)), "all swipe slots are discoverable")
            expectEqual((directions["up"] as? [String: Any])?.count, 0, "unassigned swipe stays visibly empty")
        }
    }
    let invalid = ["a =", "extra = true",
        "capsLock = 42", #"capsLock = "other""#,
        "autoUpdate = 1",
        "shellTimeoutSeconds = true", "shellTimeoutSeconds = 0", "shellTimeoutSeconds = 301",
        #"helpers."" = "echo ok""#, #"helpers."  " = "echo ok""#,
        #"helpers.good = """#, #"helpers.good = "  ""#,
        #"helpers.good = "echo hi\u0000exit 1""#,
        #"mouse.buttons.back.shell = "echo hi\u0000exit 1""#,
        #"mouse.buttons.back.shell = """#,
        #"mouse.buttons.back.shell = " \n""#,
        #"mouse.buttons.back = { shell = "echo ok", helper = "good" }"#,
        "mouse.buttons.back.shortcut = []",
        "mouse.buttons.back.shortcut = [2]",
        #"mouse.buttons.back.shortcut = ["notakey"]"#,
        #"mouse.buttons.back.shortcut = ["cmd"]"#,
        #"mouse.buttons.back.helper = "unknown""#,
        #"trackpad.threeFingerSwipe.left = "x""#,
        "mouse.verticalWheel.up.shell = \"echo old\"",
        "mouse.horizontalWheel.up = {}",
        #"mouse.horizontalWheel.left.shell = """#,
        #"mouse.horizontalWheel.right.helper = "unknown""#,
        #"mouse.horizontalWheel.left = { shell = "a", helper = "b" }"#]
    for retired in ["mouse.verticalWheel = 1", "mouse.verticalWheel.up.shell = \"echo old\"",
                    "mouse.verticalWheel.up = false", "mouse.verticalWheel.left = {}"] {
        expectEqual(validateReason(retired),
                    "mouse.verticalWheel: no longer supported; remove this table and use mouse.horizontalWheel.left/right")
    }
    for placeholders in ["mouse.verticalWheel = {}", "mouse.verticalWheel.up = {}",
                         "[mouse.verticalWheel]\nup = {}\ndown = {}"] {
        let source = "capsLock = \"hyper\"\nmouse.buttons.back.shell = \"echo back\"\n" + placeholders
        expectEqual(try? validateConfigTOML(Data(source.utf8)).get().config,
                    AppConfig(capsLock: .hyper, mouse: MouseConfig(buttons: ButtonMap(back: .shell("echo back")))),
                    "retired empty wheel placeholders preserve other settings")
    }
    expectEqual(validateReason("mouse.horizontalWheel.up = {}"), "mouse.horizontalWheel.up: unknown setting")
    expectEqual(validateReason(#"mouse.horizontalWheel.left = { shell = "a", helper = "b" }"#),
                "mouse.horizontalWheel.left: use an empty object or set exactly one of shell, shortcut or helper")
    for text in invalid {
        if case .failure(let error) = validateConfigTOML(Data(text.utf8)) {
            expect(!error.reason.isEmpty, "schema/native failure is actionable")
        } else { expect(false, "invalid config accepted: \(text)") }
    }
}
