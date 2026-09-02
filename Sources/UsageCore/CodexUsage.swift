import Foundation

public struct CodexAccount: Equatable, Sendable {
    public let email: String?
    public let plan: String?

    public init(email: String?, plan: String?) {
        self.email = email
        self.plan = plan
    }

    public var label: String? {
        let planLabel = plan.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        switch (email, planLabel) {
        case let (email?, plan?): return "\(email) · \(plan)"
        case let (email?, nil): return email
        case let (nil, plan?): return plan
        case (nil, nil): return nil
        }
    }
}

public enum CodexUsageError: LocalizedError, Equatable, Sendable {
    case notAuthenticated
    case apiKeyUnsupported
    case unsupportedAccount(String)
    case server(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "Not signed in — run codex login for this CODEX_HOME."
        case .apiKeyUnsupported:
            "API-key Codex uses usage-based billing and has no plan limit percentage."
        case let .unsupportedAccount(type):
            "Codex account type \(type) does not expose ChatGPT plan limits."
        case let .server(message):
            "Codex App Server: \(message)"
        case .invalidResponse:
            "Codex App Server returned an invalid response."
        }
    }
}

private struct RPCError: Decodable {
    let message: String
}

private struct AccountEnvelope: Decodable {
    struct Result: Decodable {
        struct Account: Decodable {
            let type: String
            let email: String?
            let planType: String?
        }

        let account: Account?
    }

    let result: Result?
    let error: RPCError?
}

private struct RateLimitsEnvelope: Decodable {
    struct Result: Decodable {
        let rateLimits: Limit?
        let rateLimitsByLimitId: [String: Limit]?
    }

    struct Limit: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: Window?
        let secondary: Window?
    }

    struct Window: Decodable {
        let usedPercent: Double?
        let windowDurationMins: Int?
        let resetsAt: TimeInterval?
    }

    let result: Result?
    let error: RPCError?
}

public func codexAccount(from response: Data) throws -> CodexAccount {
    let envelope = try JSONDecoder().decode(AccountEnvelope.self, from: response)
    if let error = envelope.error { throw CodexUsageError.server(error.message) }
    guard let account = envelope.result?.account else {
        throw CodexUsageError.notAuthenticated
    }
    switch account.type {
    case "chatgpt":
        return CodexAccount(email: account.email, plan: account.planType)
    case "apiKey":
        throw CodexUsageError.apiKeyUnsupported
    default:
        throw CodexUsageError.unsupportedAccount(account.type)
    }
}

public func codexUsageSnapshot(from response: Data) throws -> UsageSnapshot {
    let envelope = try JSONDecoder().decode(RateLimitsEnvelope.self, from: response)
    if let error = envelope.error { throw CodexUsageError.server(error.message) }
    guard let result = envelope.result else { throw CodexUsageError.invalidResponse }

    let limits: [(String, RateLimitsEnvelope.Limit)]
    if let byID = result.rateLimitsByLimitId, !byID.isEmpty {
        limits = byID.sorted { lhs, rhs in
            if lhs.key == "codex" { return true }
            if rhs.key == "codex" { return false }
            let left = lhs.value.limitName ?? lhs.key
            let right = rhs.value.limitName ?? rhs.key
            let order = left.localizedCaseInsensitiveCompare(right)
            return order == .orderedSame ? lhs.key < rhs.key : order == .orderedAscending
        }
    } else if let limit = result.rateLimits {
        limits = [(limit.limitId ?? "codex", limit)]
    } else {
        throw CodexUsageError.invalidResponse
    }

    var windows: [UsageWindow] = []
    for (fallbackID, limit) in limits {
        let limitID = limit.limitId ?? fallbackID
        append(limit.primary, position: "primary", limitID: limitID,
               limitName: limit.limitName, to: &windows)
        append(limit.secondary, position: "secondary", limitID: limitID,
               limitName: limit.limitName, to: &windows)
    }
    guard !windows.isEmpty else { throw CodexUsageError.invalidResponse }
    return UsageSnapshot(windows: windows)
}

private func append(_ source: RateLimitsEnvelope.Window?, position: String,
                    limitID: String, limitName: String?, to windows: inout [UsageWindow]) {
    guard let source, let utilization = source.usedPercent else { return }
    let duration = source.windowDurationMins
    let durationLabel = windowLabel(duration)
    let name = limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let label = name?.isEmpty == false ? "\(name!) · \(durationLabel)" : durationLabel
    windows.append(UsageWindow(
        id: "openai.\(limitID).\(position)",
        label: label,
        utilization: utilization,
        resetsAt: source.resetsAt.map(Date.init(timeIntervalSince1970:)),
        durationMinutes: duration,
        isPrimary: windows.isEmpty))
}

private func windowLabel(_ minutes: Int?) -> String {
    guard let minutes else { return "Usage window" }
    if minutes == 10_080 { return "Weekly" }
    if minutes < 60 { return "\(minutes)m window" }
    if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)d window" }
    if minutes.isMultiple(of: 60) { return "\(minutes / 60)h window" }
    return "\(minutes)m window"
}
