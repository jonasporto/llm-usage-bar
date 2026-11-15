import Foundation

/// Fetching for the command-line reader; the menu bar's store and polling stay independent.
public enum UsageCLIFetcher {
    public static func fetch(_ profile: Profile) async throws -> UsageSnapshot {
        if profile.usageAdapter != nil {
            return try await CommandAdapter.fetch(profile).usage
        }
        switch profile.configuration {
        case let .anthropic(service, _):
            guard let token = await Task.detached(priority: .utility, operation: {
                claudeToken(service: service)
            }).value else { throw CLIError.missingToken }
            let data = try await request(
                URL(string: "https://api.anthropic.com/api/oauth/usage")!, token: token,
                headers: ["anthropic-beta": "oauth-2025-04-20"])
            return try anthropicUsageSnapshot(from: data)
        case .openAI:
            return try await CodexAppServer.fetch(profile).usage
        case let .xAI(home):
            let auth = try GrokAuthStore.load(grokHome: home)
            let data = try await request(GrokAPI.billingURL, token: auth.accessToken,
                                         headers: ["x-xai-token-auth": "xai-grok-cli"])
            return try grokUsageSnapshot(from: data)
        case .antigravity:
            return try await AntigravityCLI.fetch(profile)
        case .command:
            return try await CommandAdapter.fetch(profile).usage
        }
    }

    static func request(_ url: URL, token: String, headers: [String: String]) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CLIError.http(code) }
        return data
    }

    static func accessToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return token
    }

    private static func claudeToken(service: String) -> String? {
        // Claude Code versions use either the username, username@hostname,
        // or another account label. Limit every query to the configured service.
        for account in [NSUserName(), "\(NSUserName())@\(ProcessInfo.processInfo.hostName)", nil] {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            var arguments = ["find-generic-password", "-s", service]
            if let account { arguments += ["-a", account] }
            process.arguments = arguments + ["-w"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { continue }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            if process.terminationStatus == 0, let token = accessToken(from: data) { return token }
        }
        return nil
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Authenticated requests never follow a redirect to another endpoint.
        completionHandler(nil)
    }
}
