import CommonCrypto
import Foundation
import SQLite3

/// Finds the Google login the Antigravity app keeps on this Mac.
///
/// Antigravity is a VS Code–style Electron app. Its settings live in a SQLite file
/// (~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb, table `ItemTable`).
/// Logins are usually kept as `secret://…` entries, encrypted with Electron's safeStorage:
/// AES-128-CBC, key = PBKDF2-SHA1(Keychain "Antigravity Safe Storage" password, "saltysalt", 1003 rounds),
/// IV = 16 spaces, ciphertext prefixed with "v10". macOS asks once to allow reading that Keychain item.
///
/// Every step adds a line to `report` — names, sizes and yes/no only, never token values — so the
/// Settings ▸ Gemini ▸ "Run diagnostics" button can show what was (not) found.
enum AntigravityAuth {
    struct Found {
        var accessTokens: [String] = []
        var refreshTokens: [String] = []
        var report: [String] = []
    }

    private static let appNames = ["Antigravity", "Antigravity IDE", "Google Antigravity"]

    // MARK: Discover

    static func discover() -> Found {
        var found = Found()
        let support = Parse.home.appendingPathComponent("Library/Application Support")
        let candidates = appNames.map { support.appendingPathComponent("\($0)/User/globalStorage/state.vscdb") }
        guard let db = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            found.report.append("state.vscdb: not found (looked in \(appNames.joined(separator: ", ")))")
            if let dirs = try? FileManager.default.contentsOfDirectory(atPath: support.path) {
                let similar = dirs.filter { $0.lowercased().contains("antigravity") || $0.lowercased().contains("gemini") }
                found.report.append("Application Support folders like it: \(similar)")
            }
            return found
        }
        found.report.append("state.vscdb: \(db.path)")

        let rows = readItemTable(db, report: &found.report)
        found.report.append("ItemTable rows: \(rows.count)")

        var safeKey: Data?
        var triedKey = false
        let hints = ["auth", "secret", "token", "google", "antigravity", "jetski", "account", "login", "oauth", "credential", "session"]

        for (key, value) in rows {
            let lowered = key.lowercased()
            guard hints.contains(where: { lowered.contains($0) }) else { continue }
            let before = (found.accessTokens.count, found.refreshTokens.count)
            var note = "• \(key) — \(value.count) bytes"

            // Antigravity's "UnifiedStateSync" values are base64 → protobuf → base64 → protobuf…,
            // so unwrap every embedded base64 run a few levels deep and scan each layer for tokens.
            var layers: [Data] = []
            unwrap(value, depth: 0, into: &layers)
            for layer in layers { collect(String(decoding: layer, as: UTF8.self), into: &found) }
            if layers.count > 1 { note += ", \(layers.count - 1) encoded layer(s)" }
            if let json = try? JSONSerialization.jsonObject(with: value) as? [String: Any] {
                note += ", fields: \(json.keys.sorted().joined(separator: ", "))"
                for field in ["apiKey", "accessToken", "access_token"] {
                    if let token = json[field] as? String, token.count > 20, !found.accessTokens.contains(token) {
                        found.accessTokens.insert(token, at: 0)
                    }
                }
            }

            if let encrypted = encryptedPayload(value) {
                if !triedKey {
                    safeKey = safeStorageKey(report: &found.report)
                    triedKey = true
                }
                if let safeKey, let plain = decrypt(encrypted, key: safeKey) {
                    note += ", decrypted \(plain.count) bytes"
                    collect(String(decoding: plain, as: UTF8.self), into: &found)
                    if let json = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] {
                        note += " (fields: \(json.keys.sorted().joined(separator: ", ")))"
                        for field in ["accessToken", "access_token", "apiKey", "token"] {
                            if let token = json[field] as? String, token.count > 20, !found.accessTokens.contains(token) {
                                found.accessTokens.insert(token, at: 0)
                            }
                        }
                        for field in ["refreshToken", "refresh_token"] {
                            if let token = json[field] as? String, token.count > 20, !found.refreshTokens.contains(token) {
                                found.refreshTokens.append(token)
                            }
                        }
                    }
                } else {
                    note += ", encrypted (could not decrypt)"
                }
            }

