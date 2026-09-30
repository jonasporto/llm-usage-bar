import Combine
import SwiftUI
import UsageCore

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    /// From profiles.json; reloaded when that file is saved. Never empty.
    @Published private(set) var profiles: [Profile] = Profiles.load()

    @Published var snapshots: [String: UsageSnapshot] = [:]
    @Published var errors: [String: String] = [:]
    @Published var accounts: [String: String] = [:]
    @Published var lastUpdates: [String: Date] = [:]
    /// From config.json; reloaded when that file is saved.
    @Published private(set) var settings: AppSettings = AppSettings.load()
    @AppStorage("activeProfile") var activeRaw: String = ""

    var active: Profile {
        get { profiles.first { $0.id == activeRaw } ?? profiles[0] }
        set {
            guard activeRaw != newValue.id else { return }
            activeRaw = newValue.id
            // Accounts may poll at different cadences, so the timer follows
            // whichever one is on screen.
            schedulePolling()
        }
    }

    private var pollTimer: Timer?
    private var profilesWatcher: ConfigFileWatcher?
    private var settingsWatcher: ConfigFileWatcher?

    init() {
        Task { @MainActor in await self.refresh(self.active) }
        schedulePolling()

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let profiles = ConfigFileWatcher(fileURL: Profiles.configURL(home: home)) {
            [weak self] in
            DispatchQueue.main.async { self?.reloadProfiles() }
        }
        profilesWatcher = profiles
        profiles.start()

        let settings = ConfigFileWatcher(fileURL: AppSettings.url(home: home)) {
            [weak self] in
            DispatchQueue.main.async { self?.reloadSettings() }
        }
        settingsWatcher = settings
        settings.start()
    }

    /// The visible account's own cadence, or the default from config.json.
    /// Both are clamped in `AppSettings`, so this can never poll faster than
    /// the per-account throttle.
    private func schedulePolling() {
        pollTimer?.invalidate()
        let seconds = active.refreshSeconds(default: settings.refreshSeconds)
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(seconds), repeats: true
        ) { _ in
            Task { @MainActor in await self.refresh(self.active) }
        }
    }

    private func reloadSettings() {
        let loaded = AppSettings.load()
        guard loaded != settings else { return }
        settings = loaded
        schedulePolling()
    }


    func reloadProfiles() {
        guard let loaded = Profiles.readForReload() else { return }
        guard let reload = Profiles.reconcile(
            loaded: loaded, current: profiles, activeID: active.id)
        else { return }

        profiles = reload.profiles
        for id in reload.staleIDs {
            snapshots.removeValue(forKey: id)
            errors.removeValue(forKey: id)
            accounts.removeValue(forKey: id)
            lastUpdates.removeValue(forKey: id)
            lastFetch.removeValue(forKey: id)
            cooldownUntil.removeValue(forKey: id)
            backoff.removeValue(forKey: id)
        }
        let activeChanged = activeRaw != reload.activeID
        activeRaw = reload.activeID
        schedulePolling()
        if activeChanged || reload.staleIDs.contains(reload.activeID) {
            Task { await refresh(active, force: true) }
        }
    }

    private var lastFetch: [String: Date] = [:]
    @Published private(set) var cooldownUntil: [String: Date] = [:]
    private var backoff: [String: TimeInterval] = [:]

    private func token(keychainService: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", keychainService, "-w"]
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

    private func anthropicAccountLine(configPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: configPath),
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
        if profile.provider == .anthropic, profile.usageAdapter == nil,
           let until = cooldownUntil[profile.id], Date() < until {
            return
        }
        // throttle: one fetch per profile per 45s unless the user pressed
        // Refresh
        if !force, let last = lastFetch[profile.id], Date().timeIntervalSince(last) < 45 {
            return
        }
        lastFetch[profile.id] = Date()

        if profile.usageAdapter != nil {
            await refreshAdapter(profile)
            return
        }
        switch profile.configuration {
        case let .anthropic(keychainService, configPath):
            await refreshAnthropic(profile, keychainService: keychainService,
                                    configPath: configPath)
        case .openAI:
            await refreshOpenAI(profile)
        case let .xAI(grokHome):
            await refreshXAI(profile, grokHome: grokHome)
        case let .antigravity(geminiHome, _):
            await refreshAntigravity(profile, geminiHome: geminiHome)
        case .command:
            await refreshAdapter(profile)
        }
    }

    private func refreshAdapter(_ profile: Profile) async {
        do {
            let result = try await CommandAdapter.fetch(profile)
            snapshots[profile.id] = result.usage
            let account = result.account
                ?? (profile.provider == .antigravity ? antigravityAccountLine(geminiHome: profile.home) : nil)
            if let account {
                accounts[profile.id] = account
            }
            errors[profile.id] = nil
            lastUpdates[profile.id] = Date()
        } catch {
            errors[profile.id] = error.localizedDescription
        }
    }

    /// Reached only without a usage adapter: quota then comes from the
    /// Antigravity CLI, which owns the account's credentials.
    private func refreshAntigravity(_ profile: Profile, geminiHome: String) async {
        if let account = antigravityAccountLine(geminiHome: geminiHome) {
            accounts[profile.id] = account
        }
        do {
            snapshots[profile.id] = try await AntigravityCLI.fetch(profile)
            errors[profile.id] = nil
            lastUpdates[profile.id] = Date()
        } catch {
            errors[profile.id] = error.localizedDescription
        }
    }

    private func antigravityAccountLine(geminiHome: String) -> String? {
        let path = URL(fileURLWithPath: geminiHome).appendingPathComponent("google_accounts.json").path
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["active"] as? String, !email.isEmpty
        else { return nil }
        return email
    }

    private func refreshAnthropic(_ profile: Profile, keychainService: String,
                                  configPath: String) async {
        accounts[profile.id] = anthropicAccountLine(configPath: configPath)
        guard let token = token(keychainService: keychainService) else {
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
            snapshots[profile.id] = try anthropicUsageSnapshot(from: data)
            errors[profile.id] = nil
            backoff[profile.id] = 0
            cooldownUntil[profile.id] = nil
            lastUpdates[profile.id] = Date()
        } catch {
            errors[profile.id] = error.localizedDescription
        }
    }

    private func refreshOpenAI(_ profile: Profile) async {
        do {
            let result = try await CodexAppServer.fetch(profile)
            snapshots[profile.id] = result.usage
            accounts[profile.id] = result.account.label
            errors[profile.id] = nil
            lastUpdates[profile.id] = Date()
        } catch {
            errors[profile.id] = error.localizedDescription
        }
    }

    private func refreshXAI(_ profile: Profile, grokHome: String) async {
        do {
            let auth = try GrokAuthStore.load(grokHome: grokHome)
            if let email = auth.email { accounts[profile.id] = email }

            let (data, resp) = try await URLSession.shared.data(for: grokRequest(GrokAPI.billingURL, token: auth.accessToken))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                errors[profile.id] = grokHTTPError(code)
                return
            }
            snapshots[profile.id] = try grokUsageSnapshot(from: data)
            errors[profile.id] = nil
            lastUpdates[profile.id] = Date()

            if let user = try? await grokUser(token: auth.accessToken),
               let label = user.label {
                accounts[profile.id] = label
            }
        } catch {
            errors[profile.id] = error.localizedDescription
        }
    }

    private func grokUser(token: String) async throws -> GrokAccount {
        let (data, resp) = try await URLSession.shared.data(for: grokRequest(GrokAPI.userURL, token: token))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw GrokUsageError.invalidResponse }
        return try grokAccount(from: data)
    }

    private func grokRequest(_ url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func grokHTTPError(_ code: Int) -> String {
        switch code {
        case 401, 403: "Token expired — open grok on this profile to refresh."
        default: "HTTP \(code)"
        }
    }
}

