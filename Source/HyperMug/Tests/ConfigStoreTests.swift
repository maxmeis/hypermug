import Foundation
@testable import HyperMugCore

private final class FakeToken: Cancellable {
    var cancelled = false
    func cancel() { cancelled = true }
}

/// A store over a temp dir with a fake scheduler and fake file watchers, recording everything it reports.
private final class Harness {
    struct Scheduled {
        let delay: TimeInterval
        let work: () -> Void
        let token: FakeToken
        var ran = false
    }
    struct Watch {
        let path: String
        let onEvent: (Bool) -> Void
        let token: FakeToken
    }

    let root = makeTempDir()
    let configDir: URL
    let url: URL
    var logs: [(level: LogLevel, message: String)] = []
    var scheduled: [Scheduled] = []
    var watches: [Watch] = []
    var watchReturnsNil = false
    var onLog: ((LogLevel, String) -> Void)?
    var changes: [AppConfig] = []
    var errors: [ConfigError] = []
    private(set) var store: ConfigStore!
    var beforeRead: ((URL) -> Void)?
    var failWrite = false

    var notices: [ConfigNotice] = []

    init(configURL: URL? = nil, schemaURL: URL? = nil, customIO: Bool = false, legacyURL: URL? = nil) {
        configDir = root.appendingPathComponent("cfg")
        url = configURL ?? configDir.appendingPathComponent("hypermug.toml")
        var env = ConfigStoreEnvironment(
            schemaURL: schemaURL,
            log: { [unowned self] level, message in
                logs.append((level, message))
                onLog?(level, message)
            },
            schedule: { [unowned self] delay, work in
                let token = FakeToken()
                scheduled.append(Scheduled(delay: delay, work: work, token: token))
                return token
            },
            watch: { [unowned self] path, onEvent in
                if watchReturnsNil { return nil }
                let token = FakeToken()
                watches.append(Watch(path: path, onEvent: onEvent, token: token))
                return token
            })
        if customIO {
            env.readData = { [unowned self] url in
                beforeRead?(url)
                return try Data(contentsOf: url)
            }
            env.writeData = { [unowned self] data, url in
                if failWrite { throw NSError(domain: "FixtureWrite", code: 1) }
                try data.write(to: url, options: .atomic)
            }
        }
        store = ConfigStore(url: url, legacyURL: legacyURL, environment: env)
        store.onNotice = { [unowned self] in notices.append($0) }
        store.onChange = { [unowned self] in changes.append($0) }
        store.onError = { [unowned self] in errors.append($0) }
    }

    func prepareDir() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// In-place write (same inode), like an editor saving without rename.
    func put(_ text: String) {
        prepareDir()
        try? Data(text.utf8).write(to: url)
    }

    var fileText: String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    /// Runs every scheduled reload that is neither cancelled nor already run.
    func runScheduled() {
        for index in scheduled.indices where !scheduled[index].token.cancelled && !scheduled[index].ran {
            scheduled[index].ran = true
            scheduled[index].work()
        }
    }

    var pending: [Scheduled] { scheduled.filter { !$0.token.cancelled && !$0.ran } }

    func watch(_ path: String) -> [Watch] { watches.filter { $0.path == path } }
    var dirWatches: [Watch] { watch(url.deletingLastPathComponent().path) }
    var fileWatches: [Watch] { watch(url.path) }

    func logged(_ level: LogLevel, containing part: String) -> Int {
        logs.filter { $0.level == level && $0.message.contains(part) }.count
    }

    /// Edit, notify via the file watch, let the debounce fire.
    func externalEdit(_ text: String) {
        put(text)
        fileWatches.last?.onEvent(false)
        runScheduled()
    }
}

private let hyperTOML = "capsLock = \"hyper\"\n"
private let hyperConfig = AppConfig(capsLock: .hyper)

func configStoreTests() {
    startTests()
    createIfAbsentTests()
    reloadTests()
    invalidFileTests()
    blankFileTests()
    pollFallbackTests()
    watcherLifecycleTests()
    bundledSchemaStoreTests()
    schemaMigrationRaceTests()
    documentSaveTests()
    tomlStoreTests()
    legacyFileTests()
    retiredWheelPlaceholderTests()
}

