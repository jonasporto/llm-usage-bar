import Foundation

// MARK: - Profiles

public enum ProfileProvider: String, Hashable, Sendable {
    case anthropic
    case openAI = "openai"

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        }
    }
}

/// Provider-owned settings stay separate so a Codex profile can never be
/// mistaken for an Anthropic Keychain entry, or vice versa.
public enum ProfileConfiguration: Hashable, Sendable {
    case anthropic(keychainService: String, configPath: String)
    case openAI(codexHome: String, codexPath: String?)
}

/// One selectable usage account. IDs are global across providers because
/// they also key the selected profile, cached snapshots and balance anchors.
public struct Profile: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let configuration: ProfileConfiguration

    public var provider: ProfileProvider {
        switch configuration {
        case .anthropic: .anthropic
        case .openAI: .openAI
        }
    }

    public init(id: String, name: String, configuration: ProfileConfiguration) {
        self.id = id
        self.name = name
        self.configuration = configuration
    }
}

/// Profiles are user configuration, never hardcoded: the Keychain suffix of a
/// non-default profile is derived from a local path and differs per machine.
public enum Profiles {
    /// What Claude Code uses with no `CLAUDE_CONFIG_DIR` set.
    public static let defaultService = "Claude Code-credentials"
    public static let defaultConfigPath = "~/.claude.json"
    public static let defaultCodexHome = "~/.codex"

    public static func fallback(home: String) -> [Profile] {
        [Profile(id: "default", name: "Claude",
                 configuration: .anthropic(
                    keychainService: defaultService,
                    configPath: expand(defaultConfigPath, home: home)))]
    }

    /// `~/.config/claude-usage-bar/profiles.json`, or `$XDG_CONFIG_HOME`.
    public static func configURL(home: String,
                                 environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/.config"
        return URL(fileURLWithPath: expand(base, home: home))
            .appendingPathComponent("claude-usage-bar/profiles.json")
    }

    private struct Spec: Decodable {
        let id: String
        let name: String?
        let provider: String?
        let keychainService: String?
        let configPath: String?
        let codexHome: String?
        let codexPath: String?
    }

    /// Decodes a profiles.json. Anything unusable — bad JSON, empty list, no
    /// entry with an id — yields the single default profile, so the app always
    /// has something to show.
    public static func decode(_ data: Data, home: String) -> [Profile] {
        guard let specs = try? JSONDecoder().decode([Spec].self, from: data) else {
            return fallback(home: home)
        }
        var seen = Set<String>()
        let profiles: [Profile] = specs.compactMap { spec in
            let id = spec.id.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let configuration: ProfileConfiguration
            switch spec.provider?.lowercased() ?? ProfileProvider.anthropic.rawValue {
            case ProfileProvider.anthropic.rawValue:
                configuration = .anthropic(
                    keychainService: spec.keychainService ?? defaultService,
                    configPath: expand(spec.configPath ?? defaultConfigPath, home: home))
            case ProfileProvider.openAI.rawValue:
                let configuredPath = spec.codexPath?.trimmingCharacters(in: .whitespaces)
                configuration = .openAI(
                    codexHome: expand(spec.codexHome ?? defaultCodexHome, home: home),
                    codexPath: configuredPath?.isEmpty == false
                        ? expand(configuredPath!, home: home) : nil)
            default:
                return nil
            }
            return Profile(id: id,
                           name: spec.name?.isEmpty == false ? spec.name! : id.capitalized,
                           configuration: configuration)
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
        return decode(data, home: home)
    }

    static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}
