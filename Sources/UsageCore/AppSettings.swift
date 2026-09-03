import Foundation

/// App-wide settings, kept in `config.json` next to `profiles.json`. Accounts
/// stay in their own file: this one holds only what is not per-account.
public struct AppSettings: Equatable, Sendable {
    /// The cadence the app has always used for the visible account.
    public static let defaultRefreshSeconds = 120
    /// Never faster than the per-account throttle. Anthropic's usage endpoint
    /// rate-limits on a rolling window and its `Retry-After` is always 0, so a
    /// tighter interval buys nothing and costs a 60s–600s backoff. A value
    /// below this is clamped rather than refused, so a typo cannot leave the
    /// app without a cadence.
    public static let minimumRefreshSeconds = 60
    /// Beyond an hour the gauge is stale enough to be misleading.
    public static let maximumRefreshSeconds = 3600
    public static let fileName = "config.json"

    public let refreshSeconds: Int

    public init(refreshSeconds: Int = defaultRefreshSeconds) {
        self.refreshSeconds = Self.clamp(refreshSeconds)
    }

    /// Shared by the per-account override in `profiles.json`, so one floor
    /// covers both places a cadence can be set.
    public static func clamp(_ seconds: Int) -> Int {
        Swift.min(Swift.max(seconds, minimumRefreshSeconds), maximumRefreshSeconds)
    }

    public static func url(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        Profiles.configDirectoryURL(home: home, environment: environment,
                                    fileManager: fileManager)
            .appendingPathComponent(fileName)
    }

    private struct Spec: Decodable {
        let refreshSeconds: Int?
    }

    /// Unusable JSON, or a key the app does not know, leaves the defaults in
    /// place: settings are a convenience, never a reason not to start.
    public static func decode(_ data: Data) -> AppSettings {
        guard let spec = try? JSONDecoder().decode(Spec.self, from: data) else {
            return AppSettings()
        }
        return AppSettings(refreshSeconds: spec.refreshSeconds ?? defaultRefreshSeconds)
    }

    public static func load(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> AppSettings {
        let path = url(home: home, environment: environment, fileManager: fileManager).path
        guard let data = fileManager.contents(atPath: path) else { return AppSettings() }
        return decode(data)
    }
}
