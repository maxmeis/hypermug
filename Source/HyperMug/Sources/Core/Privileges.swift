import Foundation

// `Check Privileges…`: which macOS permissions HyperMug has, which buttons the alert offers, and what each
// button does. Showing the alert and performing the actions is App/Platform work.

public let accessibilityPaneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
public let inputMonitoringPaneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

public enum PrivilegeAction: Equatable {
    case requestAccessibility, requestInputMonitoring, restart, none
}

public struct PrivilegeButton: Equatable {
    public let title: String
    public let action: PrivilegeAction

    public init(title: String, action: PrivilegeAction) {
        self.title = title
        self.action = action
    }
}

public struct PrivilegesAlertModel: Equatable {
    public let title: String
    public let body: String
    /// true: at least one permission is missing (warning style).
    public let warning: Bool
    /// In display order: one per missing permission, then Restart, then OK last.
    public let buttons: [PrivilegeButton]

    public init(title: String, body: String, warning: Bool, buttons: [PrivilegeButton]) {
        self.title = title
        self.body = body
        self.warning = warning
        self.buttons = buttons
    }
}

public func privilegesAlert(accessibility: Bool, inputMonitoring: Bool) -> PrivilegesAlertModel {
    func line(_ granted: Bool, _ name: String, _ need: String) -> String {
        "\(granted ? "✅" : "❌") \(name) — \(need)"
    }
    let body = [
        line(accessibility, "Accessibility", "needed for the keyboard/mouse event tap (Caps Lock modifiers, side buttons, scroll inversion)"),
        line(inputMonitoring, "Input Monitoring", "needed for Caps Lock detection and the thumb button"),
        "",
        "After granting Input Monitoring, relaunch HyperMug.",
    ].joined(separator: "\n")

    var buttons: [PrivilegeButton] = []
    if !accessibility {
        buttons.append(PrivilegeButton(title: "Open Accessibility Settings", action: .requestAccessibility))
    }
    if !inputMonitoring {
        buttons.append(PrivilegeButton(title: "Open Input Monitoring Settings", action: .requestInputMonitoring))
    }
    buttons.append(PrivilegeButton(title: "Restart HyperMug", action: .restart))
    buttons.append(PrivilegeButton(title: "OK", action: .none))
    return PrivilegesAlertModel(
        title: "HyperMug privileges",
        body: body,
        warning: !(accessibility && inputMonitoring),
        buttons: buttons
    )
}

/// The action of the button at `responseIndex` (0-based, display order); `.none` when out of range.
public func privilegeAction(responseIndex: Int, in model: PrivilegesAlertModel) -> PrivilegeAction {
    model.buttons.indices.contains(responseIndex) ? model.buttons[responseIndex].action : .none
}

/// Relaunch: a detached shell reopens the bundle after this process has quit.
public func relaunchCommand(bundlePath: String) -> (path: String, arguments: [String]) {
    ("/bin/sh", ["-c", #"sleep 1; /usr/bin/open "$0""#, bundlePath])
}
