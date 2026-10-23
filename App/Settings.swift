import AppKit
import Combine
import Foundation
import Security

// MARK: - Source choices

enum ClaudeSource: String, CaseIterable, Identifiable, Sendable {
    case auto, webSession, token
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Claude Code login (Keychain)"
        case .webSession: "claude.ai browser session"
        case .token: "OAuth access token"
        }
    }
}

enum CodexSource: String, CaseIterable, Identifiable, Sendable {
    case auto, logsOnly, token
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Codex CLI login (API, then session logs)"
        case .logsOnly: "Codex session logs only (offline)"
        case .token: "ChatGPT access token"
        }
    }
}

enum GeminiSource: String, CaseIterable, Identifiable, Sendable {
    case auto, antigravity, cli, token
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Automatic (Antigravity, then Gemini CLI)"
        case .antigravity: "Antigravity login"
        case .cli: "Gemini CLI login"
        case .token: "Google OAuth access token"
        }
    }
}

/// Immutable copy of the settings, handed to the fetchers off the main thread.
struct FetchSettings: Sendable {
    var claudeSource: ClaudeSource = .auto
    var claudeSessionKey = ""
    var claudeToken = ""
    var codexSource: CodexSource = .auto
    var codexToken = ""
    var codexAccountID = ""
    var geminiSource: GeminiSource = .auto
    var geminiToken = ""
    var geminiClientID = ""
    var geminiClientSecret = ""
    var geminiProject = ""
}

// MARK: - Persisted settings

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var enabled: Set<Service> { didSet { defaults.set(enabled.map(\.rawValue), forKey: "enabled") } }
    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    /// false = "63% left" (Batteries style), true = "37% used" (like Claude's /usage).
    @Published var showsUsed: Bool { didSet { defaults.set(showsUsed, forKey: "showsUsed") } }
    /// Which tool's "% left" sits next to the menu bar icon (nil = icon only).
    @Published var menuBarService: Service? { didSet { defaults.set(menuBarService?.rawValue ?? "none", forKey: "menuBarService") } }
    @Published var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: "showInDock")
            NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @Published var claudeSource: ClaudeSource { didSet { defaults.set(claudeSource.rawValue, forKey: "claudeSource") } }
    @Published var codexSource: CodexSource { didSet { defaults.set(codexSource.rawValue, forKey: "codexSource") } }
    @Published var geminiSource: GeminiSource { didSet { defaults.set(geminiSource.rawValue, forKey: "geminiSource") } }
    @Published var codexAccountID: String { didSet { defaults.set(codexAccountID, forKey: "codexAccountID") } }
    @Published var geminiClientID: String { didSet { defaults.set(geminiClientID, forKey: "geminiClientID") } }
    @Published var geminiProject: String { didSet { defaults.set(geminiProject, forKey: "geminiProject") } }

    // Secrets live in the Keychain, not in UserDefaults.
    @Published var claudeSessionKey: String { didSet { SecretStore.set(claudeSessionKey, for: "claudeSessionKey") } }
    @Published var claudeToken: String { didSet { SecretStore.set(claudeToken, for: "claudeToken") } }
    @Published var codexToken: String { didSet { SecretStore.set(codexToken, for: "codexToken") } }
    @Published var geminiToken: String { didSet { SecretStore.set(geminiToken, for: "geminiToken") } }
    @Published var geminiClientSecret: String { didSet { SecretStore.set(geminiClientSecret, for: "geminiClientSecret") } }

    init() {
        let stored = defaults.stringArray(forKey: "enabled")?.compactMap(Service.init(rawValue:))
        enabled = Set(stored ?? Service.allCases)
        refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 5
        showInDock = defaults.object(forKey: "showInDock") as? Bool ?? true
        showsUsed = defaults.bool(forKey: "showsUsed")
        menuBarService = Service(rawValue: defaults.string(forKey: "menuBarService") ?? "none")
        claudeSource = ClaudeSource(rawValue: defaults.string(forKey: "claudeSource") ?? "") ?? .auto
        codexSource = CodexSource(rawValue: defaults.string(forKey: "codexSource") ?? "") ?? .auto
        geminiSource = GeminiSource(rawValue: defaults.string(forKey: "geminiSource") ?? "") ?? .auto
        codexAccountID = defaults.string(forKey: "codexAccountID") ?? ""
        geminiClientID = defaults.string(forKey: "geminiClientID") ?? ""
        geminiProject = defaults.string(forKey: "geminiProject") ?? ""
        claudeSessionKey = SecretStore.get("claudeSessionKey")
        claudeToken = SecretStore.get("claudeToken")
        codexToken = SecretStore.get("codexToken")
        geminiToken = SecretStore.get("geminiToken")
        geminiClientSecret = SecretStore.get("geminiClientSecret")
    }

    /// Enabled services in display order.
    var orderedEnabled: [Service] { Service.allCases.filter(enabled.contains) }

    var fetchSettings: FetchSettings {
        FetchSettings(
            claudeSource: claudeSource,
            claudeSessionKey: claudeSessionKey.trimmingCharacters(in: .whitespacesAndNewlines),
            claudeToken: claudeToken.trimmingCharacters(in: .whitespacesAndNewlines),
            codexSource: codexSource,
            codexToken: codexToken.trimmingCharacters(in: .whitespacesAndNewlines),
            codexAccountID: codexAccountID.trimmingCharacters(in: .whitespacesAndNewlines),
            geminiSource: geminiSource,
            geminiToken: geminiToken.trimmingCharacters(in: .whitespacesAndNewlines),
            geminiClientID: geminiClientID.trimmingCharacters(in: .whitespacesAndNewlines),
            geminiClientSecret: geminiClientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            geminiProject: geminiProject.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Keychain

enum SecretStore {
    private static let service = "com.robertlevonyan.ailimits"

    static func get(_ key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ value: String, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
