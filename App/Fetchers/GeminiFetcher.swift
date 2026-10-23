import Foundation
import SQLite3

/// Gemini limits, from either of Google's two coding tools:
///
/// - **Antigravity** (IDE / agent): reads the Google access token Antigravity keeps in its VS Code-style
///   state database (~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb) and asks
///   Cloud Code's `fetchAvailableModels` for the per-model quota (`quotaInfo.remainingFraction` / `resetTime`).
///   Antigravity refreshes that token itself while it's open; if it has been closed for over an hour the
///   last numbers are kept until you open it again.
/// - **Gemini CLI** ("Login with Google"): ~/.gemini/oauth_creds.json + `retrieveUserQuota`. Expired tokens are
///   refreshed in memory with the OAuth client from your local Gemini CLI install.
actor GeminiFetcher: UsageFetcher {
    let service = Service.gemini

    private let hosts = ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"]
    private let cliBase = "https://cloudcode-pa.googleapis.com/v1internal"
    private var cachedToken: (value: String, expires: Date)?
    private var cachedProject: String?
    private var cachedTier: String?
    private var antigravityProject: String?
    private var refreshedAntigravity: (value: String, expires: Date)?
    private var antigravityClients: [(id: String, secret: String)]?

    func fetch(_ settings: FetchSettings) async throws -> ProviderUsage {
        let project = settings.geminiProject.isEmpty ? nil : settings.geminiProject
        switch settings.geminiSource {
        case .auto:
            do {
                return try await fetchAntigravityAnyWay(project: project)
            } catch let antigravityError {
                do {
                    return try await fetchCLI(settings, project: project)
                } catch {
                    // Neither worked: report the more useful of the two errors.
                    switch (Self.isSignInError(antigravityError), Self.isSignInError(error)) {
                    case (true, true): throw FetchError.notSignedIn("Couldn't read your Antigravity login — Settings ▸ Gemini ▸ Run diagnostics")
                    case (true, false): throw error
                    default: throw antigravityError
                    }
                }
            }
        case .antigravity:
            return try await fetchAntigravityAnyWay(project: project)
        case .cli:
            return try await fetchCLI(settings, project: project)
        case .token:
            guard !settings.geminiToken.isEmpty else { throw FetchError.notSignedIn("Paste a Google OAuth access token in Settings") }
            do {
                return try await fetchAntigravity(tokens: [settings.geminiToken], project: project)
            } catch {
                return try await quotaFromCLIEndpoint(token: settings.geminiToken, project: project)
            }
        }
    }

    // MARK: Antigravity

    /// 1) ask the running Antigravity app (uses its live login), 2) fall back to its saved login.
    private func fetchAntigravityAnyWay(project: String?) async throws -> ProviderUsage {
        var report: [String] = []
        do {
            let local = try await AntigravityLocal.fetchQuota(report: &report)
            if let plan = local.plan { cachedTier = plan }
            return ProviderUsage(service: service, windows: Self.ordered(local.windows), plan: local.plan ?? cachedTier ?? "Antigravity", fetchedAt: .now)
        } catch let localError {
            do {
                return try await fetchAntigravity(tokens: try await antigravityAccessTokens(), project: project)
            } catch {
                // Antigravity closed and its saved login expired: say so plainly.
                if Self.isSignInError(localError) { throw FetchError.notSignedIn("Open Antigravity to update Gemini usage") }
                throw localError
            }
        }
    }

    private func fetchAntigravity(tokens: [String], project: String?) async throws -> ProviderUsage {
        var lastError: Error = FetchError.notSignedIn("Sign in to Antigravity first")
        for token in tokens {
            for host in hosts {
                do {
                    return try await antigravityQuota(token: token, host: host, project: project)
                } catch FetchError.http(let code, let body) where code == 401 || code == 403 {
                    lastError = code == 401
                        ? FetchError.notSignedIn("Antigravity login expired — open Antigravity to refresh it")
                        : FetchError.http(code, body)
                    break // token is bad on every host, try the next token
                } catch {
                    lastError = error // try the next host
                }
            }
        }
        throw lastError
    }

    private func antigravityQuota(token: String, host: String, project: String?) async throws -> ProviderUsage {
        let headers = [
            "Authorization": "Bearer \(token)",
            "User-Agent": "antigravity/1.0.0 darwin/arm64",
        ]

        var projectID = project ?? antigravityProject
        var tier: String?
        if projectID == nil || cachedTier == nil {
            let load = try await HTTP.json(HTTP.postJSON(
                URL(string: "\(host)/v1internal:loadCodeAssist")!,
                body: ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]],
                headers: headers
            ))
            projectID = projectID ?? Self.projectID(from: load)
            tier = Self.tier(from: load)
            antigravityProject = projectID
            cachedTier = tier
        }

        var body: [String: Any] = [:]
        if let projectID { body["project"] = projectID }
        let json = try await HTTP.json(HTTP.postJSON(URL(string: "\(host)/v1internal:fetchAvailableModels")!, body: body, headers: headers))

        // `models` is a map of modelId → info (some versions return an array).
        var entries: [(id: String, info: [String: Any])] = []
        if let map = json["models"] as? [String: [String: Any]] {
            entries = map.map { ($0.key, $0.value) }
        } else if let list = json["models"] as? [[String: Any]] {
            entries = list.map { (($0["model"] ?? $0["name"] ?? $0["id"]) as? String ?? "", $0) }
        }

        var groups: [String: UsageWindow] = [:]
        for (id, info) in entries {
            guard let quota = info["quotaInfo"] as? [String: Any] else { continue }
            let name = (id + " " + (info["displayName"] as? String ?? "")).lowercased()
            let family: String
            if name.contains("gemini") && name.contains("pro") { family = "Pro" }
            else if name.contains("gemini") && name.contains("flash") { family = "Flash" }
            else if name.contains("claude") { family = "Claude" }
            else { continue }
            // An exhausted model omits remainingFraction.
            let remaining = Parse.double(quota["remainingFraction"]) ?? 0
            let window = UsageWindow(label: family, usedFraction: 1 - remaining, resetsAt: Parse.isoDate(quota["resetTime"]))
            if let existing = groups[family], existing.remainingFraction <= window.remainingFraction { continue }
            groups[family] = window
        }
        guard !groups.isEmpty else { throw FetchError.parse("no model quotas from Antigravity") }
        return ProviderUsage(service: service, windows: Self.ordered(groups), plan: tier ?? cachedTier ?? "Antigravity", fetchedAt: .now)
    }

    /// Access tokens from Antigravity's saved login; if it holds a refresh token, mint a fresh one too
    /// (so this keeps working while Antigravity is closed).
    private func antigravityAccessTokens() async throws -> [String] {
        if let refreshed = refreshedAntigravity, refreshed.expires > Date().addingTimeInterval(120) {
            return [refreshed.value]
        }
        var found = AntigravityAuth.discover()
        var tokens = found.accessTokens
        if !found.refreshTokens.isEmpty {
            if antigravityClients == nil { antigravityClients = AntigravityAuth.oauthClients(report: &found.report) }
            if let refreshed = await AntigravityAuth.refresh(found.refreshTokens, clients: antigravityClients ?? [], report: &found.report) {
                refreshedAntigravity = refreshed
                tokens.insert(refreshed.value, at: 0)
            }
        }
        guard !tokens.isEmpty else {
            throw FetchError.notSignedIn("Couldn't find Antigravity's login — open Settings ▸ Gemini ▸ Run diagnostics")
        }
        return tokens
    }

    /// Plain-text report of every step (no secrets) for Settings ▸ Gemini ▸ Run diagnostics.
    func diagnostics(_ settings: FetchSettings) async -> String {
        var lines = ["AI Limits — Gemini diagnostics", "Date: \(Date())", "Source setting: \(settings.geminiSource.rawValue)", ""]
        lines.append("== Running Antigravity (live) ==")
        var localReport: [String] = []
        do {
            let local = try await AntigravityLocal.fetchQuota(report: &localReport)
            lines += localReport
            lines.append("Result: " + Self.ordered(local.windows).map { "\($0.label) \(UsageFormat.usedPercent($0))% used" }.joined(separator: ", ") + " (plan: \(local.plan ?? "–"))")
        } catch {
            lines += localReport
            lines.append("Result: \(error.diagnosticDetail)")
        }
        lines.append("")
        lines.append("== Antigravity saved login ==")
        var found = AntigravityAuth.discover()
        lines += found.report
        let mark = found.report.count
        var tokens = found.accessTokens
        if !found.refreshTokens.isEmpty {
            let clients = AntigravityAuth.oauthClients(report: &found.report)
            antigravityClients = clients
            if let refreshed = await AntigravityAuth.refresh(found.refreshTokens, clients: clients, report: &found.report) {
                refreshedAntigravity = refreshed
                tokens.insert(refreshed.value, at: 0)
            }
            lines += found.report[mark...]
        }

        lines.append("")
        lines.append("== Antigravity quota API ==")
        for (index, token) in tokens.prefix(4).enumerated() {
            for host in hosts {
                do {
                    let usage = try await antigravityQuota(token: token, host: host, project: settings.geminiProject.isEmpty ? nil : settings.geminiProject)
                    lines.append("token #\(index + 1) @ \(host): OK — " + usage.windows.map { "\($0.label) \(Int(($0.remainingFraction * 100).rounded()))%" }.joined(separator: ", "))
                } catch {
                    lines.append("token #\(index + 1) (\(token.count) chars) @ \(host): \(error.diagnosticDetail)")
                }
            }
        }
        if tokens.isEmpty { lines.append("No tokens to try.") }

        lines.append("")
        lines.append("== Gemini CLI ==")
        let creds = Parse.home.appendingPathComponent(".gemini/oauth_creds.json")
        lines.append("~/.gemini/oauth_creds.json: " + (FileManager.default.fileExists(atPath: creds.path) ? "present" : "missing"))
        return lines.joined(separator: "\n")
    }

    // MARK: Gemini CLI

    private func fetchCLI(_ settings: FetchSettings, project: String?) async throws -> ProviderUsage {
        let override = settings.geminiClientID.isEmpty || settings.geminiClientSecret.isEmpty
            ? nil : (id: settings.geminiClientID, secret: settings.geminiClientSecret)
        let token = try await accessToken(clientOverride: override)
        return try await quotaFromCLIEndpoint(token: token, project: project)
    }

    private func quotaFromCLIEndpoint(token: String, project: String?) async throws -> ProviderUsage {
        let headers = ["Authorization": "Bearer \(token)"]
        if let project, cachedProject != project { cachedProject = project }
        if cachedProject == nil {
            let load = try await HTTP.json(HTTP.postJSON(
                URL(string: "\(cliBase):loadCodeAssist")!,
                body: ["metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]],
                headers: headers
            ))
            cachedProject = Self.projectID(from: load)
            cachedTier = Self.tier(from: load)
        }

        var body: [String: Any] = [:]
        if let cachedProject { body["project"] = cachedProject }
        let quota = try await HTTP.json(HTTP.postJSON(URL(string: "\(cliBase):retrieveUserQuota")!, body: body, headers: headers))
        guard let buckets = quota["buckets"] as? [[String: Any]], !buckets.isEmpty else {
            throw FetchError.parse("no quota buckets")
        }

        var groups: [String: UsageWindow] = [:]
        for bucket in buckets {
            guard let remaining = Parse.double(bucket["remainingFraction"]) else { continue }
            let model = (bucket["modelId"] as? String ?? "").lowercased()
            let family = model.contains("pro") ? "Pro" : model.contains("flash") ? "Flash" : "Requests"
            let window = UsageWindow(label: family, usedFraction: 1 - remaining, resetsAt: Parse.isoDate(bucket["resetTime"]))
            if let existing = groups[family], existing.remainingFraction <= window.remainingFraction { continue }
            groups[family] = window
        }
        return ProviderUsage(service: service, windows: Self.ordered(groups), plan: cachedTier, fetchedAt: .now)
    }

    // MARK: Helpers

    /// Pro drives the ring (that's the model you lose first); the others are shown as secondary bars.
    private static func ordered(_ groups: [String: UsageWindow]) -> [UsageWindow] {
        let order = ["Pro", "Flash", "Claude", "GPT", "Requests"]
        let headline = order.first { groups[$0] != nil }
        return order.compactMap { name -> UsageWindow? in
            guard var window = groups[name] else { return nil }
            window.isHeadline = name == headline
            return window
        }
    }

    private static func isSignInError(_ error: Error) -> Bool {
        guard let error = error as? FetchError else { return false }
        if case .notSignedIn = error { return true }
        return false
    }

    private static func projectID(from load: [String: Any]) -> String? {
        if let id = load["cloudaicompanionProject"] as? String { return id }
        return (load["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
    }

    private static func tier(from load: [String: Any]) -> String? {
        let tier = (load["paidTier"] ?? load["currentTier"]) as? [String: Any]
        return tierName(tier?["id"] as? String) ?? tier?["name"] as? String
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: Auth

    private func accessToken(clientOverride: (id: String, secret: String)?) async throws -> String {
        if let cachedToken, cachedToken.expires > Date().addingTimeInterval(60) { return cachedToken.value }

        let credsURL = Parse.home.appendingPathComponent(".gemini/oauth_creds.json")
        guard let creds = Parse.readJSON(credsURL) else {
            throw FetchError.notSignedIn("Run `gemini` and choose “Login with Google”")
        }
        if let token = creds["access_token"] as? String,
           let expiry = Parse.unixDate(creds["expiry_date"]),
           expiry > Date().addingTimeInterval(60) {
            cachedToken = (token, expiry)
            return token
        }

        guard let refresh = creds["refresh_token"] as? String else {
            throw FetchError.notSignedIn("Gemini login expired — run `gemini` once")
        }
        guard let client = clientOverride ?? Self.findOAuthClient() else {
            throw FetchError.notSignedIn("Gemini token expired and the Gemini CLI install wasn't found — run `gemini` once, or set the OAuth client in Settings")
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "client_secret", value: client.secret),
            .init(name: "refresh_token", value: refresh),
            .init(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let json = try await HTTP.json(request)
        guard let token = json["access_token"] as? String else { throw FetchError.parse("token refresh") }
        let lifetime = Parse.double(json["expires_in"]) ?? 3000
        cachedToken = (token, Date().addingTimeInterval(lifetime))
        return token
    }

    private static func tierName(_ id: String?) -> String? {
        switch id {
        case "free-tier": "Free"
        case "standard-tier": "Standard"
        case "legacy-tier": "Legacy"
        default: nil
        }
    }

    /// Finds the Gemini CLI's public "installed app" OAuth client in the local install.
    static func findOAuthClient() -> (id: String, secret: String)? {
        let fm = FileManager.default
        let home = Parse.home.path
        var roots = [
            "/opt/homebrew/lib/node_modules",
            "/usr/local/lib/node_modules",
            "\(home)/.npm-global/lib/node_modules",
            "\(home)/.bun/install/global/node_modules",
            "\(home)/.local/share/pnpm/global/5/node_modules",
        ]
        for cellar in ["/opt/homebrew/Cellar/gemini-cli", "/usr/local/Cellar/gemini-cli"] {
            for version in (try? fm.contentsOfDirectory(atPath: cellar)) ?? [] {
                roots.append("\(cellar)/\(version)/libexec/lib/node_modules")
            }
        }
        for node in (try? fm.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node")) ?? [] {
            roots.append("\(home)/.nvm/versions/node/\(node)/lib/node_modules")
        }

        // Also follow the `gemini` binary on the user's PATH.
        var bundleFiles: [URL] = []
        let which = Shell.run("/bin/zsh", ["-lc", "command -v gemini"]).output
        if which.hasPrefix("/") {
            let real = URL(fileURLWithPath: which).resolvingSymlinksInPath()
            bundleFiles.append(real)
            let dir = real.deletingLastPathComponent()
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".js") {
                bundleFiles.append(dir.appendingPathComponent(name))
            }
            var ancestor = real
            while ancestor.path != "/" {
                ancestor.deleteLastPathComponent()
                if ancestor.lastPathComponent == "node_modules" { roots.insert(ancestor.path, at: 0) }
            }
        }

        let relative = [
            "@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
        ]
        let candidates = roots.flatMap { root in relative.map { URL(fileURLWithPath: "\(root)/\($0)") } } + bundleFiles

        for file in candidates where fm.fileExists(atPath: file.path) {
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            guard size < 40_000_000, let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if let id = firstMatch(#"OAUTH_CLIENT_ID\s*=\s*['"]([^'"]+)['"]"#, in: text) ?? firstMatch(#"(\d{6,}-[a-z0-9]+\.apps\.googleusercontent\.com)"#, in: text),
               let secret = firstMatch(#"OAUTH_CLIENT_SECRET\s*=\s*['"]([^'"]+)['"]"#, in: text) ?? firstMatch(#"(GOCSPX-[A-Za-z0-9_\-]+)"#, in: text) {
                return (id, secret)
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
