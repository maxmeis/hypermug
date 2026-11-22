import AppKit
import SwiftUI
import HyperMugCore

private enum AppPage: String, CaseIterable, Identifiable {
    case overview = "Overview", configuration = "Configuration", permissions = "Permissions", conflicts = "Conflicts", activity = "Activity"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .configuration: return "curlybraces"
        case .permissions: return "hand.raised"
        case .conflicts: return "arrow.triangle.branch"
        case .activity: return "waveform.path"
        }
    }
}

@MainActor
private final class AppWindowModel: ObservableObject {
    @Published var page: AppPage? = .overview
    let editor: ConfigurationEditorModel
    @Published var permissions: [DoctorCheck] = []
    @Published var conflicts: [DoctorCheck] = []
    @Published var overview: [DoctorCheck] = []
    @Published var summary = DoctorCheck("Checking…", "", .unknown)
    @Published var logs = ""
    @Published var config = AppConfig()
    @Published var updated = Date()
    private let store: ConfigStore
    private let capture: TrackpadCapture

    init(store: ConfigStore, capture: TrackpadCapture) {
        self.store = store
        self.capture = capture
        editor = ConfigurationEditorModel(store: store)
    }

    func refresh() {
        config = store.config
        editor.refreshFromDisk()
        permissions = doctorPermissionChecks(accessibility: accessibilityTrusted(),
            inputMonitoring: inputMonitoringAccess() == .granted)
        conflicts = doctorConflictChecks(preferences: DoctorReader.preferences(),
            runningApps: DoctorReader.runningApps(), secureInputHolder: SecureInputReader.current()?.holder.name)
        overview = [doctorConfigCheck(error: store.error?.reason, unknownKeys: store.unknownKeys, notice: store.notice),
            doctorCaptureCheck(hasMappings: config.trackpad.hasMappings, enabled: capture.isEnabled,
                devices: capture.deviceCount, error: capture.captureError)]
        summary = doctorSummary(permissions + overview + conflicts)
        logs = DebugLog.recentText()
        updated = Date()
    }

    func perform(_ action: DoctorAction) {
        switch action {
        case .none: break
        case .accessibility: PrivilegeActions.requestAccessibility()
        case .inputMonitoring: PrivilegeActions.requestInputMonitoring()
        case .trackpad:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!)
        case .pointer:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Mouse")!)
        case .config:
            if !editor.draft.isLoaded { editor.reload() }
            page = .configuration
        }
    }

    func copyReport() {
        refresh()
        let checks = permissions + overview + conflicts
        let report = ["HyperMug Diagnostics", "Checked: \(updated.formatted())", summary.title,
            checks.map { "\($0.title): \($0.state.rawValue)\n\($0.detail)" }.joined(separator: "\n\n"),
            "Recent activity\n\(logs)"].joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

@MainActor
final class HyperMugWindowController: NSObject, NSWindowDelegate {
    private let model: AppWindowModel
    private var window: NSWindow?
    private var timer: Timer?
    private var confirmingDiscard = false
    var hasUnsavedChanges: Bool { model.editor.draft.isModified }

    init(store: ConfigStore, capture: TrackpadCapture) {
        model = AppWindowModel(store: store, capture: capture)
        super.init()
        model.editor.onChange = { [weak self] in self?.window?.isDocumentEdited = self?.hasUnsavedChanges ?? false }
    }

    func show(configuration: Bool? = nil) {
        if configuration == true { model.perform(.config) }
        else if configuration == false { model.page = .overview }
        DebugLog.write("HyperMug window requested")
        NSApp.setActivationPolicy(.regular)
        let panel = window ?? makeWindow()
        window = panel
        model.refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        RunLoop.main.perform(inModes: [.common]) {
            NSApp.activate(ignoringOtherApps: true)
            panel.deminiaturize(nil)
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            DebugLog.write("HyperMug window visible=\(panel.isVisible) frame=\(panel.frame)")
        }
    }

    func saveConfiguration() {
        show(configuration: true)
        model.editor.save()
    }

    func confirmDiscard(_ completion: @escaping (Bool) -> Void) {
        guard hasUnsavedChanges else { completion(true); return }
        guard !confirmingDiscard else { completion(false); return }
        show(configuration: true)
        guard let window else { completion(false); return }
        confirmingDiscard = true
        let alert = NSAlert()
        alert.messageText = "Discard unsaved configuration changes?"
        alert.informativeText = "Your changes have not been saved to the configuration file."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { completion(false); return }
            self.confirmingDiscard = false
            let discard = response == .alertSecondButtonReturn
            if discard { self.model.editor.discardChanges() }
            completion(discard)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedChanges else { return true }
        // The sheet has already confirmed the discard. Close directly rather than asking
        // performClose to validate again while the ending sheet is still attached.
        confirmDiscard { [weak self] discard in if discard { self?.window?.close() } }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 650),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("hypermug.workspace")
        panel.title = AppIdentity.appName
        panel.subtitle = "Configuration and diagnostics"
        panel.titlebarAppearsTransparent = true
        panel.toolbarStyle = .unified
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 780, height: 540)
        panel.setFrameAutosaveName("HyperMugWorkspace")
        panel.delegate = self
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let hosting = NSHostingController(rootView: HyperMugView(model: model))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: 880, height: 650))
        panel.center()
        return panel
    }
}

