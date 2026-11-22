import Foundation
import CoreGraphics

// MARK: - Model

public enum CapsMode: String, Equatable, CaseIterable {
    case `default`, meh, threeMod, hyper
    public var isModifier: Bool { self != .default }
}

public enum ButtonAction: Equatable {
    case shortcut(Shortcut)
    case shell(String)
    case helper(String)
}

public struct ButtonMap: Equatable {
    public var back: ButtonAction?
    public var forward: ButtonAction?
    public var thumb: ButtonAction?

    public init(back: ButtonAction? = nil, forward: ButtonAction? = nil, thumb: ButtonAction? = nil) {
        self.back = back
        self.forward = forward
        self.thumb = thumb
    }
}

public enum SwipeDirection: String, CaseIterable, Equatable {
    case up, down, left, right
}

public struct SwipeMap: Equatable {
    public var up: ButtonAction?
    public var down: ButtonAction?
    public var left: ButtonAction?
    public var right: ButtonAction?

    public init(up: ButtonAction? = nil, down: ButtonAction? = nil,
                left: ButtonAction? = nil, right: ButtonAction? = nil) {
        self.up = up
        self.down = down
        self.left = left
        self.right = right
    }

    public var isEmpty: Bool { up == nil && down == nil && left == nil && right == nil }

    public func action(for direction: SwipeDirection) -> ButtonAction? {
        switch direction {
        case .up: return up
        case .down: return down
        case .left: return left
        case .right: return right
        }
    }
}

public struct TrackpadConfig: Equatable {
    public var threeFingerSwipe: SwipeMap
    public var fourFingerSwipe: SwipeMap

    public init(threeFingerSwipe: SwipeMap = SwipeMap(), fourFingerSwipe: SwipeMap = SwipeMap()) {
        self.threeFingerSwipe = threeFingerSwipe
        self.fourFingerSwipe = fourFingerSwipe
    }

    public var hasMappings: Bool { !threeFingerSwipe.isEmpty || !fourFingerSwipe.isEmpty }

    public func hasMappings(fingers: Int) -> Bool {
        switch fingers {
        case 3: return !threeFingerSwipe.isEmpty
        case 4: return !fourFingerSwipe.isEmpty
        default: return false
        }
    }

    public func action(fingers: Int, direction: SwipeDirection) -> ButtonAction? {
        switch fingers {
        case 3: return threeFingerSwipe.action(for: direction)
        case 4: return fourFingerSwipe.action(for: direction)
        default: return nil
        }
    }
}

public struct InvertScroll: Equatable {
    public var vertical: Bool
    public var horizontal: Bool

    public init(vertical: Bool = false, horizontal: Bool = false) {
        self.vertical = vertical
        self.horizontal = horizontal
    }
}

public enum WheelDirection: String, CaseIterable, Equatable {
    case left, right
}

/// Actions for physical horizontal wheel steps; an unmapped direction keeps normal scrolling.
public struct WheelMap: Equatable {
    public var left: ButtonAction?
    public var right: ButtonAction?

    public init(left: ButtonAction? = nil, right: ButtonAction? = nil) {
        self.left = left
        self.right = right
    }

    public var isEmpty: Bool { left == nil && right == nil }

    public func action(for direction: WheelDirection) -> ButtonAction? {
        direction == .left ? left : right
    }
}

public struct MouseConfig: Equatable {
    public var invertScroll: InvertScroll
    public var buttons: ButtonMap
    public var horizontalWheel: WheelMap

    public init(invertScroll: InvertScroll = InvertScroll(), buttons: ButtonMap = ButtonMap(),
                horizontalWheel: WheelMap = WheelMap()) {
        self.invertScroll = invertScroll
        self.buttons = buttons
        self.horizontalWheel = horizontalWheel
    }
}

