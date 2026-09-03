import Foundation
import Testing
@testable import UsageCore

@Suite struct AppSettingsTests {
    private let home = "/Users/example"

    @Test func testDefaultsWhenThereIsNoFile() {
        let settings = AppSettings.load(home: home,
                                        environment: ["XDG_CONFIG_HOME": "/nonexistent"])
        #expect(settings.refreshSeconds == 120)
    }

    @Test func testRefreshSecondsIsRead() {
        #expect(AppSettings.decode(Data(#"{"refreshSeconds": 300}"#.utf8))
            .refreshSeconds == 300)
    }

    /// The usage endpoint rate-limits on a rolling window, so a value under
    /// the per-account throttle is clamped instead of honored.
    @Test func testAnAggressiveIntervalIsClampedToTheFloor() {
        #expect(AppSettings.decode(Data(#"{"refreshSeconds": 5}"#.utf8))
            .refreshSeconds == 60)
        #expect(AppSettings.decode(Data(#"{"refreshSeconds": 0}"#.utf8))
            .refreshSeconds == 60)
        #expect(AppSettings.decode(Data(#"{"refreshSeconds": -30}"#.utf8))
            .refreshSeconds == 60)
        #expect(AppSettings(refreshSeconds: 60).refreshSeconds == 60)
    }

    /// The same floor and ceiling apply to a per-account override.
    @Test func testTheClampIsSharedWithPerAccountOverrides() {
        #expect(AppSettings.clamp(5) == 60)
        #expect(AppSettings.clamp(300) == 300)
        #expect(AppSettings.clamp(99999) == 3600)
    }

    @Test func testAnIdleIntervalIsCappedAtAnHour() {
        #expect(AppSettings.decode(Data(#"{"refreshSeconds": 86400}"#.utf8))
            .refreshSeconds == 3600)
    }

    @Test func testUnusableOrUnknownContentKeepsTheDefaults() {
        #expect(AppSettings.decode(Data("not json".utf8)).refreshSeconds == 120)
        #expect(AppSettings.decode(Data("{}".utf8)).refreshSeconds == 120)
        #expect(AppSettings.decode(Data(#"{"somethingElse": 1}"#.utf8))
            .refreshSeconds == 120)
        #expect(AppSettings.decode(Data(#"{"refreshSeconds": "fast"}"#.utf8))
            .refreshSeconds == 120)
    }

    @Test func testTheFileSitsBesideProfiles() {
        let path = AppSettings.url(home: home, environment: [:]).path
        #expect(path == "/Users/example/.config/llm-usage-bar/config.json")
    }

    @Test func testItFollowsTheLegacyDirectoryWhenTheCatalogIsThere() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent("claude-usage-bar")
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try Data("[]".utf8).write(to: legacy.appendingPathComponent("profiles.json"))

        let url = AppSettings.url(home: root.path,
                                  environment: ["XDG_CONFIG_HOME": root.path],
                                  fileManager: fileManager)
        #expect(url.path == legacy.appendingPathComponent("config.json").path)
    }
}
