import AppKit
import SwiftUI

/// Single place that owns the settings and the poller, shared by SwiftUI scenes and the AppKit delegate.
@MainActor
final class AppModel {
    static let shared = AppModel()
    let settings: AppSettings
    let service: UsageService

    private init() {
        settings = AppSettings()
        service = UsageService(settings: settings)
    }
}

@main
struct AILimitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var service = AppModel.shared.service

    var body: some Scene {
        MenuBarExtra {
            MenuContent(service: service)
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindowController.shared.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

// MARK: - App delegate: Dock icon + "click the app icon to open Settings"

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            NSApp.setActivationPolicy(model.settings.showInDock ? .regular : .accessory)
            // Opening the app yourself (Finder, Launchpad, Spotlight, Xcode) shows Settings;
            // starting silently at login does not.
            if !Self.launchedAsLoginItem() {
                SettingsWindowController.shared.show()
            }
        }
    }

    /// Clicking the Dock icon, or opening the app again while it's running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsWindowController.shared.show() }
        return false
    }

    /// Closing Settings keeps the menu bar app and widget updates running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        return menu
    }

    @objc private func refreshNow() {
        Task { @MainActor in await AppModel.shared.service.refresh(force: true) }
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}

// MARK: - Settings window

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let model = AppModel.shared
            let hosting = NSHostingController(rootView: SettingsView(settings: model.settings, service: model.service))
            let window = NSWindow(contentViewController: hosting)
            window.title = "AI Limits Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("AILimitsSettings")
            if !window.setFrameUsingName("AILimitsSettings") { window.center() }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Menu bar popover

private struct MenuContent: View {
    @ObservedObject var service: UsageService

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                if service.snapshot.ordered.isEmpty {
                    Text("No tools enabled — turn some on in Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(service.snapshot.ordered) { usage in
                    ProviderRow(usage: usage, now: context.date, showsUsed: service.snapshot.showsUsed == true)
                }

                Divider()

                HStack {
                    if service.snapshot.updatedAt > .distantPast {
                        Text("Updated \(UsageFormat.clock(service.snapshot.updatedAt, now: context.date))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await service.refresh(force: true) }
                    } label: {
                        if service.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.borderless)
                    .disabled(service.isRefreshing)
                    .help("Refresh now")
                }

                HStack {
                    Button("Settings…") { SettingsWindowController.shared.show() }
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
                .buttonStyle(.borderless)
            }
            .padding(14)
            .frame(width: 320)
        }
    }
}

/// One tool in the popover. When its data isn't available (not signed in, failed fetch),
/// the whole row becomes a button that opens Settings.
private struct ProviderRow: View {
    let usage: ProviderUsage
    let now: Date
    let showsUsed: Bool
    @State private var hovering = false

    private var needsAttention: Bool { usage.windows.isEmpty || usage.error != nil }

    var body: some View {
        if needsAttention {
            Button {
                SettingsWindowController.shared.show()
            } label: {
                content
                    .contentShape(Rectangle())
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                    )
                    .padding(-6)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Open Settings to fix \(usage.service.displayName)")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            UsageRing(usage: usage, showsUsed: showsUsed).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(usage.service.displayName).font(.headline)
                    if let plan = usage.plan { Text(plan).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(UsageFormat.percent(usage, showsUsed: showsUsed)).font(.headline).monospacedDigit()
                }
                ForEach(usage.windows) { WindowBar(window: $0, now: now, showsUsed: showsUsed) }
                if let error = usage.error {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                        Spacer(minLength: 4)
                        Text("Settings ›").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                    }
                } else if usage.windows.isEmpty {
                    Text("Not available — click to open Settings ›")
                        .font(.caption2).foregroundStyle(.tint)
                }
            }
        }
    }
}
