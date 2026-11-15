import Foundation

/// A one-shot report. Only explicitly selected, non-credential fields are serialized.
public enum UsageCLI {
    public static let help = """
    Usage: llm-usage [--json] [--help]
    Read every account from the menu bar's profiles.json, once.
    Default: account, provider, window, percent used, local reset time.
    --json: structured output with ISO 8601 UTC reset times (null if unknown).
    Exit codes: 0 success, 1 account errors (partial output), 2 arguments/configuration.
    No retries or persistent cache; avoid frequent invocations (provider rate limits).
    """

    public struct Options {
        public let json: Bool
        public let help: Bool

        public init(arguments: [String]) throws {
            guard arguments.allSatisfy({ ["--json", "--help", "-h"].contains($0) }) else {
                throw CLIError.invalidArguments
            }
            json = arguments.contains("--json")
            help = arguments.contains("--help") || arguments.contains("-h")
        }
    }

    public struct Report: Encodable, Sendable {
        public let accounts: [Account]
        public var hasErrors: Bool { accounts.contains { $0.error != nil } }

        public func json() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }

        public func table(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
            let percent = NumberFormatter()
            percent.locale = locale
            percent.numberStyle = .percent
            percent.maximumFractionDigits = 1
            let date = DateFormatter()
            date.locale = locale
            date.timeZone = timeZone
            date.dateStyle = .short
            date.timeStyle = .short
            var rows = [["ACCOUNT", "PROVIDER", "WINDOW", "USED", "RESETS"]]
            for account in accounts {
                if let error = account.error {
                    rows.append([account.name, account.provider, "Error: \(error)", "—", "—"])
                } else if account.windows.isEmpty {
                    rows.append([account.name, account.provider, "No usage windows", "—", "—"])
                } else {
                    for window in account.windows {
                        rows.append([account.name, account.provider, window.label,
                                     percent.string(from: NSNumber(value: window.percentUsed / 100)) ?? "—",
                                     window.resetsAt.map(date.string(from:)) ?? "—"])
                    }
                }
            }
            // Keep user-configured labels on one line and suppress terminal controls.
            rows = rows.map { $0.map { value in
                String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
            } }
            let widths = (0..<5).map { column in rows.map { $0[column].count }.max() ?? 0 }
            return rows.map { row in
                row.enumerated().map { index, value in
                    index == 4 ? value : value + String(repeating: " ", count: widths[index] - value.count)
                }.joined(separator: "  ")
            }.joined(separator: "\n")
        }
    }

    public struct Account: Encodable, Sendable {
        public let id: String
        public let name: String
        public let provider: String
        public let windows: [Window]
        public let error: String?
    }

    public struct Window: Encodable, Sendable {
        public let id: String
        public let label: String
        public let percentUsed: Double
        public let resetsAt: Date?

        enum CodingKeys: String, CodingKey { case id, label, percentUsed, resetsAt }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(label, forKey: .label)
            try container.encode(percentUsed, forKey: .percentUsed)
            try container.encode(resetsAt, forKey: .resetsAt)
        }
    }

    /// Sequential fetching avoids a burst against the same provider. Failures never
    /// discard another account's results or include raw responses/credential paths.
    public static func collect(
        profiles: [Profile],
        fetch: (Profile) async throws -> UsageSnapshot = UsageCLIFetcher.fetch
    ) async -> Report {
        var accounts: [Account] = []
        for profile in profiles {
            do {
                let usage = try await fetch(profile)
                guard usage.windows.allSatisfy({ $0.utilization.isFinite }) else {
                    throw CLIError.invalidResponse
                }
                accounts.append(Account(id: profile.id, name: profile.name,
                                        provider: profile.provider.rawValue,
                                        windows: usage.windows.map {
                    Window(id: $0.id, label: $0.label, percentUsed: $0.utilization, resetsAt: $0.resetsAt)
                }, error: nil))
            } catch {
                accounts.append(Account(id: profile.id, name: profile.name,
                                        provider: profile.provider.rawValue, windows: [],
                                        error: safeError(error)))
            }
        }
        return Report(accounts: accounts)
    }

    static func safeError(_ error: Error) -> String {
        if let error = error as? CLIError { return error.localizedDescription }
        // Do not serialize arbitrary errors: subprocesses, decoder errors and
        // transport errors can contain raw payloads, URLs or credentials.
        switch error {
        case GrokUsageError.notAuthenticated, GrokUsageError.tokenExpired:
            return "Not authenticated; sign in with the provider CLI."
        case CommandAdapterError.missingExecutable, CommandAdapterError.invalidExecutable:
            return "Usage adapter not found; check path or adapter in profiles.json."
        case let CommandAdapterError.exited(status):
            return "Usage adapter exited with status \(status)."
        case CommandAdapterError.invalidResponse:
            return "Usage adapter returned an invalid response."
        case CodexAppServerError.timeout, CommandAdapterError.timeout, AntigravityCLIError.timeout:
            return "Provider CLI timed out."
        default:
            return "Usage unavailable; check the profile and provider CLI login."
        }
    }
}

enum CLIError: LocalizedError {
    case invalidArguments, missingToken, invalidResponse, http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid command-line arguments."
        case .missingToken: "No Claude token in Keychain; sign in with the provider CLI."
        case .invalidResponse: "Provider returned an invalid usage response."
        case .http(401), .http(403): "Authentication failed; sign in with the provider CLI."
        case .http(429): "Rate limited; wait before trying again."
        case let .http(code): "Usage request failed (HTTP \(code))."
        }
    }
}
