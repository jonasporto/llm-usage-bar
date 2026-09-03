import Foundation
import Testing
@testable import UsageCore

@Suite struct CommandUsageParsingTests {
    @Test func testAdapterPayloadBecomesSharedSnapshot() throws {
        let data = Data("""
        {
         "account": "user@example.com · Pro",
         "windows": [
          {"id": "primary", "label": "Weekly", "utilization": 42,
           "resetsAt": "2026-09-10T14:00:00Z", "durationMinutes": 10080, "isPrimary": true},
          {"label": "Daily", "utilization": 10}
         ],
         "extraUsage": {"isEnabled": true, "usedCredits": 123, "currency": "USD", "decimalPlaces": 2}
        }
        """.utf8)

        let parsed = try CommandAdapter.usageSnapshot(from: data)
        #expect(parsed.account == "user@example.com · Pro")
        #expect(parsed.usage.windows.map(\.label) == ["Weekly", "Daily"])
        #expect(parsed.usage.primaryWindow?.utilization == 42)
        #expect(parsed.usage.windows[1].id == "adapter.1")
        #expect(parsed.usage.extraUsage?.is_enabled == true)
        #expect(parsed.usage.extraUsage?.used_credits == 123)
    }

    /// A declared primary must win even when it is not the first window: the
    /// per-window default used to make the first window primary as well, and
    /// the popover then showed the wrong model's gauge.
    @Test func testADeclaredPrimaryWinsOverTheFirstWindow() throws {
        let data = Data("""
        {
         "windows": [
          {"id": "gemini", "label": "Gemini Models", "utilization": 64},
          {"id": "claude-gpt", "label": "Claude and GPT models",
           "utilization": 88, "isPrimary": true}
         ]
        }
        """.utf8)

        let parsed = try CommandAdapter.usageSnapshot(from: data)

        #expect(parsed.usage.primaryWindow?.label == "Claude and GPT models")
        #expect(parsed.usage.windows.filter(\.isPrimary).count == 1)
    }

    @Test func testTheFirstWindowLeadsWhenNoneIsDeclared() throws {
        let data = Data("""
        {"windows": [{"label": "5h window", "utilization": 20},
                     {"label": "Weekly", "utilization": 70}]}
        """.utf8)

        let parsed = try CommandAdapter.usageSnapshot(from: data)

        #expect(parsed.usage.primaryWindow?.label == "5h window")
        #expect(parsed.usage.windows.filter(\.isPrimary).count == 1)
    }

    @Test func testEmptyWindowsAreRejectedWithoutTheRawPayload() {
        #expect(throws: CommandAdapterError.invalidResponse) {
            _ = try CommandAdapter.usageSnapshot(from: Data(#"{"windows":[]}"#.utf8))
        }
    }
}

@Suite struct CommandAdapterFetchTests {
    @Test func testFetchRunsTheAdapterWithHomeAndProvider() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let home = root.appendingPathComponent("provider-home")
        let executable = root.appendingPathComponent("usage-adapter")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fixture = """
        #!/bin/sh
        test "$1" = --home || exit 2
        test "$2" = "\(home.path)" || exit 3
        test "$LLM_USAGE_HOME" = "\(home.path)" || exit 4
        test "$LLM_USAGE_PROVIDER" = minimax || exit 5
        printf '%s\\n' '{"account":"mini@example.com","windows":[{"label":"Weekly","utilization":7}]}'
        """
        try Data(fixture.utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let profile = Profile(
            id: "mini",
            name: "MiniMax",
            configuration: .command(home: home.path, executable: executable.path),
            provider: .custom("minimax"),
            home: home.path)
        let result = try await CommandAdapter.fetch(
            profile, environment: ["PATH": "/usr/bin:/bin"], timeout: 5)

        #expect(result.account == "mini@example.com")
        #expect(result.usage.primaryWindow?.utilization == 7)
    }

    @Test func testNonZeroExitIsARegularError() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let home = root.appendingPathComponent("provider-home")
        let executable = root.appendingPathComponent("usage-adapter")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("#!/bin/sh\nexit 9\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: executable.path)
        let profile = Profile(
            id: "mini",
            name: "MiniMax",
            configuration: .command(home: home.path, executable: executable.path),
            provider: .custom("minimax"),
            home: home.path)

        do {
            _ = try await CommandAdapter.fetch(
                profile, environment: ["PATH": "/usr/bin:/bin"], timeout: 5)
            Issue.record("Expected the exited fixture to fail")
        } catch {
            #expect(error is CommandAdapterError)
        }
    }
}
