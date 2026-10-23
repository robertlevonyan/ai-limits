import SwiftUI
import WidgetKit

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

struct UsageTimeline: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let snapshot = context.isPreview ? .preview : (SharedStore.load() ?? .preview)
        completion(UsageEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedStore.load() ?? .empty

        // Short timeline that ends in 15 minutes: when it runs out WidgetKit asks again and we re-read
        // the shared file, so the widget stays fresh even if the app's reload requests get throttled.
        // Entries every 5 minutes keep the countdowns current, plus one exactly at each reset so a
        // ring refills the moment its window rolls over.
        let horizon = now.addingTimeInterval(15 * 60)
        var dates = stride(from: 0, to: 15 * 60, by: 300).map { now.addingTimeInterval($0) }
        dates += snapshot.providers.flatMap(\.windows).compactMap(\.resetsAt).filter { $0 > now && $0 < horizon }
        dates.sort()

        let entries = dates.map { UsageEntry(date: $0, snapshot: snapshot.asOf($0)) }
        completion(Timeline(entries: entries, policy: .after(horizon)))
    }
}

// MARK: - Views

struct AILimitsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry
    private var used: Bool { entry.snapshot.showsUsed == true }

    var body: some View {
        switch family {
        case .systemSmall: SmallView(entry: entry)
        case .systemMedium: MediumView(entry: entry)
        default: LargeView(entry: entry)
        }
    }
}

/// 2×2 grid of rings, exactly like Batteries with several devices.
private struct SmallView: View {
    let entry: UsageEntry
    private var used: Bool { entry.snapshot.showsUsed == true }

    private func smallLabel(_ usage: ProviderUsage) -> String {
        guard let window = usage.binding else { return "—" }
        return used ? "\(UsageFormat.usedPercent(window))% used" : "\(UsageFormat.leftPercent(window))% left"
    }

    var body: some View {
        // Up to four slots; unused ones stay as dim empty rings, as Batteries shows.
        let usages = Array(entry.snapshot.ordered.prefix(4))
        let slots: [ProviderUsage?] = usages.map { $0 } + Array(repeating: nil, count: 4 - usages.count)
        Grid(horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { column in
                        VStack(spacing: 3) {
                            if let usage = slots[row * 2 + column] {
                                UsageRing(usage: usage, showsUsed: used)
                                // Percent under each ring, like Batteries: "63%" (left) or "37% used".
                                Text(smallLabel(usage))
                                    .font(.system(.caption, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(usage.binding?.isExhausted == true ? Color.red : Color.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            } else {
                                UsageRing(service: nil, window: nil)
                                Text(" ").font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Row of rings with remaining % and reset time underneath.
private struct MediumView: View {
    let entry: UsageEntry
    private var used: Bool { entry.snapshot.showsUsed == true }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(entry.snapshot.ordered) { usage in
                VStack(spacing: 3) {
                    UsageRing(usage: usage, showsUsed: used)
                        .frame(maxHeight: 58)
                        .padding(.bottom, 3)
                    if let window = usage.binding {
                        // Big number = your chosen one; the other one right under it.
                        let big = used ? UsageFormat.usedPercent(window) : UsageFormat.leftPercent(window)
                        let small = used ? UsageFormat.leftPercent(window) : UsageFormat.usedPercent(window)
                        (Text("\(big)%").font(.system(.title3, design: .rounded).weight(.semibold))
                         + Text(used ? " used" : " left").font(.caption2).foregroundColor(.secondary))
                            .monospacedDigit()
                        Text("\(small)% \(used ? "left" : "used")")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—").font(.system(.title3, design: .rounded).weight(.semibold))
                    }
                    Text(UsageFormat.caption(usage, now: entry.date))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(usage.binding?.isExhausted == true ? Color.red : Color.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// List with every window per tool and when each one resets.
private struct LargeView: View {
    let entry: UsageEntry
    private var used: Bool { entry.snapshot.showsUsed == true }

    var body: some View {
        let usages = entry.snapshot.ordered
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(usages.enumerated()), id: \.element.id) { index, usage in
                HStack(alignment: .center, spacing: 12) {
                    UsageRing(usage: usage, showsUsed: used)
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(usage.service.displayName).font(.headline)
                            if let plan = usage.plan {
                                Text(plan).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Text(UsageFormat.percent(usage, showsUsed: used))
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                        if usage.windows.isEmpty {
                            Text(usage.error ?? "No data yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else {
                            ForEach(usage.windows.prefix(2)) { window in
                                WindowBar(window: window, now: entry.date, showsUsed: used)
                            }
                        }
                    }
                }
                if index < usages.count - 1 { Divider() }
            }
            Spacer(minLength: 0)
            if entry.snapshot.updatedAt > .distantPast {
                Text("Updated \(UsageFormat.clock(entry.snapshot.updatedAt, now: entry.date))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

// MARK: - Widget

struct AILimitsWidget: Widget {
    let kind = "AILimitsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimeline()) { entry in
            AILimitsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("AI Limits")
        .description("Remaining Claude Code, Codex and Gemini limits, and when they reset.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct AILimitsWidgetBundle: WidgetBundle {
    var body: some Widget { AILimitsWidget() }
}

#Preview(as: .systemSmall) { AILimitsWidget() } timeline: { UsageEntry(date: .now, snapshot: .preview) }
#Preview(as: .systemMedium) { AILimitsWidget() } timeline: { UsageEntry(date: .now, snapshot: .preview) }
#Preview(as: .systemLarge) { AILimitsWidget() } timeline: { UsageEntry(date: .now, snapshot: .preview) }