public struct AppConfig: Equatable {
    /// Written only for a new or empty config file. Decoding omitted keys keeps legacy fallbacks.
    public static var newFileDefaults: AppConfig {
        let next = ButtonAction.shell("/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around next")
        let prev = ButtonAction.shell("/opt/homebrew/bin/aerospace workspace --no-stdin --wrap-around prev")
        let swipes = SwipeMap(left: next, right: prev)
        return AppConfig(
            launchAtLogin: !AppIdentity.isDevelopment,
            autoUpdate: !AppIdentity.isDevelopment,
            mouse: MouseConfig(buttons: ButtonMap(back: next, forward: prev)),
            trackpad: TrackpadConfig(threeFingerSwipe: swipes, fourFingerSwipe: swipes)
        )
    }
    public var shellTimeoutSeconds: Double
    public var helpers: [String: String]
    public var capsLock: CapsMode
    public var caffeineOnLaunch: Bool
    public var launchAtLogin: Bool
    public var autoUpdate: Bool
    public var mouse: MouseConfig
    public var trackpad: TrackpadConfig

    public init(capsLock: CapsMode = .threeMod, caffeineOnLaunch: Bool = true, launchAtLogin: Bool = false,
                autoUpdate: Bool = true,
                mouse: MouseConfig = MouseConfig(), trackpad: TrackpadConfig = TrackpadConfig(),
                helpers: [String: String] = [:], shellTimeoutSeconds: Double = 10) {
        self.helpers = helpers
        self.shellTimeoutSeconds = shellTimeoutSeconds
        self.capsLock = capsLock
        self.caffeineOnLaunch = caffeineOnLaunch
        self.launchAtLogin = launchAtLogin
        self.autoUpdate = autoUpdate
        self.mouse = mouse
        self.trackpad = trackpad
    }

    /// A validated config's effective actions for the input engine. The source model retains references.
    public func resolvedActions() -> AppConfig {
        var result = self
        func resolve(_ action: ButtonAction?) -> ButtonAction? {
            if case .helper(let name)? = action { return helpers[name].map(ButtonAction.shell) }
            return action
        }
        result.mouse.buttons.back = resolve(mouse.buttons.back)
        result.mouse.buttons.forward = resolve(mouse.buttons.forward)
        result.mouse.buttons.thumb = resolve(mouse.buttons.thumb)
        result.mouse.horizontalWheel.left = resolve(mouse.horizontalWheel.left)
        result.mouse.horizontalWheel.right = resolve(mouse.horizontalWheel.right)
        for direction in SwipeDirection.allCases {
            switch direction {
            case .up:
                result.trackpad.threeFingerSwipe.up = resolve(trackpad.threeFingerSwipe.up)
                result.trackpad.fourFingerSwipe.up = resolve(trackpad.fourFingerSwipe.up)
            case .down:
                result.trackpad.threeFingerSwipe.down = resolve(trackpad.threeFingerSwipe.down)
                result.trackpad.fourFingerSwipe.down = resolve(trackpad.fourFingerSwipe.down)
            case .left:
                result.trackpad.threeFingerSwipe.left = resolve(trackpad.threeFingerSwipe.left)
                result.trackpad.fourFingerSwipe.left = resolve(trackpad.fourFingerSwipe.left)
            case .right:
                result.trackpad.threeFingerSwipe.right = resolve(trackpad.threeFingerSwipe.right)
                result.trackpad.fourFingerSwipe.right = resolve(trackpad.fourFingerSwipe.right)
            }
        }
        return result
    }
}

/// `reason` is short and alert-ready, e.g. "mouse.buttons.thumb: needs exactly one of shortcut/shell".
public struct ConfigError: Error, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// A config that decoded, plus the keys it contained that HyperMug does not know (dotted paths).
/// Low-level decoding collects unknown keys; the store rejects them during schema validation.
public struct DecodedConfig: Equatable {
    public let config: AppConfig
    public let unknownKeys: [String]

    public init(config: AppConfig, unknownKeys: [String]) {
        self.config = config
        self.unknownKeys = unknownKeys
    }
}