private func retiredWheelPlaceholderTests() {
    let h = Harness()
    // Every default file written by the previous release contained these empty vertical-wheel slots.
    let old = """
    capsLock = "hyper"
    [mouse.buttons]
    back.shell = "echo back"
    [mouse.verticalWheel]
    down = {}
    up = {}
    [trackpad.threeFingerSwipe]
    left.shell = "echo workspace"
    """
    h.put(old)
    h.store.start()
    expect(h.errors.isEmpty && h.store.error == nil, "an older generated configuration still loads")
    expectEqual(h.store.config.capsLock, .hyper)
    expectEqual(h.store.config.mouse.buttons.back, .shell("echo back"))
    expectEqual(h.store.config.trackpad.threeFingerSwipe.left, .shell("echo workspace"))
    expect(h.store.config.mouse.horizontalWheel.isEmpty, "old empty slots never enable horizontal actions")
    expectEqual(h.fileText, old, "loading preserves the original document")
    expectEqual(try? h.store.validateDocument(Data(old.utf8)).get().config, h.store.config,
                "the editor accepts the same compatibility form")
    h.externalEdit(old.replacingOccurrences(of: "up = {}", with: "up.shell = \"echo retired\""))
    expect(h.store.error?.reason.contains("no longer supported") == true, "configured vertical actions need repair")
    expectEqual(h.store.config.mouse.buttons.back, .shell("echo back"), "an invalid edit keeps the last good mappings")
}

// MARK: - start

private func startTests() {
    // No file: directory, schema and the default config are created; one onChange; both watches armed.
    do {
        let h = Harness()
        h.store.start()
        expectEqual(h.fileText, String(decoding: encodeConfigTOML(.newFileDefaults, includeEmptyKeys: true), as: UTF8.self), "default config written")
        expect(!FileManager.default.fileExists(atPath: h.configDir.appendingPathComponent(AppIdentity.schemaFileName).path),
               "no schema is written beside the config")
        expectEqual(h.changes, [.newFileDefaults], "onChange runs exactly once")
        expectEqual(h.store.config, .newFileDefaults, "config is the new-file default")
        expect(h.store.error == nil && h.errors.isEmpty, "no error")
        expectEqual(h.dirWatches.count, 1, "directory watch armed")
        expectEqual(h.fileWatches.count, 1, "file watch armed")
        expect(h.pending.isEmpty, "no reload scheduled by start")
        expectEqual(h.logged(.error, containing: ""), 0, "no errors logged")
    }

    // Valid file: adopted, byte-identical afterwards (no rewrite), one onChange with the loaded config.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.start()
        expectEqual(h.store.config, hyperConfig, "valid file adopted")
        expectEqual(h.changes, [hyperConfig], "onChange once with the loaded config")
        expectEqual(h.fileText, hyperTOML, "file not rewritten")
    }

    // Invalid file: error set, alert once, file untouched, defaults stay active, onChange still reports them once.
    do {
        let h = Harness()
        h.put("a =")
        h.store.start()
        expectEqual(h.fileText, "a =", "invalid file untouched")
        expectEqual(h.errors.count, 1, "one alert")
        expect(h.errors.first?.reason.hasPrefix("invalid TOML") ?? false, "alert reason is the decode error")
        expectEqual(h.store.error, h.errors.first, "store.error equals the alerted error")
        expectEqual(h.store.config, AppConfig(), "defaults are active")
        expectEqual(h.changes, [AppConfig()], "onChange once")
        expectEqual(h.logged(.error, containing: "invalid config"), 1, "the error is logged")
    }

    // start twice is a no-op.
    do {
        let h = Harness()
        h.store.start()
        let watchCount = h.watches.count
        h.store.start()
        expectEqual(h.changes.count, 1, "second start does not emit again")
        expectEqual(h.watches.count, watchCount, "second start does not re-arm")
    }

    // The config directory cannot be created (its parent is a regular file): logged, start still completes.
    do {
        let h = Harness(configURL: makeTempDir().appendingPathComponent("plain").appendingPathComponent("sub").appendingPathComponent("c.toml"))
        try? Data("x".utf8).write(to: h.url.deletingLastPathComponent().deletingLastPathComponent())
        h.store.start()
        expect(h.logged(.error, containing: "cannot create") == 1, "directory failure logged")
        expectEqual(h.errors.count, 1, "unreadable config path is reported without a sidecar write")
        expectEqual(h.changes, [AppConfig()], "start still reports the defaults")
    }

    // The path is a directory: unreadable, reported as an error, alerted once.
    do {
        let h = Harness()
        h.prepareDir()
        try? FileManager.default.createDirectory(at: h.url, withIntermediateDirectories: true)
        h.store.start()
        expect(h.store.error?.reason.hasPrefix("cannot read") ?? false, "unreadable path reports cannot read")
        expectEqual(h.errors.count, 1, "alerted once")
        expectEqual(h.changes, [AppConfig()], "defaults stay active")
        // Same reason again: no second alert.
        h.fileWatches.last?.onEvent(false)
        h.runScheduled()
        expectEqual(h.errors.count, 1, "same reason is not alerted again")
    }
}

// MARK: - createIfAbsent

