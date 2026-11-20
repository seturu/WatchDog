import Charts
import SwiftUI
import WatchDogCore

/// The dashboard: what today looks like so far.
struct TodayView: View {
    let tracker: Tracker
    let rules: RuleRunner

    @State private var summary = DaySummary.empty
    @State private var recent: [Span] = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                NowStrip(tracker: tracker)
                DaemonNotices(runner: rules)
                if let block = rules.activeBlock { BlockBanner(block: block) }
                if tracker.clockReading.isTampered { ClockNotice(reading: tracker.clockReading) }
                PermissionNotices(tracker: tracker)
                if let error = loadError ?? tracker.lastError ?? rules.error {
                    Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                }
                tiles
                Card("Through the day", systemImage: "chart.bar.xaxis") { hourChart }
                HStack(alignment: .top, spacing: Theme.gap) {
                    Card("Apps", systemImage: "square.grid.2x2") { appList }
                    Card("Sites", systemImage: "globe") { siteList }
                }
                Card("Recent activity", systemImage: "list.bullet") { timeline }
            }
            .padding(20)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Today")
        .navigationSubtitle(Date().formatted(date: .complete, time: .omitted))
        .toolbar { ModeSwitch(runner: rules) }
        .onAppear(perform: reload)
        // The tracker stores a sample every 2 s; refresh every third one.
        .onChange(of: tracker.revision) { _, revision in
            if revision % 3 == 0 { withAnimation(.smooth) { reload() } }
        }
    }

    // MARK: Headline numbers

    private var tiles: some View {
        HStack(spacing: Theme.gap) {
            StatTile(title: "Active", value: Format.short(summary.active), systemImage: "bolt.fill",
                     tint: .blue, caption: "At the keyboard")
            StatTile(title: "Focus", value: Format.short(summary.focus), systemImage: "brain.head.profile",
                     tint: Theme.focus, caption: focusCaption)
            StatTile(title: "Away", value: Format.short(summary.away), systemImage: "figure.walk",
                     tint: Theme.away, caption: "No input for 2 min or more")
            if let budget = rules.budgets.values.first {
                StatTile(title: "Break budget", value: Format.short(budget.remaining),
                         systemImage: "cup.and.saucer.fill", tint: Theme.onBreak,
                         caption: "\(Format.short(budget.used)) used of \(Format.short(budget.earned)) earned")
            } else {
                StatTile(title: "Breaks", value: Format.short(summary.onBreak),
                         systemImage: "cup.and.saucer.fill", tint: Theme.onBreak, caption: "Timer on a break")
            }
        }
    }

    private var focusCaption: String {
        guard summary.active > 0 else { return "Timer on a focus interval" }
        return "\(Int((summary.focus / summary.active * 100).rounded()))% of active time"
    }

    // MARK: Chart

    @ViewBuilder private var hourChart: some View {
        if summary.hours.isEmpty {
            ContentUnavailableView("Nothing recorded yet", systemImage: "chart.bar",
                                   description: Text("Activity appears here within a few seconds."))
                .frame(height: 190)
        } else {
            let hours = visibleHours
            Chart(summary.hours) { slice in
                BarMark(x: .value("Hour", Self.label(slice.hour)),
                        y: .value("Minutes", slice.seconds / 60),
                        width: .ratio(0.62))
                    .foregroundStyle(by: .value("App", slice.series))
                    .cornerRadius(3)
            }
            .chartForegroundStyleScale(
                domain: summary.series,
                range: summary.series.enumerated().map { Theme.seriesColor($0.offset, name: $0.element) })
            .chartXScale(domain: hours.map(Self.label))
            .chartYScale(domain: 0...60)
            .chartYAxis {
                AxisMarks(values: [0, 20, 40, 60]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let minutes = value.as(Int.self) { Text("\(minutes)m") } }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
            .frame(height: 190)
            .accessibilityLabel("Active minutes per hour, by app")
        }
    }

    /// From the first active hour (or a few hours back, so one bar never fills
    /// the chart) through the current hour.
    private var visibleHours: [Int] {
        let now = Calendar.current.component(.hour, from: Date())
        let first = summary.hours.map(\.hour).min() ?? now
        let last = max(now, summary.hours.map(\.hour).max() ?? now)
        let lower = max(0, min(first, last - 7))
        // Early in the day there are no earlier hours to show; extend forward
        // instead, so the chart always spans at least eight hours.
        return Array(lower...max(last, min(23, lower + 7)))
    }

    private static func label(_ hour: Int) -> String { String(format: "%02d", hour) }

    // MARK: Lists

    @ViewBuilder private var appList: some View {
        let rows = Array(summary.apps.prefix(7))
        if rows.isEmpty {
            emptyRow("No apps yet")
        } else {
            VStack(spacing: 12) {
                ForEach(rows) { app in
                    UsageRow(label: app.label, seconds: app.seconds, maximum: rows[0].seconds,
                             tint: seriesTint(app.label)) {
                        AppIcon(bundleID: app.key, size: 26)
                    }
                }
            }
        }
    }

    @ViewBuilder private var siteList: some View {
        let rows = Array(summary.sites.prefix(7))
        if rows.isEmpty {
            emptyRow("No sites yet")
        } else {
            VStack(spacing: 12) {
                ForEach(rows) { site in
                    UsageRow(label: site.label, seconds: site.seconds, maximum: rows[0].seconds, tint: .teal) {
                        SiteIcon(domain: site.key, size: 26)
                    }
                }
            }
        }
    }

    /// Same colour as the app's series in the chart, so the two read together.
    private func seriesTint(_ label: String) -> Color {
        guard let index = summary.series.firstIndex(of: label) else { return .gray }
        return Theme.seriesColor(index, name: label)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
    }

    @ViewBuilder private var timeline: some View {
        if recent.isEmpty {
            emptyRow("Nothing yet")
        } else {
            VStack(spacing: 0) {
                ForEach(recent) { span in
                    TimelineRow(span: span)
                    if span.id != recent.last?.id { Divider().padding(.leading, 38) }
                }
            }
        }
    }

    // MARK: Data

    private func reload() {
        do {
            summary = try tracker.store.summary()
            // Sub-second flickers between apps are noise in a timeline.
            recent = try tracker.store.recentSpans(limit: 60).filter { $0.seconds >= 3 }.prefix(14).map { $0 }
            loadError = nil
        } catch {
            loadError = "Could not read usage history: \(error.localizedDescription)"
        }
    }
}