// MARK: - Decoding

/// Key type for objects whose key names are only known at run time. String keys only.
struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    /// Integer keys (array positions) are not object keys: never succeeds.
    init?(intValue: Int) { nil }
}

/// Collects unknown keys while one `decodeConfig` call runs; handed to the Decodable inits via `userInfo`.
private final class UnknownKeyCollector {
    var paths: [String] = []
}

private let unknownKeysInfoKey = CodingUserInfoKey(rawValue: "hypermug.unknownKeys")!

/// Dotted path with array indexes as `[i]`, e.g. `mouse.buttons.back.shortcut[1]`.
private func dotted(_ path: [CodingKey], _ extra: String? = nil) -> String {
    var out = ""
    for key in path {
        if let index = key.intValue {
            out += "[\(index)]"
        } else {
            out += (out.isEmpty ? "" : ".") + key.stringValue
        }
    }
    if let extra { out += (out.isEmpty ? "" : ".") + extra }
    return out
}

private func noteUnknownKeys(_ c: KeyedDecodingContainer<AnyKey>, known: Set<String>, in decoder: Decoder) {
    let collector = decoder.userInfo[unknownKeysInfoKey] as? UnknownKeyCollector
    for key in c.allKeys.map(\.stringValue).sorted() where !known.contains(key) {
        collector?.paths.append(dotted(c.codingPath, key))
    }
}

private func isBlank(_ s: String) -> Bool {
    s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func decodeAction(_ c: KeyedDecodingContainer<AnyKey>, _ name: String, in decoder: Decoder) throws -> ButtonAction? {
    let key = AnyKey(name)
    guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
    let path = dotted(c.codingPath, name)
    let a = try c.nestedContainer(keyedBy: AnyKey.self, forKey: key)
    noteUnknownKeys(a, known: ["shortcut", "shell", "helper"], in: decoder)
    // An empty/blank value counts as absent: zero real kinds = button left unmapped.
    var shell: String?
    if let v = try a.decodeIfPresent(String.self, forKey: AnyKey("shell")), !isBlank(v) {
        if v.utf8.contains(0) { throw ConfigError(reason: "\(path).shell: command cannot contain a NUL character") }
        shell = v
    }
    var helper: String?
    if let v = try a.decodeIfPresent(String.self, forKey: AnyKey("helper")) {
        if isBlank(v) { throw ConfigError(reason: "\(path).helper: name cannot be empty") }
        helper = v
    }
    var tokens: [String]?
    let shortcutKey = AnyKey("shortcut")
    if a.contains(shortcutKey), try !a.decodeNil(forKey: shortcutKey) {
        if let text = try? a.decode(String.self, forKey: shortcutKey) {
            // The old string form is gone; only an empty string still means "unmapped".
            if !isBlank(text) { throw ConfigError(reason: "\(path).shortcut \(shortcutArrayHint)") }
        } else {
            let list = try a.decode([String].self, forKey: shortcutKey)
            if !list.isEmpty { tokens = list }
        }
    }
    if [tokens != nil, shell != nil, helper != nil].filter({ $0 }).count > 1 {
        throw ConfigError(reason: "\(path): needs exactly one of shortcut/shell/helper")
    }
    if let shell { return .shell(shell) }
    if let helper { return .helper(helper) }
    if let tokens {
        switch parseShortcut(tokens) {
        case .success(let s): return .shortcut(s)
        case .failure(let e): throw ConfigError(reason: "\(path).shortcut: \(e.reason)")
        }
    }
    return nil
}

extension InvertScroll: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        noteUnknownKeys(c, known: ["vertical", "horizontal"], in: decoder)
        vertical = try c.decodeIfPresent(Bool.self, forKey: AnyKey("vertical")) ?? false
        horizontal = try c.decodeIfPresent(Bool.self, forKey: AnyKey("horizontal")) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(vertical, forKey: AnyKey("vertical"))
        try c.encode(horizontal, forKey: AnyKey("horizontal"))
    }
}

