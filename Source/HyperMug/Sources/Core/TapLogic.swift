import Foundation
import CoreGraphics

/// Set in `.eventSourceUserData` of every key event HyperMug posts, so the tap lets them through untouched.
public let kSyntheticEventTag: Int64 = 0x4D_59_4D_55_47
public let escapeKeyCode: CGKeyCode = 53

private let capsLockKeyCode: Int64 = 57
private let backButtonNumber: Int64 = 3
private let forwardButtonNumber: Int64 = 4
private let otherMouseEventMask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)

// MARK: - Settings

/// What the event tap needs from the config.
public struct TapSettings: Equatable {
    public var capsMode: CapsMode = .default
    public var back: ButtonAction? = nil
    public var forward: ButtonAction? = nil
    public var invertVertical = false
    public var invertHorizontal = false
    public var wheel = WheelMap()

    public init() {}

    public init(config: AppConfig) {
        capsMode = config.capsLock
        back = config.mouse.buttons.back
        forward = config.mouse.buttons.forward
        invertVertical = config.mouse.invertScroll.vertical
        invertHorizontal = config.mouse.invertScroll.horizontal
        wheel = config.mouse.horizontalWheel
    }

    /// Only the event types that are needed.
    public var mask: CGEventMask {
        var mask: CGEventMask = 0
        if capsMode.isModifier {
            mask |= (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.keyUp.rawValue) |
                (1 << CGEventType.flagsChanged.rawValue)
        }
        if back != nil || forward != nil {
            mask |= otherMouseEventMask
        }
        if invertVertical || invertHorizontal || !wheel.isEmpty {
            mask |= 1 << CGEventType.scrollWheel.rawValue
        }
        return mask
    }

    public var needsTap: Bool { mask != 0 }
}

// MARK: - Pure decisions

/// A short Caps press without another key in between sends Esc.
public func shouldSendEscape(heldMs: Double, otherKeyPressed: Bool, timeoutMs: Double = 200) -> Bool {
    !otherKeyPressed && heldMs < timeoutMs
}

/// Mouse-wheel events carry neither scroll phase nor momentum phase; trackpads and Magic Mouse always set one.
public func shouldInvertScroll(scrollPhase: Int64, momentumPhase: Int64) -> Bool {
    scrollPhase == 0 && momentumPhase == 0
}