private func createIfAbsentTests() {
    // Deleted while running: recreated from the in-memory config, and the file is watched again.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.start()
        try? FileManager.default.removeItem(at: h.url)
        h.fileWatches.last?.onEvent(true)   // the watch dies with the file
        h.runScheduled()
        expectEqual(h.store.config, hyperConfig, "config survives the deletion")
        let watchesBefore = h.fileWatches.count
        h.store.createIfAbsent()
        expectEqual(h.fileText, String(decoding: encodeConfigTOML(hyperConfig, includeEmptyKeys: true), as: UTF8.self), "recreated from the in-memory config")
        expectEqual(h.fileWatches.count, watchesBefore + 1, "the recreated file is watched")
        expectEqual(h.changes, [hyperConfig], "recreating does not report a change")
        // Our own write must not look like an external edit.
        let logCount = h.logs.count
        h.fileWatches.last?.onEvent(false)
        h.runScheduled()
        expectEqual(h.logs.count, logCount, "the echo of our own write is a no-op")
        expectEqual(h.changes, [hyperConfig], "still no change reported")
    }

    // An existing file is never touched: valid, invalid, or blank.
    for existing in ["capsLock = \"default\"\n", "a =", "  \n"] {
        let h = Harness()
        h.put(existing)
        h.store.start()
        h.put(existing)   // blank files were initialized by start; restore the exact text
        h.store.createIfAbsent()
        expectEqual(h.fileText, existing, "createIfAbsent leaves \(existing.debugDescription) alone")
    }

    // Config directory removed too: the directory is recreated as well.
    do {
        let h = Harness()
        h.store.start()
        try? FileManager.default.removeItem(at: h.configDir)
        h.store.createIfAbsent()
        expectEqual(h.fileText, String(decoding: encodeConfigTOML(.newFileDefaults, includeEmptyKeys: true), as: UTF8.self), "directory and file recreated")
    }
}

// MARK: - reload

private func reloadTests() {
    // An event schedules a 150 ms reload; a second event cancels the first; running the work reloads.
    do {
        let h = Harness()
        h.store.start()
        h.put(hyperTOML)
        h.fileWatches.last?.onEvent(false)
        expectEqual(h.pending.count, 1, "an event schedules one reload")
        expectEqual(h.pending.first?.delay, 0.15, "150 ms debounce")
        h.dirWatches.last?.onEvent(false)
        expectEqual(h.scheduled.count, 2, "second event schedules again")
        expect(h.scheduled[0].token.cancelled, "the first reload was cancelled")
        expectEqual(h.pending.count, 1, "only one reload is pending")
        h.runScheduled()
        expectEqual(h.store.config, hyperConfig, "the reload applied the edit")
        expectEqual(h.changes, [.newFileDefaults, hyperConfig], "onChange fired with the new config")
        expect(h.pending.isEmpty, "nothing pending afterwards")
        expectEqual(h.logged(.info, containing: "config reloaded"), 1, "reload logged")
    }

    // A rewrite that decodes to the same config does not fire onChange.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.start()
        h.externalEdit("capsLock = \"hyper\"\nunknown = 1\n")
        expectEqual(h.changes, [hyperConfig], "equal config: no onChange")
        expect(h.store.error != nil, "unknown fields are schema errors")
        expectEqual(h.store.config, hyperConfig, "unknown fields cannot replace the last valid config")
        h.externalEdit(hyperTOML)
        expectEqual(h.store.unknownKeys, [])
    }

    // An external edit goes through a delete+recreate (atomic replace): new inode, new watch.
    do {
        let h = Harness()
        h.store.start()
        let firstWatch = h.fileWatches[0]
        let tmp = h.configDir.appendingPathComponent("tmp")
        try? Data(hyperTOML.utf8).write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(h.url, withItemAt: tmp)
        h.dirWatches.last?.onEvent(false)
        h.runScheduled()
        expectEqual(h.store.config, hyperConfig, "atomic replace applied")
        expect(firstWatch.token.cancelled, "the watch on the replaced file was dropped")
        expectEqual(h.fileWatches.count, 2, "the new file is watched")
        expect(!h.fileWatches[1].token.cancelled, "new watch is live")
    }

    // Absent during reload: config kept, error cleared, no alert.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.start()
        h.externalEdit("a =")
        expect(h.store.error != nil, "precondition: invalid")
        try? FileManager.default.removeItem(at: h.url)
        h.dirWatches.last?.onEvent(false)
        h.runScheduled()
        expectEqual(h.store.config, hyperConfig, "last good config kept")
        expect(h.store.error == nil, "absent file is not an error")
        expectEqual(h.logged(.info, containing: "config file absent"), 1, "absence logged")
        expectEqual(h.errors.count, 1, "no new alert")
        expectEqual(h.fileWatches.last?.token.cancelled, true, "file watch dropped with the file")
        expectEqual(h.fileWatches.count, 1, "no watch for a missing file")
    }
}

// MARK: - invalid files

