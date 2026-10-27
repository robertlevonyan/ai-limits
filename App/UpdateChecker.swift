import AppKit
import Foundation

/// Checks GitHub Releases for a newer version and installs it in place.
///
/// - Version of this build: `CFBundleShortVersionString` (the release workflow sets it from the tag, e.g. v1.2.0 → 1.2.0).
/// - Latest release: `GET api.github.com/repos/<repo>/releases/latest` (public API, no token).
/// - Install: download the release's .dmg, mount it, copy the app over this one, relaunch.
///   If this copy can't be replaced (running from Xcode's build folder, or no write access), it opens
///   the release page instead.
@MainActor
final class UpdateChecker: ObservableObject {
    static let repository = "robertlevonyan/ai-limits"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(String)
        case downloading
        case installing
        case failed(String)
    }

    struct Release {
        let version: String
        let notes: String
        let pageURL: URL
        let dmgURL: URL?
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var latest: Release?

    private let settings: AppSettings
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Builds run from Xcode (DerivedData) aren't replaced by the updater.
    private var isDevelopmentBuild: Bool {
        Bundle.main.bundlePath.contains("/DerivedData/")
    }

    init(settings: AppSettings) {
        self.settings = settings
        // First check shortly after launch, then every 6 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            Task { await self?.checkAutomatically() }
        }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { await self?.checkAutomatically() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Checking

    private func checkAutomatically() async {
        guard settings.checkForUpdates, !isDevelopmentBuild else { return }
        await check(userInitiated: false)
    }

    /// `userInitiated` = the user clicked "Check for Updates…": always report the result.
    func check(userInitiated: Bool) async {
        status = .checking
        do {
            let release = try await fetchLatest()
            latest = release
            guard Self.isNewer(release.version, than: currentVersion) else {
                status = .upToDate(currentVersion)
                if userInitiated { showUpToDate() }
                return
            }
            status = .available(release.version)
            if userInitiated || settings.skippedVersion != release.version {
                promptToInstall(release)
            }
        } catch {
            status = .failed(error.localizedDescription)
            if userInitiated { showError("Couldn't check for updates", error.localizedDescription) }
        }
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AI-Limits/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw UpdateError("No releases published yet") }
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw UpdateError("GitHub answered HTTP \(code)")
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.lowercased().hasSuffix(".dmg") }
            .flatMap(URL.init(string:))
        return Release(
            version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            notes: json["body"] as? String ?? "",
            pageURL: page,
            dmgURL: dmg
        )
    }

    /// Semantic-ish comparison: "1.10.0" > "1.9.2", "1.2" == "1.2.0".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Prompts

    private func promptToInstall(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AI Limits \(release.version) is available"
        var info = "You have version \(currentVersion)."
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(600)) + (notes.count > 600 ? "…" : "") }
        alert.informativeText = info
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await install(release) }
        case .alertThirdButtonReturn:
            settings.skippedVersion = release.version
        default:
            break
        }
    }

    private func showUpToDate() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "AI Limits \(currentVersion) is the latest version."
        alert.runModal()
    }

    private func showError(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: Installing

    func install(_ release: Release) async {
        let appURL = Bundle.main.bundleURL
        let parent = appURL.deletingLastPathComponent()
        guard let dmgURL = release.dmgURL,
              !isDevelopmentBuild,
              FileManager.default.isWritableFile(atPath: parent.path) else {
            // Can't replace this copy: let the user download it.
            NSWorkspace.shared.open(release.pageURL)
            status = .available(release.version)
            return
        }

        do {
            status = .downloading
            let (downloaded, _) = try await URLSession.shared.download(from: dmgURL)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("AILimitsUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dmg = work.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: downloaded, to: dmg)

            status = .installing
            let mount = work.appendingPathComponent("mnt")
            let attach = Shell.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            guard attach.status == 0 else { throw UpdateError("Couldn't open the downloaded disk image") }
            defer { Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

            guard let newApp = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError("The disk image doesn't contain the app")
            }
            // Copy out of the image before we quit (the image is detached right after).
            let staged = work.appendingPathComponent(newApp.lastPathComponent)
            guard Shell.run("/usr/bin/ditto", [newApp.path, staged.path]).status == 0 else {
                throw UpdateError("Couldn't copy the new version")
            }
            Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

            try relaunch(replacing: appURL, with: staged)
        } catch {
            status = .failed(error.localizedDescription)
            showError("Update failed", "\(error.localizedDescription)\n\nYou can download it from the release page instead.")
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    /// Hands the swap to a tiny script that waits for us to quit, replaces the bundle and reopens it.
    private func relaunch(replacing appURL: URL, with newApp: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(appURL.path)"
        /usr/bin/ditto "\(newApp.path)" "\(appURL.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(appURL.path)" 2>/dev/null
        /usr/bin/open "\(appURL.path)"
        rm -rf "\(newApp.deletingLastPathComponent().path)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
