import Foundation

/// The three tools the widget tracks.
enum Service: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "ChatGPT Codex"
        case .gemini: "Gemini"
        }
    }

    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }

    /// Template image in Shared/Assets.xcassets, shown in the middle of each ring.
    var iconName: String {
        switch self {
        case .claude: "claude"
        case .codex: "chatgpt"
        case .gemini: "gemini"
        }
    }
}

/// One rate-limit window, e.g. Claude's 5-hour session or Codex's weekly cap.
struct UsageWindow: Codable, Hashable, Identifiable, Sendable {
    var label: String
    /// 0...1 of the window that has been used.
    var usedFraction: Double
    var resetsAt: Date?
    /// Headline windows drive the ring. Secondary ones (e.g. per-model caps) only show in the large widget.
    var isHeadline: Bool = true

    var id: String { label }
    var remainingFraction: Double { max(0, min(1, 1 - usedFraction)) }
    var isExhausted: Bool { usedFraction >= 0.995 }
}

struct ProviderUsage: Codable, Hashable, Identifiable, Sendable {
    var service: Service
    var windows: [UsageWindow]
    var plan: String?
    var error: String?
    var fetchedAt: Date?

    var id: Service { service }

    /// The window with the least room left — the one that will stop you first.
    var binding: UsageWindow? {
        let headline = windows.filter(\.isHeadline)
        return (headline.isEmpty ? windows : headline).min { $0.remainingFraction < $1.remainingFraction }
    }

    /// Projects the usage forward in time: any window whose reset has passed is treated as full again.
    func asOf(_ date: Date) -> ProviderUsage {
        var copy = self
        copy.windows = windows.map { window in
            guard let reset = window.resetsAt, reset <= date else { return window }
            var fresh = window
            fresh.usedFraction = 0
            fresh.resetsAt = nil
            return fresh
        }
        return copy
    }
}

struct UsageSnapshot: Codable, Sendable {
    var providers: [ProviderUsage]
    var updatedAt: Date
    /// Services the user chose to show (nil = all). Set from the app's Settings.
    var enabled: [Service]? = nil
    /// Show "% used" instead of "% left" (Settings ▸ General).
    var showsUsed: Bool? = nil

    static let empty = UsageSnapshot(providers: [], updatedAt: .distantPast)

    func usage(for service: Service) -> ProviderUsage? {
        providers.first { $0.service == service }
    }

    /// Always returns all three services in a fixed order, filling gaps with an empty entry.
    var ordered: [ProviderUsage] {
        (enabled ?? Service.allCases).map { usage(for: $0) ?? ProviderUsage(service: $0, windows: [], error: "No data yet") }
    }

    func asOf(_ date: Date) -> UsageSnapshot {
        UsageSnapshot(providers: providers.map { $0.asOf(date) }, updatedAt: updatedAt, enabled: enabled, showsUsed: showsUsed)
    }

    static var preview: UsageSnapshot {
        let now = Date()
        return UsageSnapshot(providers: [
            ProviderUsage(service: .claude, windows: [
                UsageWindow(label: "5-hour", usedFraction: 0.38, resetsAt: now.addingTimeInterval(2 * 3600 + 780)),
                UsageWindow(label: "Weekly", usedFraction: 0.21, resetsAt: now.addingTimeInterval(4 * 86400)),
            ], plan: "Max", fetchedAt: now),
            ProviderUsage(service: .codex, windows: [
                UsageWindow(label: "5-hour", usedFraction: 0.84, resetsAt: now.addingTimeInterval(55 * 60)),
                UsageWindow(label: "Weekly", usedFraction: 0.47, resetsAt: now.addingTimeInterval(3 * 86400)),
            ], plan: "Plus", fetchedAt: now),
            ProviderUsage(service: .gemini, windows: [
                UsageWindow(label: "Pro", usedFraction: 1.0, resetsAt: now.addingTimeInterval(6 * 3600)),
                UsageWindow(label: "Flash", usedFraction: 0.12, resetsAt: now.addingTimeInterval(6 * 3600), isHeadline: false),
            ], plan: "Free", fetchedAt: now),
        ], updatedAt: now)
    }
}
