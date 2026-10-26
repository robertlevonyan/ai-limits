import Foundation

/// Reads Gemini quota from the Antigravity app that's running right now.
///
/// Antigravity runs a local "language server" process. Its command line carries a CSRF token, and it
/// listens on a localhost port. Its `GetUserStatus` call returns the same per-model quota Antigravity
/// shows in its UI (`quotaInfo.remainingFraction` / `resetTime`), using Antigravity's own live login —
/// so nothing has to be refreshed here. Only works while Antigravity is open.
enum AntigravityLocal {
    struct Server {
        let pid: Int
        let csrfToken: String
        var ports: [Int]
    }

    // MARK: Find the process

    static func findServers(report: inout [String]) -> [Server] {
        let ps = Shell.run("/bin/ps", ["-axww", "-o", "pid=,command="])
        var servers: [Server] = []
        for line in ps.output.split(separator: "\n") {
            let text = String(line)
            let lowered = text.lowercased()
            guard lowered.contains("language_server"), lowered.contains("antigravity") || lowered.contains("csrf") else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let pid = Int(trimmed.prefix { $0.isNumber }) else { continue }
            guard let csrf = argument("csrf_token", in: text) else {
                report.append("Language server pid \(pid): no --csrf_token argument")
                continue
            }
            var ports = listeningPorts(pid: pid)
            for name in ["server_port", "extension_server_port", "port", "lsp_port"] {
                if let value = argument(name, in: text).flatMap(Int.init), !ports.contains(value) { ports.append(value) }
            }
            servers.append(Server(pid: pid, csrfToken: csrf, ports: ports))
            report.append("Language server pid \(pid): csrf token found, ports \(ports)")
        }
        if servers.isEmpty { report.append("No running Antigravity language server (is Antigravity open?)") }
        return servers
    }

    /// `--name value` or `--name=value`
    private static func argument(_ name: String, in commandLine: String) -> String? {
        let pattern = "--\(name)[= ]+([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: commandLine, range: NSRange(commandLine.startIndex..., in: commandLine)),
              let range = Range(match.range(at: 1), in: commandLine) else { return nil }
        return String(commandLine[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func listeningPorts(pid: Int) -> [Int] {
        let lsof = Shell.run("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", "\(pid)"])
        var ports: [Int] = []
        for line in lsof.output.split(separator: "\n") {
            guard let range = line.range(of: #":(\d+) \(LISTEN\)"#, options: .regularExpression) else { continue }
            let digits = line[range].filter(\.isNumber)
            if let port = Int(digits), !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    // MARK: Ask it

    /// The endpoint that answered last time. Reused on every refresh so we don't have to scan
    /// processes and ports (`ps` / `lsof`) every few seconds — that scan is also what makes macOS log
    /// "Unable to obtain a task name port right for pid …" for system processes it won't let us inspect.
    private final class EndpointCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (url: URL, csrf: String)?
        func get() -> (url: URL, csrf: String)? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: (url: URL, csrf: String)?) { lock.lock(); value = newValue; lock.unlock() }
    }
    private static let cache = EndpointCache()

    static func fetchQuota(report: inout [String]) async throws -> (windows: [String: UsageWindow], plan: String?) {
        // Fast path: the server we found before (until Antigravity restarts and it stops answering).
        if let cached = cache.get() {
            if let result = try? await query(cached.url, csrf: cached.csrf, report: &report) {
                return result
            }
            cache.set(nil)
            report.append("Cached endpoint stopped answering — looking for Antigravity again")
        }

        let servers = findServers(report: &report)
        guard !servers.isEmpty else { throw FetchError.notSignedIn("Open Antigravity to show Gemini usage") }

        var lastError: Error = FetchError.parse("language server didn't answer")
        for server in servers {
            for port in server.ports {
                for scheme in ["https", "http"] {
                    let url = URL(string: "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus")!
                    do {
                        let result = try await query(url, csrf: server.csrfToken, report: &report)
                        cache.set((url, server.csrfToken))
                        return result
                    } catch {
                        lastError = error
                    }
                }
            }
        }
        throw lastError
    }

    private static func query(_ url: URL, csrf: String, report: inout [String]) async throws -> (windows: [String: UsageWindow], plan: String?) {
        let body: [String: Any] = [
            "metadata": ["ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en"],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        let where_ = "\(url.scheme ?? "")://127.0.0.1:\(url.port ?? 0)"
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let json = try? JSONSerialization.jsonObject(with: data) else {
                let text = String(decoding: data.prefix(160), as: UTF8.self)
                report.append("\(where_): HTTP \(code) \(text)")
                throw FetchError.http(code, text)
            }
            let parsed = parse(json)
            report.append("\(where_): OK — \(parsed.windows.count) model group(s)")
            report += parsed.models.map { "  model: \($0)" }
            guard !parsed.windows.isEmpty else { throw FetchError.parse("no quotaInfo in GetUserStatus") }
            return (parsed.windows, parsed.plan)
        } catch let error as FetchError {
            throw error
        } catch {
            report.append("\(where_): \(error.localizedDescription)")
            throw error
        }
    }

    /// Walks the whole response for objects that carry `quotaInfo`, grouping by model family.
    static func parse(_ json: Any) -> (windows: [String: UsageWindow], plan: String?, models: [String]) {
        var groups: [String: UsageWindow] = [:]
        var plan: String?
        var models: [String] = []

        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if plan == nil, let planInfo = dict["planInfo"] as? [String: Any] {
                    plan = planInfo["planName"] as? String ?? planInfo["teamsTier"] as? String
                }
                if let quota = dict["quotaInfo"] as? [String: Any] {
                    let nameParts = [dict["label"], dict["displayName"], dict["name"], dict["model"],
                                     (dict["modelOrAlias"] as? [String: Any])?["model"]].compactMap { $0 as? String }
                    let name = nameParts.joined(separator: " ").lowercased()
                    let family: String?
                    if name.contains("gemini") && name.contains("pro") { family = "Pro" }
                    else if name.contains("gemini") && name.contains("flash") { family = "Flash" }
                    else if name.contains("claude") || name.contains("sonnet") || name.contains("opus") { family = "Claude" }
                    else if name.contains("gpt") { family = "GPT" }
                    else { family = nil }
                    let left: String
                    if let fraction = Parse.double(quota["remainingFraction"]) { left = "\(Int((fraction * 100).rounded()))%" } else { left = "0% (omitted)" }
                    let resets = quota["resetTime"] as? String ?? "–"
                    models.append("\(nameParts.first ?? "?") → \(family ?? "skipped"), left \(left), resets \(resets)")
                    if let family {
                        let remaining = Parse.double(quota["remainingFraction"]) ?? 0 // omitted when exhausted
                        let window = UsageWindow(label: family, usedFraction: 1 - remaining, resetsAt: Parse.isoDate(quota["resetTime"]))
                        if groups[family].map({ $0.remainingFraction > window.remainingFraction }) ?? true {
                            groups[family] = window
                        }
                    }
                }
                dict.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        return (groups, plan, models)
    }

    // MARK: Localhost TLS (the language server uses a self-signed certificate)

    private final class LocalhostTrust: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.host == "127.0.0.1", let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: LocalhostTrust(), delegateQueue: nil)
    }()
}