// MARK: - Views

struct MetricRow: View {
    let window: UsageWindow

    private var pct: Double { min(max(window.utilization, 0), 100) }
    private var color: Color { pct >= 85 ? .red : pct >= 60 ? .orange : .green }

    private var resetText: String {
        guard let date = window.resetsAt else { return "" }
        return UsageDate.resetDescription(date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).font(.callout)
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

struct ProviderMark: View {
    let profile: Profile

    var body: some View {
        Image(nsImage: ProviderMarks.image(for: profile))
            .accessibilityLabel(profile.provider.displayName)
    }
}

struct AccountUsageBadge: View {
    let snapshot: UsageSnapshot?
    let hasError: Bool

    var body: some View {
        if let window = snapshot?.primaryWindow {
            let pct = min(max(window.utilization, 0), 100)
            HStack(spacing: 3) {
                Image(nsImage: Gauge.image(pct: pct))
                Text("\(Int(pct))%")
                    .monospacedDigit()
            }
            .accessibilityLabel("\(Int(pct)) percent used")
        } else if hasError {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Usage unavailable")
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading usage")
        }
    }
}

struct UsageView: View {
    @ObservedObject var store: UsageStore
    @State private var editingBalance = false
    @State private var balanceInput = ""
    @State private var showingAccounts = false

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

    private func loadMissingAccountUsage() {
        Task {
            for profile in store.profiles where store.snapshots[profile.id] == nil {
                await store.refresh(profile)
            }
        }
    }

    private func accountRow(_ profile: Profile, disclosure: Bool = false) -> some View {
        HStack(spacing: 7) {
            ProviderMark(profile: profile)
                .frame(width: disclosure ? nil : 18,
                       height: 18, alignment: .leading)
            Text(profile.name)
                .lineLimit(1)
            Spacer()
            AccountUsageBadge(
                snapshot: store.snapshots[profile.id],
                hasError: store.errors[profile.id] != nil)
                .font(.caption)
                .foregroundStyle(.secondary)
            if disclosure {
                Image(systemName: showingAccounts ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .contentShape(Rectangle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.profiles.count > 1 {
                VStack(spacing: 4) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showingAccounts.toggle()
                        }
                        if showingAccounts { loadMissingAccountUsage() }
                    } label: {
                        accountRow(store.active, disclosure: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Account")
                    .accessibilityValue(store.active.name)

                    if showingAccounts {
                        let otherProfiles = store.profiles.filter { $0.id != store.active.id }
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(otherProfiles) { profile in
                                    Button {
                                        store.active = profile
                                        showingAccounts = false
                                        Task { await store.refresh(profile) }  // throttled
                                    } label: {
                                        accountRow(profile)
                                    }
                                    .buttonStyle(.plain)

                                    if profile.id != otherProfiles.last?.id {
                                        Divider().padding(.leading, 30)
                                    }
                                }
                            }
                        }
                        .frame(height: min(CGFloat(otherProfiles.count * 34), 170))
                    }
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }

            HStack(spacing: 5) {
                ProviderMark(profile: store.active)
                Text(store.accounts[store.active.id] ?? store.active.provider.displayName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // an error never hides the last good data — it shows under it
            if let error = store.errors[store.active.id], store.snapshots[store.active.id] == nil {
                Text(error).font(.callout).foregroundStyle(.red)
            } else if let snapshot = store.snapshots[store.active.id] {
                ForEach(snapshot.windows) { window in
                    MetricRow(window: window)
                }
                if let e = snapshot.extraUsage, e.is_enabled == true {
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
                .foregroundStyle(store.snapshots[store.active.id] == nil ? Color.red : .orange)
            } else if let error = store.errors[store.active.id],
                      store.snapshots[store.active.id] != nil {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }

            HStack {
                if let t = store.lastUpdates[store.active.id] {
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
            }
        }
        .padding(16)
        .frame(width: 300)
        // The active account refreshes on appearance; missing inactive
        // snapshots are filled only when the picker opens.
        .onAppear { Task { await store.refresh(store.active) } }
    }
}

// MARK: - App

/// AppKit owns the status item and the popover. SwiftUI's `MenuBarExtra`
/// window style sizes its window once and, on macOS 26 and later, does not
/// follow the content when it grows (account picker) or shrinks (switching to
/// an account with fewer bars): the content floats inside a stale frame.
/// `NSPopover` tracks the hosting controller's `preferredContentSize`, so the
/// window always fits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var host: NSHostingController<UsageView>?
    private var storeObserver: AnyCancellable?
    private var keyMonitor: Any?

    private var barPct: Double {
        store.snapshots[store.active.id]?.primaryWindow?.utilization ?? 0
    }

    // Text beside the gauge: 5h %; when the window is maxed and extra usage
    // is spending, the money spent.
    private var barLabel: String {
        guard let snapshot = store.snapshots[store.active.id] else { return "…" }
        if barPct >= 100, let e = snapshot.extraUsage, e.is_enabled == true,
           let used = e.used_credits, used > 0 {
            return "⚡\(e.money(used))"
        }
        return "\(Int(barPct))%"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingController(rootView: UsageView(store: store))
        host.sizingOptions = [.preferredContentSize]
        self.host = host
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem = item

        storeObserver = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
        updateStatusItem()

        // no visible Quit — ⌘Q with the popover open quits
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "q" {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = Gauge.image(pct: barPct)
        button.title = barLabel
        button.font = NSFont.menuBarFont(ofSize: 0)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button, let host else { return }
        // Size before showing so the popover is anchored for its real height
        // rather than repositioned after the first layout pass.
        host.view.layoutSubtreeIfNeeded()
        popover.contentSize = host.view.fittingSize
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
