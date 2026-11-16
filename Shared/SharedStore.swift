import Foundation

/// Hands the latest snapshot from the menu bar app to the (sandboxed) widget.
///
/// Two places, written together; the widget reads whichever is newer:
/// 1. The App Group container — the normal way, works for builds signed with a developer team.
/// 2. The widget's own sandbox container (~/Library/Containers/<widget id>/Data/Library/Application Support).
///    A sandboxed widget can always read its own container, so this keeps unsigned builds (GitHub releases
///    without a Developer ID) working: macOS refuses App Group access to those. The app isn't sandboxed and
///    writes there directly (macOS may ask once to allow access to another app's data).
enum SharedStore {
    static let widgetBundleID = "com.robertlevonyan.ailimits.widgets"
    /// Loopback port of the app's LocalFeed.
    static let feedPort: UInt16 = 47863
    private static let fileName = "usage.json"

    static var groupID: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "com.robertlevonyan.ailimits"
    }

    private static var isWidget: Bool { Bundle.main.bundleIdentifier == widgetBundleID }

    static var groupFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(fileName)
    }

    static var widgetContainerFileURL: URL? {
        let base: URL
        if isWidget {
            // Inside the sandbox this already resolves to the widget's own container.
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
            base = support
        } else {
            // Only once macOS has created the widget's container (i.e. the widget has run). Creating it
            // ourselves would leave a container macOS doesn't recognise.
            let data = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(widgetBundleID)/Data")
            guard FileManager.default.fileExists(atPath: data.path) else { return nil }
            base = data.appendingPathComponent("Library/Application Support")
        }
        return base.appendingPathComponent("AI Limits/\(fileName)")
    }

    /// Why the last `load()` found nothing — shown inside the widget so problems are visible.
    static var lastLoadProblem: String?

    static func load() -> UsageSnapshot? {
        var problems: [String] = []
        var found: [UsageSnapshot] = []
        let sources: [(String, URL?)] = [("App Group \(groupID)", groupFileURL), ("widget storage", widgetContainerFileURL)]
        for (name, url) in sources {
            guard let url else {
                problems.append("\(name): unavailable")
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                found.append(try JSONDecoder().decode(UsageSnapshot.self, from: data))
            } catch let error as DecodingError {
                problems.append("\(name): unreadable data (\(String(describing: error).prefix(80)))")
            } catch {
                let ns = error as NSError
                let reason = ns.code == NSFileReadNoSuchFileError ? "no file yet"
                    : ns.code == NSFileReadNoPermissionError ? "access denied by macOS"
                    : "\(ns.domain) \(ns.code)"
                problems.append("\(name): \(reason)")
            }
        }
        lastLoadProblem = found.isEmpty ? problems.joined(separator: " · ") : nil
        return found.max { $0.updatedAt < $1.updatedAt }
    }

    /// What the widget uses: asks the running app over 127.0.0.1 first, then reads the shared files.
    /// Never takes more than a few seconds, so the widget can't get stuck on the grey placeholder
    /// when macOS holds a file read (container protection prompts can't be shown for a widget).
    static func loadForWidget() async -> (UsageSnapshot?, String?) {
        var problems: [String] = []
        if let snapshot = await loadFromApp(problems: &problems), !snapshot.providers.isEmpty {
            return (snapshot, nil)
        }
        let (fileSnapshot, fileProblem) = await loadFilesWithTimeout(seconds: 3)
        if let fileSnapshot { return (fileSnapshot, nil) }
        if let fileProblem { problems.append(fileProblem) }
        return (nil, problems.joined(separator: " · "))
    }

    private static func loadFromApp(problems: inout [String]) async -> UsageSnapshot? {
        guard let url = URL(string: "http://127.0.0.1:\(feedPort)/usage.json") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = "GET"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, _) = try await session.data(for: request)
            return try JSONDecoder().decode(UsageSnapshot.self, from: data)
        } catch {
            let ns = error as NSError
            problems.append(ns.code == NSURLErrorCannotConnectToHost ? "App: not running" : "App: \(ns.localizedDescription)")
            return nil
        }
    }

    private static func loadFilesWithTimeout(seconds: Double) async -> (UsageSnapshot?, String?) {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            let finish: ((UsageSnapshot?, String?)) -> Void = { result in
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(returning: result)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let snapshot = load()
                finish((snapshot, snapshot == nil ? lastLoadProblem : nil))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                finish((nil, "Shared file: macOS didn't allow reading it (timed out)"))
            }
        }
    }

    static func save(_ snapshot: UsageSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        for url in [groupFileURL, widgetContainerFileURL].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
