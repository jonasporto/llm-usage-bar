import Foundation
import Testing
@testable import UsageCore

private let billingPayload = Data("""
{
 "config": {
  "currentPeriod": {
   "type": "USAGE_PERIOD_TYPE_WEEKLY",
   "start": "2026-08-27T14:22:27.529721+00:00",
   "end": "2026-09-03T14:22:27.529721+00:00"
  },
  "creditUsagePercent": 1.0,
  "onDemandCap": {"val": 0},
  "onDemandUsed": {"val": 0},
  "productUsage": [{"product": "GrokBuild", "usagePercent": 1.0}],
  "billingPeriodStart": "2026-08-27T14:22:27.529721+00:00",
  "billingPeriodEnd": "2026-09-03T14:22:27.529721+00:00"
 }
}
""".utf8)

private let userPayload = Data("""
{"email":"user@example.com","subscriptionTier":"XPremium","hasGrokCodeAccess":true}
""".utf8)

private func authJSON(issuer: String = "https://auth.x.ai::abc12345",
                      token: String = "test-token",
                      email: String = "user@example.com",
                      expiresAt: String = "2026-09-10T00:00:00Z") -> Data {
    Data("""
    {"\(issuer)":{"key":"\(token)","email":"\(email)","expires_at":"\(expiresAt)","auth_mode":"oidc"}}
    """.utf8)
}

@Suite struct GrokBillingTests {
    @Test func testWeeklyCreditsBecomeThePrimaryWindow() throws {
        let snapshot = try grokUsageSnapshot(from: billingPayload)

        #expect(snapshot.windows.map(\.id) == ["xai.primary"])
        #expect(snapshot.windows.map(\.label) == ["Weekly"])
        #expect(snapshot.primaryWindow?.utilization == 1)
        #expect(snapshot.primaryWindow?.durationMinutes == 10_080)
        #expect(snapshot.primaryWindow?.resetsAt == UsageDate.parse("2026-09-03T14:22:27.529721+00:00"))
        #expect(snapshot.extraUsage == nil)
    }

    @Test func testProductBreakdownIsNotASeparateQuotaWindow() throws {
        let snapshot = try grokUsageSnapshot(from: billingPayload)
        #expect(snapshot.windows.count == 1)
        #expect(!snapshot.windows.contains(where: { $0.label.contains("GrokBuild") }))
    }

    @Test func testUnwrappedConfigIsAccepted() throws {
        let payload = Data("""
        {"creditUsagePercent": 42, "currentPeriod": {
          "type": "USAGE_PERIOD_TYPE_MONTHLY",
          "start": "2026-08-01T00:00:00Z",
          "end": "2026-09-01T00:00:00Z"
        }}
        """.utf8)

        let snapshot = try grokUsageSnapshot(from: payload)
        #expect(snapshot.primaryWindow?.label == "Monthly")
        #expect(snapshot.primaryWindow?.utilization == 42)
    }

    @Test func testMissingPercentWithAPeriodIsZeroUsage() throws {
        let payload = Data("""
        {"config":{"currentPeriod":{
          "type":"USAGE_PERIOD_TYPE_WEEKLY",
          "end":"2026-09-03T00:00:00Z"
        }}}
        """.utf8)

        let snapshot = try grokUsageSnapshot(from: payload)
        #expect(snapshot.primaryWindow?.utilization == 0)
        #expect(snapshot.primaryWindow?.label == "Weekly")
    }

    @Test func testOnDemandCreditsMapToExtraUsage() throws {
        let payload = Data("""
        {"config":{
          "creditUsagePercent": 80,
          "currentPeriod": {"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-09-03T00:00:00Z"},
          "onDemandUsed": {"val": 12345},
          "onDemandCap": {"val": 50000}
        }}
        """.utf8)

        let snapshot = try grokUsageSnapshot(from: payload)
        #expect(snapshot.extraUsage?.is_enabled == true)
        #expect(snapshot.extraUsage?.used_credits == 12345)
        #expect(snapshot.extraUsage?.monthly_limit == 50000)
        #expect(snapshot.extraUsage?.currency == "USD")
    }