            note += " → access tokens +\(found.accessTokens.count - before.0), refresh tokens +\(found.refreshTokens.count - before.1)"
            found.report.append(note)
        }

        found.accessTokens = Array(found.accessTokens.prefix(6))
        found.refreshTokens = Array(found.refreshTokens.prefix(4))
        found.report.append("Total: \(found.accessTokens.count) access token(s), \(found.refreshTokens.count) refresh token(s)")
        return found
    }

    /// Adds `data` and every base64 blob found inside it (recursively, up to 4 levels).
    private static func unwrap(_ data: Data, depth: Int, into layers: inout [Data]) {
        guard depth <= 4, layers.count < 200 else { return }
        layers.append(data)
        let text = String(decoding: data, as: UTF8.self)
        for run in matches(#"[A-Za-z0-9+/_\-]{24,}={0,2}"#, in: text) {
            if run.hasPrefix("ya29.") || run.hasPrefix("1//") { continue }
            var normalized = run.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "="))
            normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
            guard let decoded = Data(base64Encoded: normalized), decoded.count >= 16 else { continue }
            unwrap(decoded, depth: depth + 1, into: &layers)
        }
    }

    private static func collect(_ text: String, into found: inout Found) {
        for token in matches(#"ya29\.[A-Za-z0-9._\-]{20,}"#, in: text) where !found.accessTokens.contains(token) {
            found.accessTokens.append(token)
        }
        for token in matches(#"1//[A-Za-z0-9_\-]{20,}"#, in: text) where !found.refreshTokens.contains(token) {
            found.refreshTokens.append(token)
        }
    }

    // MARK: SQLite

    private static func readItemTable(_ url: URL, report: inout [String]) -> [(String, Data)] {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK else {
            report.append("Could not open state.vscdb (SQLite \(status)) — macOS may be blocking access; check System Settings ▸ Privacy & Security ▸ Full Disk Access")
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM ItemTable", -1, &statement, nil) == SQLITE_OK else {
            report.append("Could not read ItemTable: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(statement) }
        var rows: [(String, Data)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyPointer = sqlite3_column_text(statement, 0) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 1))
            guard length > 0, length < 5_000_000, let blob = sqlite3_column_blob(statement, 1) else { continue }
            rows.append((String(cString: keyPointer), Data(bytes: blob, count: length)))
        }
        return rows
    }

    // MARK: Electron safeStorage

    /// VS Code stores secrets as JSON `{"type":"Buffer","data":[…]}` or raw bytes, starting with "v10"/"v11".
    private static func encryptedPayload(_ value: Data) -> Data? {
        var bytes = value
        if let json = try? JSONSerialization.jsonObject(with: value) as? [String: Any],
           json["type"] as? String == "Buffer",
           let numbers = json["data"] as? [Int] {
            bytes = Data(numbers.map { UInt8(truncatingIfNeeded: $0) })
        }
        guard bytes.count > 3 else { return nil }
        let prefix = String(decoding: bytes.prefix(3), as: UTF8.self)
        return prefix == "v10" || prefix == "v11" ? bytes.dropFirst(3) : nil
    }

    private static func safeStorageKey(report: inout [String]) -> Data? {
        for name in appNames {
            let result = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "\(name) Safe Storage", "-w"])
            guard result.status == 0, !result.output.isEmpty else { continue }
            report.append("Keychain \"\(name) Safe Storage\": found")
            var key = Data(count: kCCKeySizeAES128)
            let password = Array(result.output.utf8)
            let salt = Array("saltysalt".utf8)
            let status = key.withUnsafeMutableBytes { keyBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password.map { Int8(bitPattern: $0) }, password.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128
                )
            }
            return status == Int32(kCCSuccess) ? key : nil
        }
        report.append("Keychain \"… Safe Storage\": not found or access denied (\(appNames.map { "\($0) Safe Storage" }.joined(separator: ", ")))")
        return nil
    }

    private static func decrypt(_ data: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, data.count,
                            outBytes.baseAddress, outCapacity, &written
                        )
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        return out.prefix(written)
    }

    // MARK: OAuth refresh (uses Antigravity's own installed-app client, read from its bundle)

    static func oauthClients(report: inout [String]) -> [(id: String, secret: String)] {
        let fm = FileManager.default
        let roots = appNames.flatMap { name in
            ["/Applications/\(name).app", "\(Parse.home.path)/Applications/\(name).app"]
        }.filter { fm.fileExists(atPath: $0) }
        guard let app = roots.first else {
            report.append("Antigravity.app: not found in /Applications or ~/Applications")
            return []
        }
        report.append("App bundle: \(app)")

        // The client lives in packed files (app.asar, the Go language server), not loose .js files,
        // so search every file's raw bytes around "GOCSPX-" / ".apps.googleusercontent.com".
        var pairs: [(id: String, secret: String)] = []
        var scanned = 0
        let base = URL(fileURLWithPath: "\(app)/Contents")
        let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        let secretMarker = Data("GOCSPX-".utf8)
        let idMarker = Data(".apps.googleusercontent.com".utf8)
        while let url = enumerator?.nextObject() as? URL, scanned < 20_000 {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize, size > 0, size < 400_000_000 else { continue }
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
            scanned += 1
            guard data.range(of: secretMarker) != nil else { continue }
            let secrets = Set(snippets(around: secretMarker, in: data).flatMap { matches(#"GOCSPX-[A-Za-z0-9_\-]{20,}"#, in: $0) })
            let ids = Set(snippets(around: idMarker, in: data).flatMap { matches(#"\d{6,}-[a-z0-9]{20,}\.apps\.googleusercontent\.com"#, in: $0) })
            for id in ids {
                for secret in secrets where !pairs.contains(where: { $0.id == id && $0.secret == secret }) {
                    pairs.append((id, secret))
                }
            }
        }
        report.append("OAuth client candidates in bundle: \(pairs.count) (scanned \(scanned) files)")
        return Array(pairs.prefix(8))
    }

    /// Text around each occurrence of `marker` (max 64 hits) — cheap to regex even in huge binaries.
    private static func snippets(around marker: Data, in data: Data) -> [String] {
        var result: [String] = []
        var searchStart = data.startIndex
        while result.count < 64, let range = data.range(of: marker, in: searchStart..<data.endIndex) {
            let lower = max(data.startIndex, range.lowerBound - 160)
            let upper = min(data.endIndex, range.upperBound + 160)
            result.append(String(decoding: data[lower..<upper], as: UTF8.self))
            searchStart = range.upperBound
        }
        return result
    }

    static func refresh(_ refreshTokens: [String], clients: [(id: String, secret: String)], report: inout [String]) async -> (value: String, expires: Date)? {
        for refresh in refreshTokens {
            for client in clients {
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
                do {
                    let json = try await HTTP.json(request)
                    if let token = json["access_token"] as? String {
                        report.append("Token refresh: OK")
                        return (token, Date().addingTimeInterval(Parse.double(json["expires_in"]) ?? 3000))
                    }
                } catch {
                    report.append("Token refresh with client \(client.id.prefix(12))…: \(error.diagnosticDetail)")
                }
            }
        }
        if !refreshTokens.isEmpty { report.append("Token refresh: no working client/refresh-token pair") }
        return nil
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