/// A mapped button is an object with only its one action key.
private struct ActionFields: Encodable {
    let action: ButtonAction?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        switch action {
        case .shortcut(let s)?: try c.encode(s.tokens, forKey: AnyKey("shortcut"))
        case .shell(let s)?: try c.encode(s, forKey: AnyKey("shell"))
        case .helper(let name)?: try c.encode(name, forKey: AnyKey("helper"))
        case nil: break
        }
    }
}

extension ButtonMap: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        noteUnknownKeys(c, known: ["back", "forward", "thumb"], in: decoder)
        back = try decodeAction(c, "back", in: decoder)
        forward = try decodeAction(c, "forward", in: decoder)
        thumb = try decodeAction(c, "thumb", in: decoder)
    }

    var isEmpty: Bool { back == nil && forward == nil && thumb == nil }

    /// Initial files show every slot; ordinary model encoding can remain compact.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        if back != nil || encoder.includeEmptyKeys { try c.encode(ActionFields(action: back), forKey: AnyKey("back")) }
        if forward != nil || encoder.includeEmptyKeys { try c.encode(ActionFields(action: forward), forKey: AnyKey("forward")) }
        if thumb != nil || encoder.includeEmptyKeys { try c.encode(ActionFields(action: thumb), forKey: AnyKey("thumb")) }
    }
}

extension SwipeMap: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        noteUnknownKeys(c, known: ["up", "down", "left", "right"], in: decoder)
        up = try decodeAction(c, "up", in: decoder)
        down = try decodeAction(c, "down", in: decoder)
        left = try decodeAction(c, "left", in: decoder)
        right = try decodeAction(c, "right", in: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        if up != nil || encoder.includeEmptyKeys { try c.encode(ActionFields(action: up), forKey: AnyKey("up")) }
        if down != nil || encoder.includeEmptyKeys { try c.encode(ActionFields(action: down), forKey: AnyKey("down")) }
        if left != nil || encoder.includeEmptyKeys { try c.encode(ActionFields(action: left), forKey: AnyKey("left")) }
        if right != nil || encoder.includeEmptyKeys { try c.encode(ActionFields(action: right), forKey: AnyKey("right")) }
    }
}

extension WheelMap: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        noteUnknownKeys(c, known: ["left", "right"], in: decoder)
        left = try decodeAction(c, "left", in: decoder)
        right = try decodeAction(c, "right", in: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        if left != nil || encoder.includeEmptyKeys { try c.encode(ActionFields(action: left), forKey: AnyKey("left")) }
        if right != nil || encoder.includeEmptyKeys { try c.encode(ActionFields(action: right), forKey: AnyKey("right")) }
    }
}

extension TrackpadConfig: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        noteUnknownKeys(c, known: ["threeFingerSwipe", "fourFingerSwipe"], in: decoder)
        threeFingerSwipe = try c.decodeIfPresent(SwipeMap.self, forKey: AnyKey("threeFingerSwipe")) ?? SwipeMap()
        fourFingerSwipe = try c.decodeIfPresent(SwipeMap.self, forKey: AnyKey("fourFingerSwipe")) ?? SwipeMap()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        if !threeFingerSwipe.isEmpty || encoder.includeEmptyKeys { try c.encode(threeFingerSwipe, forKey: AnyKey("threeFingerSwipe")) }
        if !fourFingerSwipe.isEmpty || encoder.includeEmptyKeys { try c.encode(fourFingerSwipe, forKey: AnyKey("fourFingerSwipe")) }
    }
}

