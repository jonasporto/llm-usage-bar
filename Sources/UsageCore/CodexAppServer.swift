import Foundation
import Darwin

public struct CodexAppServerResult: Sendable {
    public let account: CodexAccount
    public let usage: UsageSnapshot

    public init(account: CodexAccount, usage: UsageSnapshot) {
        self.account = account
        self.usage = usage
    }
}

public enum CodexAppServerError: LocalizedError, Equatable, Sendable {
    case invalidProfile
    case missingHome(String)
    case invalidExecutable(String)
    case executableNotFound
    case homeMismatch(expected: String, actual: String)
    case timeout
    case exited(Int32)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidProfile:
            "The selected profile is not an OpenAI profile."
        case let .missingHome(path):
            "CODEX_HOME does not exist: \(path)"
        case let .invalidExecutable(path):
            "codexPath is not an executable absolute path: \(path)"
        case .executableNotFound:
            "Codex CLI not found — install it or set codexPath in profiles.json."
        case let .homeMismatch(expected, actual):
            "Codex resolved CODEX_HOME as \(actual), expected \(expected)."
        case .timeout:
            "Codex App Server timed out."
        case let .exited(status):
            "Codex App Server exited with status \(status)."
        case .invalidResponse:
            "Codex App Server returned an invalid response."
        }
    }
}

public enum CodexAppServer {
    public static func fetch(_ profile: Profile,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             timeout: TimeInterval = 15) async throws -> CodexAppServerResult {
        try await Task.detached(priority: .utility) {
            try fetchBlocking(profile, environment: environment, timeout: timeout)
        }.value
    }

    public static func executableCandidates(configuredPath: String?,
                                            environment: [String: String],
                                            home: String) -> [String] {
        if let configuredPath { return [configuredPath] }
        var candidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { "\($0)/codex" }
        candidates.append(contentsOf: [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func fetchBlocking(_ profile: Profile,
                                      environment: [String: String],
                                      timeout: TimeInterval) throws -> CodexAppServerResult {
        guard case let .openAI(codexHome, configuredPath) = profile.configuration else {
            throw CodexAppServerError.invalidProfile
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: codexHome, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CodexAppServerError.missingHome(codexHome)
        }

        let executable = try resolveExecutable(
            configuredPath: configuredPath,
            environment: environment,
            home: fileManager.homeDirectoryForCurrentUser.path,
            fileManager: fileManager)
        let expectedHome = canonical(codexHome)

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        var childEnvironment = environment
        // CODEX_HOME is the account boundary for this app. Process-scoped
        // automation credentials and alternate state roots must not override
        // the account the user selected in profiles.json.
        for key in [
            "CODEX_ACCESS_TOKEN", "CODEX_SQLITE_HOME",
            "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE",
            "OPENAI_WORKLOAD_IDENTITY_CONTEXT"
        ] {
            childEnvironment.removeValue(forKey: key)
        }
        childEnvironment["CODEX_HOME"] = expectedHome
        let executableDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let path = [executableDirectory, childEnvironment["PATH"],
                    "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
            .compactMap { $0 }
            .joined(separator: ":")
        childEnvironment["PATH"] = path
        process.environment = childEnvironment

        try process.run()
        let timeoutState = TimeoutState()
        let timeoutTask = DispatchWorkItem {
            timeoutState.fire()
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + timeout, execute: timeoutTask)

        let writer = input.fileHandleForWriting
        // A failed/early-exiting CLI must become a regular Swift error, not
        // SIGPIPE the menu bar app while a request is being written.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = JSONLineReader(handle: output.fileHandleForReading)
        var closedInput = false
        defer {
            timeoutTask.cancel()
            if !closedInput { try? writer.close() }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        try send([
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "llm_usage_bar",
                    "title": "LLM Usage Bar",
                    "version": "1.0"
                ]
            ]
        ], to: writer, process: process)
        let initializeData = try response(id: 0, from: reader, process: process,
                                          timeoutState: timeoutState)
        let initializedHome = try initializeHome(from: initializeData)
        guard canonical(initializedHome) == expectedHome else {
            throw CodexAppServerError.homeMismatch(
                expected: expectedHome, actual: canonical(initializedHome))
        }

        try send(["method": "initialized", "params": [:]], to: writer, process: process)
        try send([
            "method": "account/read",
            "id": 1,
            "params": ["refreshToken": false]
        ], to: writer, process: process)
        let accountData = try response(id: 1, from: reader, process: process,
                                       timeoutState: timeoutState)
        let account = try codexAccount(from: accountData)

        try send(["method": "account/rateLimits/read", "id": 2],
                 to: writer, process: process)
        let usageData = try response(id: 2, from: reader, process: process,
                                     timeoutState: timeoutState)
        let usage = try codexUsageSnapshot(from: usageData)

        try writer.close()
        closedInput = true
        process.waitUntilExit()
        timeoutTask.cancel()
        if timeoutState.didFire { throw CodexAppServerError.timeout }
        guard process.terminationStatus == 0 else {
            throw CodexAppServerError.exited(process.terminationStatus)
        }
        return CodexAppServerResult(account: account, usage: usage)
    }

    private static func resolveExecutable(configuredPath: String?,
                                          environment: [String: String], home: String,
                                          fileManager: FileManager) throws -> String {
        if let configuredPath {
            guard configuredPath.hasPrefix("/"),
                  fileManager.isExecutableFile(atPath: configuredPath) else {
                throw CodexAppServerError.invalidExecutable(configuredPath)
            }
            return configuredPath
        }
        for candidate in executableCandidates(configuredPath: nil,
                                              environment: environment, home: home) {
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw CodexAppServerError.executableNotFound
    }

    private static func send(_ message: [String: Any], to handle: FileHandle,
                             process: Process) throws {
        do {
            var data = try JSONSerialization.data(
                withJSONObject: message, options: [.withoutEscapingSlashes])
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            guard !process.isRunning else { throw CodexAppServerError.invalidResponse }
            throw CodexAppServerError.exited(process.terminationStatus)
        }
    }

    private static func response(id expectedID: Int, from reader: JSONLineReader,
                                 process: Process, timeoutState: TimeoutState) throws -> Data {
        while let line = try reader.nextLine() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? NSNumber else { continue }
            if id.intValue == expectedID { return line }
        }
        if process.isRunning { process.waitUntilExit() }
        if timeoutState.didFire { throw CodexAppServerError.timeout }
        if process.terminationStatus != 0 { throw CodexAppServerError.exited(process.terminationStatus) }
        throw CodexAppServerError.invalidResponse
    }

    private static func initializeHome(from data: Data) throws -> String {
        struct Envelope: Decodable {
            struct Result: Decodable { let codexHome: String }
            let result: Result?
        }
        guard let home = try JSONDecoder().decode(Envelope.self, from: data).result?.codexHome else {
            throw CodexAppServerError.invalidResponse
        }
        return home
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private final class JSONLineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func nextLine() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                return line
            }
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            buffer.append(chunk)
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