private func invalidFileTests() {
    let h = Harness()
    h.put(hyperTOML)
    h.store.start()
    let changesAfterStart = h.changes

    // First invalid edit: alert once; last good config stays; file never rewritten.
    h.externalEdit("a =")
    expectEqual(h.errors.count, 1, "invalid edit alerts once")
    expectEqual(h.store.config, hyperConfig, "last good config stays active")
    expectEqual(h.fileText, "a =", "invalid file untouched")
    expectEqual(h.changes, changesAfterStart, "no change reported")

    // Same bytes again (a touch): no reload work at all.
    let logCount = h.logs.count
    h.externalEdit("a =")
    expectEqual(h.logs.count, logCount, "identical bytes are ignored")

    // Different bytes, same reason: logged again, but not alerted again.
    h.externalEdit("a =\n")
    expectEqual(h.errors.count, 1, "the same reason is not alerted twice")
    expectEqual(h.logged(.error, containing: "invalid config"), 1, "duplicate reasons do not flood the log")
    expectEqual(h.fileText, "a =\n", "still untouched")

    // A different reason alerts again.
    h.externalEdit("capsLock = 1\n")
    expectEqual(h.errors.map { $0.reason }.last, "capsLock: expected string", "new reason shown")
    expectEqual(h.errors.count, 2, "a different reason alerts")
    expectEqual(h.store.error, h.errors.last, "store.error tracks the latest reason")

    // A valid load clears the error and the memory of the last alert: the same bad content alerts again.
    h.externalEdit("capsLock = \"default\"\n")
    expect(h.store.error == nil, "valid load clears the error")
    expectEqual(h.store.config, AppConfig(capsLock: .default), "valid edit applied")
    h.externalEdit("capsLock = 1\n")
    expectEqual(h.errors.count, 3, "same bad content alerts again after a valid load")
    expectEqual(h.fileText, "capsLock = 1\n", "file never written while invalid")
    expectEqual(h.store.config, AppConfig(capsLock: .default), "config is still the last good one")

    // A semantic error inside an otherwise valid document.
    h.externalEdit("capsLock = \"upper\"\n")
    expect(h.store.error?.reason.hasPrefix("capsLock") ?? false, "validation errors are reported")
    expectEqual(h.errors.count, 4, "alerted")
}

// MARK: - blank files

private func blankFileTests() {
    // Blank at start: defaults are written and adopted.
    do {
        let h = Harness()
        h.put("")
        h.store.start()
        expectEqual(h.fileText, String(decoding: encodeConfigTOML(.newFileDefaults, includeEmptyKeys: true), as: UTF8.self), "blank file initialized")
        expectEqual(h.store.config, .newFileDefaults, "defaults adopted")
        expectEqual(h.changes, [.newFileDefaults], "one onChange")
        expect(h.errors.isEmpty && h.store.error == nil, "blank is not an error")
    }

    // Blank while running: initialized, and the change to defaults is reported.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.start()
        h.externalEdit(" \n")
        expectEqual(h.fileText, String(decoding: encodeConfigTOML(.newFileDefaults, includeEmptyKeys: true), as: UTF8.self), "truncated file initialized")
        expectEqual(h.changes, [hyperConfig, .newFileDefaults], "defaults reported")
        // Our own initialization does not loop.
        h.fileWatches.last?.onEvent(false)
        let count = h.logs.count
        h.runScheduled()
        expectEqual(h.logs.count, count, "the echo of the initialization is a no-op")
    }

    // An editor truncates, then finishes its save before the guarded write: the new content wins and nothing is written.
    do {
        let h = Harness()
        h.put("launchAtLogin = true\n")
        h.store.start()
        h.onLog = { [unowned h] _, message in
            if message.contains("is empty") { h.put(hyperTOML) }
        }
        h.externalEdit("")
        h.onLog = nil
        expectEqual(h.fileText, hyperTOML, "the editor's content was not overwritten")
        expectEqual(h.store.config, hyperConfig, "the editor's content was loaded")
        expectEqual(h.changes.last, hyperConfig, "and reported")
    }

    // The file vanishes between the two reads: treated as absent, nothing written.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.start()
        h.onLog = { [unowned h] _, message in
            if message.contains("is empty") { try? FileManager.default.removeItem(at: h.url) }
        }
        h.externalEdit("")
        h.onLog = nil
        expectEqual(h.fileText, nil, "nothing was written")
        expectEqual(h.store.config, hyperConfig, "config kept")
    }

    // The write fails (read-only directory): logged once, not retried on every reload.
    do {
        let h = Harness()
        h.put("")
        let dir = h.configDir
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        h.store.start()
        expectEqual(h.logged(.error, containing: "hypermug.toml"), 1, "write failure logged")
        expectEqual(h.store.config, .newFileDefaults, "defaults still adopted")
        expect(h.store.error == nil, "a failed initialization is not a config error")
        h.fileWatches.last?.onEvent(false)
        h.runScheduled()
        expectEqual(h.logged(.error, containing: "hypermug.toml"), 1, "the failing write is not retried on the next reload")
        expectEqual(h.fileText, "", "file still empty")
    }

    // A symlinked config is written through; the symlink survives, and edits to the target are noticed.
    do {
        let h = Harness()
        h.prepareDir()
        let target = h.root.appendingPathComponent("dotfiles").appendingPathComponent("real.toml")
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: target)
        try? FileManager.default.createSymbolicLink(at: h.url, withDestinationURL: target)
        h.store.start()
        expectEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: h.url.path), target.path, "still a symlink")
        expectEqual(try? Data(contentsOf: target), encodeConfigTOML(.newFileDefaults, includeEmptyKeys: true), "written through to the target")
        try? Data("capsLock = \"hyper\"\nlaunchAtLogin = false\n".utf8).write(to: target)
        h.store.pollFallback()
        expectEqual(h.store.config, hyperConfig, "an edit of the symlink target is noticed by the poll")
    }
}

