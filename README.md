# ai-limits
This is an Open Source utility to show your AI usage limits

A macOS widget in the style of the Batteries widget. It shows how much of your **Claude Code**, **Codex CLI** (ChatGPT) and **Gemini CLI** limits you have left, and when each one resets.

## Run it

1. Open `AILimits.xcodeproj` in Xcode 16 or later.
2. Pick the **AILimits** scheme and press **Run** (⌘R).

That's all. The project uses folder-synced groups, so anything you add to `App/`, `Widget/` or `Shared/` (Swift files, assets) is picked up automatically. No XcodeGen, no regenerating.

Signing uses team `LBKJHBH5UN` with automatic signing. To change it, go to **Signing & Capabilities** and update both targets. Both need the App Group `$(TeamIdentifierPrefix)com.robertlevonyan.ailimits`.

After the first run, add the widget from the desktop with **Edit Widgets ▸ AI Limits**. Open **Settings…** from the gauge in the menu bar.

## Settings

| Tool | Sources you can pick |
|---|---|
| Claude Code | **Claude Code login** (the Keychain item `Claude Code-credentials`), a **claude.ai browser session** (the `sessionKey` cookie), or an **OAuth access token** you paste |
| Codex | **Codex CLI login** (`~/.codex/auth.json`, then session logs), **session logs only** (offline), or a **ChatGPT access token** plus account ID |
| Gemini | **Gemini CLI login** (`~/.gemini/oauth_creds.json`, with an optional OAuth client override), or a **Google access token**. You can also set the Google Cloud project. |

You can also:

- Turn each tool on or off for the widget.
- Choose how often it refreshes (2 to 30 minutes).
- Turn on **Launch at login**.
- See each tool's status: what the last fetch returned, or why it failed.

Pasted tokens and cookies are stored in your login Keychain, not in plain preferences.

## Layout

```
Config/   Info.plists + entitlements (not synced into targets)
App/      Menu bar host app, Settings, UsageService, Fetchers/, AppIcon
Widget/   WidgetKit extension (small / medium / large)
Shared/   Models, App Group store, ring views, service logos (both targets)
```

If the widget still shows an old version after a rebuild, remove it from the desktop and add it again. If that doesn't help, run `killall chronod NotificationCenter`.

## Releases

Releases are built by GitHub Actions (`.github/workflows/release.yml`) on a macOS runner.

1. Commit and push your changes.
2. Tag a version and push the tag:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
3. A few minutes later the release appears under **Releases** with `AI-Limits-1.0.0.dmg`.

You can also start it by hand: **Actions › Release › Run workflow**, then enter a version.

**Signing.** Without an Apple Developer ID the build is unsigned. Users drag the app to Applications and **right-click › Open** it the first time. To ship signed and notarized builds, add these repository secrets: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_ID`, `APPLE_APP_PASSWORD`. The workflow picks them up automatically.
