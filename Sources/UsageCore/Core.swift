import AppKit

// MARK: - Model

public struct Window: Decodable {
    public var utilization: Double?
    public var resets_at: String?

    public init(utilization: Double?, resets_at: String?) {
        self.utilization = utilization
        self.resets_at = resets_at
    }
}

public struct ExtraUsage: Decodable {
    public let is_enabled: Bool?
    public let used_credits: Double?
    public let monthly_limit: Double?
    public let currency: String?
    public let decimal_places: Int?

    public init(is_enabled: Bool?, used_credits: Double?, monthly_limit: Double?,
                currency: String?, decimal_places: Int?) {
        self.is_enabled = is_enabled
        self.used_credits = used_credits
        self.monthly_limit = monthly_limit
        self.currency = currency
        self.decimal_places = decimal_places
    }

    /// API values are in minor units (e.g. cents for USD). The currency comes
    /// from the payload; separators follow the reader's locale.
    public func money(_ raw: Double, locale: Locale = .current) -> String {
        let places = decimal_places ?? 2
        let value = raw / pow(10, Double(places))
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currency ?? "USD"
        nf.locale = locale
        return nf.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

public struct Usage: Decodable {
    public let five_hour: Window?
    public let seven_day: Window?
    public let extra_usage: ExtraUsage?
}

// MARK: - Dynamic weekly buckets

/// Per-model weekly buckets come from two shapes:
/// 1. top-level `seven_day_<model>` objects with a utilization;
/// 2. `limits[]` entries with kind `weekly_scoped` and a
///    `scope.model.display_name` (how Fable ships today).
/// Both become bars, deduplicated by label, preferred models first.
public func dynamicWindows(from data: Data) -> [(String, Window)] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [] }
    var out: [(String, Window)] = []

    for (key, value) in root {
        guard key.hasPrefix("seven_day_"), key != "seven_day_oauth_apps",
              let dict = value as? [String: Any],
              let util = dict["utilization"] as? Double
        else { continue }
        let label = "Weekly " + key.dropFirst("seven_day_".count)
            .split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        out.append((label, Window(utilization: util, resets_at: dict["resets_at"] as? String)))
    }

    for entry in root["limits"] as? [[String: Any]] ?? [] {
        guard entry["kind"] as? String == "weekly_scoped",
              let percent = entry["percent"] as? Double,
              let scope = entry["scope"] as? [String: Any],
              let model = scope["model"] as? [String: Any],
              let name = model["display_name"] as? String
        else { continue }
        let label = "Weekly \(name)"
        guard !out.contains(where: { $0.0 == label }) else { continue }
        out.append((label, Window(utilization: percent, resets_at: entry["resets_at"] as? String)))
    }

    let preferred = ["Weekly Opus", "Weekly Sonnet", "Weekly Fable"]
    return out.sorted {
        let a = preferred.firstIndex(of: $0.0) ?? Int.max
        let b = preferred.firstIndex(of: $1.0) ?? Int.max
        return a == b ? $0.0 < $1.0 : a < b
    }
}

// MARK: - Balance anchor

/// Available balance = user-entered balance minus spend since the anchor.
/// When the monthly counter resets (used drops below the anchor), the
/// anchor re-bases to 0.
public func remainingBalance(balance: Double, anchorUsed: Double, used: Double) -> Double {
    let effectiveAnchor = used < anchorUsed ? 0 : anchorUsed
    return max(0, balance - (used - effectiveAnchor))
}

/// Reads a balance the user typed, in their own locale: currency symbols and
/// spaces are dropped, then the locale decides which separator is decimal.
/// The fallback (locale parse failed) treats the LAST separator as decimal.
public func parseAmount(_ input: String, locale: Locale = .current) -> Double? {
    let cleaned = String(input.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" })
    guard cleaned.contains(where: \.isNumber) else { return nil }

    let nf = NumberFormatter()
    nf.numberStyle = .decimal
    nf.locale = locale
    if let n = nf.number(from: cleaned) { return n.doubleValue }

    guard let lastSeparator = cleaned.lastIndex(where: { $0 == "." || $0 == "," }) else {
        return Double(cleaned)
    }
    let integer = cleaned[..<lastSeparator].filter { $0.isNumber || $0 == "-" }
    let fraction = cleaned[cleaned.index(after: lastSeparator)...].filter(\.isNumber)
    return Double("\(integer).\(fraction)")
}

// MARK: - Gauge drawing

public enum Gauge {
    public static func color(_ pct: Double) -> NSColor {
        pct >= 85 ? .systemRed : pct >= 60 ? .systemOrange : .systemGreen
    }

    /// 270° arc gauge, filled proportionally — drawn as a real image so the
    /// menu bar shows color.
    public static func image(pct: Double) -> NSImage {
        let fraction = max(0, min(1, pct / 100))
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY - 1)
            let radius: CGFloat = 6.5

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius,
                            startAngle: 225, endAngle: -45, clockwise: true)
            track.lineWidth = 3
            track.lineCapStyle = .round
            NSColor(white: 0.5, alpha: 0.55).setStroke()
            track.stroke()

            if fraction > 0.02 {
                let fill = NSBezierPath()
                fill.appendArc(withCenter: center, radius: radius,
                               startAngle: 225, endAngle: 225 - 270 * fraction,
                               clockwise: true)
                fill.lineWidth = 3
                fill.lineCapStyle = .round
                color(pct).setStroke()
                fill.stroke()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
