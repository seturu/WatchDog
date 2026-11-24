import SwiftUI
import WatchDogCore

/// The SwiftUI app (started from `Entry.main` in DevCLI.swift): a menu-bar
/// item with a popover, and one main window.
struct WatchDogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // `.window` style makes the menu-bar item open a popover instead of a menu.
        MenuBarExtra {
            if let tracker = AppState.shared.tracker, let rules = AppState.shared.rules,
               let pomodoro = AppState.shared.pomodoro {
                MenuPopover(tracker: tracker, rules: rules, pomodoro: pomodoro)
            } else {
                Text(AppState.shared.startupError ?? "Tracking is unavailable.").padding()
            }
        } label: {
            MenuBarLabel(tracker: AppState.shared.tracker, rules: AppState.shared.rules)
        }
        .menuBarExtraStyle(.window)

        Window("WatchDog", id: "main") {
            if let tracker = AppState.shared.tracker, let rules = AppState.shared.rules,
               let pomodoro = AppState.shared.pomodoro {
                MainWindow(tracker: tracker, rules: rules, pomodoro: pomodoro)
            } else {
                StartupFailureView(message: AppState.shared.startupError ?? "Tracking is unavailable.")
            }
        }
        .defaultSize(width: 1040, height: 760)

        // The compact layout: only the pomodoro timer, sized to its content
        // and kept above other windows.
        Window("Focus", id: CompactTimerView.windowID) {
            if let tracker = AppState.shared.tracker, let pomodoro = AppState.shared.pomodoro {
                CompactTimerView(pomodoro: pomodoro, tracker: tracker)
            } else {
                Text(AppState.shared.startupError ?? "Tracking is unavailable.").padding()
            }
        }
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .defaultPosition(.topTrailing)
    }
}

/// What sits in the menu bar: a symbol for the state and, when a timer is
/// running, the number that matters most right now.
private struct MenuBarLabel: View {
    let tracker: Tracker?
    let rules: RuleRunner?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            // The label is the one view that always exists, so it hosts the
            // "open the main window at launch" option (`WatchDog --show-window`).
            .task {
                if CommandLine.arguments.contains("--show-window") { showMainWindow() }
            }
            // A second launch of the app (from Finder, Spotlight, the Dock)
            // asks the running copy to show its window.
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init(WD.showWindowNotification))) { _ in
                showMainWindow()
            }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    @ViewBuilder private var content: some View {
        // Reading `revision` makes this redraw as the tracker ticks, so the
        // countdown stays current.
        let _ = tracker?.revision
        let timer = tracker?.focusTimer ?? .none
        HStack(spacing: 4) {
            Image(systemName: symbol(timer))
            if let text = text(timer) { Text(text).monospacedDigit() }
        }
        .accessibilityLabel("WatchDog, \(TimerText.headline(timer))")
    }

    private func symbol(_ timer: TimerReading) -> String {
        if timer.isPaused { return "pause.circle" }
        switch timer.state {
        case .focus: return "eye.fill"
        case .onBreak: return "cup.and.saucer.fill"
        case .none: return "eye"
        }
    }

    /// Focus: time left in the interval. Break: break budget left, if a
    /// "Pomodoro it" rule is active, otherwise time left in the break.
    /// Paused: time left in the paused interval.
    private func text(_ timer: TimerReading) -> String? {
        if timer.isPaused { return TimerText.remaining(timer).map(Format.short) }
        switch timer.state {
        case .none:
            return nil
        case .focus:
            return TimerText.remaining(timer).map(Format.short)
        case .onBreak:
            if let budget = rules?.budgets.values.first { return Format.short(budget.remaining) }
            return TimerText.remaining(timer).map(Format.short)
        }
    }
}

/// The popover under the menu-bar item: a glance, not a dashboard.
private struct MenuPopover: View {
    let tracker: Tracker
    let rules: RuleRunner
    let pomodoro: PomodoroTimer

