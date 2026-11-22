import AppKit
import HyperMugCore

/// Composition root: builds every Platform adapter, the Core store/engine, wires their callbacks and
/// starts them. It contains no decisions of its own.
@MainActor
private final class HyperMugRuntime {
    let store: ConfigStore
    let tap: EventTapHost
    let caps: CapsKeyMonitor
    let thumb: ThumbHID
    let trackpad: TrackpadCapture
    let ports: SystemPorts
    let engine: Engine
    let updateChecker: UpdateChecker
    let statusItem: StatusItemController
    let notifications: IssueNotifications
    private var syncTimer: Timer?

    init() {
        DebugLog.reset()   // before anything that writes a debug line
        LegacyCapsRemap.removeIfPresent(log: makeLogSink(category: "legacy-caps"))

        let configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        store = ConfigStore(url: configDirectory.appendingPathComponent(AppIdentity.configFileName),
                            legacyURL: configDirectory.appendingPathComponent(AppIdentity.legacyConfigFileName),
                            environment: makeConfigStoreEnvironment(log: makeLogSink(category: "config")))
        tap = EventTapHost(log: makeLogSink(category: "tap"))
        caps = CapsKeyMonitor(log: makeLogSink(category: "caps"))
        thumb = ThumbHID(log: makeLogSink(category: "thumb"))
        trackpad = TrackpadCapture(log: makeLogSink(category: "trackpad"))
        ports = SystemPorts(log: makeLogSink(category: "engine"), tap: tap, caps: caps, thumb: thumb, trackpad: trackpad)
        engine = Engine(ports: ports)
        updateChecker = UpdateChecker()
        statusItem = StatusItemController(store: store, engine: engine, updateChecker: updateChecker, trackpad: trackpad)
        notifications = IssueNotifications()
        notifications.openConfiguration = { [statusItem] in statusItem.showConfiguration() }
        PrivilegeActions.confirmRelaunch = { [statusItem] in statusItem.confirmDiscard($0) }
        ActionRunner.onIssue = { [notifications] in notifications.report($0) }

        tap.handler = { [engine] in engine.handleTapEvent($0) }
        caps.onCapsChange = { [engine] down, nowNanos in engine.capsKeyChanged(down: down, nowNanos: nowNanos) }
        caps.onKeyboardRemoved = { [engine] in engine.capsKeyboardRemoved() }
        thumb.onPress = { [engine] in engine.thumbPressed() }
        ports.onTrackpadSwipe = { [engine] swipe in engine.trackpadSwiped(swipe) }
        ports.onCapsLatchCheck = { [engine] attempt in engine.capsLatchCheckDue(attempt: attempt) }
        engine.onStateChange = { [statusItem] in statusItem.refresh() }
        store.onChange = { [weak store, engine, updateChecker, notifications] config in
            engine.apply(config)
            updateChecker.apply(autoUpdate: config.autoUpdate)
            ActionRunner.configure(timeout: config.shellTimeoutSeconds)
            if store?.error == nil && Bundle.main.url(forResource: AppIdentity.schemaFileName, withExtension: nil) != nil { notifications.configurationRecovered() }
        }
        store.onNotice = { notice in DebugLog.write(notice.message) }
        store.onError = { [notifications, statusItem] error in
            DebugLog.write("Invalid configuration: \(error.reason)")
            notifications.report(.configuration)
            statusItem.refresh()
        }
    }

    func start() {
        engine.start()
        thumb.start()
        store.start()   // first onChange performs the first apply
        if Bundle.main.url(forResource: AppIdentity.schemaFileName, withExtension: nil) == nil {
            DebugLog.write("Bundled configuration schema is missing; reinstall the app")
            notifications.report(.configuration)
        }

        // Common modes: the timer also fires while a menu or an alert is open.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            // This timer is registered only on RunLoop.main, including menu tracking modes.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine.sync()
                self.store.pollFallback()
                self.thumb.tick()
                self.statusItem.refresh()
                if self.store.error == nil && Bundle.main.url(forResource: AppIdentity.schemaFileName, withExtension: nil) != nil {
                    self.notifications.configurationRecovered()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    func shutdown() {
        syncTimer?.invalidate()
        syncTimer = nil
        engine.shutdown()
        ActionRunner.shutdown()
    }

    func showDoctor() { statusItem.showDoctor() }
    func showWindow() { statusItem.showWindow() }
    var hasUnsavedConfiguration: Bool { statusItem.hasUnsavedConfiguration }
    func confirmDiscard(_ reply: @escaping (Bool) -> Void) { statusItem.confirmDiscard(reply) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: HyperMugRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = HyperMugRuntime()
        self.runtime = runtime
        runtime.start()
        if CommandLine.arguments.contains("--doctor") { runtime.showDoctor() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime, runtime.hasUnsavedConfiguration else { return .terminateNow }
        runtime.confirmDiscard { sender.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime?.showWindow()
        return true
    }
}

@main
enum HyperMugMain {
    static func main() {
        if CommandLine.arguments.contains("--diagnose-permissions") {
            PermissionDiagnostics.runAndExit()
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate   // NSApplication holds its delegate weakly
        withExtendedLifetime(delegate) { app.run() }
    }
}
