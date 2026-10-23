import SwiftUI
import WidgetKit

// MARK: - Formatting

enum UsageFormat {
    /// "63% left" (Batteries-style, default) or "37% used" (same wording as Claude's /usage).
    static func percent(_ usage: ProviderUsage, showsUsed: Bool = false, suffix: Bool = true) -> String {
        guard let window = usage.binding else { return "—" }
        return percent(window, showsUsed: showsUsed, suffix: suffix)
    }

    static func usedPercent(_ window: UsageWindow) -> Int { Int((min(1, max(0, window.usedFraction)) * 100).rounded()) }
    static func leftPercent(_ window: UsageWindow) -> Int { 100 - usedPercent(window) }

    /// "**37%** used · **63%** left" — both numbers, so there's no guessing which one you're looking at.
    static func usedAndLeft(_ window: UsageWindow) -> Text {
        Text("\(usedPercent(window))%").bold() + Text(" used · ").foregroundColor(.secondary)
            + Text("\(leftPercent(window))%").bold().foregroundColor(window.tint) + Text(" left").foregroundColor(.secondary)
    }

    static func percent(_ window: UsageWindow, showsUsed: Bool, suffix: Bool = true) -> String {
        let number = "\(showsUsed ? usedPercent(window) : leftPercent(window))%"
        return suffix ? number + (showsUsed ? " used" : " left") : number
    }

    /// "2h 13m", "45m", "3d 4h"
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, mins = minutes % 60
        if hours < 24 { return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m" }
        let days = hours / 24, hrs = hours % 24
        return hrs == 0 ? "\(days)d" : "\(days)d \(hrs)h"
    }

    /// "14:30" today, "Thu 14:30" otherwise.
    static func clock(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Short caption under a ring: when the limit comes back.
    static func reset(_ window: UsageWindow?, now: Date) -> String {
        guard let window, let reset = window.resetsAt, reset > now else { return window == nil ? "" : "Ready" }
        return window.isExhausted ? "Back \(clock(reset, now: now))" : "↻ \(duration(reset.timeIntervalSince(now)))"
    }

    static func caption(_ usage: ProviderUsage, now: Date) -> String {
        if usage.windows.isEmpty { return usage.error == nil ? "No data" : "Not signed in" }
        return reset(usage.binding, now: now)
    }
}

// MARK: - Ring (Batteries-widget style)

extension UsageWindow {
    /// Same semantics as the Batteries widget: green while healthy, red when nearly empty.
    var tint: Color {
        switch remainingFraction {
        case ...0.1: .red
        case ...0.25: .orange
        default: .green
        }
    }
}

struct UsageRing: View {
    var service: Service?
    var window: UsageWindow?
    var unavailable: Bool = false
    /// Fill the ring with the used share instead of what's left.
    var showsUsed: Bool = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let line = max(3, size * 0.105)
            let tint = unavailable ? Color.gray : (window?.tint ?? .gray)
            let fill = unavailable ? 0 : (showsUsed ? min(1, window?.usedFraction ?? 0) : (window?.remainingFraction ?? 0))

            ZStack {
                Circle()
                    .stroke(tint.opacity(service == nil ? 0.12 : 0.25), lineWidth: line)
                Circle()
                    .trim(from: 0, to: fill)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
                if let service {
                    centerIcon(for: service, size: size)
                        .foregroundStyle(unavailable ? .secondary : .primary)
                }
            }
            .padding(line / 2)
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Service logo (one tint for all, like Batteries' device glyphs); a status symbol when there's no data or the limit is hit.
    @ViewBuilder
    private func centerIcon(for service: Service, size: CGFloat) -> some View {
        if unavailable || window?.isExhausted == true {
            Image(systemName: unavailable ? "exclamationmark" : "hourglass")
                .font(.system(size: size * 0.3, weight: .semibold))
        } else {
            Image(service.iconName)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size * 0.4, height: size * 0.4)
        }
    }
}

extension UsageRing {
    init(usage: ProviderUsage, showsUsed: Bool = false) {
        self.init(service: usage.service, window: usage.binding, unavailable: usage.windows.isEmpty, showsUsed: showsUsed)
    }
}

/// One limit window: "5-hour        37% used · 63% left" over a bar (green = left) and the reset time.
struct WindowBar: View {
    var window: UsageWindow
    var now: Date
    var showsUsed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                UsageFormat.usedAndLeft(window)
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Whole capsule = the limit; grey part = used, coloured part = what's left.
                        Capsule().fill(Color.primary.opacity(0.13))
                        Capsule().fill(window.tint)
                            .frame(width: window.remainingFraction <= 0 ? 0 : max(4, geo.size.width * window.remainingFraction))
                            .widgetAccentable()
                    }
                }
                .frame(height: 6)
                Text(UsageFormat.reset(window, now: now))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(window.isExhausted ? Color.red : Color.secondary)
                    .frame(width: 70, alignment: .trailing)
                    .lineLimit(1)
            }
        }
    }
}