/// Meh = ⌃⌥⇧; Three Mod = ⌃⌥⌘; Hyper = ⌃⌥⇧⌘; Default = none.
public func capsModifierFlags(for mode: CapsMode) -> CGEventFlags {
    switch mode {
    case .default: return []
    case .meh: return [.maskControl, .maskAlternate, .maskShift]
    case .threeMod: return [.maskControl, .maskAlternate, .maskCommand]
    case .hyper: return [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    }
}

/// Flags of a key event while Caps is held: everything already on it (physically held modifiers) plus the selected mode.
public func flagsWhileCapsHeld(_ original: CGEventFlags, mode: CapsMode) -> CGEventFlags {
    guard mode.isModifier else { return original }
    return original.subtracting(.maskAlphaShift).union(capsModifierFlags(for: mode))
}

// MARK: - Event model

/// Line, fixed-point and point delta of one scroll axis.
public struct ScrollAxis: Equatable {
    public var line: Int64
    public var fixed: Double
    public var point: Int64

    public init(line: Int64, fixed: Double, point: Int64) {
        self.line = line
        self.fixed = fixed
        self.point = point
    }

    public static let zero = ScrollAxis(line: 0, fixed: 0, point: 0)
}

/// The fields of a CGEvent the tap logic looks at. Fields that do not apply to `type` are 0.
public struct TapEvent: Equatable {
    public var type: CGEventType
    public var userData: Int64
    public var keyCode: Int64
    public var flags: CGEventFlags
    public var button: Int64
    public var scrollPhase: Int64
    public var momentumPhase: Int64
    public var vertical: ScrollAxis
    public var horizontal: ScrollAxis
    /// Scroll events: high-resolution (pixel) deltas rather than line steps.
    public var continuous: Bool
    /// Scroll events: macOS reversed the deltas relative to the physical wheel (Natural Scrolling).
    public var invertedFromDevice: Bool
    /// Monotonic arrival time.
    public var nowNanos: UInt64

    public init(type: CGEventType, userData: Int64 = 0, keyCode: Int64 = 0, flags: CGEventFlags = [], button: Int64 = 0,
                scrollPhase: Int64 = 0, momentumPhase: Int64 = 0, vertical: ScrollAxis = .zero, horizontal: ScrollAxis = .zero,
                continuous: Bool = false, invertedFromDevice: Bool = false, nowNanos: UInt64 = 0) {
        self.type = type
        self.userData = userData
        self.keyCode = keyCode
        self.flags = flags
        self.button = button
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
        self.vertical = vertical
        self.horizontal = horizontal
        self.continuous = continuous
        self.invertedFromDevice = invertedFromDevice
        self.nowNanos = nowNanos
    }
}

/// What to do with the event. Non-nil `flags` / axes replace those fields of the event (axes are already negated).
public struct TapDecision: Equatable {
    public var pass: Bool
    public var reenableTap: Bool
    public var flags: CGEventFlags?
    public var vertical: ScrollAxis?
    public var horizontal: ScrollAxis?

    public init(pass: Bool = true, reenableTap: Bool = false, flags: CGEventFlags? = nil,
                vertical: ScrollAxis? = nil, horizontal: ScrollAxis? = nil) {
        self.pass = pass
        self.reenableTap = reenableTap
        self.flags = flags
        self.vertical = vertical
        self.horizontal = horizontal
    }
}

/// Side effects the caller has to execute, in order.
public enum TapEffect: Equatable {
    case run(ButtonAction)
    case postEscape
    /// Force the system Caps Lock latch off and verify it shortly after. Emitted whenever a latch was observed or
    /// may have happened unobserved; the read-back of the lock state is not trusted on its own.
    case clearCapsLock
    case debugLog(String)
    case log(LogLevel, String)
}

// MARK: - State

/// Caps-held and swallowed-button state of the event tap. Value type owned by `Engine`; main thread only.
public struct TapState: Equatable {
    /// True while the Caps Lock key is physically held (reported by the HID monitor).
    public private(set) var capsHeld = false
    private var otherKeyPressed = false
    private var downTime: UInt64 = 0
    /// Mouse buttons whose down event was swallowed; their up event is swallowed too.
    private var swallowed = Set<Int64>()
    private var wheelSteps = WheelSteps()

    public init() {}

    /// Decision for one tap event plus the effects to run. The order of the checks matters:
    /// tap-disabled notices, then our own synthetic events, then per event type.
    public mutating func handle(_ e: TapEvent, settings: TapSettings) -> (TapDecision, [TapEffect]) {
        if e.type == .tapDisabledByTimeout || e.type == .tapDisabledByUserInput {
            let reason = e.type == .tapDisabledByTimeout ? "timeout" : "userInput"
            let line = "tap disabled reason=\(reason) capsHeld=\(capsHeld)"
            resetCaps()
            // While the tap was off, Caps Lock flagsChanged events reached the system unfiltered and may have latched it.
            let clear: [TapEffect] = settings.capsMode.isModifier ? [.clearCapsLock] : []
            return (TapDecision(reenableTap: true), [.log(.info, line), .debugLog(line)] + clear)
        }

        // Events HyperMug posted itself (mapped shortcuts, Esc) must not hit any logic below.
        if e.userData == kSyntheticEventTag {
            return (TapDecision(), [])
        }

        switch e.type {
        case .otherMouseUp:
            return (TapDecision(pass: swallowed.remove(e.button) == nil), [])

        case .otherMouseDown:
            swallowed.remove(e.button)
            guard let action = mappedAction(button: e.button, settings: settings) else { return (TapDecision(), []) }
            swallowed.insert(e.button)
            return (TapDecision(pass: false), [.run(action)])

        case .scrollWheel:
            if let consumed = wheelBinding(e, settings: settings) { return consumed }
            guard settings.invertVertical || settings.invertHorizontal,
                  shouldInvertScroll(scrollPhase: e.scrollPhase, momentumPhase: e.momentumPhase)
            else { return (TapDecision(), []) }
            var decision = TapDecision()
            if settings.invertVertical { decision.vertical = negated(e.vertical) }
            if settings.invertHorizontal { decision.horizontal = negated(e.horizontal) }
            return (decision, [])

        case .flagsChanged:
            guard settings.capsMode.isModifier else { return (TapDecision(), []) }
            let latched = e.flags.contains(.maskAlphaShift)
            return (TapDecision(pass: e.keyCode != capsLockKeyCode,
                flags: latched ? e.flags.subtracting(.maskAlphaShift) : nil), latched ? [.clearCapsLock] : [])

        case .keyDown, .keyUp:
            guard settings.capsMode.isModifier else { return (TapDecision(), []) }
            let latched = e.flags.contains(.maskAlphaShift)
            let effects: [TapEffect] = latched ? [.clearCapsLock] : []
            guard capsHeld else {
                return (TapDecision(flags: latched ? e.flags.subtracting(.maskAlphaShift) : nil), effects)
            }
            if e.type == .keyDown { otherKeyPressed = true }
            return (TapDecision(flags: flagsWhileCapsHeld(e.flags, mode: settings.capsMode)), effects)

        default:
            return (TapDecision(), [])
        }
    }

    /// Caps Lock transition from the HID monitor. Only real transitions count; repeated values are ignored.
    public mutating func capsKey(down: Bool, nowNanos: UInt64) -> [TapEffect] {
        if down {
            guard !capsHeld else { return [] }
            capsHeld = true
            otherKeyPressed = false
            downTime = nowNanos
            return [.log(.info, "caps down"), .debugLog("caps down")]
        }
        guard capsHeld else { return [] }
        capsHeld = false
        let heldMs = Double(max(nowNanos, downTime) - downTime) / 1_000_000
        let sendEscape = shouldSendEscape(heldMs: heldMs, otherKeyPressed: otherKeyPressed)
        let line = "caps up held_ms=\(Int(heldMs)) esc=\(sendEscape)"
        var effects: [TapEffect] = [.log(.info, line), .debugLog(line)]
        if sendEscape { effects.append(.postEscape) }
        return effects
    }

    /// Ends a Caps hold without sending Esc (HID device removed, tap disabled or torn down, mode change, shutdown).
    public mutating func resetCaps() {
        capsHeld = false
    }

    /// Forgets swallowed buttons. Without a live tap no up event can arrive.
    public mutating func clearSwallowed() {
        swallowed.removeAll()
    }

    /// Settings mask plus other-mouse events while a swallowed button is still held, so its release is swallowed too.
    public func effectiveMask(_ settings: TapSettings) -> CGEventMask {
        swallowed.isEmpty ? settings.mask : settings.mask | otherMouseEventMask
    }

    private func mappedAction(button: Int64, settings: TapSettings) -> ButtonAction? {
        switch button {
        case backButtonNumber: return settings.back
        case forwardButtonNumber: return settings.forward
        default: return nil
        }
    }

    /// Consumes a mouse-wheel event whose physical horizontal direction is mapped; nil = normal scroll handling.
    /// Bindings see the device direction: Natural Scrolling is undone here, and inversion only applies to passed events.
    private mutating func wheelBinding(_ e: TapEvent, settings: TapSettings) -> (TapDecision, [TapEffect])? {
        guard !settings.wheel.isEmpty, shouldInvertScroll(scrollPhase: e.scrollPhase, momentumPhase: e.momentumPhase)
        else { return nil }
        let primary = e.continuous ? Double(e.horizontal.point) : Double(e.horizontal.line)
        let delta = primary != 0 ? primary : e.horizontal.fixed
        guard delta != 0 else { return nil }
        let direction: WheelDirection = (delta > 0) != e.invertedFromDevice ? .left : .right
        guard let action = settings.wheel.action(for: direction) else {
            wheelSteps.reset()
            return nil
        }
        let fires = wheelSteps.step(direction, continuousPoints: e.continuous ? abs(delta) : nil, nowNanos: e.nowNanos)
        // Keep vertical motion in a mixed-axis event, including its configured inversion.
        let vertical = settings.invertVertical ? negated(e.vertical) : nil
        return (TapDecision(vertical: vertical, horizontal: .zero), fires ? [.run(action)] : [])
    }

    /// nil when the axis carries no movement (nothing to rewrite).
    private func negated(_ axis: ScrollAxis) -> ScrollAxis? {
        axis == .zero ? nil : ScrollAxis(line: -axis.line, fixed: -axis.fixed, point: -axis.point)
    }
}
