import Testing
import Foundation
@testable import UsageCore

@Suite struct ProfilesTests {
    let home = "/Users/example"

    @Test func testFullEntriesDecodeAndExpandTilde() {
        let json = Data("""
        [
         {"id": "personal", "name": "Personal"},
         {"id": "work", "name": "Work",
          "keychainService": "Claude Code-credentials-abc12345",
          "configPath": "~/.claude-work/.claude.json"}
        ]
        """.utf8)
        let profiles = Profiles.decode(json, home: home)
        #expect(profiles.map(\.id) == ["personal", "work"])
        #expect(profiles.map(\.provider) == [.anthropic, .anthropic])
        #expect(profiles[0].configuration == .anthropic(
            keychainService: "Claude Code-credentials",
            configPath: "/Users/example/.claude.json"))
        #expect(profiles[1].configuration == .anthropic(
            keychainService: "Claude Code-credentials-abc12345",
            configPath: "/Users/example/.claude-work/.claude.json"))
    }

    @Test func testUnifiedHomeIsInterpretedPerProvider() {
        let json = Data("""
        [
         {"id": "claude", "provider": "anthropic"},
         {"id": "claude-work", "provider": "anthropic", "home": "~/.claude-work"},
         {"id": "codex", "provider": "openai", "home": "~/.codex-work",
          "path": "~/.local/bin/codex"},
         {"id": "grok", "provider": "xai", "home": "~/.grok-work"}
        ]
        """.utf8)

        let profiles = Profiles.decode(json, home: home)

        #expect(profiles.map(\.id) == ["claude", "claude-work", "codex", "grok"])
        #expect(profiles[0].configuration == .anthropic(
            keychainService: "Claude Code-credentials",
            configPath: "/Users/example/.claude.json"))
        #expect(profiles[1].configuration == .anthropic(
            keychainService: "Claude Code-credentials-dd1118a7",
            configPath: "/Users/example/.claude-work/.claude.json"))
        #expect(profiles[2].configuration == .openAI(
            codexHome: "/Users/example/.codex-work",
            codexPath: "/Users/example/.local/bin/codex"))
        #expect(profiles[3].configuration == .xAI(
            grokHome: "/Users/example/.grok-work"))
    }

    @Test func testDefaultClaudeHomeStaysUnsuffixed() {
        let json = Data("""
        [{"id": "claude", "provider": "anthropic", "home": "~/.claude"}]
        """.utf8)
        let profiles = Profiles.decode(json, home: home)
        #expect(profiles[0].configuration == .anthropic(
            keychainService: "Claude Code-credentials",
            configPath: "/Users/example/.claude.json"))
    }

    @Test func testLegacyProviderKeysStillWork() {
        let json = Data("""
        [
         {"id": "claude", "name": "Claude"},
         {"id": "codex", "name": "Codex", "provider": "openai"},
         {"id": "codex-work", "name": "Work", "provider": "OPENAI",
          "codexHome": "~/.codex-work", "codexPath": "~/.local/bin/codex"},
         {"id": "grok", "name": "Grok", "provider": "xai"},
         {"id": "grok-work", "name": "Grok work", "provider": "GROK",
          "grokHome": "~/.grok-work"}
        ]
        """.utf8)

        let profiles = Profiles.decode(json, home: home)

        #expect(profiles.map(\.id) == ["claude", "codex", "codex-work", "grok", "grok-work"])
        #expect(profiles.map(\.provider) == [.anthropic, .openAI, .openAI, .xAI, .xAI])
        #expect(profiles[1].configuration == .openAI(
            codexHome: "/Users/example/.codex", codexPath: nil))
        #expect(profiles[2].configuration == .openAI(
            codexHome: "/Users/example/.codex-work",
            codexPath: "/Users/example/.local/bin/codex"))
        #expect(profiles[3].configuration == .xAI(
            grokHome: "/Users/example/.grok"))
        #expect(profiles[4].configuration == .xAI(
            grokHome: "/Users/example/.grok-work"))
    }

    @Test func testUnknownProviderWithPathBecomesACommandAdapter() {
        let json = Data("""
        [
         {"id": "mini", "name": "MiniMax", "provider": "minimax",
          "home": "~/.minimax", "path": "~/.local/bin/minimax-usage",
          "icon": "~/.config/llm-usage-bar/icons/minimax.svg"}
        ]
        """.utf8)

        let profiles = Profiles.decode(json, home: home)

        #expect(profiles.map(\.id) == ["mini"])
        #expect(profiles[0].provider == .custom("minimax"))
        #expect(profiles[0].configuration == .command(
            home: "/Users/example/.minimax",
            executable: "/Users/example/.local/bin/minimax-usage"))
        #expect(profiles[0].usageAdapter == "/Users/example/.local/bin/minimax-usage")
        #expect(profiles[0].icon == "/Users/example/.config/llm-usage-bar/icons/minimax.svg")
    }


    /// `path` is the Antigravity CLI (as it is for Codex); `adapter` is a
    /// usage executable that replaces the built-in fetch. The environment is
    /// pinned so a CLI installed on the machine running the tests cannot be
    /// discovered and change the outcome.
    @Test func testAntigravityProfilesDecodeAndSupportOverrides() {
        let json = Data("""
        [
         {"id": "ag", "name": "Antigravity", "provider": "antigravity"},
         {"id": "ag-work", "name": "Work", "provider": "agy",
          "home": "~/accounts/work/.gemini", "path": "~/.local/bin/agy",
          "icon": "~/.config/llm-usage-bar/icons/custom-ag.svg"},
         {"id": "ag-custom-adapter", "provider": "antigravity",
          "adapter": "~/.local/bin/my-adapter"}
        ]
        """.utf8)

        let profiles = Profiles.decode(json, home: home, environment: isolated)

        #expect(profiles.map(\.id) == ["ag", "ag-work", "ag-custom-adapter"])
        #expect(profiles.map(\.provider) == [.antigravity, .antigravity, .antigravity])
        #expect(profiles[0].configuration == .antigravity(
            geminiHome: "/Users/example/.gemini", cliPath: nil))
        #expect(profiles[0].usageAdapter == nil)
        #expect(profiles[1].configuration == .antigravity(
            geminiHome: "/Users/example/accounts/work/.gemini",
            cliPath: "/Users/example/.local/bin/agy"))
        #expect(profiles[1].usageAdapter == nil)
        #expect(profiles[1].icon == "/Users/example/.config/llm-usage-bar/icons/custom-ag.svg")
        #expect(profiles[2].usageAdapter == "/Users/example/.local/bin/my-adapter")
    }

    private let isolated = ["PATH": "/nonexistent", "XDG_DATA_HOME": "/nonexistent",
                            "XDG_CONFIG_HOME": "/nonexistent"]

    @Test func testAntigravityProviderProperties() {
        #expect(ProfileProvider("antigravity") == .antigravity)
        #expect(ProfileProvider("agy") == .antigravity)
        #expect(ProfileProvider("ANTIGRAVITY") == .antigravity)
        #expect(ProfileProvider.antigravity.rawValue == "antigravity")
        #expect(ProfileProvider.antigravity.displayName == "Antigravity")
        #expect(ProfileProvider.antigravity.isBuiltIn)
    }

    @Test func testAntigravityCandidatesIncludeHomeAndStandardLocations() {
        let candidates = Profiles.antigravityCandidates(
            configuredPath: nil,
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin"],
            home: "/Users/example")
        #expect(candidates.contains("/opt/homebrew/bin/antigravity-usage"))
        #expect(candidates.contains("/opt/homebrew/bin/agy-usage"))
        #expect(candidates.contains("/Users/example/.local/bin/antigravity-usage"))
        #expect(candidates.contains("/Users/example/.local/bin/agy-usage"))
    }

    @Test func testUnknownProviderFindsAnAdapterNamedAfterIt() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let adapters = root.appendingPathComponent("llm-usage-bar/adapters")
        try fileManager.createDirectory(at: adapters, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let executable = adapters.appendingPathComponent("ollama-usage")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: executable.path)

        let json = Data("""
        [{"id": "ollama", "name": "Ollama", "provider": "ollama", "home": "~/.ollama"}]
        """.utf8)

        let profiles = Profiles.decode(json, home: home,
                                       environment: ["XDG_DATA_HOME": root.path],
                                       fileManager: fileManager)

        #expect(profiles.map(\.id) == ["ollama"])
        #expect(profiles[0].configuration == .command(
            home: "/Users/example/.ollama", executable: executable.path))
        #expect(profiles[0].usageAdapter == executable.path)
    }

    @Test func testUnknownProviderWithoutAnyAdapterIsDropped() {
        let json = Data("""
        [{"id": "nowhere", "provider": "nowhere-at-all"}, {"id": "claude"}]
        """.utf8)

        let profiles = Profiles.decode(json, home: home,
                                       environment: ["XDG_DATA_HOME": "/nonexistent",
                                                     "PATH": "/nonexistent"])

        #expect(profiles.map(\.id) == ["claude"])
    }

    @Test func testAnAccountCanCarryItsOwnCadence() {
        let json = Data("""
        [
         {"id": "claude"},
         {"id": "claude-slow", "refreshSeconds": 600},
         {"id": "claude-greedy", "refreshSeconds": 5}
        ]
        """.utf8)

        let profiles = Profiles.decode(json, home: home, environment: isolated)

        #expect(profiles[0].refreshSeconds == nil)
        #expect(profiles[1].refreshSeconds == 600)
        // Clamped exactly like the global default: the endpoint rate-limits
        // on a rolling window whichever file asked for the interval.
        #expect(profiles[2].refreshSeconds == 60)

        #expect(profiles[0].refreshSeconds(default: 120) == 120)
        #expect(profiles[1].refreshSeconds(default: 120) == 600)
        #expect(profiles[0].refreshSeconds(default: 1) == 60)
    }

    @Test func testAdapterCandidatesLookInTheAppAdaptersDirectoryFirst() {
        let candidates = Profiles.adapterCandidates(
            names: Profiles.customAdapterNames(forProvider: "ollama"),
            environment: ["PATH": "/usr/bin"],
            home: home)

        #expect(candidates.first ==
            "/Users/example/.local/share/llm-usage-bar/adapters/ollama-usage")
        #expect(candidates.contains(
            "/Users/example/.local/share/llm-usage-bar/adapters/ollama"))
        #expect(candidates.contains(
            "/Users/example/.local/bin/llm-usage-bar/ollama-usage"))
        #expect(candidates.contains(
            "/Users/example/.config/llm-usage-bar/adapters/ollama-usage"))
        #expect(candidates.contains("/usr/bin/ollama-usage"))
        #expect(candidates.contains("/Users/example/.local/bin/ollama-usage"))
    }

    @Test func testAdapterCandidatesHonorAConfiguredPath() {
        #expect(Profiles.adapterCandidates(names: ["ollama-usage"],
                                           configuredPath: "/opt/bin/mine",
                                           environment: ["PATH": "/usr/bin"],
                                           home: home) == ["/opt/bin/mine"])
    }

    @Test func testAdaptersDirectoryLivesUnderTheDataHome() {
        #expect(Profiles.adaptersDirectory(home: home, environment: [:])
            == "/Users/example/.local/share/llm-usage-bar/adapters")
        #expect(Profiles.adaptersDirectory(
            home: home, environment: ["XDG_DATA_HOME": "~/elsewhere"])
            == "/Users/example/elsewhere/llm-usage-bar/adapters")
    }

    @Test func testAdapterLookupFollowsTheLegacyConfigDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let configDir = root.appendingPathComponent("config")
        let legacyDir = configDir.appendingPathComponent("claude-usage-bar")
        try fileManager.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try Data("[]".utf8).write(to: legacyDir.appendingPathComponent("profiles.json"))

        let environment = ["XDG_CONFIG_HOME": configDir.path]
        #expect(Profiles.configDirectoryURL(home: root.path,
                                            environment: environment,
                                            fileManager: fileManager).path == legacyDir.path)
        #expect(Profiles.adapterCandidates(names: ["demo-usage"],
                                           environment: environment,
                                           home: root.path,
                                           fileManager: fileManager)
            .contains(legacyDir.appendingPathComponent("adapters/demo-usage").path))
    }

    @Test func testAdapterOverridesABuiltInProvider() {
        let json = Data("""
        [{"id": "claude", "provider": "anthropic",
          "adapter": "~/.local/bin/claude-usage"}]
        """.utf8)
        let profiles = Profiles.decode(json, home: home)
        #expect(profiles[0].provider == .anthropic)
        #expect(profiles[0].usageAdapter == "/Users/example/.local/bin/claude-usage")
        if case .anthropic = profiles[0].configuration {} else {
            Issue.record("expected the built-in Anthropic configuration to remain")
        }
    }

    @Test func testUnknownProviderDoesNotInvalidateValidSiblings() {
        let json = Data("""
        [
         {"id": "unsupported", "provider": "other"},
         {"id": "codex", "provider": "openai"}
        ]
        """.utf8)

        let profiles = Profiles.decode(json, home: home)

        #expect(profiles.map(\.id) == ["codex"])
        #expect(profiles[0].provider == .openAI)
    }

    @Test func testNameDefaultsToTheIdAndDuplicatesAreDropped() {
        let json = Data("""
        [{"id": "work"}, {"id": "work", "name": "Second"}, {"id": "  "}]
        """.utf8)
        let profiles = Profiles.decode(json, home: home)
        #expect(profiles.map(\.id) == ["work"])
        #expect(profiles[0].name == "Work")
    }

    @Test func testUnusableConfigFallsBackToTheDefaultProfile() {
        for raw in ["[]", "not json", #"{"id": "work"}"#] {
            let profiles = Profiles.decode(Data(raw.utf8), home: home)
            #expect(profiles.map(\.id) == ["default"], Comment(rawValue: raw))
            #expect(profiles[0].configuration == .anthropic(
                keychainService: "Claude Code-credentials",
                configPath: "/Users/example/.claude.json"))
        }
    }

    @Test func testDuplicateIdsAreGlobalAcrossProviders() {
        let json = Data("""
        [
         {"id": "work"},
         {"id": "work", "provider": "openai"}
        ]
        """.utf8)

        let profiles = Profiles.decode(json, home: home)

        #expect(profiles.count == 1)
        #expect(profiles[0].provider == .anthropic)
    }

    @Test func testConfigPathHonoursXDGConfigHome() {
        let plain = Profiles.configURL(home: home, environment: [:]).path
        #expect(plain == "/Users/example/.config/llm-usage-bar/profiles.json")

        let xdg = Profiles.configURL(home: home,
                                     environment: ["XDG_CONFIG_HOME": "~/somewhere"]).path
        #expect(xdg == "/Users/example/somewhere/llm-usage-bar/profiles.json")
    }

    @Test func testConfigPathFallsBackToTheLegacyDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let configDir = root.appendingPathComponent("config")
        let legacyDir = configDir.appendingPathComponent("claude-usage-bar")
        try fileManager.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let legacy = legacyDir.appendingPathComponent("profiles.json")
        try Data("[]".utf8).write(to: legacy)

        let url = Profiles.configURL(home: root.path,
                                     environment: ["XDG_CONFIG_HOME": configDir.path],
                                     fileManager: fileManager)
        #expect(url.path == legacy.path)
    }

    @Test func testConfigPathPrefersTheCanonicalDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let configDir = root.appendingPathComponent("config")
        let canonicalDir = configDir.appendingPathComponent("llm-usage-bar")
        let legacyDir = configDir.appendingPathComponent("claude-usage-bar")
        try fileManager.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let canonical = canonicalDir.appendingPathComponent("profiles.json")
        try Data("[]".utf8).write(to: canonical)
        try Data("[]".utf8).write(to: legacyDir.appendingPathComponent("profiles.json"))

        let url = Profiles.configURL(home: root.path,
                                     environment: ["XDG_CONFIG_HOME": configDir.path],
                                     fileManager: fileManager)
        #expect(url.path == canonical.path)
    }

    @Test func testParseLeavesUnusableJSONToTheCaller() {
        #expect(Profiles.parse(Data("not json".utf8), home: home) == nil)
        #expect(Profiles.parse(Data(#"{"id":"work"}"#.utf8), home: home) == nil)
        #expect(Profiles.parse(Data("[]".utf8), home: home)?.map(\.id) == ["default"])
    }

    @Test func testReconcileKeepsTheActiveAccountWhenItStillExists() {
        let current = Profiles.decode(Data("""
        [{"id":"claude"},{"id":"grok","provider":"xai"}]
        """.utf8), home: home)
        let loaded = Profiles.decode(Data("""
        [{"id":"grok","name":"Grok personal","provider":"xai"},{"id":"claude"}]
        """.utf8), home: home)

        let reload = Profiles.reconcile(loaded: loaded, current: current, activeID: "grok")

        #expect(reload?.activeID == "grok")
        #expect(reload?.profiles.map(\.name) == ["Grok personal", "Claude"])
        #expect(reload?.staleIDs == [])
    }

    @Test func testReconcileMovesOffARemovedActiveAccount() {
        let current = Profiles.decode(Data("""
        [{"id":"claude"},{"id":"grok","provider":"xai"}]
        """.utf8), home: home)
        let loaded = Profiles.decode(Data(#"[{"id":"claude"}]"#.utf8), home: home)

        let reload = Profiles.reconcile(loaded: loaded, current: current, activeID: "grok")

        #expect(reload?.activeID == "claude")
        #expect(reload?.staleIDs == ["grok"])
    }

    @Test func testReconcileDropsCacheWhenConfigurationChanges() {
        let current = Profiles.decode(Data("""
        [{"id":"grok","provider":"xai","grokHome":"~/.grok"}]
        """.utf8), home: home)
        let loaded = Profiles.decode(Data("""
        [{"id":"grok","provider":"xai","grokHome":"~/.grok-work"}]
        """.utf8), home: home)

        let reload = Profiles.reconcile(loaded: loaded, current: current, activeID: "grok")

        #expect(reload?.staleIDs == ["grok"])
        #expect(reload?.activeID == "grok")
    }

    @Test func testReconcileIgnoresAnUnchangedCatalog() {
        let profiles = Profiles.decode(Data(#"[{"id":"claude"}]"#.utf8), home: home)
        #expect(Profiles.reconcile(loaded: profiles, current: profiles, activeID: "claude") == nil)
    }

    @Test func testReadForReloadKeepsUnusableJSONFromReplacingAccounts() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let configDir = root.appendingPathComponent("config")
        try? fileManager.createDirectory(at: configDir.appendingPathComponent("llm-usage-bar"),
                                         withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let url = Profiles.configURL(home: root.path, environment: ["XDG_CONFIG_HOME": configDir.path])
        try? Data("{".utf8).write(to: url)

        #expect(Profiles.readForReload(home: root.path,
                                       environment: ["XDG_CONFIG_HOME": configDir.path],
                                       fileManager: fileManager) == nil)
    }
}