private struct HyperMugView: View {
    @ObservedObject var model: AppWindowModel
    @State private var search = ""
    @State private var paused = false
    @State private var pausedLogs = ""
    @State private var copied = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppIdentity.appName).font(.headline)
                        Text(bundleVersion).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(16)
                List(AppPage.allCases, selection: $model.page) { page in
                    Label(page.rawValue, systemImage: page.symbol).tag(page).padding(.vertical, 5)
                }.listStyle(.sidebar)
                Divider()
                Button {
                    model.copyReport()
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy diagnostic checks and recent activity, excluding your configuration draft")
                .padding(16)
            }
            .frame(minWidth: 180, idealWidth: 190, maxWidth: 230, maxHeight: .infinity)
            VStack(spacing: 0) {
                if model.page != .configuration {
                    HStack {
                        Text((model.page ?? .overview).rawValue).font(.title2.bold())
                        Spacer()
                        Button("Edit Configuration", systemImage: "doc.text") { model.perform(.config) }
                    }.padding(20)
                    Divider()
                }
                Group {
                    switch model.page ?? .overview {
                    case .overview: overview
                    case .configuration: ConfigurationEditorView(model: model.editor)
                    case .permissions: permissions
                    case .conflicts: conflicts
                    case .activity: activity
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.page != .configuration {
                    Divider()
                    HStack {
                        Text("Checked \(model.updated.formatted(date: .omitted, time: .standard))")
                        Spacer()
                        Button("Check Again", action: model.refresh).buttonStyle(.link)
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10)
                }
            }.frame(minWidth: 560, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.page) { _, _ in copied = false }
    }

    private var bundleVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Local"
        let channel = info["HyperMugReleaseChannel"] as? String ?? "local"
        return "\(version) · \(channel.capitalized)"
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    stateIcon(model.summary.state).font(.system(size: 30))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.summary.title).font(.title2.bold())
                        Text(model.summary.detail).foregroundStyle(.secondary)
                    }
                }
                GroupBox("Your configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.overview.filter { $0.title == "Configuration" }.enumerated()), id: \.offset) { _, check in
                            checkRow(check)
                        }
                        Divider()
                        LabeledContent("Mouse bindings", value: "\([model.config.mouse.buttons.back, model.config.mouse.buttons.forward, model.config.mouse.buttons.thumb, model.config.mouse.horizontalWheel.left, model.config.mouse.horizontalWheel.right].compactMap { $0 }.count) configured")
                        LabeledContent("Swipe bindings", value: "\([3, 4].flatMap { fingers in SwipeDirection.allCases.compactMap { model.config.trackpad.action(fingers: fingers, direction: $0) } }.count) configured")
                        LabeledContent("Shell deadline", value: "\(model.config.shellTimeoutSeconds.formatted()) seconds")
                        Text("Edit the TOML file in Configuration. Save applies validated settings; the menu’s Stay Awake checkbox controls only this session.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(10)
                }
                GroupBox("Input and permissions") {
                    VStack(spacing: 0) {
                        ForEach(Array((model.permissions + model.overview.filter { $0.title != "Configuration" }).enumerated()), id: \.offset) { index, check in
                            if index > 0 { Divider() }
                            checkRow(check)
                        }
                    }
                }
                HStack {
                    Button("Review Conflicts", systemImage: "arrow.triangle.branch") { model.page = .conflicts }
                    Button("View Activity", systemImage: "waveform.path") { model.page = .activity }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissions: some View {
        Form {
            Section {
                ForEach(Array(model.permissions.enumerated()), id: \.offset) { _, check in checkRow(check) }
            } header: { Text("Required permissions") }
            Section {
                Text("macOS controls these permissions. HyperMug cannot grant them automatically.")
                Text("After changing Input Monitoring, restart HyperMug to apply the change.")
                    .foregroundStyle(.secondary)
                Button("Restart \(AppIdentity.appName)", action: PrivilegeActions.relaunch)
            } header: { Text("Apply permission changes") }
        }.formStyle(.grouped)
    }

    private var conflicts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Check for overlapping controls").font(.title2.bold())
                Text("macOS gestures and other input apps can handle the same action. These checks do not change your settings.")
                    .foregroundStyle(.secondary)
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(Array(model.conflicts.enumerated()), id: \.offset) { index, check in
                            if index > 0 { Divider() }
                            checkRow(check)
                        }
                    }
                }
                Text("A saved setting does not prove that a gesture is active. Check Mission Control, App Exposé, and full-screen app swipes in Trackpad settings. Check three-finger dragging in Pointer settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Test a swipe").font(.title2.bold())
            Text("Look for a recognized swipe and a shell action ID. Failures report an exit status or deadline; successful commands stay quiet.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Filter activity", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter activity")
                Toggle("Pause", isOn: $paused).toggleStyle(.button)
                    .onChange(of: paused) { _, value in if value { pausedLogs = model.logs } }
                Menu("Logs") {
                    Button("Open Current Log") { NSWorkspace.shared.open(DebugLog.fileURL) }
                    Button("Show Log Folder") { NSWorkspace.shared.activateFileViewerSelecting([DebugLog.fileURL]) }
                }
            }
            ScrollView([.vertical, .horizontal]) {
                Text(filteredLogs)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            Text("Recent activity updates automatically. Typed keys and command contents are not recorded here.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }

    private var filteredLogs: String {
        let lines = (paused ? pausedLogs : model.logs).split(separator: "\n")
            .filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        return lines.isEmpty ? "No matching activity." : lines.joined(separator: "\n")
    }

    private func checkRow(_ check: DoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stateIcon(check.state).font(.title3).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title).font(.headline)
                Text(check.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if check.action != .none {
                Button(actionTitle(check.action)) { model.perform(check.action) }
                    .controlSize(.small)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionTitle(_ action: DoctorAction) -> String {
        switch action {
        case .config: return "Edit Configuration"
        case .accessibility: return "Allow Accessibility"
        case .inputMonitoring: return "Allow Input Monitoring"
        case .trackpad: return "Trackpad Settings"
        case .pointer: return "Pointer Settings"
        case .none: return ""
        }
    }

    @ViewBuilder private func stateIcon(_ state: DoctorState) -> some View {
        switch state {
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .blocked: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        case .inactive: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
