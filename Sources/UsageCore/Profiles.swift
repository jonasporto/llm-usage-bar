import CryptoKit
import Foundation

// MARK: - Profiles

public enum ProfileProvider: Hashable, Sendable {
    case anthropic
    case openAI
    case xAI
    case antigravity
    case custom(String)

    public init(_ raw: String) {
        switch raw.lowercased() {
        case "anthropic": self = .anthropic
        case "openai": self = .openAI
        case "xai", "grok": self = .xAI
        case "antigravity", "agy": self = .antigravity
        default: self = .custom(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .anthropic: "anthropic"
        case .openAI: "openai"
        case .xAI: "xai"
        case .antigravity: "antigravity"
        case let .custom(value): value
        }
    }

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .xAI: "xAI"
        case .antigravity: "Antigravity"
        case let .custom(value): value
        }
    }

    public var isBuiltIn: Bool {
        if case .custom = self { return false }
        return true
    }
}

/// Provider-owned settings stay separate so a Codex profile can never be
/// mistaken for an Anthropic Keychain entry, or vice versa.
public enum ProfileConfiguration: Hashable, Sendable {
    case anthropic(keychainService: String, configPath: String)
    case openAI(codexHome: String, codexPath: String?)
    case xAI(grokHome: String)
    case antigravity(geminiHome: String, cliPath: String?)
    case command(home: String, executable: String)

    var impliedHome: String {
        switch self {
        case let .anthropic(_, configPath):
            URL(fileURLWithPath: configPath).deletingLastPathComponent().path
        case let .openAI(codexHome, _): codexHome
        case let .xAI(grokHome): grokHome
        case let .antigravity(geminiHome, _): geminiHome
        case let .command(home, _): home
        }
    }

    var impliedProvider: ProfileProvider {
        switch self {
        case .anthropic: .anthropic
        case .openAI: .openAI
        case .xAI: .xAI
        case .antigravity: .antigravity
        case .command: .custom("command")
        }
    }
}

/// One selectable usage account. IDs are global across providers because
/// they also key the selected profile, cached snapshots and balance anchors.
public struct Profile: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let provider: ProfileProvider
    public let configuration: ProfileConfiguration
    public let home: String
    public let adapter: String?
    public let icon: String?
    /// Per-account cadence, clamped like the global default. `nil` means the
    /// value from `config.json`.
    public let refreshSeconds: Int?

    /// Built-in fetch is skipped when this is set: an unknown provider's
    /// `path`, or an explicit `adapter` override on a built-in provider.
    public var usageAdapter: String? {
        if let adapter { return adapter }
        if case let .command(_, executable) = configuration { return executable }
        return nil
    }

    public init(id: String, name: String, configuration: ProfileConfiguration,
                provider: ProfileProvider? = nil, home: String? = nil,
                adapter: String? = nil, icon: String? = nil,
                refreshSeconds: Int? = nil) {
        self.id = id
        self.name = name
        self.configuration = configuration
        self.provider = provider ?? configuration.impliedProvider
        self.home = home ?? configuration.impliedHome
        self.adapter = adapter
        self.icon = icon
        self.refreshSeconds = refreshSeconds.map(AppSettings.clamp)
    }

    /// The cadence to poll this account with, given the global default.
    public func refreshSeconds(default fallback: Int) -> Int {
        refreshSeconds ?? AppSettings.clamp(fallback)
    }
}

/// Profiles are user configuration, never hardcoded: the Keychain suffix of a
/// non-default profile is derived from a local path and differs per machine.
public enum Profiles {
    /// What Claude Code uses with no `CLAUDE_CONFIG_DIR` set.
    public static let defaultService = "Claude Code-credentials"
    public static let defaultClaudeHome = "~/.claude"
    public static let defaultConfigPath = "~/.claude.json"
    public static let defaultCodexHome = "~/.codex"
    public static let defaultGrokHome = "~/.grok"
    public static let defaultAntigravityHome = "~/.gemini"

    public static func fallback(home: String) -> [Profile] {
        [Profile(id: "default", name: "Claude",
                 configuration: .anthropic(
                    keychainService: defaultService,
                    configPath: expand(defaultConfigPath, home: home)))]
    }

