import Foundation
import CoreGraphics

public enum LoginItemStatus: Equatable { case notRegistered, enabled, requiresApproval, notFound }

/// Delay between a Caps Lock event and the read-back that verifies the system latch is off. macOS updates the lock
/// state asynchronously to the HID values and tap events HyperMug sees, so a single clear can race a toggle.
public let capsLatchCheckDelayMs = 100
/// Follow-up checks after a check that still found the latch on; the 2 s sync takes over after that.
public let capsLatchCheckLimit = 5

/// Everything the engine needs from the OS. Implemented by `SystemPorts` (Platform); faked in tests.
public protocol EnginePorts: AnyObject {
    func accessibilityTrusted() -> Bool
    func promptAccessibility()
    func inputMonitoringAccess() -> HIDAccess
    /// Replace semantics: the previous tap (if any) is gone afterwards. `false` = the tap could not be created,
    /// and no tap is installed.
    func installTap(mask: CGEventMask) -> Bool
    func removeTap()
    /// Called on every sync; the Platform applies `CapsMonitorPolicy`.
    func setCapsKeyboardMonitoring(_ on: Bool)
    func acquireCaffeine() -> Bool
    func releaseCaffeine()
    func loginItemStatus() -> LoginItemStatus
    /// nil = ok, otherwise the error text.
    func setLoginItem(registered: Bool) -> String?
    func setThumbDiversion(_ on: Bool)
    func shutdownThumb()
    func configureTrackpad(_ config: TrackpadConfig, enabled: Bool)
    func shutdownTrackpad()
    func run(_ action: ButtonAction)
    func postEscape()
    /// Turns the system Caps Lock latch off. `force` sets it off without trusting the lock-state read-back.
    /// Returns true when the latch was (or could not be confirmed not to be) on, so a clear was issued.
    func clearCapsLock(force: Bool) -> Bool
    /// Calls `Engine.capsLatchCheckDue(attempt:)` on the main thread after the delay. Each call is independent.
    func scheduleCapsLatchCheck(afterMilliseconds: Int, attempt: Int)
    func log(_ level: LogLevel, _ message: String)
    func debugLog(_ line: String)
}

/// Applies the config: event tap lifecycle, Caps Lock state, caffeine, login item, thumb diversion. Main thread only.
public final class Engine {
    public var onStateChange: (() -> Void)?
    public private(set) var caffeineOn = false
    public private(set) var settings = TapSettings()

    private let ports: EnginePorts
    private var tapState = TapState()
    private var lastCaffeineOnLaunch: Bool?
    private var thumbAction: ButtonAction?
    private var thumbEnabled: Bool?
    /// Mask of the installed tap; nil = no tap.
    private var installedMask: CGEventMask?
    private var lastTrusted: Bool?
    private var trackpadConfig = TrackpadConfig()
    private var stopped = false

    public init(ports: EnginePorts) {
        self.ports = ports
    }

    /// Does not apply a config; `apply` is driven by `ConfigStore.onChange`.
    public func start() {
        ports.promptAccessibility()
        ports.debugLog("AXIsProcessTrusted=\(ports.accessibilityTrusted()) IOHIDCheckAccess(listen)=\(ports.inputMonitoringAccess())")
    }

    public func apply(_ config: AppConfig) {
        stopped = false
        let config = config.resolvedActions()
        trackpadConfig = config.trackpad
        let newSettings = TapSettings(config: config)
        if newSettings.capsMode != settings.capsMode { tapState.resetCaps() }
        settings = newSettings
        // Caffeine is session state: the config only supplies its initial value, and only when that setting changes.
        if lastCaffeineOnLaunch != config.caffeineOnLaunch {
            lastCaffeineOnLaunch = config.caffeineOnLaunch
            setCaffeine(config.caffeineOnLaunch)
        }
        thumbAction = config.mouse.buttons.thumb
        let wantThumb = thumbAction != nil
        if thumbEnabled != wantThumb {
            thumbEnabled = wantThumb
            ports.setThumbDiversion(wantThumb)
        }
        applyLaunchAtLogin(config.launchAtLogin)
        sync()
    }

    /// Reconciles the tap and the Caps monitor with the settings and the Accessibility trust. Runs every 2 s and after `apply`.
    public func sync() {
        let trusted = ports.accessibilityTrusted()
        if lastTrusted != trusted {
            lastTrusted = trusted
            note("trust changed trusted=\(trusted)")
        }
        if !trusted { tapState.clearSwallowed() }

        let mask = tapState.effectiveMask(settings)
        if mask != 0 && trusted {
            if installedMask != mask { replaceTap(mask: mask) }
        } else if installedMask != nil {
            tearDownTap()
        }

        // Caps Lock is only watched while its effect (flags in the tap) can be applied; closed otherwise.
        let capsWanted = capsLatchSuppressed
        if !capsWanted { tapState.resetCaps() }
        ports.setCapsKeyboardMonitoring(capsWanted)
        if capsWanted && ports.clearCapsLock(force: false) { scheduleCapsLatchCheck(attempt: 1) }
        ports.configureTrackpad(trackpadConfig, enabled: !stopped && trusted && ports.inputMonitoringAccess() == .granted && trackpadConfig.hasMappings)

        onStateChange?()
    }