    @Test func testEmptyBillingIsRejected() {
        #expect(throws: GrokUsageError.invalidResponse) {
            try grokUsageSnapshot(from: Data("{}".utf8))
        }
    }
}

@Suite struct GrokAccountTests {
    @Test func testSubscriptionTierBecomesAReadablePlan() throws {
        let account = try grokAccount(from: userPayload)
        #expect(account.label == "user@example.com · X Premium")
    }

    @Test func testKnownPlanLabels() {
        #expect(grokPlanLabel("XPremium") == "X Premium")
        #expect(grokPlanLabel("SuperGrokHeavy") == "SuperGrok Heavy")
        #expect(grokPlanLabel("SuperGrok") == "SuperGrok")
        #expect(grokPlanLabel("x_premium_plus") == "X Premium+")
    }
}

@Suite struct GrokAuthTests {
    let now = UsageDate.parse("2026-09-02T12:00:00Z")!

    @Test func testPrefersAuthXAIAndIgnoresExpiredSiblings() throws {
        let json = Data("""
        {
         "https://accounts.x.ai/sign-in": {
          "key": "legacy-token", "email": "old@example.com",
          "expires_at": "2026-09-10T00:00:00Z"
         },
         "https://auth.x.ai::abc12345": {
          "key": "current-token", "email": "user@example.com",
          "expires_at": "2026-09-03T06:00:00Z"
         },
         "https://auth.x.ai::expired": {
          "key": "expired-token", "email": "expired@example.com",
          "expires_at": "2026-09-01T00:00:00Z"
         }
        }
        """.utf8)

        let auth = try grokAuth(from: json, now: now)
        #expect(auth.accessToken == "current-token")
        #expect(auth.email == "user@example.com")
    }

    @Test func testExpiredTokenIsActionable() {
        #expect(throws: GrokUsageError.tokenExpired) {
            try grokAuth(from: authJSON(expiresAt: "2026-09-01T00:00:00Z"), now: now)
        }
    }

    @Test func testMissingKeyIsUnauthenticated() {
        let json = Data(#"{"https://auth.x.ai::abc12345":{"email":"user@example.com"}}"#.utf8)
        #expect(throws: GrokUsageError.notAuthenticated) {
            try grokAuth(from: json, now: now)
        }
    }

    @Test func testErrorDescriptionsDoNotIncludeTheToken() throws {
        for error in [
            GrokUsageError.notAuthenticated,
            GrokUsageError.tokenExpired,
            GrokUsageError.invalidResponse,
            GrokUsageError.missingHome("/Users/example/.grok")
        ] {
            let text = try #require(error.errorDescription)
            #expect(!text.localizedCaseInsensitiveContains("token-"))
            #expect(!text.contains("Bearer"))
        }
    }
}

@Suite struct GrokAuthStoreTests {
    @Test func testLoadReadsAuthJSONFromTheConfiguredHome() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-bar-tests-\(UUID().uuidString)")
        let grokHome = root.appendingPathComponent("grok-home")
        try fileManager.createDirectory(at: grokHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try authJSON().write(to: grokHome.appendingPathComponent("auth.json"))
        let auth = try GrokAuthStore.load(
            grokHome: grokHome.path,
            now: UsageDate.parse("2026-09-02T12:00:00Z")!,
            fileManager: fileManager)

        #expect(auth.accessToken == "test-token")
        #expect(auth.email == "user@example.com")
    }

    @Test func testMissingHomeIsARegularError() {
        let path = "/tmp/missing-grok-home-\(UUID().uuidString)"
        #expect(throws: GrokUsageError.missingHome(path)) {
            try GrokAuthStore.load(grokHome: path)
        }
    }
}
