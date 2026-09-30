import Testing
import AppKit
@testable import UsageCore

/// Fixture: a real /api/oauth/usage payload captured 2026-08-06, trimmed to
/// the fields the app reads. Fable ships as a `limits[]` weekly_scoped entry,
/// not as a `seven_day_*` key.
private let capturedPayload = Data("""
{
 "five_hour": {"utilization": 31.0, "resets_at": "2026-08-06T22:29:59.937836+00:00"},
 "seven_day": {"utilization": 60.0, "resets_at": "2026-08-10T16:59:59.937859+00:00"},
 "seven_day_oauth_apps": null,
 "seven_day_opus": null,
 "seven_day_sonnet": null,
 "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null,
                 "currency": null, "decimal_places": null},
 "limits": [
  {"kind": "session", "group": "session", "percent": 31, "scope": null, "is_active": false},
  {"kind": "weekly_all", "group": "weekly", "percent": 60, "scope": null, "is_active": false},
  {"kind": "weekly_scoped", "group": "weekly", "percent": 100, "severity": "critical",
   "resets_at": "2026-08-10T16:59:59.938130+00:00",
   "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
   "is_active": true}
 ]
}
""".utf8)

@Suite struct DynamicWindowsTests {
    @Test func testFableComesFromWeeklyScopedLimits() {
        let windows = dynamicWindows(from: capturedPayload)
        #expect(windows.map(\.0) == ["Weekly Fable"])
        #expect(windows[0].1.utilization == 100)
        #expect(windows[0].1.resets_at == "2026-08-10T16:59:59.938130+00:00")
    }

    @Test func testSevenDayKeysBecomeBarsAndDedupeAgainstLimits() {
        let payload = Data("""
        {
         "seven_day_opus": {"utilization": 40.0, "resets_at": null},
         "seven_day_fable": {"utilization": 90.0, "resets_at": null},
         "seven_day_oauth_apps": {"utilization": 5.0},
         "limits": [
          {"kind": "weekly_scoped", "percent": 100,
           "scope": {"model": {"display_name": "Fable"}}}
         ]
        }
        """.utf8)
        let windows = dynamicWindows(from: payload)
        // oauth_apps excluded; Fable from the key wins over the limits entry
        #expect(windows.map(\.0) == ["Weekly Opus", "Weekly Fable"])
        #expect(windows[1].1.utilization == 90)
    }

    @Test func testNullBucketsProduceNoBars() {
        let windows = dynamicWindows(from: Data("{}".utf8))
        #expect(windows.isEmpty)
    }
}

@Suite struct UsageDecodingTests {
    @Test func testFixedFieldsDecode() throws {
        let usage = try JSONDecoder().decode(Usage.self, from: capturedPayload)
        #expect(usage.five_hour?.utilization == 31)
        #expect(usage.seven_day?.utilization == 60)
        #expect(usage.extra_usage?.is_enabled == false)
    }

    @Test func testAnthropicPayloadBecomesSharedSnapshot() throws {
        let snapshot = try anthropicUsageSnapshot(from: capturedPayload)
        #expect(snapshot.windows.map(\.label) == [
            "5h window", "Weekly (all models)", "Weekly Fable"
        ])
        #expect(snapshot.primaryWindow?.id == "anthropic.five_hour")
        #expect(snapshot.primaryWindow?.utilization == 31)
        #expect(snapshot.windows[2].utilization == 100)
        #expect(snapshot.extraUsage?.is_enabled == false)
    }

    @Test func testUsageDateAcceptsFractionalAndPlainISO8601() {
        #expect(UsageDate.parse("2026-08-06T22:29:59.937836+00:00") != nil)
        #expect(UsageDate.parse("2026-08-06T22:29:59Z") != nil)
        #expect(UsageDate.parse("not-a-date") == nil)
    }

    @Test func testWeeklyResetIncludesCalendarDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(ISO8601DateFormatter().date(from: "2025-01-06T10:00:00Z"))
        let reset = try #require(ISO8601DateFormatter().date(from: "2025-01-13T05:03:00Z"))

        let text = UsageDate.resetDescription(
            reset, now: now, calendar: calendar, locale: Locale(identifier: "en_US"))

        #expect(text.contains("Mon"), Comment(rawValue: text))
        #expect(text.contains("Jan 13"), Comment(rawValue: text))
        #expect(text.hasSuffix("(6d)"), Comment(rawValue: text))
    }

    @Test func testSameDayResetStaysTimeOnly() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(ISO8601DateFormatter().date(from: "2025-01-06T10:00:00Z"))
        let reset = try #require(ISO8601DateFormatter().date(from: "2025-01-06T11:29:00Z"))

        let text = UsageDate.resetDescription(
            reset, now: now, calendar: calendar, locale: Locale(identifier: "en_US"))

        #expect(!text.contains("Jan"), Comment(rawValue: text))
        #expect(text.hasSuffix("(1h)"), Comment(rawValue: text))
    }
}

@Suite struct GaugeWindowTests {
    private let snapshot = UsageSnapshot(windows: [
        UsageWindow(id: "anthropic.five_hour", label: "5h window", utilization: 24,
                    resetsAt: nil, isPrimary: true),
        UsageWindow(id: "anthropic.seven_day", label: "Weekly (all models)",
                    utilization: 53, resetsAt: nil),
        UsageWindow(id: "anthropic.model.fable", label: "Weekly Fable",
                    utilization: 96, resetsAt: nil)
    ])

    @Test func testNothingPinnedShowsThePrimary() {
        #expect(snapshot.gaugeWindow(pinnedID: nil)?.id == "anthropic.five_hour")
    }

