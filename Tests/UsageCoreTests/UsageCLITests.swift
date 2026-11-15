import Foundation
import Testing
@testable import UsageCore

@Suite struct UsageCLITests {
    private func profile(_ id: String, name: String = "Work") -> Profile {
        Profile(id: id, name: name, configuration: .openAI(codexHome: "/unused", codexPath: nil))
    }

    @Test func arguments() throws {
        #expect(try !UsageCLI.Options(arguments: []).json)
        #expect(try UsageCLI.Options(arguments: ["--json"]).json)
        #expect(try UsageCLI.Options(arguments: ["-h"]).help)
        #expect(throws: (any Error).self) { try UsageCLI.Options(arguments: ["--unknown"]) }
    }

    @Test func partialFailureKeepsEveryAccountAndNeverPrintsRawError() async throws {
        let report = await UsageCLI.collect(profiles: [profile("first"), profile("bad"), profile("last")]) { profile in
            if profile.id == "bad" {
                throw NSError(domain: "secret-payload", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "secret-token"])
            }
            return UsageSnapshot(windows: [
                UsageWindow(id: "weekly", label: "Weekly", utilization: 123.5,
                            resetsAt: UsageDate.parse("2026-11-15T21:00:00Z"), isPrimary: true),
                UsageWindow(id: "model", label: "Model", utilization: 0, resetsAt: nil, isPrimary: false)
            ])
        }
        #expect(report.hasErrors)
        #expect(report.accounts.map(\.id) == ["first", "bad", "last"])
        let json = try report.json()
        #expect(!json.contains("secret"))
        #expect(!json.contains("/unused"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let accounts = try #require(object["accounts"] as? [[String: Any]])
        let windows = try #require(accounts[0]["windows"] as? [[String: Any]])
        #expect(windows[0]["percentUsed"] as? Double == 123.5)
        #expect(windows[0]["resetsAt"] as? String == "2026-11-15T21:00:00Z")
        #expect(windows[1]["resetsAt"] is NSNull)
        #expect(accounts[1]["error"] != nil)
        let table = report.table(locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(table.contains("123.5%"))
        #expect(table.contains("Weekly"))
        #expect(table.contains("11/15/26"))
        #expect(table.contains("Error:"))
    }

    @Test func tableUsesLocaleAndSanitizesLabels() async {
        let report = await UsageCLI.collect(profiles: [profile("work", name: "Work\n\u{1b}label")]) { _ in
            UsageSnapshot(windows: [UsageWindow(id: "week", label: "Weekly", utilization: 12.5,
                                                resetsAt: nil, isPrimary: true)])
        }
        let table = report.table(locale: Locale(identifier: "pt_BR"))
        #expect(table.contains("12,5%"))
        #expect(table.split(separator: "\n").count == 2)
        #expect(!table.contains("\u{1b}"))
        #expect(!report.hasErrors)
    }

    @Test func nonFinitePercentBecomesAccountError() async throws {
        let report = await UsageCLI.collect(profiles: [profile("work")]) { _ in
            UsageSnapshot(windows: [UsageWindow(id: "week", label: "Weekly", utilization: .nan,
                                                resetsAt: nil, isPrimary: true)])
        }
        #expect(report.hasErrors)
        #expect(try report.json().contains("invalid usage response"))
    }

    @Test func emptySnapshotStillHasAnAccountRow() async {
        let report = await UsageCLI.collect(profiles: [profile("work")]) { _ in UsageSnapshot(windows: []) }
        #expect(report.table().contains("No usage windows"))
    }

    @Test func keychainPayloadAndSafeHTTPFailures() {
        #expect(UsageCLIFetcher.accessToken(from: Data(#"{"claudeAiOauth":{"accessToken":"example-token"}}"#.utf8)) == "example-token")
        #expect(UsageCLIFetcher.accessToken(from: Data(#"{"claudeAiOauth":{"accessToken":" "}}"#.utf8)) == nil)
        #expect(UsageCLIFetcher.accessToken(from: Data("invalid".utf8)) == nil)
        #expect(UsageCLI.safeError(CLIError.http(429)).contains("Rate limited"))
        #expect(UsageCLI.safeError(CLIError.http(401)).contains("Authentication failed"))
    }

    @Test func adapterOverrideIsUsedForBuiltInProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = root.appendingPathComponent("adapter")
        try Data("""
        #!/bin/sh
        printf '%s\\n' '{"windows":[{"label":"Daily","utilization":7}]}'
        """.utf8).write(to: adapter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adapter.path)
        let profile = Profile(id: "work", name: "Work",
                              configuration: .openAI(codexHome: root.path, codexPath: "/unused"),
                              adapter: adapter.path)
        let report = await UsageCLI.collect(profiles: [profile])
        #expect(!report.hasErrors)
        #expect(report.accounts.first?.windows.first?.percentUsed == 7)
    }
}
