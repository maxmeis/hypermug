import Foundation
import CoreGraphics
@testable import HyperMugCore

private let keyBits: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
    (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
private let mouseBits: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
private let scrollBit: CGEventMask = 1 << CGEventType.scrollWheel.rawValue

private let back = ButtonAction.shell("back-cmd")
private let forward = ButtonAction.shell("forward-cmd")
private let meh: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
private let threeMod: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
private let hyper: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

private func settings(caps: CapsMode = .default, back: ButtonAction? = nil, forward: ButtonAction? = nil,
                      vertical: Bool = false, horizontal: Bool = false, wheel: WheelMap = WheelMap()) -> TapSettings {
    var s = TapSettings()
    s.capsMode = caps
    s.back = back
    s.forward = forward
    s.invertVertical = vertical
    s.invertHorizontal = horizontal
    s.wheel = wheel
    return s
}

private func mouse(_ type: CGEventType, button: Int64) -> TapEvent {
    TapEvent(type: type, button: button)
}

private func scroll(phase: Int64 = 0, momentum: Int64 = 0, vertical: ScrollAxis = .zero, horizontal: ScrollAxis = .zero) -> TapEvent {
    TapEvent(type: .scrollWheel, scrollPhase: phase, momentumPhase: momentum, vertical: vertical, horizontal: horizontal)
}

private let ms: UInt64 = 1_000_000

private func expectNoop(_ result: (TapDecision, [TapEffect])) {
    expectEqual(result.0, TapDecision())
    expectEqual(result.1, [])
}

func tapLogicTests() {
    escapeDecisionTests()
    scrollDecisionTests()
    settingsMaskTests()
    capsFlagsTests()
    tapDisabledTests()
    syntheticEventTests()
    sideButtonTests()
    scrollEventTests()
    capsKeyEventTests()
    capsStateTests()
    effectiveMaskTests()
    wheelStepTests()
    wheelBindingTests()
}

// MARK: - Pure functions

private func escapeDecisionTests() {
    expect(shouldSendEscape(heldMs: 80, otherKeyPressed: false), "fast tap escapes")
    expect(!shouldSendEscape(heldMs: 500, otherKeyPressed: false), "long hold does not escape")
    expect(!shouldSendEscape(heldMs: 80, otherKeyPressed: true), "meh combo does not escape")
    expect(!shouldSendEscape(heldMs: 200, otherKeyPressed: false), "the 200 ms boundary does not escape")
    expect(shouldSendEscape(heldMs: 199.9, otherKeyPressed: false), "just below the boundary escapes")
    expect(!shouldSendEscape(heldMs: 250, otherKeyPressed: false, timeoutMs: 250), "custom timeout boundary")
    expect(shouldSendEscape(heldMs: 249, otherKeyPressed: false, timeoutMs: 250), "custom timeout below boundary")
}

private func scrollDecisionTests() {
    expect(shouldInvertScroll(scrollPhase: 0, momentumPhase: 0), "a wheel event inverts")
    let phased: [(Int64, Int64)] = [(1, 0), (2, 0), (4, 0), (0, 1), (0, 2), (0, 3), (4, 3)]
    for (scrollPhase, momentumPhase) in phased {
        expect(!shouldInvertScroll(scrollPhase: scrollPhase, momentumPhase: momentumPhase),
               "phase \(scrollPhase)/\(momentumPhase) (trackpad, Magic Mouse) stays untouched")
    }
}

private func settingsMaskTests() {
    let defaults = TapSettings()
    expectEqual(defaults.mask, 0)
    expect(!defaults.needsTap, "default settings need no tap")

    expectEqual(settings(caps: .meh).mask, keyBits)
    expectEqual(settings(caps: .hyper).mask, keyBits)
    expect(settings(caps: .meh).needsTap, "a Caps modifier mode needs the tap")
    expectEqual(settings(back: back).mask, mouseBits)
    expectEqual(settings(forward: forward).mask, mouseBits)
    expect(settings(back: back).needsTap, "a mapped side button needs the tap")
    expectEqual(settings(vertical: true).mask, scrollBit)
    expectEqual(settings(horizontal: true).mask, scrollBit)
    expect(settings(horizontal: true).needsTap, "scroll inversion needs the tap")
    expectEqual(settings(wheel: WheelMap(left: back)).mask, scrollBit)
    expectEqual(settings(wheel: WheelMap(right: forward)).mask, scrollBit)
    expectEqual(settings(caps: .meh, back: back, forward: forward, vertical: true, horizontal: true).mask,
                keyBits | mouseBits | scrollBit)

    var config = AppConfig()
    config.capsLock = .default
    config.mouse.buttons.thumb = back
    expect(!TapSettings(config: config).needsTap, "a thumb mapping alone needs no tap (HID++, not the tap)")

    config.capsLock = .hyper
    config.mouse.buttons.forward = forward
    config.mouse.invertScroll.vertical = true
    let fromConfig = TapSettings(config: config)
    expectEqual(fromConfig, settings(caps: .hyper, forward: forward, vertical: true))
    expectEqual(fromConfig.mask, keyBits | mouseBits | scrollBit)

    config.mouse.buttons.back = back
    config.mouse.invertScroll = InvertScroll(vertical: false, horizontal: true)
    expectEqual(TapSettings(config: config), settings(caps: .hyper, back: back, forward: forward, horizontal: true))
    config.mouse.horizontalWheel = WheelMap(left: back)
    expectEqual(TapSettings(config: config).wheel, WheelMap(left: back), "wheel bindings reach the tap")
}

private func capsFlagsTests() {
    expectEqual(capsModifierFlags(for: .default), [])
    expectEqual(capsModifierFlags(for: .meh), meh)
    expectEqual(capsModifierFlags(for: .threeMod), threeMod)
    expectEqual(capsModifierFlags(for: .hyper), hyper)

    expectEqual(flagsWhileCapsHeld([], mode: .meh), meh)
    expectEqual(flagsWhileCapsHeld([], mode: .threeMod), threeMod)
    expectEqual(flagsWhileCapsHeld([], mode: .hyper), hyper)
    expectEqual(flagsWhileCapsHeld(.maskShift, mode: .meh), meh.union(.maskShift))
    expectEqual(flagsWhileCapsHeld(.maskShift, mode: .threeMod), threeMod.union(.maskShift))
    expectEqual(flagsWhileCapsHeld(.maskCommand, mode: .meh), meh.union(.maskCommand))
    expectEqual(flagsWhileCapsHeld(.maskShift, mode: .hyper), hyper)
    expectEqual(flagsWhileCapsHeld([.maskSecondaryFn, .maskShift], mode: .meh), meh.union([.maskSecondaryFn, .maskShift]))
    expectEqual(flagsWhileCapsHeld([.maskShift, .maskCommand], mode: .default), [.maskShift, .maskCommand])
    expectEqual(flagsWhileCapsHeld([.maskAlphaShift, .maskShift], mode: .meh), meh.union(.maskShift))
    expectEqual(flagsWhileCapsHeld(.maskAlphaShift, mode: .hyper), hyper)
    expectEqual(flagsWhileCapsHeld(.maskAlphaShift, mode: .default), .maskAlphaShift)
}

// MARK: - TapState.handle

private func tapDisabledTests() {
    for (type, reason) in [(CGEventType.tapDisabledByTimeout, "timeout"), (.tapDisabledByUserInput, "userInput")] {
        var state = TapState()
        _ = state.capsKey(down: true, nowNanos: 0)
        let (decision, effects) = state.handle(TapEvent(type: type), settings: settings(caps: .meh))
        expectEqual(decision, TapDecision(pass: true, reenableTap: true))
        let line = "tap disabled reason=\(reason) capsHeld=true"
        // Caps toggles that happened while the tap was off went unfiltered, so the latch is cleared unconditionally.
        expectEqual(effects, [.log(.info, line), .debugLog(line), .clearCapsLock])
        expect(!state.capsHeld, "a disabled tap ends the Caps hold (\(reason))")
        // The key-up that was lost with the tap must not produce Esc later.
        expectEqual(state.capsKey(down: false, nowNanos: 10 * ms), [])
        // Default mode leaves the native latch alone.
        let idle = "tap disabled reason=\(reason) capsHeld=false"
        expectEqual(state.handle(TapEvent(type: type), settings: settings(back: back)).1, [.log(.info, idle), .debugLog(idle)])
    }
}

private func syntheticEventTests() {
    var state = TapState()
    _ = state.capsKey(down: true, nowNanos: 0)
    let s = settings(caps: .hyper, back: back, forward: forward, vertical: true, horizontal: true)
    let tag = kSyntheticEventTag
    let events = [
        TapEvent(type: .keyDown, userData: tag, flags: []),
        TapEvent(type: .keyUp, userData: tag),
        TapEvent(type: .flagsChanged, userData: tag, keyCode: 57),
        TapEvent(type: .otherMouseDown, userData: tag, button: 3),
        scrollWithTag(tag),
    ]
    for event in events {
        let (decision, effects) = state.handle(event, settings: s)
        expect(decision == TapDecision(), "own \(event.type) events pass untouched even while Caps is held")
        expectEqual(effects, [])
    }
    // The tagged mouse-down was not recorded as swallowed: its up passes.
    expectEqual(state.handle(mouse(.otherMouseUp, button: 3), settings: s).0, TapDecision())
    // A different user-data value is not our tag.
    let (decision, _) = state.handle(TapEvent(type: .keyDown, userData: tag + 1), settings: s)
    expectEqual(decision.flags, hyper)
}

private func scrollWithTag(_ tag: Int64) -> TapEvent {
    TapEvent(type: .scrollWheel, userData: tag, vertical: ScrollAxis(line: 1, fixed: 1, point: 10))
}

private func sideButtonTests() {
    let s = settings(back: back, forward: forward)

    var state = TapState()
    var (decision, effects) = state.handle(mouse(.otherMouseDown, button: 3), settings: s)
    expectEqual(decision, TapDecision(pass: false))
    expectEqual(effects, [.run(back)])
    (decision, effects) = state.handle(mouse(.otherMouseUp, button: 3), settings: s)
    expectEqual(decision, TapDecision(pass: false))
    expectEqual(effects, [])
    // The record is consumed by the up.
    expectEqual(state.handle(mouse(.otherMouseUp, button: 3), settings: s).0, TapDecision())

    (decision, effects) = state.handle(mouse(.otherMouseDown, button: 4), settings: s)
    expectEqual(decision, TapDecision(pass: false))
    expectEqual(effects, [.run(forward)])
    expectEqual(state.handle(mouse(.otherMouseUp, button: 4), settings: s).0, TapDecision(pass: false))

    // Unmapped buttons pass, in both directions.
    let onlyForward = settings(forward: forward)
    (decision, effects) = state.handle(mouse(.otherMouseDown, button: 3), settings: onlyForward)
    expectEqual(decision, TapDecision())
    expectEqual(effects, [])
    expectEqual(state.handle(mouse(.otherMouseUp, button: 3), settings: onlyForward).0, TapDecision())

    // Other buttons (middle, 5+) pass even when back and forward are mapped.
    for button: Int64 in [2, 5, 7] {
        expectNoop(state.handle(mouse(.otherMouseDown, button: button), settings: s))
        expectEqual(state.handle(mouse(.otherMouseUp, button: button), settings: s).0, TapDecision())
    }

    // Up without a preceding swallowed down passes.
    var fresh = TapState()
    expectEqual(fresh.handle(mouse(.otherMouseUp, button: 4), settings: s).0, TapDecision())

    // The mapping disappears between down and up: the up is still swallowed (no dangling up).
    var removed = TapState()
    _ = removed.handle(mouse(.otherMouseDown, button: 3), settings: s)
    expectEqual(removed.handle(mouse(.otherMouseUp, button: 3), settings: TapSettings()).0, TapDecision(pass: false))

    // A mapping appears between down and up: the down passed, so the up passes too.
    var added = TapState()
    expectEqual(added.handle(mouse(.otherMouseDown, button: 3), settings: TapSettings()).0, TapDecision())
    expectEqual(added.handle(mouse(.otherMouseUp, button: 3), settings: s).0, TapDecision())

    // A stale record (up never seen) is dropped by the next down of that button, which then passes if unmapped.
    var stale = TapState()
    _ = stale.handle(mouse(.otherMouseDown, button: 3), settings: s)
    expectEqual(stale.handle(mouse(.otherMouseDown, button: 3), settings: TapSettings()).0, TapDecision())
    expectEqual(stale.handle(mouse(.otherMouseUp, button: 3), settings: s).0, TapDecision())
    expectEqual(stale.effectiveMask(TapSettings()), 0)

    // Each repeated mapped down runs the action again (one press = one down).
    var twice = TapState()
    expectEqual(twice.handle(mouse(.otherMouseDown, button: 3), settings: s).1, [.run(back)])
    expectEqual(twice.handle(mouse(.otherMouseDown, button: 3), settings: s).1, [.run(back)])
}

private func scrollEventTests() {
    let vertical = ScrollAxis(line: 3, fixed: 3.5, point: 30)
    let horizontal = ScrollAxis(line: -2, fixed: -2.25, point: -20)
    let negatedVertical = ScrollAxis(line: -3, fixed: -3.5, point: -30)
    let negatedHorizontal = ScrollAxis(line: 2, fixed: 2.25, point: 20)
    var state = TapState()

    // Inversion off: untouched.
    var (decision, effects) = state.handle(scroll(vertical: vertical, horizontal: horizontal), settings: settings(caps: .meh))
    expectEqual(decision, TapDecision())
    expectEqual(effects, [])

    // Vertical only: only the vertical axis is rewritten.
    decision = state.handle(scroll(vertical: vertical, horizontal: horizontal), settings: settings(vertical: true)).0
    expectEqual(decision, TapDecision(vertical: negatedVertical))
    expect(decision.horizontal == nil, "horizontal stays untouched")

    // Horizontal only.
    decision = state.handle(scroll(vertical: vertical, horizontal: horizontal), settings: settings(horizontal: true)).0
    expectEqual(decision, TapDecision(horizontal: negatedHorizontal))

    // Both axes.
    decision = state.handle(scroll(vertical: vertical, horizontal: horizontal), settings: settings(vertical: true, horizontal: true)).0
    expectEqual(decision, TapDecision(vertical: negatedVertical, horizontal: negatedHorizontal))

    // An axis without movement is not rewritten.
    decision = state.handle(scroll(vertical: vertical), settings: settings(vertical: true, horizontal: true)).0
    expectEqual(decision, TapDecision(vertical: negatedVertical))
    decision = state.handle(scroll(), settings: settings(vertical: true, horizontal: true)).0
    expectEqual(decision, TapDecision())
    // An axis that only has a sub-line fixed-point delta still counts as movement.
    decision = state.handle(scroll(vertical: ScrollAxis(line: 0, fixed: 0.25, point: 0)), settings: settings(vertical: true)).0
    expectEqual(decision.vertical, ScrollAxis(line: 0, fixed: -0.25, point: 0))

    // Trackpad / Magic Mouse (phase or momentum set): untouched, whatever the settings.
    for (phase, momentum) in [(Int64(4), Int64(0)), (0, 2)] {
        decision = state.handle(scroll(phase: phase, momentum: momentum, vertical: vertical, horizontal: horizontal),
                                settings: settings(vertical: true, horizontal: true)).0
        expectEqual(decision, TapDecision())
    }
}

private func capsKeyEventTests() {
    var state = TapState()

    // The Caps Lock toggle event never reaches apps in a modifier mode; other keycodes and default mode pass.
    let toggle = TapEvent(type: .flagsChanged, keyCode: 57)
    expectEqual(state.handle(toggle, settings: settings(caps: .meh)).0, TapDecision(pass: false))
    expectEqual(state.handle(toggle, settings: settings(caps: .hyper)).0, TapDecision(pass: false))
    expectEqual(state.handle(toggle, settings: settings(caps: .default)).0, TapDecision())
    expectEqual(state.handle(TapEvent(type: .flagsChanged, keyCode: 56), settings: settings(caps: .meh)).0, TapDecision())

    for mode in [CapsMode.meh, .threeMod, .hyper] {
        var clean = TapState()
        let capsToggle = TapEvent(type: .flagsChanged, keyCode: 57, flags: [.maskAlphaShift, .maskShift])
        let toggled = clean.handle(capsToggle, settings: settings(caps: mode))
        expectEqual(toggled.0, TapDecision(pass: false, flags: .maskShift))
        expectEqual(toggled.1, [.clearCapsLock])
        let shiftChange = clean.handle(TapEvent(type: .flagsChanged, keyCode: 56, flags: [.maskAlphaShift, .maskShift]), settings: settings(caps: mode))
        expectEqual(shiftChange.0, TapDecision(flags: .maskShift))
        expectEqual(shiftChange.1, [.clearCapsLock])
        for type in [CGEventType.keyDown, .keyUp] {
            let event = TapEvent(type: type, keyCode: 0, flags: [.maskAlphaShift, .maskShift])
            let released = clean.handle(event, settings: settings(caps: mode))
            expectEqual(released.0, TapDecision(flags: .maskShift))
            expectEqual(released.1, [.clearCapsLock])
            _ = clean.capsKey(down: true, nowNanos: 0)
            let held = clean.handle(event, settings: settings(caps: mode))
            expectEqual(held.0.flags, Optional(capsModifierFlags(for: mode).union(.maskShift)))
            expectEqual(held.1, [.clearCapsLock])
            clean.resetCaps()
            expectNoop(clean.handle(event, settings: settings(caps: .default)))
        }
    }

    // Not held: keys pass without flags.
    let key = TapEvent(type: .keyDown, keyCode: 40, flags: .maskShift)
    expectNoop(state.handle(key, settings: settings(caps: .meh)))

    // Held: both key phases get the mode flags; physical modifiers are kept.
    _ = state.capsKey(down: true, nowNanos: 0)
    expectEqual(state.handle(key, settings: settings(caps: .meh)).0, TapDecision(flags: meh.union(.maskShift)))
    expectEqual(state.handle(key, settings: settings(caps: .threeMod)).0, TapDecision(flags: threeMod.union(.maskShift)))
    expectEqual(state.handle(TapEvent(type: .keyUp, keyCode: 40), settings: settings(caps: .hyper)).0, TapDecision(flags: hyper))
    // Default mode ignores a held Caps state.
    expectEqual(state.handle(key, settings: settings(caps: .default)).0, TapDecision())

    // Event types the tap never asked for pass.
    for type in [CGEventType.leftMouseDown, .mouseMoved, .otherMouseDragged] {
        expectNoop(state.handle(TapEvent(type: type), settings: settings(caps: .meh, back: back)))
    }
}

// MARK: - TapState.capsKey / reset

private func capsStateTests() {
    // Short tap: Esc.
    var state = TapState()
    expectEqual(state.capsKey(down: true, nowNanos: 1_000 * ms), [.log(.info, "caps down"), .debugLog("caps down")])
    expect(state.capsHeld, "down sets held")
    let up = "caps up held_ms=80 esc=true"
    expectEqual(state.capsKey(down: false, nowNanos: 1_080 * ms), [.log(.info, up), .debugLog(up), .postEscape])
    expect(!state.capsHeld, "up clears held")

    // Another key pressed while held: no Esc, even for a quick hold.
    _ = state.capsKey(down: true, nowNanos: 5_000 * ms)
    _ = state.handle(TapEvent(type: .keyDown, keyCode: 4), settings: settings(caps: .meh))
    let combo = "caps up held_ms=50 esc=false"
    expectEqual(state.capsKey(down: false, nowNanos: 5_050 * ms), [.log(.info, combo), .debugLog(combo)])

    // A key-up alone while held does not count as "other key pressed".
    _ = state.capsKey(down: true, nowNanos: 6_000 * ms)
    _ = state.handle(TapEvent(type: .keyUp, keyCode: 4), settings: settings(caps: .meh))
    expect(state.capsKey(down: false, nowNanos: 6_010 * ms).contains(.postEscape), "a stray key-up does not suppress Esc")

    // The other-key memory does not leak into the next press.
    _ = state.capsKey(down: true, nowNanos: 7_000 * ms)
    expect(state.capsKey(down: false, nowNanos: 7_010 * ms).contains(.postEscape), "new press starts clean")

    // Held 200 ms or longer: no Esc (boundary), 199 ms still Esc.
    _ = state.capsKey(down: true, nowNanos: 8_000 * ms)
    expect(!state.capsKey(down: false, nowNanos: 8_200 * ms).contains(.postEscape), "200 ms hold is not a tap")
    _ = state.capsKey(down: true, nowNanos: 9_000 * ms)
    expect(state.capsKey(down: false, nowNanos: 9_199 * ms).contains(.postEscape), "199 ms hold is a tap")

    // Repeated down and up-without-down are ignored.
    var repeated = TapState()
    _ = repeated.capsKey(down: true, nowNanos: 0)
    expectEqual(repeated.capsKey(down: true, nowNanos: 500 * ms), [])
    // The ignored repeat did not restart the clock: this is a 100 ms hold counted from the first down.
    let first = "caps up held_ms=100 esc=true"
    expectEqual(repeated.capsKey(down: false, nowNanos: 100 * ms), [.log(.info, first), .debugLog(first), .postEscape])
    expectEqual(repeated.capsKey(down: false, nowNanos: 200 * ms), [])

    // A clock that did not advance cannot produce a negative hold time.
    var clock = TapState()
    _ = clock.capsKey(down: true, nowNanos: 500 * ms)
    expect(clock.capsKey(down: false, nowNanos: 400 * ms).contains(.log(.info, "caps up held_ms=0 esc=true")), "clamped to 0 ms")

    // Reset ends the hold silently.
    var reset = TapState()
    _ = reset.capsKey(down: true, nowNanos: 0)
    reset.resetCaps()
    expect(!reset.capsHeld, "reset clears held")
    expectEqual(reset.capsKey(down: false, nowNanos: 10 * ms), [])
    expectEqual(reset.handle(TapEvent(type: .keyDown, keyCode: 4), settings: settings(caps: .meh)).0, TapDecision())
}

private func effectiveMaskTests() {
    let s = settings(caps: .meh)
    var state = TapState()
    expectEqual(state.effectiveMask(s), keyBits)
    expectEqual(state.effectiveMask(TapSettings()), 0)

    // While a swallowed button is held, its release must stay observable even if the mapping is gone.
    _ = state.handle(mouse(.otherMouseDown, button: 4), settings: settings(forward: forward))
    expectEqual(state.effectiveMask(TapSettings()), mouseBits)
    expectEqual(state.effectiveMask(s), keyBits | mouseBits)

    _ = state.handle(mouse(.otherMouseUp, button: 4), settings: TapSettings())
    expectEqual(state.effectiveMask(TapSettings()), 0)

    _ = state.handle(mouse(.otherMouseDown, button: 3), settings: settings(back: back))
    state.clearSwallowed()
    expectEqual(state.effectiveMask(TapSettings()), 0)
    expectEqual(state.handle(mouse(.otherMouseUp, button: 3), settings: settings(back: back)).0, TapDecision())
}

// MARK: - Horizontal wheel bindings

private let wheelLeft = ButtonAction.helper("nextWindow")
private let wheelRight = ButtonAction.shell("previous-window")

/// A horizontal thumb-wheel notch (line delta) or a high-resolution continuous chunk (point delta).
private func notch(_ lines: Int64, at time: UInt64, inverted: Bool = false, phase: Int64 = 0, momentum: Int64 = 0) -> TapEvent {
    TapEvent(type: .scrollWheel, scrollPhase: phase, momentumPhase: momentum,
             horizontal: ScrollAxis(line: lines, fixed: Double(lines), point: lines * 10),
             invertedFromDevice: inverted, nowNanos: time)
}

private func smooth(_ points: Int64, at time: UInt64, phase: Int64 = 0, momentum: Int64 = 0) -> TapEvent {
    TapEvent(type: .scrollWheel, scrollPhase: phase, momentumPhase: momentum,
             horizontal: ScrollAxis(line: points > 0 ? 1 : -1, fixed: Double(points) / 10, point: points),
             continuous: true, nowNanos: time)
}

private func wheelStepTests() {
    let gap = WheelSteps.rollGapNanos, interval = WheelSteps.minIntervalNanos, threshold = WheelSteps.continuousStepPoints
    var steps = WheelSteps()
    expect(steps.step(.right, continuousPoints: nil, nowNanos: 1_000 * ms), "first notch fires")
    expect(!steps.step(.right, continuousPoints: nil, nowNanos: 1_000 * ms + interval - 1), "too soon after a step")
    expect(steps.step(.right, continuousPoints: nil, nowNanos: 1_000 * ms + interval), "interval boundary fires")

    steps = WheelSteps()
    var fired = 0
    for i in 0..<200 where steps.step(.right, continuousPoints: nil, nowNanos: UInt64(i) * 10 * ms) { fired += 1 }
    expectEqual(fired, WheelSteps.maxStepsPerRoll, "a 2 s free-spin flick is limited")
    expect(!steps.step(.right, continuousPoints: nil, nowNanos: 1_990 * ms + gap), "gap boundary still continues the roll")
    expect(steps.step(.right, continuousPoints: nil, nowNanos: 1_990 * ms + 2 * gap + 1), "a quiet gap starts a new roll")

    steps = WheelSteps()
    expect(!steps.step(.left, continuousPoints: threshold / 2, nowNanos: 1_000 * ms), "half a step")
    expect(!steps.step(.left, continuousPoints: threshold / 2 - 0.5, nowNanos: 1_010 * ms), "still below the threshold")
    expect(steps.step(.left, continuousPoints: 0.5, nowNanos: 1_020 * ms), "threshold reached")
    expect(!steps.step(.left, continuousPoints: threshold, nowNanos: 1_030 * ms), "the rest of the same notch is rate-limited")
    expect(!steps.step(.left, continuousPoints: threshold / 2, nowNanos: 1_020 * ms + interval), "limited travel was discarded")
    expect(steps.step(.left, continuousPoints: threshold / 2, nowNanos: 1_020 * ms + interval + 1), "fresh travel fires again")

    steps = WheelSteps()
    expect(!steps.step(.left, continuousPoints: threshold - 1, nowNanos: 1_000 * ms), "almost a step")
    expect(!steps.step(.left, continuousPoints: 1, nowNanos: 1_000 * ms + gap + 1), "stale travel is dropped")
    steps = WheelSteps()
    expect(!steps.step(.left, continuousPoints: threshold - 1, nowNanos: 1_000 * ms), "almost a step left")
    expect(!steps.step(.right, continuousPoints: 1, nowNanos: 1_010 * ms), "reversal drops travel")
    for i in 0..<WheelSteps.maxStepsPerRoll {
        expect(steps.step(.left, continuousPoints: nil, nowNanos: 2_000 * ms + UInt64(i) * interval), "roll step \(i)")
    }
    expect(steps.step(.right, continuousPoints: nil, nowNanos: 2_000 * ms + 3 * interval), "a reversal resets the roll cap")
    steps.reset()
    expect(steps.step(.right, continuousPoints: nil, nowNanos: 2_000 * ms + 4 * interval), "reset ends the roll")
    expect(!steps.step(.right, continuousPoints: nil, nowNanos: 0), "earlier timestamp is too soon")
}

private func wheelBindingTests() {
    let both = settings(wheel: WheelMap(left: wheelLeft, right: wheelRight))
    var state = TapState()

    var result = state.handle(notch(1, at: 1_000 * ms), settings: both)
    expectEqual(result.0, TapDecision(horizontal: .zero))
    expectEqual(result.1, [.run(wheelLeft)], "positive horizontal delta is physical left")
    result = state.handle(notch(-3, at: 2_000 * ms), settings: both)
    expectEqual(result.1, [.run(wheelRight)], "negative horizontal delta is physical right")
    result = state.handle(notch(-1, at: 2_010 * ms), settings: both)
    expectEqual(result.0, TapDecision(horizontal: .zero), "rate-limited horizontal movement is still removed")
    expectEqual(result.1, [])

    result = state.handle(notch(-1, at: 3_000 * ms, inverted: true), settings: both)
    expectEqual(result.1, [.run(wheelLeft)], "Natural Scrolling preserves physical left")
    let onlyRight = settings(wheel: WheelMap(right: wheelRight))
    expectNoop(state.handle(notch(1, at: 4_000 * ms), settings: onlyRight))
    let invertedRight = settings(horizontal: true, wheel: WheelMap(right: wheelRight))
    result = state.handle(notch(1, at: 4_100 * ms), settings: invertedRight)
    expectEqual(result.0, TapDecision(horizontal: ScrollAxis(line: -1, fixed: -1, point: -10)),
                "unmapped left remains subject to horizontal inversion")
    result = state.handle(notch(-1, at: 4_200 * ms), settings: invertedRight)
    expectEqual(result.0, TapDecision(horizontal: .zero))
    expectEqual(result.1, [.run(wheelRight)], "horizontal inversion does not swap bindings")

    var roll = TapState()
    for i in 0..<UInt64(WheelSteps.maxStepsPerRoll) {
        _ = roll.handle(notch(-1, at: (5_000 + i * 200) * ms), settings: onlyRight)
    }
    expectEqual(roll.handle(notch(-1, at: 5_600 * ms), settings: onlyRight).1, [], "roll cap reached")
    _ = roll.handle(notch(1, at: 5_700 * ms), settings: onlyRight)
    expectEqual(roll.handle(notch(-1, at: 5_800 * ms), settings: onlyRight).1, [.run(wheelRight)], "unmapped scroll resets roll")

    // Vertical-only movement is never bound. Mixed-axis events preserve vertical motion.
    let vertical = ScrollAxis(line: 1, fixed: 1, point: 10)
    expectNoop(state.handle(TapEvent(type: .scrollWheel, vertical: vertical), settings: both))
    let mixed = TapEvent(type: .scrollWheel, vertical: vertical,
                         horizontal: ScrollAxis(line: 1, fixed: 1, point: 10), nowNanos: 8_000 * ms)
    result = state.handle(mixed, settings: both)
    expectEqual(result.0, TapDecision(horizontal: .zero), "mixed event retains the original vertical delta")
    expectEqual(result.1, [.run(wheelLeft)])
    result = state.handle(mixed, settings: settings(vertical: true, wheel: WheelMap(left: wheelLeft)))
    expectEqual(result.0, TapDecision(vertical: ScrollAxis(line: -1, fixed: -1, point: -10), horizontal: .zero),
                "mixed event honors vertical inversion")
    expectEqual(result.1, []) // Same instant remains subject to step throttling.
    expectNoop(state.handle(TapEvent(type: .scrollWheel), settings: both))
    let subLine = TapEvent(type: .scrollWheel, horizontal: ScrollAxis(line: 0, fixed: -0.5, point: 0), nowNanos: 9_000 * ms)
    expectEqual(state.handle(subLine, settings: both).1, [.run(wheelRight)])

    var hires = TapState()
    result = hires.handle(smooth(8, at: 1_000 * ms), settings: both)
    expectEqual(result.0, TapDecision(horizontal: .zero), "partial travel is consumed")
    expectEqual(result.1, [])
    _ = hires.handle(smooth(8, at: 1_008 * ms), settings: both)
    expectEqual(hires.handle(smooth(8, at: 1_016 * ms), settings: both).1, [.run(wheelLeft)], "threshold crossed")
    expectEqual(hires.handle(smooth(-25, at: 1_400 * ms), settings: both).1, [.run(wheelRight)], "rightward travel")
    let fixedOnly = TapEvent(type: .scrollWheel, horizontal: ScrollAxis(line: 0, fixed: -30, point: 0),
                             continuous: true, nowNanos: 2_000 * ms)
    expectEqual(hires.handle(fixedOnly, settings: both).1, [.run(wheelRight)], "continuous fixed-point fallback")

    for (phase, momentum) in [(Int64(1), Int64(0)), (2, 0), (4, 0), (0, 1), (0, 2), (0, 3)] {
        expectNoop(state.handle(smooth(40, at: 10_000 * ms, phase: phase, momentum: momentum), settings: both))
        expectNoop(state.handle(notch(1, at: 10_000 * ms, phase: phase, momentum: momentum), settings: both))
    }
    expectNoop(state.handle(notch(1, at: 11_000 * ms), settings: settings()))
    var synthetic = notch(1, at: 12_000 * ms)
    synthetic.userData = kSyntheticEventTag
    expectNoop(state.handle(synthetic, settings: both))
}
