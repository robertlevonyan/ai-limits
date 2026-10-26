import Foundation
import Security

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
            let (token, plan) = try await validCLIToken()
            do {
                return try await fetchOAuth(token: token, plan: plan)
            } catch FetchError.http(401, _) {
                // Token was revoked early — renew once and retry.
                let (fresh, plan) = try await validCLIToken(forceRefresh: true)
                return try await fetchOAuth(token: fresh, plan: plan)
            }
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
        case .auto: token = try? await validCLIToken().token
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

    private struct CLICredentials {
        var token: String
        var plan: String?
        var refreshToken: String?
        var expires: Date?
        var root: [String: Any]
        var fromKeychain: Bool
    }

    private func cliCredentials() throws -> (token: String, plan: String?) {
        let creds = try loadCLICredentials()
        return (creds.token, creds.plan)
    }

    private func loadCLICredentials() throws -> CLICredentials {
        var raw: String?
        var fromKeychain = false
        let keychain = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        if keychain.status == 0, !keychain.output.isEmpty { raw = keychain.output; fromKeychain = true }
        if raw == nil {
            raw = try? String(contentsOf: Parse.home.appendingPathComponent(".claude/.credentials.json"), encoding: .utf8)
        }
        guard let data = raw?.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw FetchError.notSignedIn("Run `claude` and log in with your subscription")
        }
        return CLICredentials(
            token: token,
            plan: (oauth["subscriptionType"] as? String)?.capitalized,
            refreshToken: oauth["refreshToken"] as? String,
            expires: Parse.unixDate(oauth["expiresAt"]),
            root: root,
            fromKeychain: fromKeychain
        )
    }

    /// Claude Code only renews its login while you use it, so after a quiet weekend the saved token is
    /// expired. Renew it the same way Claude Code does and save the new login back where Claude Code
    /// keeps it (refresh tokens rotate, so Claude Code needs the new one too).
    private func validCLIToken(forceRefresh: Bool = false) async throws -> (token: String, plan: String?) {
        var creds = try loadCLICredentials()
        let expired = creds.expires.map { $0 < Date().addingTimeInterval(60) } ?? false
        guard forceRefresh || expired else { return (creds.token, creds.plan) }
        guard let refreshToken = creds.refreshToken else {
            throw FetchError.notSignedIn("Claude Code login expired — run `claude` once")
        }

        var lastError: Error = FetchError.notSignedIn("Claude Code login expired — run `claude` once")
        for endpoint in ["https://console.anthropic.com/v1/oauth/token", "https://platform.claude.com/v1/oauth/token"] {
            let request = HTTP.postJSON(URL(string: endpoint)!, body: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e", // Claude Code's public OAuth client
            ], headers: ["User-Agent": "ai-limits-widget"])
            do {
                let json = try await HTTP.json(request)
                guard let access = json["access_token"] as? String else { throw FetchError.parse("no access_token") }
                var oauth = creds.root["claudeAiOauth"] as? [String: Any] ?? [:]
                oauth["accessToken"] = access
                if let newRefresh = json["refresh_token"] as? String { oauth["refreshToken"] = newRefresh }
                if let seconds = Parse.double(json["expires_in"]) {
                    oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + seconds) * 1000)
                }
                creds.root["claudeAiOauth"] = oauth
                save(creds)
                return (access, creds.plan)
            } catch {
                lastError = error
            }
        }
        if case FetchError.http(let code, _)? = lastError as? FetchError, code == 400 || code == 401 {
            throw FetchError.notSignedIn("Claude Code login expired — run `claude` once")
        }
        throw lastError
    }

    /// Writes the renewed login back to Claude Code's Keychain item (or its credentials file).
    private func save(_ creds: CLICredentials) {
        guard let data = try? JSONSerialization.data(withJSONObject: creds.root),
              let json = String(data: data, encoding: .utf8) else { return }
        if creds.fromKeychain {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: "Claude Code-credentials"]
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(json.utf8)] as CFDictionary)
            if status != errSecSuccess {
                // Fall back to the `security` tool (it's already on the item's access list).
                let info = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials"]).output
                var account = NSUserName()
                if let regex = try? NSRegularExpression(pattern: #""acct"<blob>="([^"]*)""#),
                   let match = regex.firstMatch(in: info, range: NSRange(info.startIndex..., in: info)),
                   let range = Range(match.range(at: 1), in: info) {
                    account = String(info[range])
                }
                Shell.run("/usr/bin/security", ["add-generic-password", "-U", "-s", "Claude Code-credentials", "-a", account, "-w", json])
            }
        } else {
            let url = Parse.home.appendingPathComponent(".claude/.credentials.json")
            try? data.write(to: url, options: .atomic)
        }
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