// MARK: - pollFallback

private func pollFallbackTests() {
    // Before start: nothing happens.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.pollFallback()
        expect(h.changes.isEmpty && h.watches.isEmpty && h.logs.isEmpty, "poll before start does nothing")
    }

    // A changed file is reloaded.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.start()
        h.put("capsLock = \"default\"\nlaunchAtLogin = true\n")   // no watcher event delivered
        h.store.pollFallback()
        expectEqual(h.store.config, AppConfig(capsLock: .default, launchAtLogin: true), "poll picked up the edit")
        expectEqual(h.changes.count, 2, "reported once")
    }

    // An unchanged stamp (inode, mtime, size) does not reload, even if the content differs: stat is the gate.
    do {
        let h = Harness()
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)   // whole microseconds: setAttributes cannot store more
        func pinMtime(_ h: Harness) {
            try? FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: h.url.path)
        }
        h.put("capsLock = \"meh\"  ")
        pinMtime(h)
        h.store.start()
        h.put("capsLock = \"hyper\"")   // same size, same inode
        pinMtime(h)
        h.store.pollFallback()
        expectEqual(h.store.config, AppConfig(capsLock: .meh), "no reload when the stamp is unchanged")
        expectEqual(h.changes.count, 1, "no change reported")
    }

    // An absent file stays quiet on every poll.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.start()
        try? FileManager.default.removeItem(at: h.url)
        h.store.pollFallback()
        let logs = h.logs.count
        h.store.pollFallback()
        expectEqual(h.logs.count, logs, "a missing file is reloaded once, not on every poll")
        expectEqual(h.store.config, hyperConfig, "config kept")
    }

    // Directory removed and recreated: the watch is re-armed.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.start()
        h.store.pollFallback()
        expectEqual(h.dirWatches.count, 1, "an unchanged directory keeps its watch")
        let first = h.dirWatches[0]
        try? FileManager.default.removeItem(at: h.configDir)
        h.prepareDir()
        h.store.pollFallback()
        expect(first.token.cancelled, "the stale directory watch is dropped")
        expectEqual(h.dirWatches.count, 2, "a new directory watch is armed")
        expect(!h.dirWatches[1].token.cancelled, "and it is live")
    }
}

// MARK: - watcher lifecycle

private func watcherLifecycleTests() {
    // A "gone" directory event drops the watch; the next poll re-arms it.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.start()
        h.dirWatches[0].onEvent(true)
        expect(h.dirWatches[0].token.cancelled, "gone cancels the directory watch")
        expectEqual(h.pending.count, 1, "and still schedules a reload")
        h.store.pollFallback()
        expectEqual(h.dirWatches.count, 2, "the poll re-armed it")
        expect(!h.dirWatches[1].token.cancelled, "live")
    }

    // A "gone" file event drops the watch; the reload that follows re-arms it for the file that is there now.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.start()
        h.fileWatches[0].onEvent(true)
        expect(h.fileWatches[0].token.cancelled, "gone cancels the file watch")
        h.runScheduled()
        expectEqual(h.fileWatches.count, 2, "re-armed by the reload")
        expect(!h.fileWatches[1].token.cancelled, "live")
        // A non-gone event keeps the watch.
        h.fileWatches[1].onEvent(false)
        expect(!h.fileWatches[1].token.cancelled, "ordinary events keep the watch")
    }

    // The poll re-arms a file watch that died without a reload following.
    do {
        let h = Harness()
        h.put(hyperTOML)
        h.store.start()
        h.fileWatches[0].onEvent(true)
        h.store.pollFallback()
        expectEqual(h.fileWatches.count, 2, "poll re-armed the file watch")
    }

    // A watcher that cannot be created: logged, no crash, retried on the next poll.
    do {
        let h = Harness()
        h.watchReturnsNil = true
        h.put(hyperTOML)
        h.store.start()
        expectEqual(h.logged(.error, containing: "cannot watch"), 1, "directory watch failure logged")
        expectEqual(h.store.config, hyperConfig, "the store still works")
        h.watchReturnsNil = false
        h.store.pollFallback()
        expectEqual(h.dirWatches.count, 1, "directory watch armed on the next poll")
        expectEqual(h.fileWatches.count, 1, "file watch armed on the next poll")
        let armed = h.watches.count
        h.store.pollFallback()
        expectEqual(h.watches.count, armed, "nothing more to arm")
    }

    // Starting without a file: the file watch appears once the file does.
    do {
        let h = Harness()
        h.store.start()
        try? FileManager.default.removeItem(at: h.url)
        h.fileWatches[0].onEvent(true)
        h.runScheduled()
        expect(h.fileWatches[0].token.cancelled, "watch of a deleted file is dropped")
        expectEqual(h.fileWatches.count, 1, "no watch while the file is missing")
        h.put(hyperTOML)
        h.dirWatches[0].onEvent(false)
        h.runScheduled()
        expectEqual(h.store.config, hyperConfig, "the file is picked up when it comes back")
        expectEqual(h.fileWatches.count, 2, "and watched again")
    }
}

