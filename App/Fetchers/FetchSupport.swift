import Foundation

protocol UsageFetcher: Sendable {
    var service: Service { get }
    func fetch(_ settings: FetchSettings) async throws -> ProviderUsage
}

enum FetchError: LocalizedError {
    case notSignedIn(String)
    case http(Int, String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn(let hint): hint
        case .http(401, _), .http(403, _): "Login expired — open the CLI once to refresh it"
        case .http(429, _): "Rate limited, will retry"
        case .http(let code, let body): "HTTP \(code) \(body.prefix(80))"
        case .parse(let what): "Unexpected response: \(what)"
        }
    }

    /// Status code plus the server's own error text (never contains our tokens) — for diagnostics.
    var detail: String {
        switch self {
        case .http(let code, let body):
            let compact = body.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
            return "HTTP \(code): \(compact.prefix(220))"
        default: return errorDescription ?? "\(self)"
        }
    }
}

extension Error {
    var diagnosticDetail: String { (self as? FetchError)?.detail ?? localizedDescription }
}

enum HTTP {
    static func json(_ request: URLRequest) async throws -> [String: Any] {
        guard let object = try await any(request) as? [String: Any] else {
            throw FetchError.parse("not a JSON object")
        }
        return object
    }

    static func any(_ request: URLRequest) async throws -> Any {
        var request = request
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw FetchError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Status code + pretty-printed body, for diagnostics.
    static func raw(_ request: URLRequest) async -> String {
        var request = request
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            var body = String(decoding: data.prefix(4000), as: UTF8.self)
            if let object = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                body = String(decoding: pretty.prefix(6000), as: UTF8.self)
            }
            return "HTTP \(code)\n\(body)"
        } catch {
            return "Request failed: \(error.localizedDescription)"
        }
    }

    static func postJSON(_ url: URL, body: [String: Any], headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return request
    }
}

enum Shell {
    /// Runs a binary synchronously and returns trimmed stdout.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum Parse {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// ISO-8601 with or without (any number of) fractional digits.
    static func isoDate(_ value: Any?) -> Date? {
        guard var string = value as? String else { return nil }
        if let range = string.range(of: #"\.\d+"#, options: .regularExpression) {
            string.removeSubrange(range)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func unixDate(_ value: Any?) -> Date? {
        guard var seconds = double(value) else { return nil }
        if seconds > 1e12 { seconds /= 1000 } // milliseconds
        return Date(timeIntervalSince1970: seconds)
    }

    static func windowLabel(seconds: Double?) -> String {
        guard let seconds else { return "Limit" }
        switch seconds {
        case 17_000...19_000: return "5-hour"
        case 600_000...610_000: return "Weekly"
        case 86_000...87_000: return "Daily"
        default: return UsageFormat.duration(seconds)
        }
    }
}
