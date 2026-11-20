import Charts
import SwiftUI
import WatchDogCore
import WidgetKit

/// Focus & breaks: focused work today, breaks earned, breaks taken; the
/// large size adds the last seven days.
struct FocusWidget: Widget {
    let kind = "FocusAndBreaks"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            FocusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Focus & Breaks")
        .description("Focused work today, the breaks it earned, and the breaks you took.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct FocusWidgetView: View {
    let entry: SnapshotEntry
    /// Nil: the size WidgetKit draws the widget at.
    var size: WidgetFamily?
    @Environment(\.widgetFamily) private var drawnSize
    private var family: WidgetFamily { size ?? drawnSize }

    var body: some View {
        if let snapshot = entry.snapshot, !entry.appAway {
            switch family {
            case .systemSmall: small(snapshot)
            case .systemLarge: large(snapshot)
            default: medium(snapshot)
            }
        } else {
            AppAwayView(hasSnapshot: entry.snapshot != nil)
        }
    }

    // MARK: Sizes

    private func small(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            focusFigure(s, size: 30)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Label(earnedLine(s.breaksEarned), systemImage: "sparkles")
                Label(takenLine(s.today), systemImage: "cup.and.saucer.fill")
            }
            .font(.caption)
            .labelStyle(CompactLabel(tint: WidgetTheme.onBreak))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func medium(_ s: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                focusFigure(s, size: 34)
                Spacer(minLength: 0)
                timerLine(s.timer)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 12) {
                earnedBlock(s.breaksEarned)
                takenBlock(s.today)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func large(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            medium(s).frame(height: 128)
            Divider()
            WeekChart(days: s.earlier + [s.today])
        }
    }

    // MARK: Pieces

    private func focusFigure(_ s: WidgetSnapshot, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Focus today", systemImage: "brain.head.profile")
                .font(.caption.weight(.medium))
                .foregroundStyle(WidgetTheme.focus)
            Text(WidgetFormat.short(s.today.focusSeconds))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .widgetAccentable()
            Text(intervals(s.today.focusIntervals))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func earnedBlock(_ breaks: WidgetBreaks) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Breaks earned", systemImage: "sparkles")
                .font(.caption.weight(.medium))
                .foregroundStyle(WidgetTheme.onBreak)
            if breaks.earnedSeconds < 30 {
                Text("None yet")
                    .font(.callout.weight(.semibold))
                Text("Focus time earns them")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let left = breaks.remainingSeconds {
                Meter(fraction: breaks.earnedSeconds > 0 ? left / breaks.earnedSeconds : 0, tint: WidgetTheme.onBreak)
                Text("\(WidgetFormat.short(left)) left of \(WidgetFormat.short(breaks.earnedSeconds))")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            } else {
                Text(WidgetFormat.short(breaks.earnedSeconds))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("at your timer's rhythm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func takenBlock(_ today: FocusTally) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Breaks taken", systemImage: "cup.and.saucer.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(WidgetTheme.onBreak)
            Text(takenLine(today))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder private func timerLine(_ timer: WidgetTimer) -> some View {
        let shown = entry.timer ?? timer
        HStack(spacing: 4) {
            Circle().fill(WidgetTheme.color(for: shown.interval)).frame(width: 7, height: 7)
            switch shown.status {
            case .running:
                Text(shown.interval == .onBreak ? "Break" : "Focus")
                if let end = shown.endsAt {
                    Text(timerInterval: entry.date...max(entry.date, end), countsDown: true)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            case .paused:
                Text("Paused")
            case .ended:
                Text("Time's up")
            case .idle:
                Text("No timer running").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func earnedLine(_ breaks: WidgetBreaks) -> String {
        if breaks.earnedSeconds < 30 { return "No breaks earned yet" }
        if let left = breaks.remainingSeconds {
            return "\(WidgetFormat.short(left)) of \(WidgetFormat.short(breaks.earnedSeconds)) left"
        }
        return "\(WidgetFormat.short(breaks.earnedSeconds)) earned"
    }

    private func takenLine(_ today: FocusTally) -> String {
        let count = today.breaks == 1 ? "1 break" : "\(today.breaks) breaks"
        return today.breaks == 0 ? "No breaks taken yet" : "\(count) · \(WidgetFormat.short(today.breakSeconds))"
    }

    private func intervals(_ count: Int) -> String {
        switch count {
        case 0: "No focus intervals yet"
        case 1: "1 focus interval"
        default: "\(count) focus intervals"
        }
    }
}

/// How much of the break budget is left, as a bar.
private struct Meter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { space in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: space.size.width * min(1, max(0, fraction)))
                    .widgetAccentable()
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// A small icon in a colour, then the text.
private struct CompactLabel: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint).frame(width: 14)
            configuration.title
        }
    }
}

/// Focus and break minutes per day, the last seven days.
private struct WeekChart: View {
    let days: [FocusTally]

    private struct Bar: Identifiable {
        let day: Date
        let kind: String
        let minutes: Double
        var id: String { "\(day.timeIntervalSince1970)-\(kind)" }
    }

    private var bars: [Bar] {
        days.flatMap { day in
            [Bar(day: day.day, kind: "Focus", minutes: day.focusSeconds / 60),
             Bar(day: day.day, kind: "Breaks", minutes: day.breakSeconds / 60)]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last 7 days").font(.caption.weight(.medium))
                Spacer()
                Text("Focus \(WidgetFormat.short(days.reduce(0) { $0 + $1.focusSeconds }))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Chart(bars) { bar in
                BarMark(x: .value("Day", bar.day, unit: .day),
                        y: .value("Minutes", bar.minutes))
                    .foregroundStyle(by: .value("Kind", bar.kind))
                    .position(by: .value("Kind", bar.kind))
                    .cornerRadius(2)
            }
            .chartForegroundStyleScale(["Focus": WidgetTheme.focus, "Breaks": WidgetTheme.onBreak])
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let minutes = value.as(Double.self) { Text(axisLabel(minutes)) } }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
        }
    }

    private func axisLabel(_ minutes: Double) -> String {
        minutes >= 60 ? "\(Int(minutes / 60))h" : "\(Int(minutes))m"
    }
}
