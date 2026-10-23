import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var service: UsageService
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var diagnosticsStatus: String?

    var body: some View {
        Form {
            Section("General") {
                Picker("Refresh every", selection: $settings.refreshMinutes) {
                    ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Picker("Percentages show", selection: $settings.showsUsed) {
                    Text("What's left (like Batteries)").tag(false)
                    Text("What's used (like Claude /usage)").tag(true)
                }
                Toggle("Show icon in Dock", isOn: $settings.showInDock)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                HStack {
                    Text("Widget data")
                    Spacer()
                    if service.snapshot.updatedAt > .distantPast {
                        Text("Updated \(UsageFormat.clock(service.snapshot.updatedAt, now: .now))")
                            .foregroundStyle(.secondary)
                    }
                    Button("Refresh now") { Task { await service.refresh(force: true) } }
                        .disabled(service.isRefreshing)
                }
                HStack {
                    Button("Run diagnostics") { Task { await runDiagnostics() } }
                    if let diagnosticsStatus {
                        Text(diagnosticsStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            serviceSection(.claude) {
                Picker("Source", selection: $settings.claudeSource) {
                    ForEach(ClaudeSource.allCases) { Text($0.title).tag($0) }
                }
                switch settings.claudeSource {
                case .auto:
                    Hint("Uses the login from `claude`. The first time, macOS asks to let “security” read “Claude Code-credentials” — choose Always Allow.")
                case .webSession:
                    SecureField("sessionKey", text: $settings.claudeSessionKey, prompt: Text("sk-ant-sid01-…"))
                    Hint("In your browser on claude.ai: Developer Tools ▸ Application/Storage ▸ Cookies ▸ claude.ai ▸ copy the value of “sessionKey”. Expires after about a month.")
                case .token:
                    SecureField("Access token", text: $settings.claudeToken, prompt: Text("sk-ant-oat01-…"))
                    Hint("A Claude OAuth access token with the user:profile scope (the “accessToken” in Claude Code's credentials). Expires after a few hours.")
                }
            }

            serviceSection(.codex) {
                Picker("Source", selection: $settings.codexSource) {
                    ForEach(CodexSource.allCases) { Text($0.title).tag($0) }
                }
                switch settings.codexSource {
                case .auto:
                    Hint("Uses ~/.codex/auth.json from `codex login`. If the API fails, falls back to the limits in your latest Codex session.")
                case .logsOnly:
                    Hint("Reads the rate limits Codex records in ~/.codex/sessions. No network calls; only as fresh as your last Codex run.")
                case .token:
                    SecureField("Access token", text: $settings.codexToken, prompt: Text("eyJhbGciOi…"))
                    TextField("Account ID (optional)", text: $settings.codexAccountID, prompt: Text("ChatGPT-Account-Id"))
                    Hint("chatgpt.com ▸ Developer Tools ▸ Network ▸ any backend-api request ▸ copy the Bearer token from the Authorization header, and the ChatGPT-Account-Id header.")
                }
            }

            serviceSection(.gemini) {
                Picker("Source", selection: $settings.geminiSource) {
                    ForEach(GeminiSource.allCases) { Text($0.title).tag($0) }
                }
                switch settings.geminiSource {
                case .auto:
                    Hint("Tries your Antigravity login first, then the Gemini CLI (`gemini` ▸ Login with Google).")
                case .antigravity:
                    Hint("Reads the Google login Antigravity keeps in its settings and shows its per-model quota (Gemini Pro, Flash, Claude). Antigravity refreshes that login while it's open — if it's been closed for more than an hour, the last numbers stay until you open it again.")
                case .cli:
                    Hint("Uses ~/.gemini/oauth_creds.json from `gemini` ▸ Login with Google. Expired tokens are refreshed in memory using the OAuth client from your Gemini CLI install.")
                    TextField("OAuth client ID (optional)", text: $settings.geminiClientID, prompt: Text("Auto-detected"))
                    SecureField("OAuth client secret (optional)", text: $settings.geminiClientSecret, prompt: Text("Auto-detected"))
                case .token:
                    SecureField("Access token", text: $settings.geminiToken, prompt: Text("ya29.…"))
                    Hint("Any Google access token for your account (e.g. `gcloud auth print-access-token`). Expires after one hour.")
                }
                TextField("Google Cloud project (optional)", text: $settings.geminiProject, prompt: Text("Auto-detected"))
                HStack {
                    Button("Run diagnostics") { Task { await runDiagnostics() } }
                    if let diagnosticsStatus {
                        Text(diagnosticsStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
    }

    /// Writes a report (setting names, sizes, yes/no — no token values) to Downloads and reveals it.
    private func runDiagnostics() async {
        diagnosticsStatus = "Running…"
        let report = await service.diagnostics()
        let saved = UsageService.save(diagnostics: report)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        if let first = saved.first {
            NSWorkspace.shared.activateFileViewerSelecting([first])
            diagnosticsStatus = "Saved (\(saved.count) location\(saved.count == 1 ? "" : "s")) and copied"
        } else {
            diagnosticsStatus = "Couldn't save — but it's copied to the clipboard"
        }
        await service.refresh()
    }

    // MARK: - Pieces

    @ViewBuilder
    private func serviceSection<Content: View>(_ kind: Service, @ViewBuilder content: () -> Content) -> some View {
        let isOn = Binding(
            get: { settings.enabled.contains(kind) },
            set: { on in if on { settings.enabled.insert(kind) } else { settings.enabled.remove(kind) } }
        )
        Section {
            Toggle("Show in widget", isOn: isOn)
            if isOn.wrappedValue {
                content()
                StatusRow(usage: service.snapshot.usage(for: kind))
            }
        } header: {
            HStack(spacing: 8) {
                Image(kind.iconName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                Text(kind.displayName)
            }
        }
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What the last fetch returned for this tool — handy to see why a ring is empty.
private struct StatusRow: View {
    let usage: ProviderUsage?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Status")
            Spacer()
            if let usage, let error = usage.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            } else if let usage, !usage.windows.isEmpty {
                Label(
                    usage.windows.map { "\($0.label) \(Int(($0.remainingFraction * 100).rounded()))%" }.joined(separator: " · "),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else {
                Text("Waiting for first refresh").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}
