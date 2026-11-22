import Foundation

/// Turns mapped horizontal wheel events into discrete action steps. Value type owned by `TapState`.
///
/// A clicky wheel reports one line-delta event per notch: each event is one step. A high-resolution or smooth
/// wheel reports a stream of small continuous point deltas: `continuousStepPoints` of travel make one step.
/// Events closer than `rollGapNanos` form one roll; a roll fires at most `maxStepsPerRoll` actions, at least
/// `minIntervalNanos` apart, so a free-spinning flick does not fire a burst. Travel consumed while limited is
/// discarded. Reversing the direction starts a new roll. Calibration: one MX Master notch is about 1 line or a
/// few dozen points; deliberate notches are rarely closer than 150 ms.
public struct WheelSteps: Equatable {
    public static let continuousStepPoints: Double = 20
    public static let minIntervalNanos: UInt64 = 150_000_000
    public static let rollGapNanos: UInt64 = 300_000_000
    public static let maxStepsPerRoll = 3

    private var direction: WheelDirection?
    private var lastEvent: UInt64 = 0
    private var lastStep: UInt64?
    private var travel: Double = 0
    private var stepsInRoll = 0

    public init() {}

    /// One mapped wheel event. `continuousPoints` is the absolute point travel of a continuous event, nil for a
    /// line (notch) event. Returns true when the action runs now.
    public mutating func step(_ direction: WheelDirection, continuousPoints: Double?, nowNanos: UInt64) -> Bool {
        if direction != self.direction || elapsed(since: lastEvent, nowNanos) > WheelSteps.rollGapNanos {
            self.direction = direction
            travel = 0
            stepsInRoll = 0
        }
        lastEvent = nowNanos
        if let points = continuousPoints {
            travel += points
            guard travel >= WheelSteps.continuousStepPoints else { return false }
        }
        travel = 0
        guard stepsInRoll < WheelSteps.maxStepsPerRoll,
              lastStep.map({ elapsed(since: $0, nowNanos) >= WheelSteps.minIntervalNanos }) ?? true
        else { return false }
        stepsInRoll += 1
        lastStep = nowNanos
        return true
    }

    /// Ends the current roll (an unmapped or non-wheel scroll came in between).
    public mutating func reset() {
        direction = nil
        travel = 0
        stepsInRoll = 0
    }

    private func elapsed(since start: UInt64, _ now: UInt64) -> UInt64 {
        max(now, start) - start
    }
}
