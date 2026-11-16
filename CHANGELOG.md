# Changelog

## 0.0.9
- Releases are signed with the team's Apple Development certificate, so the desktop widgets can read the app's data. This needs the `SIGNING_P12_*` secrets; see the README.

## 0.0.8
- The release workflow supports three signing modes: Developer ID (notarized), Apple Development (team) and unsigned.

## 0.0.7
- The widget can also read the app's data from its own storage, a fallback for unsigned builds.

## 0.0.6
- Claude handles Anthropic's rate limits better. It backs off properly and keeps the last numbers across restarts. While usage checks are blocked, it reads the limits from the headers of a tiny request instead.
- Diagnostics are saved to `~/Library/Application Support/AI Limits/` instead of Downloads.

## Earlier
- In-app updates from GitHub Releases.
- Settings hides itself when minimized, and the Dock icon only shows while Settings is open.
- Per-AI small widgets; the Claude one has a weekly bar.
- Claude follows the 5-hour limit everywhere.
- Menu bar percentage, 5-second refresh, Antigravity support for Gemini, and Batteries-style widgets.