    @Environment(\.openWindow) private var openWindow
    @State private var summary = DaySummary.empty

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            now
            if let block = rules.activeBlock {
                Label("Blocked for \(Format.duration(block.remainingSeconds)): \(block.domains.joined(separator: ", "))",
                      systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.red).lineLimit(2).monospacedDigit()
            }
            Divider()
            timer
            if let budget = rules.budgets.values.first {
                Gauge(value: budget.remaining, in: 0...max(budget.earned, 1)) {
                    Text("Break budget")
                } currentValueLabel: {
                    Text("\(Format.short(budget.remaining)) left").monospacedDigit()
                }
                .tint(Theme.onBreak)
            }
            Divider()
            HStack {
                figure("Active", Format.short(summary.active))
                Spacer()
                figure("Focus", Format.short(summary.focus))
                Spacer()
                figure("Away", Format.short(summary.away))
            }
            if !tracker.accessibilityGranted {
                Label("Window titles need Accessibility access", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Theme.warning)
            }
            // Adjacent glass controls share one container so they render as a group.
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        openWindow(id: "main")
                        // A menu-bar app is never frontmost by itself; without
                        // this the window would open behind other apps.
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Text("Open WatchDog").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("o")

                    Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .disabled(rules.isEnforcing)
                        .help(rules.isEnforcing ? "WatchDog cannot be quit while enforcing" : "Quit WatchDog")
                        .keyboardShortcut("q")
                }
                .controlSize(.large)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear(perform: reload)
        .onChange(of: tracker.revision) { _, revision in
            if revision % 5 == 0 { reload() }
        }
    }

    private var now: some View {
        HStack(spacing: 12) {
            if let sample = tracker.current, !sample.isIdle {
                AppIcon(bundleID: sample.bundleID, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sample.appName).font(.headline).lineLimit(1)
                    if let detail = sample.domain ?? sample.windowTitle {
                        Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                Image(systemName: "moon.zzz.fill").font(.title).foregroundStyle(.secondary).frame(width: 36, height: 36)
                Text(tracker.current == nil ? "Starting…" : "Away").font(.headline)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var timer: some View {
        if pomodoro.usesBuiltIn {
            PopoverTimer(timer: pomodoro)
        } else {
            let reading = tracker.focusTimer
            HStack {
                Label(TimerText.headline(reading), systemImage: TimerText.symbol(reading))
                    .foregroundStyle(Theme.color(for: reading.state))
                    .fontWeight(.medium)
                Spacer()
                if let detail = TimerText.detail(reading) {
                    Text(detail).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    private func reload() {
        if let fresh = try? tracker.store.summary() {
            withAnimation(.smooth) { summary = fresh }
        }
    }
}

/// The built-in timer in the popover: what runs, how long is left, and the
/// buttons to start, pause, skip and stop it. After a focus session, the
/// rating.
private struct PopoverTimer: View {
    let timer: PomodoroTimer

    var body: some View {
        let machine = timer.machine
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(PomodoroText.headline(machine), systemImage: PomodoroText.symbol(machine))
                    .foregroundStyle(machine.isIdle ? AnyShapeStyle(.primary) : AnyShapeStyle(machine.phase.tint))
                    .fontWeight(.medium)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = machine.isIdle ? timer.settings.seconds(for: machine.phase) : timer.remaining()
                    Text(Format.countdown(left))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(machine.isIdle ? .secondary : .primary)
                }
            }
            HStack(spacing: 8) {
                if machine.phase == .focus && !timer.categories.isEmpty {
                    CategoryPicker(timer: timer)
                } else if let name = timer.selectedCategory?.name, machine.phase == .focus {
                    Text(name).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                RoundDots(machine: machine, settings: timer.settings)
            }
            .font(.callout)
            GlassEffectContainer(spacing: 8) {
                PomodoroControls(timer: timer, inPopover: true)
            }
            if let review = timer.review {
                ReviewPanel(timer: timer, session: review, inPopover: true)
                    .id(review.id)
                    .padding(.top, 2)
            }
        }
    }
}