private func bundledSchemaStoreTests() {
    let schema = URL(fileURLWithPath: "/Applications/HyperMug.app/Contents/Resources/hypermug.schema.json")
    do {
        let h = Harness(schemaURL: schema)
        h.store.start()
        expectEqual(try? parseConfigTOML(Data(h.fileText!.utf8)).get()["$schema"], .string(schema.absoluteString),
                    "new config references bundled schema")
        expectEqual(h.store.config, .newFileDefaults)
    }
    do {
        let h = Harness(schemaURL: schema)
        h.put("\"$schema\" = \"./hypermug.schema.json\"\ncapsLock = \"hyper\"\n")
        h.store.start()
        expectEqual(h.store.config, hyperConfig, "migration preserves settings")
        expect(h.fileText!.contains(schema.absoluteString), "legacy sidecar link migrated")
        let stable = h.fileText
        h.store.pollFallback()
        expectEqual(h.fileText, stable, "poll is byte-idempotent")
        expect(h.errors.isEmpty, "migration is not an error")
    }
    do {
        let h = Harness(schemaURL: schema)
        h.put("a =")
        h.store.start()
        expectEqual(h.fileText, "a =", "invalid TOML is never rewritten")
        expectEqual(h.errors.count, 1)
    }
    do {
        let h = Harness(schemaURL: schema)
        h.put("capsLock = \"hyper\"\nfuture.keep = 1\n")
        h.store.start()
        expect(h.store.error != nil, "unknown fields cause native config error")
        expect(h.fileText!.contains("future"), "migration does not delete unsupported settings")
        expectEqual(h.store.config, AppConfig(), "failed validation keeps last valid settings")
    }
}

private func schemaMigrationRaceTests() {
    let schema = URL(fileURLWithPath: "/Applications/HyperMug.app/Contents/Resources/hypermug.schema.json")
    do {
        let h = Harness(schemaURL: schema, customIO: true)
        h.put("capsLock = \"meh\"\n")
        var reads = 0
        h.beforeRead = { _ in
            reads += 1
            if reads == 3 { h.put(hyperTOML) }
        }
        h.store.start()
        h.runScheduled()
        expectEqual(h.store.config, hyperConfig, "a concurrent editor save wins schema migration")
        expect(h.fileText!.contains("hyper"), "old settings never overwrite the concurrent edit")
    }
    do {
        let h = Harness(schemaURL: schema, customIO: true)
        h.put(hyperTOML)
        h.failWrite = true
        h.store.start()
        expectEqual(h.fileText, hyperTOML, "failed schema migration leaves bytes intact")
        expect(h.store.error?.reason.contains("bundled schema reference") == true, "metadata write failure is actionable")
        expectEqual(h.errors.count, 1)
        expectEqual(h.store.config, AppConfig(), "write failure retains previous valid config")
        h.failWrite = false
        h.externalEdit(hyperTOML + "\n")
        expectEqual(h.store.config, hyperConfig)
        expect(h.store.error == nil, "repair recovers normally")
    }
    do {
        let h = Harness(schemaURL: schema)
        h.prepareDir()
        let target = h.root.appendingPathComponent("dotfiles.toml")
        try! Data(hyperTOML.utf8).write(to: target)
        try! FileManager.default.createSymbolicLink(at: h.url, withDestinationURL: target)
        h.store.start()
        expectEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: h.url.path), target.path, "schema migration preserves dotfiles symlink")
        expectEqual(h.store.config, hyperConfig)
        expect((try? String(contentsOf: target, encoding: .utf8))?.contains(schema.absoluteString) == true)
    }
}


