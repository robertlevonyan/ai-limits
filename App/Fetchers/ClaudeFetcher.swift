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

    /// Anthropic's usage endpoint rate-limits aggressively (HTTP 429). After a 429 we wait — as long as
    /// its Retry-After says, otherwise 2 → 5 → 10 → 20 → 30 minutes — and make NO request meanwhile.
    /// While waiting we show the last good numbers (kept across restarts), or read the same limits from
    /// the rate-limit headers of a tiny Claude request (see `fetchViaMessageHeaders`).
    private var notBefore: Date = .distantPast
    private var consecutive429 = 0
    private var lastHeaderProbe: Date = .distantPast
    private var lastGood: ProviderUsage? = ClaudeFetcher.loadLastGood() {
        didSet { ClaudeFetcher.saveLastGood(lastGood) }
    }

    func fetch(_ settings: FetchSettings) async throws -> ProviderUsage {
        if Date() < notBefore {
            return try await whileRateLimited(settings)
        }
        do {
            let usage = try await fetchFresh(settings)
            consecutive429 = 0
            lastGood = usage
            return usage
        } catch FetchError.http(429, _) {
            return try await backOff(retryAfter: nil, settings)
        } catch let RateLimited.wait(seconds) {
            return try await backOff(retryAfter: seconds, settings)
        }
    }

    private func backOff(retryAfter seconds: TimeInterval?, _ settings: FetchSettings) async throws -> ProviderUsage {
        do {
            consecutive429 += 1
            let ladder: [TimeInterval] = [120, 300, 600, 1200, 1800]
            let wait = seconds ?? ladder[min(consecutive429 - 1, ladder.count - 1)]
            notBefore = Date().addingTimeInterval(wait)
            return try await whileRateLimited(settings)
        }
    }

    /// No calls to the usage endpoint until `notBefore`.
    private func whileRateLimited(_ settings: FetchSettings) async throws -> ProviderUsage {
        // Same numbers from response headers, at most every 5 minutes (Claude Code login only).
        if settings.claudeSource == .auto, Date().timeIntervalSince(lastHeaderProbe) > 300 {
            lastHeaderProbe = Date()
            if let creds = try? await validCLIToken(),
               let usage = try? await fetchViaMessageHeaders(token: creds.token, plan: creds.plan) {
                lastGood = usage
                return usage
            }
        }
        if var cached = lastGood {
            // Older than 10 minutes: still show it, but flagged ("⚠︎ Not updating" in the widget).
            if let fetched = cached.fetchedAt, Date().timeIntervalSince(fetched) > 600 {
                cached.error = "Anthropic is rate-limiting usage checks — showing numbers from \(fetched.formatted(date: .omitted, time: .shortened))"
            }
            return cached
        }
        let minutes = max(1, Int((notBefore.timeIntervalSinceNow / 60).rounded(.up)))
        throw FetchError.notSignedIn("Anthropic is rate-limiting usage checks — retrying in \(minutes) min")
    }

    private enum RateLimited: Error { case wait(TimeInterval?) }

    private static let lastGoodKey = "claude.lastGood"
    private static func loadLastGood() -> ProviderUsage? {
        guard let data = UserDefaults.standard.data(forKey: lastGoodKey) else { return nil }
        return try? JSONDecoder().decode(ProviderUsage.self, from: data)
    }
    private static func saveLastGood(_ usage: ProviderUsage?) {
        guard let usage, let data = try? JSONEncoder().encode(usage) else { return }
        UserDefaults.standard.set(data, forKey: lastGoodKey)
    }

    private func fetchFresh(_ settings: FetchSettings) async throws -> ProviderUsage {
        switch settings.claudeSource {
        case .auto:
            let (token, plan) = try await validCLIToken()
            do {
                return try await fetchOAuth(token: token, plan: plan)
            } catch FetchError.http(401, _) {
                // Rejected early (Claude Code may have renewed it): re-read the Keychain once and retry.
                cachedCLI = nil
                let (fresh, plan) = try await validCLIToken(reread: true)
                guard fresh != token else { throw FetchError.notSignedIn("Claude Code login expired — run `claude` once") }
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
        if Date() < notBefore {
            lines.append("Usage endpoint: rate-limited, waiting until \(notBefore) (no request sent)")
        } else if let token {
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 429 {
            throw RateLimited.wait((http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init))
        }
        guard (200..<300).contains(code) else {
            throw FetchError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.parse("not a JSON object")
        }
        return try usage(from: json, plan: plan)
    }

    /// Fallback while the usage endpoint is rate-limited: every Claude API response carries the
    /// subscription's limits in `anthropic-ratelimit-unified-5h-*` / `-7d-*` headers. Sends a minimal
    /// request (1 output token on the smallest model) — a negligible bit of your usage — and reads them.
    private func fetchViaMessageHeaders(token: String, plan: String?) async throws -> ProviderUsage {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5",
            "max_tokens": 1,
            "system": "You are Claude Code, Anthropic's official CLI for Claude.",
            "messages": [["role": "user", "content": "."]],
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.parse("no response") }

        func header(_ name: String) -> String? { http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-\(name)") }
        func window(_ key: String, _ label: String, headline: Bool, blocks: Bool?) -> UsageWindow? {
            guard let utilization = header("\(key)-utilization").flatMap(Double.init) else { return nil }
            let reset = header("\(key)-reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            // Header values are 0…1 (the usage endpoint uses 0…100).
            let used = utilization > 1.5 ? utilization / 100 : utilization
            return UsageWindow(label: label, usedFraction: used, resetsAt: reset, isHeadline: headline, blocks: blocks)
        }
        let windows = [window("5h", "5-hour", headline: true, blocks: nil),
                       window("7d", "Weekly", headline: false, blocks: true)].compactMap { $0 }
        guard !windows.isEmpty else { throw FetchError.parse("no rate-limit headers (HTTP \(http.statusCode))") }
        // Keep extra-usage info from the last full read, if any.
        let extra = lastGood?.windows.filter { $0.label == "Extra usage" } ?? []
        return ProviderUsage(service: service, windows: windows + extra, plan: plan ?? lastGood?.plan, fetchedAt: .now)
    }

    private struct CLICredentials {
        var token: String
        var plan: String?
        var expires: Date?
    }

    /// Claude Code's login, read once and kept in memory. The Keychain is read again only when this
    /// expires or the API rejects it — not on every fetch — so macOS asks at most once per renewal.
    private var cachedCLI: CLICredentials?
    /// After a failed or denied Keychain read, don't ask again until this time (no dialog storms).
    private var nextKeychainAttempt: Date = .distantPast

    private func loadCLICredentials() throws -> CLICredentials {
        guard Date() >= nextKeychainAttempt else {
            throw FetchError.notSignedIn("Can't read the Claude Code login — allow “security” to access “Claude Code-credentials”, then refresh")
        }
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
            // Denied, cancelled or not signed in: wait 10 minutes before reading (and prompting) again.
            nextKeychainAttempt = Date().addingTimeInterval(600)
            throw FetchError.notSignedIn("Run `claude` and log in with your subscription")
        }
        return CLICredentials(
            token: token,
            plan: (oauth["subscriptionType"] as? String)?.capitalized,
            expires: Parse.unixDate(oauth["expiresAt"])
        )
    }

    /// Returns Claude Code's current access token. Read-only: this app never refreshes the login or
    /// writes to Claude Code's Keychain item. Refresh tokens rotate, so refreshing here would break
    /// Claude Code's login, and writing to the item resets its access list (the daily “security wants
    /// to access…” prompts). When the token has expired we wait for Claude Code to renew it.
    private func validCLIToken(reread: Bool = false) async throws -> (token: String, plan: String?) {
        func isExpired(_ creds: CLICredentials) -> Bool {
            creds.expires.map { $0 < Date().addingTimeInterval(60) } ?? false
        }
        if !reread, let cached = cachedCLI, !isExpired(cached) {
            return (cached.token, cached.plan)
        }
        // Expired cached token: look at most once a minute for one Claude Code has renewed.
        if !reread, cachedCLI != nil, Date() < nextKeychainAttempt {
            throw FetchError.notSignedIn("Claude Code login expired — run `claude` once")
        }
        let creds = try loadCLICredentials()
        cachedCLI = creds
        if isExpired(creds) {
            nextKeychainAttempt = Date().addingTimeInterval(60)
            throw FetchError.notSignedIn("Claude Code login expired — run `claude` once")
        }
        return (creds.token, creds.plan)
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
        func add(_ key: String, _ label: String, headline: Bool, blocks: Bool? = nil) {
            guard let window = json[key] as? [String: Any],
                  let utilization = Parse.double(window["utilization"]) else { return }
            windows.append(UsageWindow(
                label: label,
                usedFraction: utilization / 100,
                resetsAt: Parse.isoDate(window["resets_at"]),
                isHeadline: headline,
                blocks: blocks
            ))
        }
        add("five_hour", "5-hour", headline: true)
        // The 5-hour session drives the ring, top bar and big number; weekly is shown as a secondary bar
        // (and still takes over the ring if it's used up — see ProviderUsage.binding).
        add("seven_day", "Weekly", headline: false, blocks: true)
        add("seven_day_opus", "Opus wk", headline: false)
        add("seven_day_sonnet", "Sonnet wk", headline: false)
        // Paid "extra usage" credits (Team/Enterprise), shown as a secondary bar.
        if let extra = json["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let utilization = Parse.double(extra["utilization"]) {
            windows.append(UsageWindow(label: "Extra usage", usedFraction: utilization / 100, resetsAt: nil, isHeadline: false, blocks: false))
        }

        guard !windows.isEmpty else { throw FetchError.parse("no five_hour / seven_day") }
        return ProviderUsage(service: service, windows: windows, plan: plan, fetchedAt: .now)
    }
}