    @Test func testPinnedWindowDrivesTheGauge() {
        #expect(snapshot.gaugeWindow(pinnedID: "anthropic.model.fable")?.utilization == 96)
    }

    @Test func testPinToAWindowThePayloadStoppedSendingFallsBackToThePrimary() {
        #expect(snapshot.gaugeWindow(pinnedID: "anthropic.model.opus")?.id == "anthropic.five_hour")
    }

    @Test func testNoPrimaryAndNoPinShowsNothing() {
        let bare = UsageSnapshot(windows: [
            UsageWindow(id: "x", label: "X", utilization: 1, resetsAt: nil)
        ])
        #expect(bare.gaugeWindow(pinnedID: nil) == nil)
        #expect(bare.gaugeWindow(pinnedID: "x")?.id == "x")
    }
}

@Suite struct AccountLineTests {
    @Test func testPlanSuffixIsSplitFromTheIdentity() {
        let line = AccountLine("jane@example.com · Pro")
        #expect(line.identity == "jane@example.com")
        #expect(line.suffix == "Pro")
    }

    @Test func testLabelWithoutSuffixIsAllIdentity() {
        #expect(AccountLine("jane@example.com") == AccountLine("jane@example.com"))
        #expect(AccountLine("jane@example.com").suffix == nil)
    }
}

@Suite struct MoneyTests {
    func extra(currency: String?, places: Int?) -> ExtraUsage {
        ExtraUsage(is_enabled: true, used_credits: nil, monthly_limit: nil,
                   currency: currency, decimal_places: places)
    }

    @Test func testMinorUnitsConvertWithDecimalPlaces() {
        // 5640 minor units with 2 decimal places = 56.40 of the currency
        let text = extra(currency: "USD", places: 2).money(5640, locale: Locale(identifier: "en_US"))
        #expect(text.contains("56.40"), Comment(rawValue: text))
        #expect(text.contains("$"), Comment(rawValue: text))
    }

    @Test func testCurrencyComesFromThePayloadNotTheLocale() {
        let text = extra(currency: "BRL", places: 2).money(5640, locale: Locale(identifier: "pt_BR"))
        #expect(text.contains("56,40"), Comment(rawValue: text))
        #expect(text.contains("R$"), Comment(rawValue: text))
    }

    @Test func testDefaultsToTwoPlacesUSD() {
        let text = extra(currency: nil, places: nil).money(10152, locale: Locale(identifier: "en_US"))
        #expect(text.contains("101.52"), Comment(rawValue: text))
    }
}

@Suite struct BalanceTests {
    @Test func testSpendSinceAnchorIsSubtracted() {
        // balance 1042.22 anchored when spend was 101.52; now 141.59
        #expect(remainingBalance(balance: 104222, anchorUsed: 10152, used: 14159) == 100215)
    }

    @Test func testMonthlyResetReanchorsToZero() {
        // used dropped below the anchor -> new month -> anchor re-bases to 0
        #expect(remainingBalance(balance: 104222, anchorUsed: 10152, used: 500) == 103722)
    }

    @Test func testNeverNegative() {
        #expect(remainingBalance(balance: 100, anchorUsed: 0, used: 5000) == 0)
    }
}

@Suite struct ParseAmountTests {
    @Test func testReadsTheUsersOwnSeparators() {
        #expect(parseAmount("$1,042.22", locale: Locale(identifier: "en_US")) == 1042.22)
        #expect(parseAmount("R$ 1.042,22", locale: Locale(identifier: "pt_BR")) == 1042.22)
    }

    @Test func testPlainNumberNeedsNoSeparator() {
        #expect(parseAmount("100", locale: Locale(identifier: "en_US")) == 100)
    }

    @Test func testNonNumericIsRejected() {
        #expect(parseAmount("", locale: Locale(identifier: "en_US")) == nil)
        #expect(parseAmount("abc", locale: Locale(identifier: "en_US")) == nil)
    }
}

@Suite struct GaugeTests {
    @Test func testColorThresholds() {
        #expect(Gauge.color(0) == .systemGreen)
        #expect(Gauge.color(59.9) == .systemGreen)
        #expect(Gauge.color(60) == .systemOrange)
        #expect(Gauge.color(84.9) == .systemOrange)
        #expect(Gauge.color(85) == .systemRed)
        #expect(Gauge.color(100) == .systemRed)
    }

    @Test func testImageRendersAtExpectedSize() {
        let img = Gauge.image(pct: 50)
        #expect(img.size == NSSize(width: 20, height: 18))
        #expect(!(img.isTemplate))
    }

    @Test func testProviderMarksRenderAsTemplateImages() {
        for image in [ProviderMarks.anthropicImage(), ProviderMarks.openAIImage(),
                      ProviderMarks.xAIImage(), ProviderMarks.antigravityImage(),
                      ProviderMarks.genericImage()] {
            #expect(image.size == NSSize(width: 16, height: 16))
            #expect(image.isTemplate)
            #expect(image.tiffRepresentation?.isEmpty == false)
        }
    }

    @Test func testCustomIconOverridesProviderMark() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-icon-\(UUID().uuidString).svg")
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" fill=\"#fff\" viewBox=\"0 0 16 16\"><circle cx=\"8\" cy=\"8\" r=\"8\"/></svg>"
        try svg.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let profile = Profile(id: "test", name: "Test",
                              configuration: .antigravity(geminiHome: "/home/user/.gemini", cliPath: nil),
                              icon: tmp.path)
        let img = ProviderMarks.image(for: profile)
        #expect(img.size == NSSize(width: 16, height: 16))
        #expect(img.isTemplate)
    }
}
