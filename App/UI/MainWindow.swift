import SwiftUI
import WatchDogCore

/// The main window: a sidebar on the left, the chosen screen on the right.
/// `NavigationSplitView` is the standard Mac layout for this; on macOS 26 the
/// sidebar and toolbar get the system's Liquid Glass treatment for free.
struct MainWindow: View {
    let tracker: Tracker
    let rules: RuleRunner
    let pomodoro: PomodoroTimer

    enum Pane: String, Hashable, CaseIterable {
        case today, focus, rules, history, setup, settings, checks

        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        var symbol: String {
            switch self {
            case .today: "sun.max"
            case .focus: "timer"
            case .rules: "checklist"
            case .history: "clock.arrow.circlepath"
            case .setup: "checklist.checked"
            case .settings: "gearshape"
            case .checks: "stethoscope"
            }
        }
    }

    @State private var pane: Pane? = .today

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                // Rows come from a ForEach so each row's selection value is its
                // identity, and the tag is the outermost modifier. With
                // `.tag(x).badge(n)` the badged rows (History, Setup) could not
                // be selected.
                ForEach(Pane.allCases.filter { $0 != .checks }, id: \.self) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(badge(for: item))
                        .tag(item)
                }
                if !WD.isArmed {
                    Section("Developer") {
                        Label("Checks", systemImage: "stethoscope").tag(Pane.checks)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { SidebarStatus(tracker: tracker) }
        } detail: {
            switch pane ?? .today {
            case .today: TodayView(tracker: tracker, rules: rules)
            case .focus: FocusView(pomodoro: pomodoro, tracker: tracker, rules: rules)
            case .rules: RulesView(runner: rules, tracker: tracker)
            case .history: HistoryView(runner: rules)
            case .setup: SetupView(tracker: tracker, runner: rules, pomodoro: pomodoro)
            case .settings: SettingsView(runner: rules, pomodoro: pomodoro)
            case .checks: SpikePanel().navigationTitle("Checks")
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        // A menu-bar app has no Dock icon. While this window is open, behave
        // like a regular app (Dock icon, Cmd-Tab), then go back to menu-bar only.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private func badge(for item: Pane) -> Int {
        switch item {
        case .history: todaysVerdicts
        case .setup: SetupView.remaining(tracker: tracker, runner: rules)
        default: 0
        }
    }

    private var todaysVerdicts: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return rules.verdicts.filter { $0.at >= start }.count
    }
}

/// Bottom of the sidebar: is tracking alive, and what is the timer doing.
private struct SidebarStatus: View {
    let tracker: Tracker

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(tracker.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(tracker.isRunning ? "Tracking" : "Not tracking")
                Spacer()
                TimerBadge(state: tracker.focusTimer.state)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

/// The mode switch in every screen's toolbar: dry run or enforcing.
/// Turning enforcement on asks first, because from then on rules act.
struct ModeSwitch: ToolbarContent {
    @Bindable var runner: RuleRunner
    @State private var confirming = false
    @State private var stopping = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                if runner.isEnforcing { stopping = true } else { confirming = true }
            } label: {
                Label(runner.isEndingEnforcement ? "Enforcing, ending soon" : runner.isEnforcing ? "Enforcing" : "Dry run",
                      systemImage: runner.isEnforcing ? "shield.lefthalf.filled" : "testtube.2")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(runner.isEnforcing ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .disabled(!runner.daemonReachable)
            .help(!runner.daemonReachable ? "The background service is not reachable, so rules run as a dry run."
                  : runner.isEnforcing ? "Rules close tabs and apps and start blocks."
                  : "Rules only notify and log. Click to start enforcing.")
            .confirmationDialog("Start enforcing rules?", isPresented: $confirming) {
                Button("Start Enforcing") { runner.requestEnforcing(true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Rules set to “Close it” will close matching browser tabs and quit matching apps. "
                     + "Rules set to “Block it” will start a timed block that cannot be cancelled. "
                     + "Once enforcing, switching back or relaxing a rule only takes effect after "
                     + "\(Format.duration(Limits.coolingOffSeconds)), and WatchDog cannot be quit.")
            }
            .confirmationDialog("Go back to dry run?", isPresented: $stopping) {
                Button("Switch to Dry Run After the Delay") { runner.requestEnforcing(false) }
                Button("Keep Enforcing", role: .cancel) {}
            } message: {
                Text("Enforcement stays on for another \(Format.duration(Limits.coolingOffSeconds)). "
                     + "While a block is running this is refused.")
            }
        }
    }
}

/// Everything the daemon wants you to know, stacked: a change counting down,
/// a refusal, a penalty block, or the daemon being unreachable.
struct DaemonNotices: View {
    let runner: RuleRunner

    var body: some View {
        if !runner.daemonReachable {
            banner("The background service is not reachable", "Rules run from the local copy, as a dry run only.",
                   symbol: "bolt.horizontal.circle.fill", tint: Theme.warning)
        }
        if let pending = runner.pending {
            HStack(spacing: 12) {
                Image(systemName: "hourglass").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your change takes effect in \(Format.duration(pending.remainingSeconds))")
                        .fontWeight(.medium).monospacedDigit()
                    Text(pending.config.isEnforcing
                         ? "It relaxes an active rule, so it waits. Until then the current rules stay in force."
                         : "Enforcement stays on until then.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Discard Change") { runner.discardPending() }
            }
            .padding(12)
            .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
        if let notice = runner.notice {
            banner("Change refused", notice, symbol: "lock.fill", tint: .red)
        }
        if !runner.penaltyDomains.isEmpty {
            banner("Blocked because WatchDog could not watch",
                   "\(runner.penaltyDomains.joined(separator: ", ")) stay blocked until the app is running with its permissions.",
                   symbol: "eye.slash.fill", tint: .red)
        }
    }

    private func banner(_ title: String, _ detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

/// Shown while the system clock or time zone disagrees with the trusted clock.
struct ClockNotice: View {
    let reading: TrustedClock.Reading

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark.fill").font(.title2).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(reading.clockChanged ? "The system clock was changed" : "The time zone was changed")
                    .fontWeight(.medium)
                Text("Schedules keep running on the original time: \(reading.now.formatted(.dateTime.weekday().hour().minute().timeZone()).description) in \(reading.calendar.timeZone.identifier). Restart WatchDog if the change is genuine.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

/// A running block: what, and for how much longer. There is no cancel button.
struct BlockBanner: View {
    let block: BlockState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.title2).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Blocked for \(Format.duration(block.remainingSeconds))").fontWeight(.medium).monospacedDigit()
                Text(block.domains.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            ProgressView(value: block.totalSeconds - block.remainingSeconds, total: max(block.totalSeconds, 1))
                .frame(width: 120)
                .tint(.red)
        }
        .padding(12)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
