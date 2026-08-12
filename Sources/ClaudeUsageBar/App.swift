import SwiftUI
import UsageCore

// SwiftUI also declares a `Window` scene type; ours wins in this file
typealias Window = UsageCore.Window

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    /// Loaded once at launch from profiles.json (see README). Never empty.
    let profiles: [Profile] = Profiles.load()

    @Published var usage: [String: Usage] = [:]
    @Published var modelWindows: [String: [(String, Window)]] = [:]
    @Published var errors: [String: String] = [:]
    @Published var accounts: [String: String] = [:]
    @Published var lastUpdate: Date?
    @AppStorage("activeProfile") var activeRaw: String = ""

    var active: Profile {
        get { profiles.first { $0.id == activeRaw } ?? profiles[0] }
        set { activeRaw = newValue.id }
    }

    private var pollTimer: Timer?

    init() {
        Task { @MainActor in await self.refresh(self.active) }
        // single cadence: active profile every 2 minutes, popover open or
        // not; the other profiles update on popover open / tab switch
        pollTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in await self.refresh(self.active) }
        }
    }

    private var lastFetch: [String: Date] = [:]
    @Published private(set) var cooldownUntil: [String: Date] = [:]
    private var backoff: [String: TimeInterval] = [:]

    func refreshAll(force: Bool = false) {
        for p in profiles { Task { await self.refresh(p, force: force) } }
    }

    private func token(for profile: Profile) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", profile.keychainService, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let raw = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return oauth["accessToken"] as? String
    }

    private func accountLine(for profile: Profile) -> String? {
        guard let data = FileManager.default.contents(atPath: profile.configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acc = json["oauthAccount"] as? [String: Any]
        else { return nil }
        let email = acc["emailAddress"] as? String ?? ""
        let org = acc["organizationName"] as? String ?? ""
        return org.isEmpty || org.contains(email) ? email : "\(email) · \(org)"
    }

    func refresh(_ profile: Profile, force: Bool = false) async {
        // 429 cooldown: not even Refresh bypasses it (the endpoint uses a
        // rolling window and Retry-After is useless — always 0). The view
        // renders a live countdown from cooldownUntil.
        if let until = cooldownUntil[profile.id], Date() < until {
            return
        }
        // throttle: one fetch per profile per 45s unless the user pressed
        // Refresh
        if !force, let last = lastFetch[profile.id], Date().timeIntervalSince(last) < 45 {
            return
        }
        lastFetch[profile.id] = Date()
        accounts[profile.id] = accountLine(for: profile)
        guard let token = token(for: profile) else {
            errors[profile.id] = "No token in Keychain — open claude on this profile and /login."
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                switch code {
                case 401: errors[profile.id] = "Token expired — open claude on this profile to refresh."
                case 429:
                    let next = min(600, max(60, (backoff[profile.id] ?? 30) * 2))
                    backoff[profile.id] = next
                    cooldownUntil[profile.id] = Date().addingTimeInterval(next)
                    errors[profile.id] = nil
                    // auto-retry the moment the countdown hits zero
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(next * 1_000_000_000))
                        await self.refresh(profile, force: true)
                    }
                default: errors[profile.id] = "HTTP \(code)"
                }
                return
            }
            usage[profile.id] = try JSONDecoder().decode(Usage.self, from: data)
            modelWindows[profile.id] = dynamicWindows(from: data)
            errors[profile.id] = nil
            backoff[profile.id] = 0
            cooldownUntil[profile.id] = nil
            lastUpdate = Date()
        } catch {
            errors[profile.id] = error.localizedDescription
        }
    }
}

// MARK: - Views

struct MetricRow: View {
    let label: String
    let window: Window

    private var pct: Double { min(max(window.utilization ?? 0, 0), 100) }
    private var color: Color { pct >= 85 ? .red : pct >= 60 ? .orange : .green }

