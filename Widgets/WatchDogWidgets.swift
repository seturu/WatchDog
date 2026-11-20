import SwiftUI
import WatchDogCore
import WidgetKit

// The widget extension: desktop and Notification Center widgets.
//
// It is sandboxed and never opens the usage database. It reads the
// snapshot the app publishes in the shared App Group container, and its
// buttons leave a command there for the app (see WidgetChannel in
// WatchDogCore). With the app not running, the widgets say so and offer
// no buttons.

@main
struct WatchDogWidgets: WidgetBundle {
    var body: some Widget {
        FocusWidget()
        PomodoroWidget()
    }
}

// MARK: Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// Nil before the app has published anything.
    let snapshot: WidgetSnapshot?
    /// The app had not written for a while when this timeline was made.
    let appAway: Bool

    var timer: WidgetTimer? { snapshot?.timer(at: date) }

    static func empty(_ date: Date) -> SnapshotEntry { SnapshotEntry(date: date, snapshot: nil, appAway: true) }
}

/// Reads the app's snapshot. One entry now and, while an interval runs, one
/// a minute until its end; then asks again soon after the end, or in 15
/// minutes for the day's totals. The app also asks for a redraw whenever the
/// timer changes.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample(at: Date()), appAway: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let now = Date()
        // The widget gallery shows sample numbers until the app has published some.
        if let entry = current(at: now), entry.snapshot != nil {
            completion(entry)
        } else {
            completion(context.isPreview ? placeholder(in: context) : .empty(now))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        guard let entry = current(at: now), let snapshot = entry.snapshot else {
            completion(Timeline(entries: [.empty(now)], policy: .after(now.addingTimeInterval(15 * 60))))
            return
        }
        var entries = [entry]
        if !entry.appAway, snapshot.timer.status == .running, let end = snapshot.timer.endsAt, end > now {
            // The countdown text runs by itself; these move the ring once a
            // minute and show the end. Entries cost nothing from the budget.
            var next = now.addingTimeInterval(60)
            while next < end.addingTimeInterval(-1) && entries.count < 120 {
                entries.append(SnapshotEntry(date: next, snapshot: snapshot, appAway: false))
                next.addTimeInterval(60)
            }
            entries.append(SnapshotEntry(date: end, snapshot: snapshot, appAway: false))
        }
        completion(Timeline(entries: entries, policy: .after(snapshot.nextRefresh(after: now))))
    }

    private func current(at now: Date) -> SnapshotEntry? {
        guard let channel = WidgetChannel.shared() else { return nil }
        let snapshot = channel.readSnapshot()
        return SnapshotEntry(date: now, snapshot: snapshot, appAway: snapshot?.isStale(at: now) ?? true)
    }
}

// MARK: Shared pieces

enum WidgetFormat {
    /// 45 -> "45s", 190 -> "3m", 3720 -> "1h 2m". As the app's dashboard.
    static func short(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return s == 0 ? "0m" : "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let minutes = (s % 3600) / 60
        return minutes == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(minutes)m"
    }

    /// 1499 -> "24:59".
    static func countdown(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

enum WidgetTheme {
    // The app's colours (Theme.focus and Theme.onBreak).
    static let focus = Color.indigo
    static let onBreak = Color.green

    static func color(for interval: TimerState) -> Color {
        switch interval {
        case .focus: focus
        case .onBreak: onBreak
        case .none: .secondary
        }
    }

    static func color(_ category: CategoryColor) -> Color {
        switch category {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .brown: .brown
        case .gray: .gray
        }
    }
}

/// Shown instead of the numbers when there are none to trust.
struct AppAwayView: View {
    let hasSnapshot: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(hasSnapshot ? "WatchDog is not running" : "Open WatchDog")
                .font(.headline)
            Text(hasSnapshot ? "These numbers come back when it starts." : "Your focus and breaks appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: Gallery sample

extension WidgetSnapshot {
    /// Made-up numbers for the widget gallery.
    static func sample(at now: Date) -> WidgetSnapshot {
        let today = Calendar.current.startOfDay(for: now)
        let earlier = (1...6).reversed().map { back in
            FocusTally(day: Calendar.current.date(byAdding: .day, value: -back, to: today) ?? today,
                       focusSeconds: Double([5400, 7200, 3600, 9000, 6300, 4500][back - 1]),
                       focusIntervals: 4, breakSeconds: 1500, breaks: 4)
        }
        let timer = WidgetTimer(isBuiltIn: true, sourceName: WidgetTimer.builtInName, status: .running,
                                interval: .focus, phase: .focus, endsAt: now.addingTimeInterval(17 * 60 + 24),
                                plannedSeconds: 1500, completedInRound: 1, roundLength: 4,
                                categoryName: "Writing", categoryColor: .teal, token: "sample",
                                actions: [.pause, .skip, .stop])
        return WidgetSnapshot(writtenAt: now, timer: timer,
                              today: FocusTally(day: today, focusSeconds: 8100, focusIntervals: 5,
                                                breakSeconds: 1680, breaks: 4),
                              earlier: earlier,
                              breaksEarned: WidgetBreaks(earnedSeconds: 2430, usedSeconds: 900, ruleName: "Sample"))
    }
}
