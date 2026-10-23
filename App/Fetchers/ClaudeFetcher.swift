import Foundation

/// Claude Code subscription limits (Pro / Max) — the same numbers `/usage` shows in the CLI.
///
/// Sources (picked in Settings):
/// - Claude Code login: the OAuth token Claude Code keeps in the Keychain ("Claude Code-credentials"),
///   falling back to ~/.claude/.credentials.json. Never refreshed here — refresh tokens rotate, so
///   refreshing from this app would log Claude Code out.
/// - claude.ai session: the `sessionKey` cookie from a logged-in browser.
/// - OAuth token: an access token you paste yourself.
actor ClaudeFetcher: UsageFetcher {
    let service = Service.claude

    /// Anthropic's usage endpoint rate-limits aggressively (HTTP 429). After a 429 we back off for
    /// 10 minutes and keep showing the last good numbers instead of an error.
    private var notBefore: Date = .distantPast
    private var lastGood: ProviderUsage?

    func fetch(_ settings: FetchSettings) async throws -> ProviderUsage {
        if Date() < notBefore, let lastGood { return lastGood }
        do {
            let usage = try await fetchFresh(settings)
            lastGood = usage
            return usage
        } catch FetchError.http(429, let body) {
            notBefore = Date().addingTimeInterval(10 * 60)
            if let lastGood { return lastGood }
            throw FetchError.http(429, body)
        }
    }

    private func fetchFresh(_ settings: FetchSettings) async throws -> ProviderUsage {
        switch settings.claudeSource {
        case .auto:
            let (token, plan) = try cliCredentials()
            return try await fetchOAuth(token: token, plan: plan)
        case .token:
            guard !settings.claudeToken.isEmpty else { throw FetchError.notSignedIn("Paste an OAuth token in Settings") }
            return try await fetchOAuth(token: settings.claudeToken, plan: nil)
        case .webSession:
            guard !settings.claudeSessionKey.isEmpty else { throw FetchError.notSignedIn("Paste your claude.ai sessionKey in Settings") }
            return try await fetchWeb(sessionKey: settings.claudeSessionKey)
        }
    }

    /// What each step returned (raw usage numbers, never the token) for Settings ▸ Run diagnostics.
    func diagnostics(_ settings: FetchSettings) async -> String {
        var lines = ["Source setting: \(settings.claudeSource.rawValue)"]
        let keychain = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        lines.append("Keychain \"Claude Code-credentials\": " + (keychain.status == 0 ? "readable" : "not readable (status \(keychain.status))"))
        let file = Parse.home.appendingPathComponent(".claude/.credentials.json")
        lines.append("~/.claude/.credentials.json: " + (FileManager.default.fileExists(atPath: file.path) ? "present" : "missing"))
        if let data = (keychain.status == 0 ? keychain.output : (try? String(contentsOf: file, encoding: .utf8)))?.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = root["claudeAiOauth"] as? [String: Any] {
            lines.append("Credential fields: \(oauth.keys.sorted().joined(separator: ", "))")
            lines.append("subscriptionType: \(oauth["subscriptionType"] ?? "–"), rateLimitTier: \(oauth["rateLimitTier"] ?? "–")")
            lines.append("scopes: \(oauth["scopes"] ?? "–")")
            if let expires = Parse.unixDate(oauth["expiresAt"]) {
                lines.append("Token expires: \(expires) (" + (expires > Date() ? "valid" : "EXPIRED — run `claude` to refresh") + ")")
            }
        }
        lines.append("")
        let token: String?
        switch settings.claudeSource {
        case .auto: token = try? cliCredentials().token
        case .token: token = settings.claudeToken.isEmpty ? nil : settings.claudeToken
        case .webSession: token = nil
        }
        if let token {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("ai-limits-widget", forHTTPHeaderField: "User-Agent")
            lines.append("GET api.anthropic.com/api/oauth/usage →")
            lines.append(await HTTP.raw(request))
        } else if settings.claudeSource == .webSession {
            lines.append("Web session source: run a normal refresh and check the status line.")
        } else {
            lines.append("No token available.")
        }
        // No second request here — the endpoint rate-limits back-to-back calls.
        if let lastGood {
            lines.append("")
            lines.append("Last shown: " + lastGood.windows.map { "\($0.label) \(UsageFormat.usedPercent($0))% used" }.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: OAuth API (Claude Code login or pasted token)

    private func fetchOAuth(token: String, plan: String?) async throws -> ProviderUsage {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ai-limits-widget", forHTTPHeaderField: "User-Agent")
        return try usage(from: try await HTTP.json(request), plan: plan)
    }

    private func cliCredentials() throws -> (token: String, plan: String?) {
        var raw: String?
        let keychain = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        if keychain.status == 0, !keychain.output.isEmpty { raw = keychain.output }
        if raw == nil {
            raw = try? String(contentsOf: Parse.home.appendingPathComponent(".claude/.credentials.json"), encoding: .utf8)
        }
        guard let data = raw?.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw FetchError.notSignedIn("Run `claude` and log in with your subscription")
        }
        return (token, (oauth["subscriptionType"] as? String)?.capitalized)
    }

    // MARK: claude.ai web session

    private func fetchWeb(sessionKey: String) async throws -> ProviderUsage {
        func request(_ path: String) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://claude.ai/api\(path)")!)
            request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
            return request
        }

        guard let orgs = try await HTTP.any(request("/organizations")) as? [[String: Any]], !orgs.isEmpty else {
            throw FetchError.parse("no organizations")
        }
        // Prefer the personal/chat org (the one that has the subscription limits).
        let org = orgs.first { ($0["capabilities"] as? [String])?.contains("chat") == true } ?? orgs[0]
        guard let orgID = org["uuid"] as? String else { throw FetchError.parse("organization id") }

        let plan = (org["capabilities"] as? [String])?
            .first { $0.hasPrefix("claude_") }?
            .replacingOccurrences(of: "claude_", with: "")
            .capitalized
        return try usage(from: try await HTTP.json(request("/organizations/\(orgID)/usage")), plan: plan)
    }

    // MARK: Shared parsing (both endpoints return the same shape)

    private func usage(from json: [String: Any], plan: String?) throws -> ProviderUsage {
        var windows: [UsageWindow] = []
        func add(_ key: String, _ label: String, headline: Bool) {
            guard let window = json[key] as? [String: Any],
                  let utilization = Parse.double(window["utilization"]) else { return }
            windows.append(UsageWindow(
                label: label,
                usedFraction: utilization / 100,
                resetsAt: Parse.isoDate(window["resets_at"]),
                isHeadline: headline
            ))
        }
        add("five_hour", "5-hour", headline: true)
        add("seven_day", "Weekly", headline: true)
        add("seven_day_opus", "Opus wk", headline: false)
        add("seven_day_sonnet", "Sonnet wk", headline: false)
        // Paid "extra usage" credits (Team/Enterprise), shown as a secondary bar.
        if let extra = json["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let utilization = Parse.double(extra["utilization"]) {
            windows.append(UsageWindow(label: "Extra usage", usedFraction: utilization / 100, resetsAt: nil, isHeadline: false))
        }

        guard !windows.isEmpty else { throw FetchError.parse("no five_hour / seven_day") }
        return ProviderUsage(service: service, windows: windows, plan: plan, fetchedAt: .now)
    }
}
