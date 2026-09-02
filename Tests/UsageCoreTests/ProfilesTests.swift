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

    @Test func testMixedProvidersDecodeInConfiguredOrder() {
        let json = Data("""
        [
         {"id": "claude", "name": "Claude"},
         {"id": "codex", "name": "Codex", "provider": "openai"},
         {"id": "codex-work", "name": "Work", "provider": "OPENAI",
          "codexHome": "~/.codex-work", "codexPath": "~/.local/bin/codex"}
        ]
        """.utf8)

        let profiles = Profiles.decode(json, home: home)

        #expect(profiles.map(\.id) == ["claude", "codex", "codex-work"])
        #expect(profiles.map(\.provider) == [.anthropic, .openAI, .openAI])
        #expect(profiles[1].configuration == .openAI(
            codexHome: "/Users/example/.codex", codexPath: nil))
        #expect(profiles[2].configuration == .openAI(
            codexHome: "/Users/example/.codex-work",
            codexPath: "/Users/example/.local/bin/codex"))
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
        #expect(plain == "/Users/example/.config/claude-usage-bar/profiles.json")

        let xdg = Profiles.configURL(home: home,
                                     environment: ["XDG_CONFIG_HOME": "~/somewhere"]).path
        #expect(xdg == "/Users/example/somewhere/claude-usage-bar/profiles.json")
    }
}
