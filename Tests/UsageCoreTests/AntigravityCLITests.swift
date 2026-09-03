import Foundation
import Testing
@testable import UsageCore

@Suite struct AntigravityCLIQuotaTests {
    /// Verbatim output of `agy -p /quota`: group, metric, remaining, reset.
    private let real = """
    Gemini Models\tWeekly Limit Remaining\t0%\t2026-09-10T12:46:51Z
    Claude and GPT models\tWeekly Limit Remaining\t0%\t2026-09-10T13:11:35Z
    """

    @Test func testGroupsBecomeWeeklyWindows() throws {
        let snapshot = try #require(AntigravityCLI.parseQuota(real))

        #expect(snapshot.windows.map(\.label)
            == ["Gemini Models", "Claude and GPT models"])
        #expect(snapshot.windows.map(\.id)
            == ["antigravity.gemini-models", "antigravity.claude-and-gpt-models"])
        #expect(snapshot.windows.allSatisfy { $0.durationMinutes == 7 * 24 * 60 })
        #expect(snapshot.windows[0].resetsAt
            == UsageDate.parse("2026-09-10T12:46:51Z"))
    }

    /// The CLI prints what is left, the bar shows what is used.
    @Test func testRemainingIsInvertedIntoUtilization() throws {
        let snapshot = try #require(AntigravityCLI.parseQuota("""
        Gemini Models\tWeekly Limit Remaining\t62.5%\t2026-09-10T12:46:51Z
        Claude and GPT models\tWeekly Limit Remaining\t100%\t2026-09-10T13:11:35Z
        """))

        #expect(snapshot.windows[0].utilization == 37.5)
        #expect(snapshot.windows[1].utilization == 0)
    }

    @Test func testTheHeaviestGroupDrivesTheMenuBar() throws {
        let snapshot = try #require(AntigravityCLI.parseQuota("""
        Gemini Models\tWeekly Limit Remaining\t80%\t2026-09-10T12:46:51Z
        Claude and GPT models\tWeekly Limit Remaining\t5%\t2026-09-10T13:11:35Z
        """))

        #expect(snapshot.primaryWindow?.label == "Claude and GPT models")
        #expect(snapshot.windows.filter(\.isPrimary).count == 1)
    }

    @Test func testExhaustedQuotaIsFullNotEmpty() throws {
        let snapshot = try #require(AntigravityCLI.parseQuota(real))
        #expect(snapshot.windows.allSatisfy { $0.utilization == 100 })
        #expect(snapshot.primaryWindow?.label == "Gemini Models")
    }

    @Test func testPrintModeNoiseIsSkipped() throws {
        let snapshot = try #require(AntigravityCLI.parseQuota("""
        Fetching quota...
        Gemini Models\tWeekly Limit Remaining\t10%\t2026-09-10T12:46:51Z
        \t\t
        Some Group\tWeekly Limit Remaining\tunknown
        """))

        #expect(snapshot.windows.map(\.label) == ["Gemini Models"])
    }

    @Test func testAMissingResetStillProducesAWindow() throws {
        let snapshot = try #require(
            AntigravityCLI.parseQuota("Gemini Models\tWeekly Limit Remaining\t40%"))
        #expect(snapshot.windows[0].utilization == 60)
        #expect(snapshot.windows[0].resetsAt == nil)
    }

    @Test func testNothingParseableIsNoSnapshot() {
        #expect(AntigravityCLI.parseQuota("") == nil)
        #expect(AntigravityCLI.parseQuota("not a quota table") == nil)
        #expect(AntigravityCLI.parseQuota("Group\tMetric\t\t2026-09-10T12:46:51Z") == nil)
    }

    /// A machine row always uses a dot, whatever the reader's locale is.
    @Test func testPercentagesAreLocaleIndependent() {
        #expect(AntigravityCLI.percentage("12.5%") == 12.5)
        #expect(AntigravityCLI.percentage("0%") == 0)
        #expect(AntigravityCLI.percentage("100 %") == 100)  // a space is tolerated
        #expect(AntigravityCLI.percentage("12,5%") == nil)
        #expect(AntigravityCLI.percentage("12.5") == nil)
    }
}

@Suite struct AntigravityCLIProcessTests {
    /// The CLI always reads `$HOME/.gemini`, so isolation is the parent
    /// directory. Anything else must fail loudly instead of silently
    /// reporting the default account's quota.
    @Test func testIsolationComesFromTheParentOfAGeminiDirectory() {
        #expect(AntigravityCLI.processHome(forGeminiHome: "/Users/example/.gemini")
            == "/Users/example")
        #expect(AntigravityCLI.processHome(
            forGeminiHome: "/Users/example/accounts/work/.gemini")
            == "/Users/example/accounts/work")
        #expect(AntigravityCLI.processHome(forGeminiHome: "/Users/example/.gemini-work") == nil)
        #expect(AntigravityCLI.processHome(forGeminiHome: "/Users/example") == nil)
    }

    @Test func testUnisolatableHomeIsAnActionableError() {
        let message = AntigravityCLIError
            .unisolatableHome("/Users/example/.gemini-work").errorDescription
        #expect(message?.contains("/Users/example/.gemini-work") == true)
        #expect(message?.contains("$HOME/.gemini") == true)
    }

    @Test func testCandidatesCoverTheUsualInstallLocations() {
        let candidates = AntigravityCLI.candidates(
            environment: ["PATH": "/usr/local/bin"], home: "/Users/example")

        #expect(candidates.contains("/usr/local/bin/agy"))
        #expect(candidates.contains("/Users/example/.local/bin/agy"))
        #expect(candidates.contains("/opt/homebrew/bin/agy"))
        #expect(candidates.contains("/Users/example/.local/bin/antigravity"))
    }

    @Test func testAConfiguredPathThatIsNotExecutableIsNotAccepted() {
        #expect(AntigravityCLI.resolveExecutable(
            configuredPath: "/nonexistent/agy",
            environment: ["PATH": "/nonexistent"],
            home: "/Users/example") == nil)
    }

    @Test func testResolutionFindsAnExecutableCandidate() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let agy = bin.appendingPathComponent("agy")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: agy)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: agy.path)

        #expect(AntigravityCLI.resolveExecutable(
            environment: ["PATH": bin.path, "XDG_DATA_HOME": "/nonexistent"],
            home: root.path) == agy.path)
    }

    @Test func testFetchRefusesAHomeThatDoesNotExist() async {
        let profile = Profile(
            id: "ag", name: "Antigravity",
            configuration: .antigravity(geminiHome: "/nonexistent/.gemini",
                                        cliPath: "/bin/echo"))
        await #expect(throws: AntigravityCLIError.missingHome("/nonexistent/.gemini")) {
            try await AntigravityCLI.fetch(profile, executable: "/bin/echo",
                                           environment: [:], timeout: 5)
        }
    }

    @Test func testFetchParsesWhatTheCLIPrints() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let geminiHome = root.appendingPathComponent(".gemini")
        try fileManager.createDirectory(at: geminiHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let stub = root.appendingPathComponent("agy")
        try Data("""
        #!/bin/sh
        printf 'Gemini Models\\tWeekly Limit Remaining\\t25%%\\t2026-09-10T12:46:51Z\\n'
        printf 'Claude and GPT models\\tWeekly Limit Remaining\\t90%%\\t2026-09-10T13:11:35Z\\n'
        """.utf8).write(to: stub)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: stub.path)

        let profile = Profile(
            id: "ag", name: "Antigravity",
            configuration: .antigravity(geminiHome: geminiHome.path,
                                        cliPath: stub.path))
        let snapshot = try await AntigravityCLI.fetch(profile, environment: [:],
                                                      timeout: 15)

        #expect(snapshot.windows.map(\.utilization) == [75, 10])
        #expect(snapshot.primaryWindow?.label == "Gemini Models")
    }

    @Test func testANonZeroExitIsReported() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let geminiHome = root.appendingPathComponent(".gemini")
        try fileManager.createDirectory(at: geminiHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let stub = root.appendingPathComponent("agy")
        try Data("#!/bin/sh\nexit 3\n".utf8).write(to: stub)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: stub.path)

        let profile = Profile(
            id: "ag", name: "Antigravity",
            configuration: .antigravity(geminiHome: geminiHome.path,
                                        cliPath: stub.path))
        await #expect(throws: AntigravityCLIError.exited(3)) {
            try await AntigravityCLI.fetch(profile, environment: [:], timeout: 15)
        }
    }
}
