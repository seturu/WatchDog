import SwiftUI
import WatchDogCore

/// The Focus screen: the pomodoro timer and the history of past sessions.
///
/// With the built-in timer it is the timer itself. With an external app it
/// shows what that app reports, since WatchDog only reads it.
struct FocusView: View {
    let pomodoro: PomodoroTimer
    let tracker: Tracker
    let rules: RuleRunner

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var editing: FocusSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                if pomodoro.usesBuiltIn {
                    TimerCard(timer: pomodoro)
                    if let review = pomodoro.review {
                        Card { ReviewPanel(timer: pomodoro, session: review) }
                            .id(review.id)
                    }
                } else {
                    ExternalTimerCard(app: pomodoro.externalApp, reading: tracker.focusTimer)
                }
                if let error = pomodoro.error {
                    Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                }
                history
            }
            .padding(20)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Focus")
        .navigationSubtitle(pomodoro.usesBuiltIn ? "Built-in timer" : "Following \(pomodoro.externalApp?.name ?? "an external timer")")
        .toolbar {
            ToolbarItem {
                Button("Compact Timer", systemImage: "arrow.down.right.and.arrow.up.left") {
                    openWindow(id: CompactTimerView.windowID)
                    dismissWindow(id: "main")
                }
                .help("Shrink to a small timer that floats above other windows")
            }
            ModeSwitch(runner: rules)
        }
        .sheet(item: $editing) { session in
            SessionEditor(timer: pomodoro, session: session)
        }
    }

    // MARK: History

    @ViewBuilder private var history: some View {
        let days = SessionDay.group(pomodoro.sessions)
        if days.isEmpty {
            Card("Sessions", systemImage: "list.bullet") {
                Text(pomodoro.usesBuiltIn
                     ? "Finished focus sessions appear here by day, with their category, rating and note."
                     : "Sessions from the built-in timer appear here. \(pomodoro.externalApp?.name ?? "The external app") keeps its own history.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        } else {
            ForEach(days) { day in
                Card(title: Self.dayTitle(day.day), systemImage: nil) {
                    Text(Self.daySummary(day)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                } content: {
                    VStack(spacing: 0) {
                        ForEach(day.sessions) { session in
                            SessionRow(session: session, category: session.categoryID.flatMap { pomodoro.categoryByID[$0] })
                                .onTapGesture { editing = session }
                                .contextMenu {
                                    Button("Edit…") { editing = session }
                                    Button("Delete", role: .destructive) { pomodoro.delete(session) }
                                }
                            if session.id != day.sessions.last?.id { Divider().padding(.leading, 20) }
                        }
                    }
                }
            }
        }
    }

    static func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func daySummary(_ day: SessionDay) -> String {
        let count = day.sessions.count
        var parts = ["\(count) \(count == 1 ? "session" : "sessions")", Format.short(day.focusedSeconds)]
        let focused = day.count(.focused)
        if focused > 0 { parts.append("\(focused) focused") }
        return parts.joined(separator: " · ")
    }
}

/// The built-in timer: ring and countdown, what is running, and the controls.
private struct TimerCard: View {
    let timer: PomodoroTimer

    var body: some View {
        let machine = timer.machine
        Card {
            HStack(spacing: 28) {
                PomodoroDial(timer: timer)
                VStack(alignment: .leading, spacing: 12) {
                    Label(PomodoroText.headline(machine), systemImage: PomodoroText.symbol(machine))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(machine.isIdle ? AnyShapeStyle(.primary) : AnyShapeStyle(machine.phase.tint))
                    HStack(spacing: 10) {
                        RoundDots(machine: machine, settings: timer.settings)
                        Text(PomodoroText.round(machine, settings: timer.settings))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if machine.phase == .focus {
                        if timer.categories.isEmpty {
                            Text("Add categories under Settings → Pomodoro to sort your sessions.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            CategoryPicker(timer: timer)
                        }
                    }
                    PomodoroControls(timer: timer)
                        .padding(.top, 4)
                    Text(footnote(machine))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
    }

    private func footnote(_ machine: PomodoroMachine) -> String {
        let r = timer.settings.rhythm
        let rhythm = "\(r.focusMinutes) min focus, \(r.shortBreakMinutes) min breaks, \(r.longBreakMinutes) min after every \(timer.settings.roundLength)."
        if machine.isPaused && machine.phase == .focus {
            return "Rules still treat a paused focus session as focus. " + rhythm
        }
        return rhythm
    }
}

/// An external timer app WatchDog follows but does not control.
private struct ExternalTimerCard: View {
    let app: (any ExternalTimerApp)?
    let reading: TimerReading

    var body: some View {
        Card {
            HStack(spacing: 14) {
                if let app { AppIcon(bundleID: app.bundleID, size: 44) }
                VStack(alignment: .leading, spacing: 3) {
                    Label(TimerText.headline(reading), systemImage: TimerText.symbol(reading))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.color(for: reading.state))
                    if let detail = TimerText.detail(reading) {
                        Text(detail).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                if let app, app.isInstalled {
                    Button("Open \(app.name)") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                            NSWorkspace.shared.openApplication(at: url, configuration: .init())
                        }
                    }
                }
            }
            Text(explanation)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: String {
        guard let app else { return "Choose a timer under Settings → Pomodoro." }
        if !app.isInstalled { return "\(app.name) is not installed. Install it, or choose the built-in timer under Settings → Pomodoro." }
        return "WatchDog reads \(app.name)'s timer and does not control it: start, pause and skip in \(app.name). To use WatchDog's own timer, choose Built-in under Settings → Pomodoro."
    }
}
