import Foundation

public struct GrokAuth: Sendable {
    public let accessToken: String
    public let email: String?

    public init(accessToken: String, email: String?) {
        self.accessToken = accessToken
        self.email = email
    }
}

public struct GrokAccount: Equatable, Sendable {
    public let email: String?
    public let plan: String?

    public init(email: String?, plan: String?) {
        self.email = email
        self.plan = plan
    }

    public var label: String? {
        let planLabel = plan.map(grokPlanLabel)
        switch (email, planLabel) {
        case let (email?, plan?): return "\(email) · \(plan)"
        case let (email?, nil): return email
        case let (nil, plan?): return plan
        case (nil, nil): return nil
        }
    }
}

public enum GrokUsageError: LocalizedError, Equatable, Sendable {
    case invalidProfile
    case missingHome(String)
    case notAuthenticated
    case tokenExpired
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidProfile:
            "The selected profile is not an xAI profile."
        case let .missingHome(path):
            "GROK_HOME does not exist: \(path)"
        case .notAuthenticated:
            "Not signed in — run grok login for this GROK_HOME."
        case .tokenExpired:
            "Token expired — open grok on this profile to refresh."
        case .invalidResponse:
            "xAI billing returned an invalid response."
        }
    }
}

public enum GrokAPI {
    public static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    public static let userURL = URL(string: "https://cli-chat-proxy.grok.com/v1/user?include=subscription")!
}

public enum GrokAuthStore {
    public static func load(grokHome: String, now: Date = Date(),
                            fileManager: FileManager = .default) throws -> GrokAuth {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: grokHome, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GrokUsageError.missingHome(grokHome)
        }
        let url = URL(fileURLWithPath: grokHome).appendingPathComponent("auth.json")
        guard let data = fileManager.contents(atPath: url.path) else {
            throw GrokUsageError.notAuthenticated
        }
        return try grokAuth(from: data, now: now)
    }
}

private struct GrokAuthEntry: Decodable {
    let key: String?
    let email: String?
    let expires_at: String?
}

private struct BillingConfig: Decodable {
    struct Period: Decodable {
        let type: String?
        let start: String?
        let end: String?
    }

    struct Money: Decodable {
        let val: Double?
    }

    let currentPeriod: Period?
    let creditUsagePercent: Double?
    let onDemandCap: Money?
    let onDemandUsed: Money?
    let billingPeriodStart: String?
    let billingPeriodEnd: String?
}

private struct BillingEnvelope: Decodable {
    let config: BillingConfig?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.config),
           let nested = try container.decodeIfPresent(BillingConfig.self, forKey: .config) {
            config = nested
        } else {
            config = try BillingConfig(from: decoder)
        }
    }

    enum CodingKeys: String, CodingKey { case config }
}

private struct UserEnvelope: Decodable {
    let email: String?
    let subscriptionTier: String?
}

public func grokAuth(from data: Data, now: Date = Date()) throws -> GrokAuth {
    guard let entries = try? JSONDecoder().decode([String: GrokAuthEntry].self, from: data),
          !entries.isEmpty else {
        throw GrokUsageError.notAuthenticated
    }

    let ranked = entries.sorted { lhs, rhs in
        let leftPreferred = lhs.key.localizedCaseInsensitiveContains("auth.x.ai")
        let rightPreferred = rhs.key.localizedCaseInsensitiveContains("auth.x.ai")
        if leftPreferred != rightPreferred { return leftPreferred }
        return lhs.key < rhs.key
    }

    var sawExpired = false
    for (_, entry) in ranked {
        guard let token = entry.key?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { continue }
        if let expiry = UsageDate.parse(entry.expires_at), expiry <= now {
            sawExpired = true
            continue
        }
        let email = entry.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GrokAuth(accessToken: token,
                        email: email?.isEmpty == false ? email : nil)
    }
    throw sawExpired ? GrokUsageError.tokenExpired : GrokUsageError.notAuthenticated
}

public func grokAccount(from data: Data) throws -> GrokAccount {
    let user = try JSONDecoder().decode(UserEnvelope.self, from: data)
    let email = user.email?.trimmingCharacters(in: .whitespacesAndNewlines)
    let plan = user.subscriptionTier?.trimmingCharacters(in: .whitespacesAndNewlines)
    return GrokAccount(
        email: email?.isEmpty == false ? email : nil,
        plan: plan?.isEmpty == false ? plan : nil)
}

public func grokUsageSnapshot(from data: Data) throws -> UsageSnapshot {
    let envelope = try JSONDecoder().decode(BillingEnvelope.self, from: data)
    guard let config = envelope.config else { throw GrokUsageError.invalidResponse }

    let start = UsageDate.parse(config.currentPeriod?.start ?? config.billingPeriodStart)
    let end = UsageDate.parse(config.currentPeriod?.end ?? config.billingPeriodEnd)
    let durationMinutes: Int?
    if let start, let end {
        durationMinutes = max(0, Int(end.timeIntervalSince(start) / 60))
    } else {
        durationMinutes = nil
    }

    let hasPeriod = config.currentPeriod != nil || config.billingPeriodEnd != nil
    guard config.creditUsagePercent != nil || hasPeriod else {
        throw GrokUsageError.invalidResponse
    }

    let window = UsageWindow(
        id: "xai.primary",
        label: grokWindowLabel(type: config.currentPeriod?.type, durationMinutes: durationMinutes),
        utilization: config.creditUsagePercent ?? 0,
        resetsAt: end,
        durationMinutes: durationMinutes,
        isPrimary: true)

    let used = config.onDemandUsed?.val ?? 0
    let cap = config.onDemandCap?.val ?? 0
    let extra: ExtraUsage? = (used > 0 || cap > 0)
        ? ExtraUsage(is_enabled: true, used_credits: used,
                     monthly_limit: cap > 0 ? cap : nil,
                     currency: "USD", decimal_places: 2)
        : nil

    return UsageSnapshot(windows: [window], extraUsage: extra)
}

func grokPlanLabel(_ raw: String) -> String {
    switch raw.replacingOccurrences(of: "_", with: "").lowercased() {
    case "xpremium": return "X Premium"
    case "xpremiumplus", "xpremium+": return "X Premium+"
    case "supergrok": return "SuperGrok"
    case "supergrokheavy": return "SuperGrok Heavy"
    default: return raw.replacingOccurrences(of: "_", with: " ")
    }
}

private func grokWindowLabel(type: String?, durationMinutes: Int?) -> String {
    if let type {
        let raw = type.replacingOccurrences(of: "USAGE_PERIOD_TYPE_", with: "",
                                            options: .caseInsensitive)
        switch raw.lowercased() {
        case "weekly": return "Weekly"
        case "monthly": return "Monthly"
        case "daily": return "Daily"
        default: break
        }
    }
    guard let minutes = durationMinutes else { return "Usage window" }
    if (6 * 1_440...8 * 1_440).contains(minutes) { return "Weekly" }
    if (20 * 1_440...45 * 1_440).contains(minutes) { return "Monthly" }
    if minutes < 60 { return "\(minutes)m window" }
    if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)d window" }
    if minutes.isMultiple(of: 60) { return "\(minutes / 60)h window" }
    return "\(minutes)m window"
}
