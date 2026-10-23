import Foundation

/// OpenAI Codex CLI limits for ChatGPT plans (5-hour + weekly windows).
///
/// Primary source: the usage endpoint the Codex CLI itself calls, authenticated with ~/.codex/auth.json.
/// Fallback: the `rate_limits` block Codex writes into its newest session log (~/.codex/sessions/**.jsonl).
struct CodexFetcher: UsageFetcher {
    let service = Service.codex

    private var codexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"] { return URL(fileURLWithPath: custom) }
        return Parse.home.appendingPathComponent(".codex")
    }

    func fetch(_ settings: FetchSettings) async throws -> ProviderUsage {
        switch settings.codexSource {
        case .auto:
            do {
                let (token, account) = try cliCredentials()
                return try await fetchFromAPI(token: token, account: account)
            } catch {
                if let local = fetchFromSessionLogs() { return local }
                throw error
            }
        case .logsOnly:
            guard let local = fetchFromSessionLogs() else {
                throw FetchError.notSignedIn("No Codex session logs with rate limits yet — use `codex` once")
            }
            return local
        case .token:
            guard !settings.codexToken.isEmpty else { throw FetchError.notSignedIn("Paste a ChatGPT access token in Settings") }
            return try await fetchFromAPI(token: settings.codexToken, account: settings.codexAccountID.isEmpty ? nil : settings.codexAccountID)
        }
    }

    func diagnostics(_ settings: FetchSettings) async -> String {
        var lines = ["Source setting: \(settings.codexSource.rawValue)"]
        let authURL = codexHome.appendingPathComponent("auth.json")
        lines.append("auth.json: " + (FileManager.default.fileExists(atPath: authURL.path) ? "present" : "missing"))
        if let credentials = try? cliCredentials() {
            let (token, account) = credentials
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let account { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
            request.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
            lines.append("GET chatgpt.com/backend-api/wham/usage →")
            lines.append(await HTTP.raw(request))
        }
        lines.append("Session-log fallback: " + (fetchFromSessionLogs().map { u in u.windows.map { "\($0.label) used \(Int(($0.usedFraction * 100).rounded()))%" }.joined(separator: ", ") } ?? "nothing found"))
        return lines.joined(separator: "\n")
    }

    // MARK: API

    private func cliCredentials() throws -> (token: String, account: String?) {
        guard let auth = Parse.readJSON(codexHome.appendingPathComponent("auth.json")),
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else {
            throw FetchError.notSignedIn("Run `codex login` with your ChatGPT account")
        }
        return (accessToken, tokens["account_id"] as? String)
    }

    private func fetchFromAPI(token accessToken: String, account: String?) async throws -> ProviderUsage {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let account {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        let json = try await HTTP.json(request)

        guard let limits = json["rate_limit"] as? [String: Any] else { throw FetchError.parse("no rate_limit") }
        let windows = ["primary_window", "secondary_window"].compactMap { key -> UsageWindow? in
            guard let window = limits[key] as? [String: Any],
                  let used = Parse.double(window["used_percent"]) else { return nil }
            var reset = Parse.unixDate(window["reset_at"])
            if reset == nil, let after = Parse.double(window["reset_after_seconds"]) {
                reset = Date().addingTimeInterval(after)
            }
            return UsageWindow(
                label: Parse.windowLabel(seconds: Parse.double(window["limit_window_seconds"])),
                usedFraction: used / 100,
                resetsAt: reset
            )
        }
        guard !windows.isEmpty else { throw FetchError.parse("empty rate_limit") }
        let plan = (json["plan_type"] as? String)?.capitalized
        return ProviderUsage(service: service, windows: windows, plan: plan, fetchedAt: .now)
    }

    // MARK: Session-log fallback

    private func fetchFromSessionLogs() -> ProviderUsage? {
        let sessions = codexHome.appendingPathComponent("sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if newest == nil || date > newest!.date { newest = (url, date) }
        }
        guard let newest, let text = try? String(contentsOf: newest.url, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data),
                  let limits = Self.find("rate_limits", in: event) as? [String: Any] else { continue }
            let eventDate = Parse.isoDate((event as? [String: Any])?["timestamp"]) ?? newest.date

            let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
                guard let window = limits[key] as? [String: Any],
                      let used = Parse.double(window["used_percent"]) else { return nil }
                var reset = Parse.unixDate(window["resets_at"])
                if reset == nil, let seconds = Parse.double(window["resets_in_seconds"]) {
                    reset = eventDate.addingTimeInterval(seconds)
                }
                let minutes = Parse.double(window["window_minutes"])
                return UsageWindow(
                    label: Parse.windowLabel(seconds: minutes.map { $0 * 60 }),
                    usedFraction: used / 100,
                    resetsAt: reset
                )
            }
            if !windows.isEmpty {
                return ProviderUsage(service: service, windows: windows, plan: "from last session", fetchedAt: eventDate)
            }
        }
        return nil
    }

    private static func find(_ key: String, in object: Any) -> Any? {
        if let dict = object as? [String: Any] {
            if let hit = dict[key] { return hit }
            for value in dict.values { if let hit = find(key, in: value) { return hit } }
        } else if let array = object as? [Any] {
            for value in array { if let hit = find(key, in: value) { return hit } }
        }
        return nil
    }
}
