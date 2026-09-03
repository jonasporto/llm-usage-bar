import Foundation

public struct CommandAdapterResult: Sendable {
    public let account: String?
    public let usage: UsageSnapshot

    public init(account: String?, usage: UsageSnapshot) {
        self.account = account
        self.usage = usage
    }
}

public enum CommandAdapterError: LocalizedError, Equatable, Sendable {
    case missingExecutable
    case invalidExecutable(String)
    case missingHome(String)
    case timeout
    case exited(Int32)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingExecutable:
            "No adapter executable — set path or adapter in profiles.json."
        case let .invalidExecutable(path):
            "adapter is not an executable absolute path: \(path)"
        case let .missingHome(path):
            "Provider home does not exist: \(path)"
        case .timeout:
            "Usage adapter timed out."
        case let .exited(status):
            "Usage adapter exited with status \(status)."
        case .invalidResponse:
            "Usage adapter returned an invalid response."
        }
    }
}

public enum CommandAdapter {
    public static func fetch(_ profile: Profile,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             timeout: TimeInterval = 15) async throws -> CommandAdapterResult {
        try await Task.detached(priority: .utility) {
            try fetchBlocking(profile, environment: environment, timeout: timeout)
        }.value
    }

    public static func usageSnapshot(from data: Data) throws -> (account: String?, usage: UsageSnapshot) {
        struct Window: Decodable {
            let id: String?
            let label: String
            let utilization: Double
            let resetsAt: String?
            let durationMinutes: Int?
            let isPrimary: Bool?
        }
        struct Extra: Decodable {
            let isEnabled: Bool?
            let usedCredits: Double?
            let monthlyLimit: Double?
            let currency: String?
            let decimalPlaces: Int?
        }
        struct Envelope: Decodable {
            let account: String?
            let windows: [Window]
            let extraUsage: Extra?
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let windows: [UsageWindow] = envelope.windows.enumerated().map { index, window in
            UsageWindow(
                id: window.id ?? "adapter.\(index)",
                label: window.label,
                utilization: window.utilization,
                resetsAt: UsageDate.parse(window.resetsAt),
                durationMinutes: window.durationMinutes,
                isPrimary: window.isPrimary ?? (index == 0))
        }
        guard !windows.isEmpty else { throw CommandAdapterError.invalidResponse }
        let extra = envelope.extraUsage.map {
            ExtraUsage(is_enabled: $0.isEnabled, used_credits: $0.usedCredits,
                       monthly_limit: $0.monthlyLimit, currency: $0.currency,
                       decimal_places: $0.decimalPlaces)
        }
        return (envelope.account, UsageSnapshot(windows: windows, extraUsage: extra))
    }

    private static func fetchBlocking(_ profile: Profile,
                                      environment: [String: String],
                                      timeout: TimeInterval) throws -> CommandAdapterResult {
        guard let executable = profile.usageAdapter else {
            throw CommandAdapterError.missingExecutable
        }
        let fileManager = FileManager.default
        guard executable.hasPrefix("/"),
              fileManager.isExecutableFile(atPath: executable) else {
            throw CommandAdapterError.invalidExecutable(executable)
        }

        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: profile.home, isDirectory: &isDirectory)
            || !isDirectory.boolValue {
            throw CommandAdapterError.missingHome(profile.home)
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--home", profile.home]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        var childEnvironment = environment
        childEnvironment["LLM_USAGE_HOME"] = profile.home
        childEnvironment["LLM_USAGE_PROVIDER"] = profile.provider.rawValue
        process.environment = childEnvironment

        try process.run()
        let timeoutState = TimeoutState()
        let timeoutTask = DispatchWorkItem {
            timeoutState.fire()
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
        if timeoutState.didFire { throw CommandAdapterError.timeout }
        guard process.terminationStatus == 0 else {
            throw CommandAdapterError.exited(process.terminationStatus)
        }
        do {
            let parsed = try usageSnapshot(from: data)
            return CommandAdapterResult(account: parsed.account, usage: parsed.usage)
        } catch {
            throw CommandAdapterError.invalidResponse
        }
    }
}

private final class TimeoutState {
    private let lock = NSLock()
    private var fired = false

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    func fire() {
        lock.lock()
        fired = true
        lock.unlock()
    }
}
