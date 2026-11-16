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

    static func load() -> UsageSnapshot? {
        [groupFileURL, widgetContainerFileURL]
            .compactMap { $0 }
            .compactMap { url -> UsageSnapshot? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    static func save(_ snapshot: UsageSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        for url in [groupFileURL, widgetContainerFileURL].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
