import Foundation
import Testing
@testable import UsageCore

private let accountResponse = Data("""
{"id":1,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"plus"},"requiresOpenaiAuth":true}}
""".utf8)

private let rateLimitsResponse = Data("""
{
 "id": 2,
 "result": {
  "rateLimits": {
   "limitId": "codex",
   "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1788309000},
   "secondary": {"usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1788913800}
  },
  "rateLimitsByLimitId": {
   "codex_other": {
    "limitId": "codex_other", "limitName": "Other models",
    "primary": {"usedPercent": 42, "windowDurationMins": 60, "resetsAt": 1788312600},
    "secondary": null,
    "futureField": true
   },
   "codex": {
    "limitId": "codex", "limitName": null,
    "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1788309000},
    "secondary": {"usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1788913800}
   }
  },
  "accountId": "acct_fixture",
  "rateLimitUpsell": null
 }
}
""".utf8)

@Suite struct CodexAccountTests {
    @Test func testChatGPTAccountLabelIncludesPlan() throws {
        let account = try codexAccount(from: accountResponse)
        #expect(account.label == "user@example.com · Plus")
    }

    @Test func testSignedOutAccountIsActionable() {
        let response = Data(#"{"id":1,"result":{"account":null,"requiresOpenaiAuth":true}}"#.utf8)
        #expect(throws: CodexUsageError.notAuthenticated) {
            try codexAccount(from: response)
        }
    }

    @Test func testAPIKeyAccountDoesNotPretendToHavePlanLimits() {
        let response = Data(#"{"id":1,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}"#.utf8)
        #expect(throws: CodexUsageError.apiKeyUnsupported) {
            try codexAccount(from: response)
        }
    }
}

@Suite struct CodexRateLimitTests {
    @Test func testMultipleBucketsBecomeOrderedSharedWindows() throws {
        let snapshot = try codexUsageSnapshot(from: rateLimitsResponse)

        #expect(snapshot.windows.map(\.id) == [
            "openai.codex.primary",
            "openai.codex.secondary",
            "openai.codex_other.primary"
        ])
        #expect(snapshot.windows.map(\.label) == [
            "5h window", "Weekly", "Other models · 1h window"
        ])
        #expect(snapshot.primaryWindow?.utilization == 25)
        #expect(snapshot.windows[1].durationMinutes == 10_080)
        #expect(snapshot.windows[2].resetsAt == Date(timeIntervalSince1970: 1788312600))
    }

    @Test func testLegacyBucketIsUsedWhenMapIsEmpty() throws {
        let response = Data("""
        {"id":2,"result":{"rateLimits":{
          "limitId":"codex","primary":{"usedPercent":73}
        },"rateLimitsByLimitId":{}}}
        """.utf8)

        let snapshot = try codexUsageSnapshot(from: response)

        #expect(snapshot.windows.count == 1)
        #expect(snapshot.primaryWindow?.utilization == 73)
        #expect(snapshot.primaryWindow?.label == "Usage window")
    }

    @Test func testResponseWithoutAnyWindowsIsRejected() {
        let response = Data(#"{"id":2,"result":{"rateLimits":{"limitId":"codex"}}}"#.utf8)
        #expect(throws: CodexUsageError.invalidResponse) {
            try codexUsageSnapshot(from: response)
        }
    }

    @Test func testRPCErrorIsPreservedWithoutRawPayloadLogging() {
        let response = Data(#"{"id":2,"error":{"code":-32600,"message":"Authentication required"}}"#.utf8)
        #expect(throws: CodexUsageError.server("Authentication required")) {
            try codexUsageSnapshot(from: response)
        }
    }
}

@Suite struct CodexExecutableTests {
    @Test func testConfiguredPathWinsWithoutShellExpansion() {
        let candidates = CodexAppServer.executableCandidates(
            configuredPath: "/path/to/codex",
            environment: ["PATH": "/ignored"],
            home: "/Users/example")
        #expect(candidates == ["/path/to/codex"])
    }

    @Test func testFinderSafeCandidatesIncludeHomeAndStandardLocations() {
        let candidates = CodexAppServer.executableCandidates(
            configuredPath: nil,
            environment: ["PATH": "/custom/bin:/usr/bin"],
            home: "/Users/example")
        #expect(candidates == [
            "/custom/bin/codex",
            "/usr/bin/codex",
            "/Users/example/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])
    }

    @Test func testRelativePathEntriesAreNotExecutableCandidates() {
        let candidates = CodexAppServer.executableCandidates(
            configuredPath: nil,
            environment: ["PATH": ".:bin:/usr/bin"],
            home: "/Users/example")
        #expect(!candidates.contains("./codex"))
        #expect(!candidates.contains("bin/codex"))
        #expect(candidates.first == "/usr/bin/codex")
    }
}

@Suite struct CodexAppServerTests {
    @Test func testFetchUsesConfiguredHomeAndAppServerProtocol() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let codexHome = root.appendingPathComponent("codex-home")
        let executable = root.appendingPathComponent("codex-fixture")
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fixture = """
        #!/bin/sh
        if [ "${CODEX_ACCESS_TOKEN+x}" = x ] || [ "${CODEX_SQLITE_HOME+x}" = x ]; then
          exit 9
        fi
        while IFS= read -r line; do
          case "$line" in
            *'"initialize"'*)
              printf '%s\n' '{"id":0,"result":{"codexHome":"\(codexHome.path)"}}'
              ;;
            *'"account/read"'*)
              printf '%s\n' '{"id":1,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"plus"}}}'
              ;;
            *'"account/rateLimits/read"'*)
              printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1788217200}}}}'
              ;;
          esac
        done
        """
        try Data(fixture.utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let profile = Profile(
            id: "codex",
            name: "Codex",
            configuration: .openAI(codexHome: codexHome.path, codexPath: executable.path))
        let result = try await CodexAppServer.fetch(
            profile,
            environment: [
                "PATH": "/usr/bin:/bin",
                "CODEX_ACCESS_TOKEN": "must-not-be-inherited",
                "CODEX_SQLITE_HOME": "/tmp/must-not-be-used"
            ],
            timeout: 5)

        #expect(result.account.label == "user@example.com · Plus")
        #expect(result.usage.primaryWindow?.label == "5h window")
        #expect(result.usage.primaryWindow?.utilization == 12)
    }

    @Test func testEarlyExitIsARegularAppServerError() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let codexHome = root.appendingPathComponent("codex-home")
        let executable = root.appendingPathComponent("codex-fixture")
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("#!/bin/sh\nexit 7\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: executable.path)
        let profile = Profile(
            id: "codex",
            name: "Codex",
            configuration: .openAI(codexHome: codexHome.path, codexPath: executable.path))

        do {
            _ = try await CodexAppServer.fetch(
                profile, environment: ["PATH": "/usr/bin:/bin"], timeout: 5)
            Issue.record("Expected the exited fixture to fail")
        } catch {
            #expect(error is CodexAppServerError)
        }
    }
}
