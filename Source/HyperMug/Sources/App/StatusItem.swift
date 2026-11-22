import AppKit
import HyperMugCore

/// Menu bar icon. Clicking opens the native menu; its Stay Awake checkbox toggles Caffeine for the
/// running session (never written to the config). All click decisions live in Core `StatusLogic`.
@MainActor
final class StatusItemController: NSObject {
    private let store: ConfigStore
    private let engine: Engine
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var stayAwakeItem: NSMenuItem!
    private var configErrorItem: NSMenuItem!
    private var tracker = SecureInputTracker()
    private var secureItem: NSMenuItem?
    private var secureSeparator: NSMenuItem?
    private var secureTimer: Timer?
    private var doctorObserver: NSObjectProtocol?
    private let trackpad: TrackpadCapture
    private lazy var appWindow = HyperMugWindowController(store: store, capture: trackpad)
    /// Details window; each refresh re-polls so "seen since" stays owned by this controller.
    private lazy var secureWindow = SecureInputWindowController { [weak self] in
        self?.pollSecureInput()
        return (self?.tracker.info, self?.tracker.since)
    }

    init(store: ConfigStore, engine: Engine, updateChecker: UpdateChecker, trackpad: TrackpadCapture) {
        self.store = store
        self.engine = engine
        self.trackpad = trackpad
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        doctorObserver = NotificationCenter.default.addObserver(forName: .showHyperMugDoctor, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.showDoctor() } }
        ApplicationMenu.install(settingsTarget: self, settingsAction: #selector(openSettings), doctorAction: #selector(showDoctor), saveAction: #selector(saveConfiguration))

        let settings = NSMenuItem(title: MenuText.settings, action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        let stayAwake = NSMenuItem(title: "Stay Awake", action: #selector(toggleCaffeine), keyEquivalent: "")
        stayAwake.target = self
        stayAwakeItem = stayAwake
        let doctor = NSMenuItem(title: "Doctor…", action: #selector(showDoctor), keyEquivalent: "")
        let updates = NSMenuItem(title: MenuText.updates, action: nil, keyEquivalent: "")
        let quit = NSMenuItem(title: MenuText.quit, action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        for item in [settings, doctor, quit] { item.target = self }
        updateChecker.configureMenuItem(updates)

        menu.autoenablesItems = false
        let errorItem = NSMenuItem(title: "Configuration Error…", action: #selector(openSettings), keyEquivalent: "")
        errorItem.target = self
        errorItem.isHidden = true
        configErrorItem = errorItem
        menu.addItem(errorItem)
        menu.addItem(stayAwake)
        menu.addItem(.separator())
        menu.addItem(settings)
        menu.addItem(doctor)
        menu.addItem(updates)
        menu.addItem(.separator())
        menu.addItem(quit)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollSecureInput() } }
        RunLoop.main.add(timer, forMode: .common)
        secureTimer = timer
        pollSecureInput()
        refresh()
    }

    func refresh() {
        configErrorItem.isHidden = store.error == nil
        stayAwakeItem.state = engine.caffeineOn ? .on : .off
        let icon = statusIcon(caffeineOn: engine.caffeineOn, secureHolderName: tracker.info?.holder.name)
        let image: NSImage?
        switch icon.glyph {
        case .mokaFilled: image = MokaPotStatusImage.make(filled: true)
        case .mokaOutline: image = MokaPotStatusImage.make(filled: false)
        case .secureInput: image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: icon.label)
        }
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel(icon.label)
        statusItem.button?.toolTip = icon.label
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        let kind: MouseUpKind
        switch event.type {
        case .leftMouseUp: kind = .left
        case .rightMouseUp: kind = .right
        default: kind = .other
        }
        switch classifyStatusClick(kind, controlHeld: event.modifierFlags.contains(.control)) {
        case .showMenu:
            // Re-read Secure Input so the first item is current when the menu opens.
            pollSecureInput()
            // Attach the same native menu for left, right and Control clicks.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    @objc private func toggleCaffeine() {
        engine.toggleCaffeine()
    }

    /// Main-thread poll (2 s timer, common modes so it also runs while the menu or an alert is open).
    /// Keeps the latest details for the window; the icon and menu change only when the holder changes.
    private func pollSecureInput() {
        guard tracker.update(SecureInputReader.current(), now: Date()) else { return }
        updateSecureMenuItems()
        refresh()
    }

    /// `Blocked by Secure Input: <app>…` plus a separator at the top of the menu while active; nothing otherwise.
    private func updateSecureMenuItems() {
        if let item = secureItem {
            menu.removeItem(item)
            secureItem = nil
        }
        if let separator = secureSeparator {
            menu.removeItem(separator)
            secureSeparator = nil
        }
        guard let title = secureMenuTitle(holderName: tracker.info?.holder.name) else { return }
        let item = NSMenuItem(title: title, action: #selector(showSecureInputWindow), keyEquivalent: "")
        item.target = self
        let separator = NSMenuItem.separator()
        menu.insertItem(item, at: 0)
        menu.insertItem(separator, at: 1)
        secureItem = item
        secureSeparator = separator
    }

    @objc private func showSecureInputWindow() {
        secureWindow.show(anchor: statusItem.button)
    }

    @objc private func openSettings() {
        showConfiguration()
    }

    func showConfiguration() { appWindow.show(configuration: true) }
    @objc func showDoctor() { appWindow.show(configuration: false) }
    func showWindow() { appWindow.show() }
    @objc private func saveConfiguration() { appWindow.saveConfiguration() }
    var hasUnsavedConfiguration: Bool { appWindow.hasUnsavedChanges }
    func confirmDiscard(_ reply: @escaping (Bool) -> Void) { appWindow.confirmDiscard(reply) }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