extension MouseConfig: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        noteUnknownKeys(c, known: ["invertScroll", "buttons", "horizontalWheel"], in: decoder)
        invertScroll = try c.decodeIfPresent(InvertScroll.self, forKey: AnyKey("invertScroll")) ?? InvertScroll()
        buttons = try c.decodeIfPresent(ButtonMap.self, forKey: AnyKey("buttons")) ?? ButtonMap()
        horizontalWheel = try c.decodeIfPresent(WheelMap.self, forKey: AnyKey("horizontalWheel")) ?? WheelMap()
    }

    /// Show the button and wheel slots when initializing a configuration file.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(invertScroll, forKey: AnyKey("invertScroll"))
        if !buttons.isEmpty || encoder.includeEmptyKeys { try c.encode(buttons, forKey: AnyKey("buttons")) }
        if !horizontalWheel.isEmpty || encoder.includeEmptyKeys { try c.encode(horizontalWheel, forKey: AnyKey("horizontalWheel")) }
    }
}

extension AppConfig: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        noteUnknownKeys(c, known: ["$schema", "capsLock", "caffeineOnLaunch", "launchAtLogin", "autoUpdate", "mouse", "trackpad", "helpers", "shellTimeoutSeconds"], in: decoder)
        if c.contains(AnyKey("$schema")) { _ = try c.decode(String.self, forKey: AnyKey("$schema")) }
        shellTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: AnyKey("shellTimeoutSeconds")) ?? 10
        guard shellTimeoutSeconds.isFinite && (1...300).contains(shellTimeoutSeconds) else {
            throw ConfigError(reason: "shellTimeoutSeconds must be between 1 and 300 seconds")
        }
        helpers = try c.decodeIfPresent([String: String].self, forKey: AnyKey("helpers")) ?? [:]
        for (name, command) in helpers {
            if isBlank(name) { throw ConfigError(reason: "helpers: name cannot be empty") }
            if isBlank(command) { throw ConfigError(reason: "helpers.\(name): command cannot be empty") }
            if command.utf8.contains(0) { throw ConfigError(reason: "helpers.\(name): command cannot contain a NUL character") }
        }
        if let raw = try c.decodeIfPresent(String.self, forKey: AnyKey("capsLock")) {
            guard let mode = CapsMode(rawValue: raw) else {
                throw ConfigError(reason: "capsLock must be \"default\", \"meh\", \"threeMod\" or \"hyper\" (got \"\(raw)\")")
            }
            capsLock = mode
        }
        caffeineOnLaunch = try c.decodeIfPresent(Bool.self, forKey: AnyKey("caffeineOnLaunch")) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: AnyKey("launchAtLogin")) ?? false
        autoUpdate = try c.decodeIfPresent(Bool.self, forKey: AnyKey("autoUpdate")) ?? true
        mouse = try c.decodeIfPresent(MouseConfig.self, forKey: AnyKey("mouse")) ?? MouseConfig()
        trackpad = try c.decodeIfPresent(TrackpadConfig.self, forKey: AnyKey("trackpad")) ?? TrackpadConfig()
        let references: [(String, ButtonAction?)] = [
            ("mouse.buttons.back", mouse.buttons.back), ("mouse.buttons.forward", mouse.buttons.forward),
            ("mouse.buttons.thumb", mouse.buttons.thumb),
            ("mouse.horizontalWheel.left", mouse.horizontalWheel.left), ("mouse.horizontalWheel.right", mouse.horizontalWheel.right)
        ] + [3, 4].flatMap { fingers in SwipeDirection.allCases.map { direction in
            ("trackpad.\(fingers == 3 ? "threeFingerSwipe" : "fourFingerSwipe").\(direction.rawValue)",
             trackpad.action(fingers: fingers, direction: direction))
        } }
        for (path, action) in references {
            if case .helper(let name)? = action, helpers[name] == nil {
                throw ConfigError(reason: "\(path).helper: unknown helper \"\(name)\"")
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        if let schema = encoder.userInfo[schemaReferenceKey] as? String {
            try c.encode(schema, forKey: AnyKey("$schema"))
        }
        try c.encode(shellTimeoutSeconds, forKey: AnyKey("shellTimeoutSeconds"))
        try c.encode(capsLock.rawValue, forKey: AnyKey("capsLock"))
        try c.encode(caffeineOnLaunch, forKey: AnyKey("caffeineOnLaunch"))
        try c.encode(launchAtLogin, forKey: AnyKey("launchAtLogin"))
        try c.encode(autoUpdate, forKey: AnyKey("autoUpdate"))
        try c.encode(mouse, forKey: AnyKey("mouse"))
        if !helpers.isEmpty || encoder.includeEmptyKeys { try c.encode(helpers, forKey: AnyKey("helpers")) }
        if trackpad.hasMappings || encoder.includeEmptyKeys { try c.encode(trackpad, forKey: AnyKey("trackpad")) }
    }
}

