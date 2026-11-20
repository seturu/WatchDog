import AppIntents
import SwiftUI
import WatchDogCore
import WidgetKit

/// The pomodoro timer: what runs, the time left, and the Focus screen's
/// buttons (start, pause or resume, skip, stop) for WatchDog's own timer.
/// An external timer (Session) is shown but cannot be controlled.
struct PomodoroWidget: Widget {
    let kind = "Pomodoro"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            PomodoroWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Pomodoro")
        .description("The time left, with buttons to start, pause, skip or stop WatchDog's timer.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PomodoroWidgetView: View {
    let entry: SnapshotEntry
    /// Nil: the size WidgetKit draws the widget at.
    var size: WidgetFamily?
    @Environment(\.widgetFamily) private var drawnSize
    private var family: WidgetFamily { size ?? drawnSize }

    var body: some View {
        if let timer = entry.timer, !entry.appAway {
            if family == .systemSmall { small(timer) } else { medium(timer) }
        } else {
            AppAwayView(hasSnapshot: entry.snapshot != nil)
        }
    }

    // MARK: Sizes

    private func small(_ timer: WidgetTimer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            headline(timer).font(.caption.weight(.medium))
            countdown(timer, size: 34)
            Spacer(minLength: 0)
            if timer.actions.isEmpty {
                footnote(timer, compact: true)
            } else {
                buttons(timer, compact: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func medium(_ timer: WidgetTimer) -> some View {
        HStack(spacing: 16) {
            Dial(timer: timer, date: entry.date)
                .frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 6) {
                headline(timer).font(.headline)
                if let name = timer.categoryName {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(timer.categoryColor.map(WidgetTheme.color) ?? Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(name).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if timer.isBuiltIn { RoundDots(timer: timer) }
                Spacer(minLength: 0)
                if timer.actions.isEmpty {
                    footnote(timer, compact: false)
                } else {
                    buttons(timer, compact: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Pieces

    private func headline(_ timer: WidgetTimer) -> some View {
        Label(Self.title(timer), systemImage: Self.symbol(timer))
            .foregroundStyle(timer.status == .idle && timer.interval == .none
                             ? AnyShapeStyle(.secondary) : AnyShapeStyle(WidgetTheme.color(for: timer.interval)))
            .lineLimit(1)
    }

    @ViewBuilder private func countdown(_ timer: WidgetTimer, size: CGFloat) -> some View {
        Group {
            if timer.status == .running, let end = timer.endsAt {
                Text(timerInterval: entry.date...max(entry.date, end), countsDown: true)
            } else if let left = timer.remainingSeconds {
                Text(WidgetFormat.countdown(left))
                    .foregroundStyle(timer.status == .paused ? .primary : .secondary)
            } else {
                Text("--:--").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .widgetAccentable()
    }

    /// The Focus screen's buttons for this moment, nothing else.
    private func buttons(_ timer: WidgetTimer, compact: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(timer.actions, id: \.self) { action in
                let prominent = action == timer.actions.first
                Button(intent: TimerControlIntent(TimerButton(action), token: timer.token)) {
                    if compact || !prominent {
                        Image(systemName: Self.symbol(action)).frame(maxWidth: compact && prominent ? .infinity : nil)
                    } else {
                        Label(Self.label(action, timer: timer), systemImage: Self.symbol(action))
                            .frame(maxWidth: .infinity)
                    }
                }
                .tint(prominent ? WidgetTheme.color(for: timer.interval == .none ? .focus : timer.interval) : nil)
                .buttonStyle(.bordered)
                .help(Self.label(action, timer: timer))
                .accessibilityLabel(Self.label(action, timer: timer))
            }
        }
        .controlSize(compact ? .small : .regular)
        .font(compact ? .callout : .callout.weight(.medium))
    }

    @ViewBuilder private func footnote(_ timer: WidgetTimer, compact: Bool) -> some View {
        Group {
            if timer.isBuiltIn {
                Text(timer.status == .ended ? "Moving on…" : "")
            } else {
                Text(compact ? "Run by \(timer.sourceName). Read only."
                     : "\(timer.sourceName) runs this timer. Choose WatchDog's in Settings → Pomodoro to control it here.")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(3)
    }

    // MARK: Words and symbols

    static func title(_ timer: WidgetTimer) -> String {
        let breakName = timer.phase == .longBreak ? "Long break" : "Break"
        switch timer.status {
        case .idle:
            guard timer.isBuiltIn else { return "\(timer.sourceName): no timer" }
            switch timer.phase {
            case .shortBreak: return "Time for a break"
            case .longBreak: return "Time for a long break"
            default: return "Ready to focus"
            }
        case .running:
            return timer.interval == .onBreak ? breakName : "Focus"
        case .paused:
            return timer.interval == .onBreak ? "Break paused" : "Focus paused"
        case .ended:
            return timer.interval == .onBreak ? "Break over" : "Focus done"
        }
    }

    static func symbol(_ timer: WidgetTimer) -> String {
        if timer.status == .paused { return "pause.circle" }
        if timer.status == .ended { return "checkmark.circle" }
        return timer.interval == .onBreak ? "cup.and.saucer.fill" : "timer"
    }

    static func symbol(_ action: WidgetAction) -> String {
        switch action {
        case .start, .resume: "play.fill"
        case .pause: "pause.fill"
        case .skip: "forward.end.fill"
        case .stop: "stop.fill"
        }
    }

    static func label(_ action: WidgetAction, timer: WidgetTimer) -> String {
        switch action {
        case .start: timer.interval == .onBreak ? "Start Break" : "Start Focus"
        case .pause: "Pause"
        case .resume: "Resume"
        case .skip: timer.status == .idle ? "Skip Break" : "Skip"
        case .stop: "Stop"
        }
    }
}

/// A ring that empties as the interval runs, with the time left inside.
/// The countdown text runs by itself; the ring moves with the timeline's
/// once-a-minute entries.
private struct Dial: View {
    let timer: WidgetTimer
    let date: Date

    var body: some View {
        let tint = WidgetTheme.color(for: timer.interval == .none ? .focus : timer.interval)
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            Group {
                if timer.status == .running, let end = timer.endsAt {
                    Text(timerInterval: date...max(date, end), countsDown: true)
                } else {
                    Text(timer.remainingSeconds.map(WidgetFormat.countdown) ?? "--:--")
                        .foregroundStyle(timer.status == .idle ? .secondary : .primary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
        }
        .font(.system(.title2, design: .rounded, weight: .semibold))
        .monospacedDigit()
        .padding(4)
    }

    /// Share of the interval still to run, 0...1. An idle timer shows an empty ring.
    private var fraction: Double {
        guard let planned = timer.plannedSeconds, planned > 0 else { return 0 }
        let left: Double = switch timer.status {
        case .running: timer.endsAt.map { max(0, $0.timeIntervalSince(date)) } ?? 0
        case .paused: timer.remainingSeconds ?? 0
        case .idle, .ended: 0
        }
        return min(1, left / planned)
    }
}

/// One dot per focus session in the round: done, current, to come.
private struct RoundDots: View {
    let timer: WidgetTimer

    var body: some View {
        let length = max(1, timer.roundLength)
        let done = timer.phase == .longBreak ? length : min(timer.completedInRound, length)
        HStack(spacing: 4) {
            ForEach(0..<length, id: \.self) { index in
                Circle()
                    .fill(index < done ? AnyShapeStyle(WidgetTheme.focus)
                          : index == done && timer.phase == .focus && timer.status != .idle
                          ? AnyShapeStyle(WidgetTheme.focus.opacity(0.4)) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(timer.phase?.isBreak == true ? "\(done) of \(length) done" : "Session \(min(done + 1, length)) of \(length)")
    }
}

// MARK: The buttons' intent

/// The control a widget button asks for.
enum TimerButton: String, AppEnum {
    case start, pause, resume, skip, stop

    init(_ action: WidgetAction) {
        self = TimerButton(rawValue: action.rawValue) ?? .start
    }

    var action: WidgetAction { WidgetAction(rawValue: rawValue) ?? .start }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Timer control"
    static let caseDisplayRepresentations: [TimerButton: DisplayRepresentation] = [
        .start: "Start", .pause: "Pause", .resume: "Resume", .skip: "Skip", .stop: "Stop",
    ]
}

/// Runs in the widget extension when a button is pressed. It cannot touch
/// the timer itself: it leaves a command for the app, which checks it and
/// carries it out the way the Focus screen's button would. It then waits a
/// moment for the app's answer, so the widget redraws with the new state.
struct TimerControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Control WatchDog's pomodoro timer"
    /// Only the widget's buttons use it; it is not offered in Shortcuts.
    static let isDiscoverable = false

    @Parameter(title: "Control") var control: TimerButton
    /// The timer the button was drawn for (`WidgetTimer.token`).
    @Parameter(title: "Timer") var token: String

    init() {}

    init(_ control: TimerButton, token: String) {
        self.control = control
        self.token = token
    }

    func perform() async throws -> some IntentResult {
        guard let channel = WidgetChannel.shared() else { return .result() }
        let command = WidgetCommand(action: control.action, token: token, issuedAt: Date())
        try channel.send(command)
        WidgetSignal.post()
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(100))
            if channel.readSnapshot()?.receipt(for: command.id) != nil { return .result() }
        }
        // No answer: the app is not running. Do not leave the press for later.
        channel.withdraw(command.id)
        return .result()
    }
}