    /// `~/.config/llm-usage-bar/profiles.json`, or `$XDG_CONFIG_HOME`.
    /// A leftover `claude-usage-bar` directory is still read when the new
    /// path does not exist yet.
    public static let configDirectory = "llm-usage-bar"
    public static let legacyConfigDirectory = "claude-usage-bar"

    /// Subdirectories the installer creates next to `profiles.json`, so
    /// adding an icon or an adapter never means making a directory by hand.
    public static let iconsSubdirectory = "icons"
    public static let adaptersSubdirectory = "adapters"

    public static func configURL(home: String,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 fileManager: FileManager = .default)
        -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/.config"
        let root = URL(fileURLWithPath: expand(base, home: home))
        let canonical = root.appendingPathComponent("\(configDirectory)/profiles.json")
        if fileManager.fileExists(atPath: canonical.path) { return canonical }
        let legacy = root.appendingPathComponent("\(legacyConfigDirectory)/profiles.json")
        if fileManager.fileExists(atPath: legacy.path) { return legacy }
        return canonical
    }

    /// The directory that owns `profiles.json`, `icons/` and `adapters/`.
    public static func configDirectoryURL(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        configURL(home: home, environment: environment, fileManager: fileManager)
            .deletingLastPathComponent()
    }

    /// Where the installer drops adapter executables: `$XDG_DATA_HOME`
    /// (default `~/.local/share`), not the config directory — a config
    /// directory gets synced and committed, and executables should not ride
    /// along. Looked up before `$PATH`, so a starter adapter runs with no
    /// shell setup.
    public static func adaptersDirectory(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let base = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/.local/share"
        return "\(expand(base, home: home))/\(configDirectory)/\(adaptersSubdirectory)"
    }

    /// Every place an adapter is looked for, in order. The list is generous on
    /// purpose: wherever someone reasonably drops an executable, it is found
    /// without an entry in `profiles.json`.
    static func adapterDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String,
        fileManager: FileManager = .default
    ) -> [String] {
        var directories = [
            adaptersDirectory(home: home, environment: environment),
            "\(home)/.local/bin/\(configDirectory)",
            configDirectoryURL(home: home, environment: environment,
                               fileManager: fileManager)
                .appendingPathComponent(adaptersSubdirectory).path
        ]
        directories += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        directories += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return directories
    }

    private struct Spec: Decodable {
        let id: String
        let name: String?
        let provider: String?
        let home: String?
        let path: String?
        let adapter: String?
        let icon: String?
        let refreshSeconds: Int?
        let keychainService: String?
        let configPath: String?
        let codexHome: String?
        let codexPath: String?
        let grokHome: String?
        let geminiHome: String?
    }

    /// Result of applying a newly loaded catalog to the accounts already on
    /// screen. `staleIDs` are gone, or still present with a different provider
    /// configuration, so cached usage for them must be dropped.
    public struct Reload: Equatable, Sendable {
        public let profiles: [Profile]
        public let activeID: String
        public let staleIDs: Set<String>

        public init(profiles: [Profile], activeID: String, staleIDs: Set<String>) {
            self.profiles = profiles
            self.activeID = activeID
            self.staleIDs = staleIDs
        }
    }

    /// Decodes a profiles.json. Anything unusable — bad JSON, empty list, no
    /// entry with an id — yields the single default profile, so the app always
    /// has something to show.
    public static func decode(_ data: Data, home: String,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              fileManager: FileManager = .default) -> [Profile] {
        parse(data, home: home, environment: environment, fileManager: fileManager)
            ?? fallback(home: home)
    }

    /// Like `decode`, but `nil` for a half-written or otherwise unusable file
    /// so a live reload can keep the current accounts instead of flashing the
    /// fallback profile.
    public static func parse(_ data: Data, home: String,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             fileManager: FileManager = .default) -> [Profile]? {
        guard let specs = try? JSONDecoder().decode([Spec].self, from: data) else {
            return nil
        }
        var seen = Set<String>()
        let profiles: [Profile] = specs.compactMap { spec in
            let id = spec.id.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let provider = ProfileProvider(spec.provider ?? ProfileProvider.anthropic.rawValue)
            let isolation = isolationHome(spec, provider: provider, home: home)
            var adapter = nonempty(spec.adapter).map { expand($0, home: home) }
            let icon = nonempty(spec.icon).map { expand($0, home: home) }
            let configuration: ProfileConfiguration
            switch provider {
            case .anthropic:
                configuration = anthropicConfiguration(spec, home: home)
            case .openAI:
                configuration = openAIConfiguration(spec, home: home)
            case .xAI:
                configuration = xAIConfiguration(spec, home: home)
            case .antigravity:
                configuration = antigravityConfiguration(
                    spec, home: home, environment: environment, fileManager: fileManager)
                // An installed antigravity-usage is a deliberate override of
                // the built-in CLI fetch, so it is honored like an explicit
                // `adapter`.
                adapter = adapter ?? resolveAdapterExecutable(
                    names: antigravityAdapterNames, environment: environment,
                    home: home, fileManager: fileManager)
            case let .custom(name):
                let executable = adapter
                    ?? nonempty(spec.path).map { expand($0, home: home) }
                    ?? resolveAdapterExecutable(
                        names: customAdapterNames(forProvider: name),
                        environment: environment,
                        home: home,
                        fileManager: fileManager)
                guard let executable else { return nil }
                configuration = .command(home: isolation, executable: executable)
            }
            return Profile(id: id,
                           name: spec.name?.isEmpty == false ? spec.name! : id.capitalized,
                           configuration: configuration,
                           provider: provider,
                           home: isolation,
                           adapter: provider.isBuiltIn ? adapter : nil,
                           icon: icon,
                           refreshSeconds: spec.refreshSeconds)
        }
        return profiles.isEmpty ? fallback(home: home) : profiles
    }

    public static func load(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                            environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [Profile] {
        let url = configURL(home: home, environment: environment)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return fallback(home: home)
        }
        return decode(data, home: home, environment: environment)
    }

    /// Reads the on-disk catalog for a live reload. A missing file is the
    /// default profile; unusable JSON is `nil` so the caller keeps what it has.
    public static func readForReload(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [Profile]? {
        let url = configURL(home: home, environment: environment)
        guard let data = fileManager.contents(atPath: url.path) else {
            return fallback(home: home)
        }
        return parse(data, home: home, environment: environment, fileManager: fileManager)
    }

    /// `nil` when the loaded catalog is identical to what is already shown.
    public static func reconcile(loaded: [Profile], current: [Profile],
                                 activeID: String) -> Reload? {
        guard loaded != current else { return nil }
        let loadedIDs = Set(loaded.map(\.id))
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var stale = Set(currentByID.keys).subtracting(loadedIDs)
        for profile in loaded {
            if let previous = currentByID[profile.id],
               previous.configuration != profile.configuration {
                stale.insert(profile.id)
            }
        }
        let nextActive = loadedIDs.contains(activeID) ? activeID : loaded[0].id
        return Reload(profiles: loaded, activeID: nextActive, staleIDs: stale)
    }

    static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// Claude Code: default dir is unsuffixed; any other CLAUDE_CONFIG_DIR
    /// hashes the expanded path (`sha256` hex prefix 8).
    static func claudeKeychainService(forConfigDir dir: String) -> String {
        let digest = SHA256.hash(data: Data(dir.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(defaultService)-\(suffix)"
    }

    private static func anthropicConfiguration(_ spec: Spec, home: String) -> ProfileConfiguration {
        let configDir = normalizeDir(expand(
            nonempty(spec.home) ?? defaultClaudeHome, home: home))
        let isDefault = configDir == normalizeDir(expand(defaultClaudeHome, home: home))
        let configPath = nonempty(spec.configPath).map { expand($0, home: home) }
            ?? (isDefault ? expand(defaultConfigPath, home: home)
                : "\(configDir)/.claude.json")
        let keychainService = nonempty(spec.keychainService)
            ?? (isDefault ? defaultService : claudeKeychainService(forConfigDir: configDir))
        return .anthropic(keychainService: keychainService, configPath: configPath)
    }

    private static func openAIConfiguration(_ spec: Spec, home: String) -> ProfileConfiguration {
        let codexHome = expand(
            nonempty(spec.home) ?? nonempty(spec.codexHome) ?? defaultCodexHome,
            home: home)
        let executable = nonempty(spec.path) ?? nonempty(spec.codexPath)
        return .openAI(
            codexHome: normalizeDir(codexHome),
            codexPath: executable.map { expand($0, home: home) })
    }

    private static func xAIConfiguration(_ spec: Spec, home: String) -> ProfileConfiguration {
        .xAI(grokHome: normalizeDir(expand(
            nonempty(spec.home) ?? nonempty(spec.grokHome) ?? defaultGrokHome,
            home: home)))
    }

    /// `path` is the Antigravity CLI, the same meaning it has for Codex; the
    /// usage adapter is `adapter` (or a discovered `antigravity-usage`).
    private static func antigravityConfiguration(
        _ spec: Spec, home: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> ProfileConfiguration {
        let geminiHome = normalizeDir(expand(
            nonempty(spec.home) ?? nonempty(spec.geminiHome) ?? defaultAntigravityHome,
            home: home))
        let cliPath = nonempty(spec.path).map { expand($0, home: home) }
            ?? AntigravityCLI.resolveExecutable(environment: environment, home: home,
                                                fileManager: fileManager)
        return .antigravity(geminiHome: geminiHome, cliPath: cliPath)
    }

    /// Adapter lookup order: the app's own `adapters/` directory first — the
    /// installer owns it, so nothing has to be added to `$PATH` — then `$PATH`
    /// and the locations a hand-installed executable usually lands in.
    public static func adapterCandidates(names: [String],
                                         configuredPath: String? = nil,
                                         environment: [String: String] = ProcessInfo.processInfo.environment,
                                         home: String,
                                         fileManager: FileManager = .default) -> [String] {
        if let configuredPath { return [configuredPath] }
        var seen = Set<String>()
        return adapterDirectories(environment: environment, home: home,
                                  fileManager: fileManager)
            .flatMap { directory in names.map { "\(directory)/\($0)" } }
            .filter { seen.insert($0).inserted }
    }

    public static func antigravityCandidates(configuredPath: String?,
                                             environment: [String: String] = ProcessInfo.processInfo.environment,
                                             home: String) -> [String] {
        adapterCandidates(names: antigravityAdapterNames,
                          configuredPath: configuredPath,
                          environment: environment,
                          home: home)
    }

    /// `provider` in `profiles.json` names the executable an unknown provider
    /// is fetched with, so `"provider": "ollama"` finds `adapters/ollama-usage`
    /// without a `path` of its own.
    public static func customAdapterNames(forProvider provider: String) -> [String] {
        ["\(provider)-usage", provider]
    }

    static let antigravityAdapterNames = ["antigravity-usage", "agy-usage"]

    private static func resolveAdapterExecutable(
        names: [String],
        configuredPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String,
        fileManager: FileManager = .default
    ) -> String? {
        if let configuredPath {
            let expanded = expand(configuredPath, home: home)
            return fileManager.isExecutableFile(atPath: expanded) ? expanded : configuredPath
        }
        for candidate in adapterCandidates(names: names, environment: environment,
                                           home: home, fileManager: fileManager) {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func isolationHome(_ spec: Spec, provider: ProfileProvider,
                                      home: String) -> String {
        let fallback: String
        switch provider {
        case .anthropic: fallback = defaultClaudeHome
        case .openAI: fallback = defaultCodexHome
        case .xAI: fallback = defaultGrokHome
        case .antigravity: fallback = defaultAntigravityHome
        case let .custom(name): fallback = "~/.\(name)"
        }
        let raw = nonempty(spec.home)
            ?? nonempty(spec.codexHome)
            ?? nonempty(spec.grokHome)
            ?? nonempty(spec.geminiHome)
            ?? fallback
        return normalizeDir(expand(raw, home: home))
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func normalizeDir(_ path: String) -> String {
        if path == "/" { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