    /// Session-only toggle (left-click on the status item); never written to the config.
    public func toggleCaffeine() {
        setCaffeine(!caffeineOn)
        onStateChange?()
    }

    public func shutdown() {
        stopped = true
        trackpadConfig = TrackpadConfig()
        ports.shutdownTrackpad()
        setCaffeine(false)
        settings = TapSettings()
        thumbAction = nil
        ports.setCapsKeyboardMonitoring(false)
        tapState.resetCaps()
        tapState.clearSwallowed()
        if installedMask != nil { tearDownTap() }
        ports.shutdownThumb()
    }

    // MARK: Event paths

    public func handleTapEvent(_ e: TapEvent) -> TapDecision {
        let (decision, effects) = tapState.handle(e, settings: settings)
        perform(effects)
        return decision
    }

    /// Every physical transition also clears the latch: the HID monitor sees presses the tap may not (tap disabled,
    /// Secure Input), and the system toggle can land after this callback, so a check follows either way.
    public func capsKeyChanged(down: Bool, nowNanos: UInt64) {
        perform(tapState.capsKey(down: down, nowNanos: nowNanos))
        guard capsLatchSuppressed else { return }
        _ = ports.clearCapsLock(force: false)
        scheduleCapsLatchCheck(attempt: 1)
    }

    /// A scheduled verification. Keeps checking while it still finds the latch on, up to `capsLatchCheckLimit`.
    public func capsLatchCheckDue(attempt: Int) {
        guard capsLatchSuppressed, ports.clearCapsLock(force: false), attempt < capsLatchCheckLimit else { return }
        scheduleCapsLatchCheck(attempt: attempt + 1)
    }

    public func capsKeyboardRemoved() {
        ports.debugLog("caps hid device removed")
        tapState.resetCaps()
    }

    public func thumbPressed() {
        if let action = thumbAction { ports.run(action) }
    }

    public func trackpadSwiped(_ swipe: TrackpadSwipe) {
        guard !stopped, trackpadConfig.hasMappings(fingers: swipe.fingers),
              let action = trackpadConfig.action(fingers: swipe.fingers, direction: swipe.direction) else { return }
        ports.run(action)
    }

    // MARK: Internals

    private func perform(_ effects: [TapEffect]) {
        for effect in effects {
            switch effect {
            case .run(let action): ports.run(action)
            case .postEscape: ports.postEscape()
            case .clearCapsLock:
                _ = ports.clearCapsLock(force: true)
                scheduleCapsLatchCheck(attempt: 1)
            case .debugLog(let line): ports.debugLog(line)
            case .log(let level, let message): ports.log(level, message)
            }
        }
    }

    /// Native Caps Lock must stay off while a modifier mode and its event tap are active.
    private var capsLatchSuppressed: Bool { settings.capsMode.isModifier && installedMask != nil }

    private func scheduleCapsLatchCheck(attempt: Int) {
        ports.scheduleCapsLatchCheck(afterMilliseconds: capsLatchCheckDelayMs, attempt: attempt)
    }

    private func note(_ message: String) {
        ports.log(.info, message)
        ports.debugLog(message)
    }

    private func replaceTap(mask: CGEventMask) {
        tapState.resetCaps()
        let created = ports.installTap(mask: mask)
        installedMask = created ? mask : nil
        note("tap created location=session mask=\(String(mask, radix: 16)) ok=\(created)")
        if !created { ports.log(.error, "event tap could not be created") }
    }

    private func tearDownTap() {
        tapState.resetCaps()
        ports.removeTap()
        installedMask = nil
        note("tap torn down location=session")
    }

    private func setCaffeine(_ on: Bool) {
        if on && !caffeineOn {
            caffeineOn = ports.acquireCaffeine()
        } else if !on && caffeineOn {
            ports.releaseCaffeine()
            caffeineOn = false
        }
    }

    /// Idempotent: only registers/unregisters when the service status differs, so reloads don't re-prompt.
    private func applyLaunchAtLogin(_ on: Bool) {
        let register: Bool
        switch (on, ports.loginItemStatus()) {
        case (true, .notRegistered), (true, .notFound): register = true
        case (false, .enabled), (false, .requiresApproval): register = false
        default: return
        }
        if let message = ports.setLoginItem(registered: register) {
            ports.log(.error, "launch at login failed: \(message)")
        }
    }
}
