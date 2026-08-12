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
        #expect(profiles[0].keychainService == "Claude Code-credentials")
        #expect(profiles[0].configPath == "/Users/example/.claude.json")
        #expect(profiles[1].keychainService == "Claude Code-credentials-abc12345")
        #expect(profiles[1].configPath == "/Users/example/.claude-work/.claude.json")
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
            #expect(profiles[0].keychainService == "Claude Code-credentials")
            #expect(profiles[0].configPath == "/Users/example/.claude.json")
        }
    }

    @Test func testConfigPathHonoursXDGConfigHome() {
        let plain = Profiles.configURL(home: home, environment: [:]).path
        #expect(plain == "/Users/example/.config/claude-usage-bar/profiles.json")

        let xdg = Profiles.configURL(home: home,
                                     environment: ["XDG_CONFIG_HOME": "~/somewhere"]).path
        #expect(xdg == "/Users/example/somewhere/claude-usage-bar/profiles.json")
    }
}