private func documentSaveTests() {
    do {
        let h = Harness(customIO: true)
        h.put(hyperTOML)
        h.store.start()
        let before = try! h.store.readDocument()
        let edit = Data("capsLock = \"default\"\n".utf8)
        try! h.store.saveDocument(edit, replacing: before)
        expectEqual(h.store.config.capsLock, .default, "the editor saves through the running store")
        expectEqual(try! h.store.readDocument(), edit, "raw formatting survives without schema migration")
        expectEqual(h.changes.count, 2, "save applies once")
        for invalid in ["", "a =", "capsLock = \"typo\"\n"] {
            do { try h.store.saveDocument(Data(invalid.utf8), replacing: edit); expect(false) }
            catch { expectEqual(try! h.store.readDocument(), edit, "invalid drafts never replace disk") }
        }
        h.put(hyperTOML + "\n")
        do { try h.store.saveDocument(edit, replacing: edit); expect(false) }
        catch { expectEqual(h.fileText, hyperTOML + "\n", "external edits win a stale Save") }
        h.failWrite = true
        do { try h.store.saveDocument(edit, replacing: try h.store.readDocument()); expect(false) }
        catch { expectEqual(h.store.config.capsLock, .default, "write failure cannot apply a draft") }
        h.failWrite = false
        try! FileManager.default.removeItem(at: h.url)
        expectEqual(try! h.store.readDocument(), nil)
        try! h.store.saveDocument(edit, replacing: nil)
        expectEqual(try! h.store.readDocument(), edit, "an explicitly absent baseline can be recreated")
    }
    do {
        let schema = URL(fileURLWithPath: "/Applications/HyperMug.app/Contents/Resources/hypermug.schema.json")
        let h = Harness(schemaURL: schema)
        h.prepareDir()
        let target = h.root.appendingPathComponent("editor-dotfiles.toml")
        try! Data(hyperTOML.utf8).write(to: target)
        try! FileManager.default.createSymbolicLink(at: h.url, withDestinationURL: target)
        h.store.start()
        let baseline = try! h.store.readDocument()
        try! h.store.saveDocument(Data("capsLock = \"default\"\n".utf8), replacing: baseline)
        expectEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: h.url.path), target.path)
        let saved = try! parseConfigTOML(Data(contentsOf: target)).get()
        expectEqual(saved["$schema"], .string(schema.absoluteString), "editor writes the real bundle reference")
    }
    do {
        let h = Harness()
        h.put("a =")
        h.store.start()
        try! FileManager.default.removeItem(at: h.url)
        h.store.pollFallback()
        h.externalEdit("a =")
        expectEqual(h.errors.count, 2, "recreating an invalid file reports a new error after absence cleared it")
    }
    do {
        let directory = makeTempDir()
        let h = Harness(configURL: directory)
        do { _ = try h.store.readDocument(); expect(false) }
        catch { expect(true, "unreadable disk cannot be mistaken for an absent file") }
    }
}

// MARK: - TOML documents and the retired JSON file

private let tomlSchema = URL(fileURLWithPath: "/Applications/HyperMug.app/Contents/Resources/hypermug.schema.json")

/// A store with a retired `hypermug.json` slot beside it.
private func legacyHarness() -> (Harness, URL) {
    let root = makeTempDir().appendingPathComponent("cfg")
    let legacy = root.appendingPathComponent("hypermug.json")
    let h = Harness(configURL: root.appendingPathComponent("hypermug.toml"), schemaURL: tomlSchema, legacyURL: legacy)
    h.prepareDir()
    return (h, legacy)
}

