import Foundation

public enum AntigravityCLIError: LocalizedError, Equatable, Sendable {
    case missingExecutable
    case missingHome(String)
    case unisolatableHome(String)
    case timeout
    case exited(Int32)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingExecutable:
            "Antigravity CLI not found — install agy, or set path in profiles.json."
        case let .missingHome(path):
            "Antigravity home does not exist: \(path)"
        case let .unisolatableHome(path):
            "The Antigravity CLI reads $HOME/.gemini, so it cannot be pointed at "
                + "\(path). Use a `.gemini` directory inside its own parent, or set adapter."
        case .timeout:
            "The Antigravity CLI timed out."
        case let .exited(status):
            "The Antigravity CLI exited with status \(status)."
        case .invalidResponse:
            "The Antigravity CLI reported no quota groups."
        }
    }
}

/// Antigravity quota comes from the CLI, never from an endpoint of our own:
/// the CLI owns the account's credentials, exactly as `codex app-server` does
/// for OpenAI. `agy -p /quota` prints one tab-separated row per quota group,
/// and models inside a group share that group's weekly limit.
public enum AntigravityCLI {
    /// Names the CLI ships under, newest first.
    public static let executableNames = ["agy", "antigravity"]
    public static let weeklyMinutes = 7 * 24 * 60
    /// The directory the CLI resolves relative to `$HOME`.
    public static let homeComponent = ".gemini"

    public static func candidates(
        configuredPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String,
        fileManager: FileManager = .default
    ) -> [String] {
        Profiles.adapterCandidates(names: executableNames,
                                   configuredPath: configuredPath,
                                   environment: environment,
                                   home: home,
                                   fileManager: fileManager)
    }

    public static func resolveExecutable(
        configuredPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String,
        fileManager: FileManager = .default
    ) -> String? {
        if let configuredPath {
            return fileManager.isExecutableFile(atPath: configuredPath)
                ? configuredPath : nil
        }
        return candidates(environment: environment, home: home,
                          fileManager: fileManager)
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// The CLI has no flag or variable for its configuration directory: it
    /// always reads `$HOME/.gemini`. A second account is therefore a `.gemini`
    /// directory under a parent of its own, and that parent becomes `$HOME`
    /// for the child process. Any other directory cannot be isolated, and
    /// silently reading the default account would be worse than an error.
    public static func processHome(forGeminiHome geminiHome: String) -> String? {
        let url = URL(fileURLWithPath: geminiHome)
        guard url.lastPathComponent == homeComponent else { return nil }
        let parent = url.deletingLastPathComponent().path
        return parent.isEmpty ? nil : parent
    }

    /// One row per group: `<group>\t<metric>\t<remaining>%\t<ISO-8601 reset>`.
    /// The printed percentage is what is *left*, so the bar shows what is
    /// used. Rows that do not carry a percentage are print-mode noise and are
    /// skipped; the group consuming the most drives the menu bar.
    public static func parseQuota(_ text: String) -> UsageSnapshot? {
        var windows: [UsageWindow] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3 else { continue }
            let group = fields[0]
            guard !group.isEmpty else { continue }
            guard let remaining = percentage(fields[2]) else { continue }
            let resetsAt = fields.count >= 4 ? UsageDate.parse(fields[3]) : nil
            windows.append(UsageWindow(
                id: identifier(for: group),
                label: group,
                utilization: max(0, min(100, 100 - remaining)),
                resetsAt: resetsAt,
                durationMinutes: weeklyMinutes))
        }
        guard !windows.isEmpty else { return nil }
        let leaderIndex = windows.indices.max {
            windows[$0].utilization < windows[$1].utilization
        } ?? windows.startIndex
        let ranked = windows.enumerated().map { index, window in
            UsageWindow(id: window.id, label: window.label,
                        utilization: window.utilization, resetsAt: window.resetsAt,
                        durationMinutes: window.durationMinutes,
                        isPrimary: index == leaderIndex)
        }
        return UsageSnapshot(windows: ranked)
    }

    /// Locale-independent on purpose: the CLI prints a machine row with a dot
    /// decimal separator, whatever the reader's locale is.
    static func percentage(_ field: String) -> Double? {
        var text = field
        guard text.hasSuffix("%") else { return nil }
        text.removeLast()
        return Double(text.trimmingCharacters(in: .whitespaces))
    }

    static func identifier(for group: String) -> String {
        let slug = group.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { partial, character in
                if character == "-", partial.hasSuffix("-") { return }
                partial.append(character)
            }
        return "antigravity." + slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func fetch(_ profile: Profile,
                             executable: String? = nil,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             timeout: TimeInterval = 25) async throws -> UsageSnapshot {
        try await Task.detached(priority: .utility) {
            try fetchBlocking(profile, executable: executable,
                              environment: environment, timeout: timeout)
        }.value
    }

    private static func fetchBlocking(_ profile: Profile,
                                      executable: String?,
                                      environment: [String: String],
                                      timeout: TimeInterval) throws -> UsageSnapshot {
        let fileManager = FileManager.default
        guard case let .antigravity(geminiHome, configuredPath) = profile.configuration
        else { throw AntigravityCLIError.missingExecutable }

        guard let binary = executable
            ?? resolveExecutable(configuredPath: configuredPath,
                                 environment: environment,
                                 home: NSHomeDirectory(),
                                 fileManager: fileManager)
        else { throw AntigravityCLIError.missingExecutable }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: geminiHome, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw AntigravityCLIError.missingHome(geminiHome) }

        guard let processHome = processHome(forGeminiHome: geminiHome) else {
            throw AntigravityCLIError.unisolatableHome(geminiHome)
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-p", "/quota", "--print-timeout", "20s"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var childEnvironment = environment
        childEnvironment["HOME"] = processHome
        process.environment = childEnvironment

        try process.run()
        let timedOut = TimeoutFlag()
        let timeoutTask = DispatchWorkItem {
            timedOut.fire()
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
        defer {
            timeoutTask.cancel()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutTask.cancel()
        if timedOut.didFire { throw AntigravityCLIError.timeout }
        guard process.terminationStatus == 0 else {
            throw AntigravityCLIError.exited(process.terminationStatus)
        }
        guard let text = String(data: data, encoding: .utf8),
              let snapshot = parseQuota(text)
        else { throw AntigravityCLIError.invalidResponse }
        return snapshot
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}
