import AppKit
import Combine
import Foundation
import WidgetKit

/// Polls the enabled tools, keeps the last good numbers when a fetch fails,
/// and hands the result to the widget via the App Group.
@MainActor
final class UsageService: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var isRefreshing = false

    let settings: AppSettings
    private let fetchers: [Service: any UsageFetcher] = [
        .claude: ClaudeFetcher(),
        .codex: CodexFetcher(),
        .gemini: GeminiFetcher(),
    ]
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    /// Menu bar apps with no visible window get App Nap'ed, which stalls the polling timer for
    /// long stretches. This keeps the (tiny) poller on schedule without blocking system sleep.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep],
        reason: "Polling AI usage limits for the widget"
    )

    init(settings: AppSettings) {
        self.settings = settings
        snapshot = SharedStore.load() ?? .empty

        // Re-arm the timer when the interval changes.
        settings.$refreshSeconds
            .removeDuplicates()
            .sink { [weak self] seconds in self?.schedule(every: seconds) }
            .store(in: &bag)

        // Refetch shortly after any settings change (debounced so typing a token doesn't spam requests).
        settings.objectWillChange
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] in Task { await self?.refresh() } }
            .store(in: &bag)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    private func schedule(every seconds: Int) {
        timer?.invalidate()
        let interval = TimeInterval(max(5, seconds))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        timer.tolerance = min(15, interval * 0.2)
        // .common so it also fires while the menu bar popover is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Ask WidgetKit to redraw every AI Limits widget from the file we just saved. A second request a
    /// moment later covers the case where the first one is coalesced while the widget is mid-render.
    func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Where diagnostics reports go: Downloads (easy to find) and a Library folder that never needs
    /// a privacy prompt (so the report is still saved if macOS blocks Downloads).
    static var diagnosticsURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Downloads/AILimits-diagnostics.txt"),
            home.appendingPathComponent("Library/Developer/Xcode/DerivedData/AILimits-diagnostics.txt"),
        ]
    }

    /// Writes the report to every location that accepts it; returns the ones that worked.
    @discardableResult
    static func save(diagnostics report: String) -> [URL] {
        diagnosticsURLs.filter { url -> Bool in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? report.write(to: url, atomically: true, encoding: .utf8)) != nil
        }
    }

    private var lastAutoDiagnostics: Date = .distantPast

    /// Shortest gap between network requests per service (their own rate limits), for timer refreshes.
    /// Pressing Refresh ignores this.
    private let minimumGap: [Service: TimeInterval] = [.claude: 60, .codex: 30, .gemini: 5]
    private var lastFetched: [Service: Date] = [:]
    private var failing: Set<Service> = []
    private var lastWidgetData: Data?

    /// Full report for all tools (raw usage responses and yes/no checks — no tokens).
    func diagnostics() async -> String {
        let fs = settings.fetchSettings
        var parts = ["AI Limits diagnostics — \(Date())", "Display: " + (settings.showsUsed ? "% used" : "% left")]
        if let claude = fetchers[.claude] as? ClaudeFetcher { parts.append("\n===== Claude Code =====\n" + (await claude.diagnostics(fs))) }
        if let codex = fetchers[.codex] as? CodexFetcher { parts.append("\n===== Codex =====\n" + (await codex.diagnostics(fs))) }
        parts.append("\n===== Gemini =====\n" + (await geminiDiagnostics()))
        return parts.joined(separator: "\n")
    }

    /// Step-by-step Gemini/Antigravity report (no secrets) for Settings ▸ Gemini ▸ Run diagnostics.
    func geminiDiagnostics() async -> String {
        guard let gemini = fetchers[.gemini] as? GeminiFetcher else { return "Gemini fetcher missing" }
        return await gemini.diagnostics(settings.fetchSettings)
    }

    /// `force` = the user pressed Refresh: always ends with the widget redrawing, even if a
    /// refresh was already running or a service is backing off.
    func refresh(force: Bool = false) async {
        guard !isRefreshing else {
            if force { reloadWidgets() }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let enabled = settings.orderedEnabled
        let fetchSettings = settings.fetchSettings
        let now = Date()
        let due = enabled.filter { service in
            // A service that's currently failing is retried once a minute, not every few seconds.
            let gap = failing.contains(service) ? max(60, minimumGap[service] ?? 0) : (minimumGap[service] ?? 0)
            return force || now.timeIntervalSince(lastFetched[service] ?? .distantPast) >= gap
        }
        due.forEach { lastFetched[$0] = now }
        let active = due.compactMap { fetchers[$0] }

        let results = await withTaskGroup(of: (Service, Result<ProviderUsage, Error>).self) { group in
            for fetcher in active {
                group.addTask {
                    do { return (fetcher.service, .success(try await fetcher.fetch(fetchSettings))) }
                    catch { return (fetcher.service, .failure(error)) }
                }
            }
            var collected: [Service: Result<ProviderUsage, Error>] = [:]
            for await (service, result) in group { collected[service] = result }
            return collected
        }

        let providers = enabled.map { service -> ProviderUsage in
            switch results[service] {
            case .success(let usage):
                return usage
            case .failure(let error):
                // Keep showing the last known numbers, just flag them.
                var stale = snapshot.usage(for: service) ?? ProviderUsage(service: service, windows: [])
                stale.error = error.localizedDescription
                return stale.asOf(.now)
            case nil:
                // Not due this round: keep what we have.
                return snapshot.usage(for: service)?.asOf(.now) ?? ProviderUsage(service: service, windows: [], error: "Not fetched yet")
            }
        }

        snapshot = UsageSnapshot(providers: providers, updatedAt: .now, enabled: enabled, showsUsed: settings.showsUsed)
        SharedStore.save(snapshot)
        // Only ask WidgetKit to redraw when something visible changed (it rations redraws).
        for (service, result) in results {
            if case .failure = result { failing.insert(service) } else { failing.remove(service) }
        }
        let visible = providers.map { usage -> ProviderUsage in var copy = usage; copy.fetchedAt = nil; return copy }
        let widgetData = try? JSONEncoder().encode(UsageSnapshot(providers: visible, updatedAt: .distantPast, enabled: enabled, showsUsed: settings.showsUsed))
        if force || widgetData != lastWidgetData {
            lastWidgetData = widgetData
            reloadWidgets()
        }

        // If something failed, save a diagnostics report automatically (at most every 30 minutes).
        if providers.contains(where: { $0.error != nil }), Date().timeIntervalSince(lastAutoDiagnostics) > 30 * 60 {
            lastAutoDiagnostics = Date()
            let report = await diagnostics()
            Self.save(diagnostics: report)
        }
    }
}