private func readText(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

private func tomlStoreTests() {
    // A new TOML file shows every slot, links the schema both ways and loads the defaults.
    do {
        let h = Harness(schemaURL: tomlSchema)
        h.store.start()
        expectEqual(h.fileText, String(decoding: encodeConfigTOML(.newFileDefaults, schemaURL: tomlSchema, includeEmptyKeys: true), as: UTF8.self))
        expect(h.fileText!.hasPrefix("#:schema \(tomlSchema.absoluteString)\n"), "directive for TOML editors")
        expectEqual(h.store.config, .newFileDefaults)
        expect(h.notices.isEmpty && h.store.notice == nil, "no notice without a legacy file")
    }
    // Schema links preserve comments; a later poll does not rewrite.
    do {
        let h = Harness(schemaURL: tomlSchema)
        h.put("# my settings\ncapsLock = \"hyper\" # hold for hyper\n")
        h.store.start()
        expectEqual(h.store.config, hyperConfig)
        expectEqual(h.fileText, "#:schema \(tomlSchema.absoluteString)\n\"$schema\" = \"\(tomlSchema.absoluteString)\"\n# my settings\ncapsLock = \"hyper\" # hold for hyper\n")
        let stable = h.fileText
        h.store.pollFallback()
        expectEqual(h.fileText, stable)
    }
    // Invalid TOML is reported with its position and never rewritten.
    do {
        let h = Harness(schemaURL: tomlSchema)
        h.put("capsLock = \"hyper\"\nmouse = {\n")
        h.store.start()
        expectEqual(h.store.error?.reason, "invalid TOML at line 2, column 10: expected a key")
        expectEqual(h.fileText, "capsLock = \"hyper\"\nmouse = {\n")
        h.externalEdit("capsLock = \"other\"\n")
        expectEqual(h.store.error?.reason, "capsLock: unsupported value", "schema errors name the setting")
        h.externalEdit("capsLock = \"hyper\"\n")
        expectEqual(h.store.config, hyperConfig)
        expect(h.store.error == nil)
    }
    // Editor saves keep comments; empty saves get a TOML hint.
    do {
        let h = Harness()
        h.put("capsLock = \"meh\"\n")
        h.store.start()
        let before = try! h.store.readDocument()
        let edit = "# comment kept\ncapsLock = \"hyper\" # inline kept\n"
        try! h.store.saveDocument(Data(edit.utf8), replacing: before)
        expectEqual(h.fileText, edit, "save writes the user's text")
        expectEqual(h.store.config, hyperConfig)
        expectEqual(h.store.validateDocument(Data("  \n".utf8)).failureReason,
                    "Configuration cannot be empty. Use a comment such as # defaults for default settings.")
        expect((try? h.store.validateDocument(Data("# defaults\n".utf8)).get())?.config == AppConfig(), "comment-only means defaults")
        do { try h.store.saveDocument(Data("a =".utf8), replacing: Data(edit.utf8)); expect(false) }
        catch { expectEqual((error as? ConfigError)?.reason, "invalid TOML at line 1, column 4: expected a value") }
    }
    // A blank TOML file is initialized with TOML defaults.
    do {
        let h = Harness()
        h.put("")
        h.store.start()
        expectEqual(h.fileText, String(decoding: encodeConfigTOML(.newFileDefaults, includeEmptyKeys: true), as: UTF8.self))
    }
}

private func legacyFileTests() {
    // Only a legacy JSON file: it is not read, TOML defaults are written and used, and one notice says why.
    do {
        let (h, legacy) = legacyHarness()
        let json = #"{"capsLock":"hyper","launchAtLogin":true}"#
        try! Data(json.utf8).write(to: legacy)
        h.store.start()
        expectEqual(h.fileText, String(decoding: encodeConfigTOML(.newFileDefaults, schemaURL: tomlSchema, includeEmptyKeys: true), as: UTF8.self),
                    "TOML defaults are written")
        expectEqual(h.store.config, .newFileDefaults, "the JSON settings are not applied")
        expect(h.store.error == nil && h.errors.isEmpty, "the JSON file is not a configuration error")
        expectEqual(readText(legacy), json, "the JSON file is left alone")
        let notice = ConfigNotice.legacyUnsupported(legacy: "hypermug.json", active: "hypermug.toml")
        expectEqual(notice.message, "hypermug.json is no longer supported; settings now live in hypermug.toml.")
        expectEqual(h.store.notice, notice)
        expectEqual(h.notices, [notice], "one notice")
        expectEqual(h.logged(.info, containing: "hypermug.json is no longer supported"), 1)
        // Later reloads keep the notice without repeating it.
        h.externalEdit(hyperTOML)
        h.store.pollFallback()
        expectEqual(h.store.config, hyperConfig)
        expectEqual(h.notices, [notice], "not repeated")
        expectEqual(h.store.notice, notice, "still reported while the file exists")
        // Removing the JSON file clears the notice.
        try! FileManager.default.removeItem(at: legacy)
        h.externalEdit("capsLock = \"meh\"\n")
        expect(h.store.notice == nil, "the notice clears")
        expectEqual(h.notices, [notice])
    }
    // Both files: the TOML file is used and the JSON file is still reported.
    do {
        let (h, legacy) = legacyHarness()
        h.put(hyperTOML)
        try! Data(#"{"capsLock":"default"}"#.utf8).write(to: legacy)
        h.store.start()
        expectEqual(h.store.config, hyperConfig)
        expectEqual(h.store.notice, .legacyUnsupported(legacy: "hypermug.json", active: "hypermug.toml"))
    }
    // No legacy file: no notice.
    do {
        let (h, _) = legacyHarness()
        h.store.start()
        expect(h.store.notice == nil && h.notices.isEmpty)
    }
}

private extension Result where Failure == ConfigError {
    var failureReason: String? {
        if case .failure(let e) = self { return e.reason }
        return nil
    }
}