    private var resetText: String {
        guard let iso = window.resets_at,
              let date = ISO8601DateFormatter.flexible.date(from: iso) else { return "" }
        let hours = date.timeIntervalSinceNow / 3600
        let fmt = DateFormatter()
        fmt.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        let span: String
        if hours < 1 {
            let mins = max(1, Int((hours * 60).rounded()))
            span = "\(mins)m"
        } else if hours < 48 {
            span = "\(Int(hours.rounded()))h"
        } else {
            span = "\(Int(hours / 24))d"
        }
        return "resets \(fmt.string(from: date)) (\(span))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text("\(Int(pct))%")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            ProgressView(value: pct, total: 100)
                .tint(color)
            Text(resetText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct UsageView: View {
    @ObservedObject var store: UsageStore
    @State private var editingBalance = false
    @State private var balanceInput = ""

    private func anchorKey(_ p: Profile) -> String { "balanceAnchor_\(p.id)" }

    /// Available credit ≈ user-entered balance minus spend measured by the
    /// API since it was entered. Re-anchors when the monthly counter resets.
    private func remaining(_ e: ExtraUsage, _ p: Profile) -> Double? {
        guard let s = UserDefaults.standard.string(forKey: anchorKey(p)) else { return nil }
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return remainingBalance(balance: parts[0], anchorUsed: parts[1],
                                used: e.used_credits ?? 0)
    }

    private func updatedText(_ t: Date) -> String {
        let mins = Int(Date().timeIntervalSince(t) / 60)
        if mins < 1 { return "Updated less than 1 min ago" }
        if mins < 60 { return "Updated \(mins) min ago" }
        return "Updated \(mins / 60)h \(mins % 60)m ago"
    }

    private func saveBalance(_ e: ExtraUsage, _ p: Profile) {
        guard let value = parseAmount(balanceInput) else { return }
        let minor = value * pow(10, Double(e.decimal_places ?? 2))
        UserDefaults.standard.set("\(minor):\(e.used_credits ?? 0)", forKey: anchorKey(p))
        editingBalance = false
        balanceInput = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.profiles.count > 1 {
                Picker("Profile", selection: Binding(
                    get: { store.active },
                    set: { newValue in
                        store.active = newValue
                        Task { await store.refresh(newValue) }  // throttled
                    }
                )) {
                    ForEach(store.profiles) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let account = store.accounts[store.active.id] {
                Text(account).font(.caption).foregroundStyle(.secondary)
            }

            // an error never hides the last good data — it shows under it
            if let error = store.errors[store.active.id], store.usage[store.active.id] == nil {
                Text(error).font(.callout).foregroundStyle(.red)
            } else if let u = store.usage[store.active.id] {
                if let w = u.five_hour { MetricRow(label: "5h window", window: w) }
                if let w = u.seven_day { MetricRow(label: "Weekly (all models)", window: w) }
                ForEach(store.modelWindows[store.active.id] ?? [], id: \.0) { label, window in
                    MetricRow(label: label, window: window)
                }
                if let e = u.extra_usage, e.is_enabled == true {
                    let limit = e.monthly_limit.map { e.money($0) } ?? "no monthly limit"
                    Text("extra usage ON — \(e.money(e.used_credits ?? 0)) spent · \(limit)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let rem = remaining(e, store.active) {
                            Text("available ≈ \(e.money(rem))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("balance not set")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Button(editingBalance ? "cancel" : "set") {
                            editingBalance.toggle()
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                    if editingBalance {
                        TextField("current balance, e.g. 100.00", text: $balanceInput)
                            .textFieldStyle(.roundedBorder).font(.caption)
                            .onSubmit { saveBalance(e, store.active) }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }

            if let until = store.cooldownUntil[store.active.id], until > Date() {
                HStack(spacing: 4) {
                    Text("Rate limited — retrying in")
                    Text(timerInterval: Date()...until, countsDown: true)
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(store.usage[store.active.id] == nil ? Color.red : .orange)
            } else if let error = store.errors[store.active.id],
                      store.usage[store.active.id] != nil {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }

            HStack {
                if let t = store.lastUpdate {
                    // coarse relative time, re-evaluated every 30s (no
                    // second-by-second ticking)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(updatedText(t))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button {
                    Task { await store.refresh(store.active, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Refresh")
                // no visible Quit — ⌘Q with the popover open quits
                Button("") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                    .hidden()
                    .frame(width: 0, height: 0)
            }
        }
        .padding(16)
        .frame(width: 300)
        // every fetch targets only the visible profile; the others load
        // when their tab is selected
        .onAppear { Task { await store.refresh(store.active) } }
    }
}

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - App

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var store = UsageStore()

    private var barPct: Double {
        store.usage[store.active.id]?.five_hour?.utilization ?? 0
    }

    // Text beside the gauge: 5h %; when the window is maxed and extra usage
    // is spending, the money spent.
    private var barLabel: String {
        guard let u = store.usage[store.active.id] else { return "…" }
        if barPct >= 100, let e = u.extra_usage, e.is_enabled == true,
           let used = e.used_credits, used > 0 {
            return "⚡\(e.money(used))"
        }
        return "\(Int(barPct))%"
    }

    var body: some Scene {
        MenuBarExtra {
            UsageView(store: store)
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: Gauge.image(pct: barPct))
                Text(barLabel)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