/// Short, alert-ready text for an error thrown by `JSONDecoder`. Validation errors are `ConfigError`s already;
/// the decoder raises only these three: a wrong type, a `null` where a value is required (inside a shortcut
/// array), or unparsable JSON (everything else, since every key is optional).
private func describe(_ error: Error) -> String {
    func expected(_ type: Any.Type) -> String {
        if type == Bool.self { return "true or false" }
        if type == String.self { return "a string" }
        if type == Double.self { return "a number" }
        if type == [String: Any].self { return "an object" }
        return "an array"
    }
    switch error {
    case DecodingError.typeMismatch(let type, let ctx), DecodingError.valueNotFound(let type, let ctx):
        if ctx.codingPath.isEmpty { return "config must be a JSON object" }
        return "\(dotted(ctx.codingPath)): expected \(expected(type))"
    default:
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        var reason = "invalid JSON"
        if let detail = underlying?.userInfo[NSDebugDescriptionErrorKey] as? String { reason += ": \(detail)" }
        return reason
    }
}

/// Empty or whitespace-only file contents mean "all defaults".
public func isBlankConfigData(_ data: Data) -> Bool {
    isBlank(String(decoding: data, as: UTF8.self))
}

/// The model's Codable bridge: Foundation's serialization of an already parsed and schema-checked TOML tree.
/// Not a configuration format; users only ever write TOML.
func decodeConfig(_ data: Data) -> Result<DecodedConfig, ConfigError> {
    if isBlankConfigData(data) { return .success(DecodedConfig(config: AppConfig(), unknownKeys: [])) }
    let collector = UnknownKeyCollector()
    let decoder = JSONDecoder()
    decoder.userInfo[unknownKeysInfoKey] = collector
    do {
        let config = try decoder.decode(AppConfig.self, from: data)
        return .success(DecodedConfig(config: config, unknownKeys: collector.paths))
    } catch let e as ConfigError {
        return .failure(e)
    } catch {
        return .failure(ConfigError(reason: describe(error)))
    }
}

// MARK: - Encoding

/// Pretty, sorted keys (so `$schema` comes first), no escaped slashes, trailing newline.
private let schemaReferenceKey = CodingUserInfoKey(rawValue: "hypermug.schemaReference")!

private let emptyKeysKey = CodingUserInfoKey(rawValue: "hypermug.includeEmptyKeys")!
private extension Encoder {
    var includeEmptyKeys: Bool { userInfo[emptyKeysKey] as? Bool == true }
}

/// The model's Codable encoding, rendered by `encodeConfigTOML`. Include unassigned slots as `{}` when
/// creating or recreating a configuration file.
func encodeConfig(_ config: AppConfig, schemaURL: URL? = nil, includeEmptyKeys: Bool = false) -> Data {
    let encoder = JSONEncoder()
    encoder.userInfo[emptyKeysKey] = includeEmptyKeys
    if let schemaURL { encoder.userInfo[schemaReferenceKey] = schemaURL.absoluteString }
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    // App-created models contain finite numbers and Codable value types.
    var data = try! encoder.encode(config)
    data.append(0x0A)
    return data
}
