import Foundation
import HyperMugCore

@main
struct ConfigurationEditorChecks {
    @MainActor static func main() throws {
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(message)") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hypermug-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.toml")
        var failWrite = false
        let env = ConfigStoreEnvironment(writeData: { data, path in
            if failWrite { throw NSError(domain: "TestWrite", code: 1) }
            try data.write(to: path, options: .atomic)
        }, log: { _,_ in }, schedule: { _,_ in Token() }, watch: { _,_ in nil })
        let store = ConfigStore(url: url, environment: env)
        store.start()
        let model = ConfigurationEditorModel(store: store)
        model.reload()
        check(model.draft.isLoaded && !model.draft.isModified, "the app loads the actual TOML file")
        let initial = try Data(contentsOf: url)
        model.edit("capsLock = ")
        model.save()
        check(model.messageIsError && model.draft.isModified, "invalid TOML stays in the editor for repair")
        check(try Data(contentsOf: url) == initial, "invalid Save cannot overwrite the running configuration")
        model.edit(#"capsLock = "hyper""#)
        model.validate()
        check(!model.messageIsError && store.config.capsLock == .threeMod, "Validate does not apply settings")
        check(model.message?.contains("Valid TOML") == true, "Validate names the document format")
        model.save()
        check(!model.draft.isModified && store.config.capsLock == .hyper, "Save applies through ConfigStore")
        model.edit(#"capsLock = "default""#)
        try Data(#"capsLock = "meh""#.utf8).write(to: url)
        model.refreshFromDisk()
        check(model.draft.hasExternalChanges && model.draft.text.contains("default"), "external edits preserve the draft")
        model.save()
        check(model.messageIsError && model.draft.isModified, "stale Save fails closed")
        check(try String(contentsOf: url, encoding: .utf8) == #"capsLock = "meh""#, "the external file wins")
        model.reload()
        check(!model.draft.isModified && !model.draft.hasExternalChanges, "explicit reload resolves conflict")
        model.edit("# defaults")
        model.discardChanges()
        check(!model.draft.isModified && model.draft.text.contains("meh"), "discard affects only the draft")
        model.edit("# defaults")
        failWrite = true
        model.save()
        check(model.messageIsError && model.draft.isModified, "write failure keeps the unsaved document")
        failWrite = false
        model.reload()
        try Data(#"capsLock = "default""#.utf8).write(to: url)
        model.refreshFromDisk()
        check(model.draft.text.contains("default") && !model.draft.isModified, "a clean editor follows external changes")
        try Data([0xff]).write(to: url)
        model.reload()
        check(model.messageIsError && model.draft.text.contains("default"), "invalid UTF-8 cannot erase the editor")
        try Data("[".utf8).write(to: url)
        model.reload()
        check(model.messageIsError && model.draft.text == "[" && !model.draft.isModified,
              "opening a broken document shows its validation error without rewriting it")
        print("ConfigurationEditor: \(checks) checks, \(failures) failures; temporary file only")
        exit(failures == 0 ? 0 : 1)
    }

    private final class Token: Cancellable { func cancel() {} }
}