/// What is happening right now: front app, timer, and anything making sound.
private struct NowStrip: View {
    let tracker: Tracker

    var body: some View {
        HStack(spacing: 14) {
            if let now = tracker.current {
                if now.isIdle {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 30)).foregroundStyle(.secondary).frame(width: 44, height: 44)
                } else {
                    AppIcon(bundleID: now.bundleID, size: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOW").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    Text(now.isIdle ? "Away" : now.appName).font(.title3.weight(.semibold))
                    if let detail = now.domain ?? now.windowTitle, !now.isIdle {
                        Text(detail).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Starting…").foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                let timer = tracker.focusTimer
                Label(TimerText.headline(timer), systemImage: TimerText.symbol(timer))
                    .foregroundStyle(Theme.color(for: timer.state))
                    .font(.callout.weight(.medium))
                if let detail = TimerText.detail(timer) {
                    Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                if let source = tracker.nowPlaying.first {
                    Label(source.title ?? "Sound playing", systemImage: "speaker.wave.2.fill")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(Theme.gap)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
    }
}

private struct TimelineRow: View {
    let span: Span

    var body: some View {
        HStack(spacing: 12) {
            if span.isIdle {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.secondary).frame(width: 26, height: 26)
            } else {
                AppIcon(bundleID: span.bundleID, size: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(span.isIdle ? "Away" : span.appName)
                    TimerBadge(state: span.timerState)
                }
                if let detail = span.domain ?? span.windowTitle, !span.isIdle {
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.short(span.seconds)).monospacedDigit()
                Text(Format.clock(span.startedAt)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

/// Missing permissions, each with the one button that fixes it.
struct PermissionNotices: View {
    let tracker: Tracker

    var body: some View {
        if !tracker.accessibilityGranted {
            notice("Window titles are not being recorded",
                   detail: "WatchDog needs Accessibility access to read them.",
                   button: "Grant Access…", action: SystemSettings.requestAccessibility)
        }
        ForEach(tracker.browserAccess.filter { $0.value == .denied }.map(\.key).sorted(), id: \.self) { bundleID in
            notice("Addresses are not being recorded for this browser",
                   detail: "Allow WatchDog to control it under Automation.",
                   button: "Open Settings…", action: SystemSettings.openAutomation) {
                AppIcon(bundleID: bundleID, size: 28)
            }
        }
    }

    private func notice(_ title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        notice(title, detail: detail, button: button, action: action) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(Theme.warning)
        }
    }

    private func notice<Icon: View>(_ title: String, detail: String, button: String,
                                    action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 12) {
            icon()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action)
        }
        .padding(12)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}
