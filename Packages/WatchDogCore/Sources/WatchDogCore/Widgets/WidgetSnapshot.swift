import Foundation

// The desktop and Notification Center widgets.
//
// Widget extensions must be sandboxed and the app is not, and the usage
// database is private to the app (0600 in a 0700 folder). So the widgets
// never read it: the app publishes a small `WidgetSnapshot` into the shared
// App Group container, and the widget's buttons leave a `WidgetCommand` there
// for the app to carry out (see `WidgetChannel`). Everything in this file is
// pure and unit-tested.
//
// The snapshot holds numbers and the timer's state only: no window titles,
// addresses, apps, sites or session notes.

// MARK: Day totals

/// Focus and breaks over one day, from the spans the tracker stored. The
/// same numbers whichever timer runs (built-in or Session), because both feed
/// `timer_state` on the spans.
public struct FocusTally: Codable, Sendable, Equatable {
    /// Midnight at the start of the day.
    public var day: Date
    /// At the keyboard while the timer was on a focus interval: the Today
    /// screen's "Focus".
    public var focusSeconds: Double
    /// Focus intervals that ran today (whole or in part).
    public var focusIntervals: Int
    /// Timer on a break, at the keyboard or away.
    public var breakSeconds: Double
    /// Breaks taken.
    public var breaks: Int

    public init(day: Date, focusSeconds: Double = 0, focusIntervals: Int = 0,
                breakSeconds: Double = 0, breaks: Int = 0) {
        self.day = day
        self.focusSeconds = focusSeconds
        self.focusIntervals = focusIntervals
        self.breakSeconds = breakSeconds
        self.breaks = breaks
    }

    /// Stretches of the same timer state closer than this count as one
    /// interval: pausing a break for a moment (a paused break reads as no
    /// timer), a restart of the app, a hole in the history. A stretch of the
    /// other state in between always separates them.
    public static let mergeGap: TimeInterval = 300

    /// Totals for `day`. Spans are clipped to it; `spans` must be in
    /// chronological order.
    public init(spans: [Span], day: DateInterval) {
        self.init(day: day.start)
        var focusRuns = RunCounter(state: .focus)
        var breakRuns = RunCounter(state: .onBreak)
        for span in spans {
            let start = max(span.startedAt, day.start)
            let end = min(span.endedAt, day.end)
            // Spans written by older versions can run backwards after a clock
            // change; they count as nothing.
            guard end > start else { continue }
            let seconds = end.timeIntervalSince(start)
            switch span.timerState {
            case .focus where !span.isIdle: focusSeconds += seconds
            case .onBreak: breakSeconds += seconds
            default: break
            }
            focusRuns.see(span.timerState, from: start, to: end)
            breakRuns.see(span.timerState, from: start, to: end)
        }
        focusIntervals = focusRuns.count
        breaks = breakRuns.count
    }

    /// One tally per day for the `count` days ending with the day of `date`,
    /// oldest first. `spans` must be in chronological order.
    public static func days(_ count: Int, endingOn date: Date, spans: [Span],
                            calendar: Calendar = .current) -> [FocusTally] {
        let today = calendar.startOfDay(for: date)
        return (0..<max(0, count)).reversed().compactMap { back -> FocusTally? in
            guard let start = calendar.date(byAdding: .day, value: -back, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let day = DateInterval(start: start, end: end)
            return FocusTally(spans: spans.filter { $0.endedAt > day.start && $0.startedAt < day.end }, day: day)
        }
    }

    /// Counts separate runs of one timer state.
    private struct RunCounter {
        let state: TimerState
        var count = 0
        var lastEnd: Date?
        var interrupted = true

        mutating func see(_ seen: TimerState, from start: Date, to end: Date) {
            if seen == state {
                let close = lastEnd.map { start.timeIntervalSince($0) <= FocusTally.mergeGap } ?? false
                if interrupted || !close { count += 1 }
                interrupted = false
                lastEnd = end
            } else if seen != .none {
                interrupted = true
            }
        }
    }
}

// MARK: Break budget

/// Breaks earned by focus work. With a "Pomodoro it" rule, that rule's
/// budget (earned at its own rhythm since its period began today, and the
/// part already spent on its activity). Without one, focus time at the
/// built-in timer's rhythm, for information only.
public struct WidgetBreaks: Codable, Sendable, Equatable {
    public var earnedSeconds: Double
    /// Spent on the rule's activity during breaks. Nil without a rule.
    public var usedSeconds: Double?
    /// The "Pomodoro it" rule the budget belongs to.
    public var ruleName: String?

    public init(earnedSeconds: Double, usedSeconds: Double? = nil, ruleName: String? = nil) {
        self.earnedSeconds = earnedSeconds
        self.usedSeconds = usedSeconds
        self.ruleName = ruleName
    }

    /// Budget left, when a rule keeps one.
    public var remainingSeconds: Double? { usedSeconds.map { max(0, earnedSeconds - $0) } }

    public init(budget: RuleEngine.PomodoroStatus, ruleName: String) {
        self.init(earnedSeconds: budget.earned, usedSeconds: budget.used, ruleName: ruleName)
    }

    public init(focusSeconds: Double, rhythm: PomodoroSettings) {
        self.init(earnedSeconds: focusSeconds * rhythm.earnRatio)
    }
}

// MARK: Timer

/// A control a widget button can ask for. The same ones the Focus screen
/// offers at that moment, never more (see `WidgetTimer.actions`).
public enum WidgetAction: String, Codable, Sendable, CaseIterable {
    /// Start the interval on offer (focus or break).
    case start
    case pause
    case resume
    /// End the interval now and move on; when idle with a break on offer, skip that break.
    case skip
    /// End the interval and the round.
    case stop

    /// What the Focus screen shows for this machine (`PomodoroControls`).
    public static func available(for machine: PomodoroMachine) -> [WidgetAction] {
        switch machine.status {
        case .idle: machine.phase.isBreak ? [.start, .skip] : [.start]
        case .running: [.pause, .skip, .stop]
        case .paused: [.resume, .skip, .stop]
        }
    }
}

/// The pomodoro timer, as a widget shows it.
public struct WidgetTimer: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case idle, running, paused
        /// Drawn ahead of time only: the interval's time is up and the app
        /// has not said yet what comes next.
        case ended
    }

    /// True for WatchDog's own timer, the only one the widget can control.
    public var isBuiltIn: Bool
    /// "WatchDog" or the external app's name ("Session").
    public var sourceName: String
    public var status: Status
    /// Focus or break: the interval running or paused, or (idle, built-in)
    /// the one Start begins. `.none` when an external timer is not running.
    public var interval: TimerState
    /// Built-in timer only.
    public var phase: PomodoroPhase?
    /// Running: when the interval ends, on the system clock (what a widget
    /// counts down to). Nil when the source does not say.
    public var endsAt: Date?
    /// Paused: time left. Idle: the length of the interval on offer.
    public var remainingSeconds: Double?
    /// Length of the interval in progress, or of the one on offer.
    public var plannedSeconds: Double?
    /// Built-in: focus sessions run in full this round, and the round's length.
    public var completedInRound: Int
    public var roundLength: Int
    public var categoryName: String?
    public var categoryColor: CategoryColor?
    /// Names the moment the buttons were drawn for. A command carries it
    /// back, and is refused if the timer has moved on since.
    public var token: String
    /// What the buttons may ask for now. Empty unless the built-in timer is chosen.
    public var actions: [WidgetAction]

    public init(isBuiltIn: Bool, sourceName: String, status: Status, interval: TimerState,
                phase: PomodoroPhase? = nil, endsAt: Date? = nil, remainingSeconds: Double? = nil,
                plannedSeconds: Double? = nil, completedInRound: Int = 0, roundLength: Int = 0,
                categoryName: String? = nil, categoryColor: CategoryColor? = nil,
                token: String, actions: [WidgetAction] = []) {
        self.isBuiltIn = isBuiltIn
        self.sourceName = sourceName
        self.status = status
        self.interval = interval
        self.phase = phase
        self.endsAt = endsAt
        self.remainingSeconds = remainingSeconds
        self.plannedSeconds = plannedSeconds
        self.completedInRound = completedInRound
        self.roundLength = roundLength
        self.categoryName = categoryName
        self.categoryColor = categoryColor
        self.token = token
        self.actions = actions
    }

    public static let builtInName = "WatchDog"

    /// The built-in timer. `moment` is the trusted clock the machine runs
    /// on; `now` is the system clock the widget counts down on.
    public init(machine: PomodoroMachine, settings: BuiltInTimerSettings, category: SessionCategory?,
                moment: TimerMoment, now: Date) {
        let status: Status = switch machine.status {
        case .idle: .idle
        case .running: .running
        case .paused: .paused
        }
        let remaining = machine.isIdle ? settings.seconds(for: machine.phase) : machine.remaining(at: moment)
        let shownCategory = machine.phase == .focus ? category : nil
        self.init(isBuiltIn: true, sourceName: Self.builtInName, status: status,
                  interval: machine.phase.timerState, phase: machine.phase,
                  endsAt: machine.isRunning ? now.addingTimeInterval(remaining) : nil,
                  remainingSeconds: machine.isRunning ? nil : remaining,
                  plannedSeconds: machine.isIdle ? remaining : machine.plannedSeconds,
                  completedInRound: machine.completedInRound, roundLength: settings.roundLength,
                  categoryName: shownCategory?.name, categoryColor: shownCategory?.color,
                  token: Self.token(for: machine), actions: WidgetAction.available(for: machine))
    }

    /// An external timer app, which WatchDog only reads.
    public init(external reading: TimerReading, appName: String) {
        let interval = reading.shownInterval
        let endsAt: Date? = if let start = reading.startedAt, let length = reading.durationSeconds {
            start.addingTimeInterval(TimeInterval(length))
        } else {
            nil
        }
        self.init(isBuiltIn: false, sourceName: appName,
                  status: interval == .none ? .idle : (reading.isPaused ? .paused : .running),
                  interval: interval, endsAt: interval == .none ? nil : endsAt,
                  plannedSeconds: reading.durationSeconds.map(Double.init),
                  categoryName: reading.project ?? reading.title, token: "external")
    }

    /// Shows the same as `other`: equal, except for a countdown end that
    /// moved by under a second (it is worked out afresh at each look).
    public func shows(sameAs other: WidgetTimer) -> Bool {
        var a = self
        if let x = a.endsAt, let y = other.endsAt, abs(x.timeIntervalSince(y)) < 1 { a.endsAt = y }
        return a == other
    }

    /// Changes whenever the timer changes in a way a button cares about:
    /// started, paused, resumed, moved on, stopped.
    public static func token(for machine: PomodoroMachine) -> String {
        let started = machine.phaseStartedAt.map { String(Int(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "-"
        return "\(machine.status.rawValue).\(machine.phase.rawValue).\(started).\(machine.completedInRound)"
    }
}

// MARK: The snapshot

/// Everything the widgets show, written by the app to the App Group container.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// The app writes the snapshot at least this often while it runs.
    public static let refreshInterval: TimeInterval = 60
    /// Older than this, the app is taken to be not running.
    public static let staleAfter: TimeInterval = 180

    public var version: Int
    /// When the app wrote it, on the system clock.
    public var writtenAt: Date
    public var timer: WidgetTimer
    public var today: FocusTally
    /// The six days before today, oldest first.
    public var earlier: [FocusTally]
    public var breaksEarned: WidgetBreaks
    /// The latest commands the app handled, newest last.
    public var receipts: [WidgetCommandReceipt]

    public init(writtenAt: Date, timer: WidgetTimer, today: FocusTally, earlier: [FocusTally] = [],
                breaksEarned: WidgetBreaks, receipts: [WidgetCommandReceipt] = []) {
        version = Self.currentVersion
        self.writtenAt = writtenAt
        self.timer = timer
        self.today = today
        self.earlier = earlier
        self.breaksEarned = breaksEarned
        self.receipts = receipts
    }

    /// Kept in the snapshot so the button that sent a command can see it was handled.
    public static let receiptsKept = 8

    /// Puts a snapshot together from what the app knows.
    /// - `budget`: the first "Pomodoro it" rule's budget and that rule's
    ///   name, if there is such a rule; otherwise breaks earned are shown at
    ///   `rhythm`, the built-in timer's.
    /// - `receipts`: the previous snapshot's, to which `newReceipts` are added.
    public static func make(at now: Date, timer: WidgetTimer, today: FocusTally, earlier: [FocusTally],
                            budget: (status: RuleEngine.PomodoroStatus, ruleName: String)?,
                            rhythm: PomodoroSettings, receipts: [WidgetCommandReceipt],
                            newReceipts: [WidgetCommandReceipt] = []) -> WidgetSnapshot {
        let breaks = budget.map { WidgetBreaks(budget: $0.status, ruleName: $0.ruleName) }
            ?? WidgetBreaks(focusSeconds: today.focusSeconds, rhythm: rhythm)
        return WidgetSnapshot(writtenAt: now, timer: timer, today: today, earlier: earlier,
                              breaksEarned: breaks,
                              receipts: Array((receipts + newReceipts).suffix(receiptsKept)))
    }

    /// The receipt for a command, once the app has handled it.
    public func receipt(for id: UUID) -> WidgetCommandReceipt? {
        receipts.last { $0.id == id }
    }

    /// True if the app has not written for a while: it is not running.
    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(writtenAt) > Self.staleAfter || writtenAt.timeIntervalSince(now) > Self.staleAfter
    }

    /// This snapshot and an earlier one show the same thing (the write time
    /// aside), so the widgets need not be redrawn.
    public func looksLike(_ other: WidgetSnapshot) -> Bool {
        var a = self
        a.writtenAt = other.writtenAt
        a.timer = other.timer
        return a == other && timer.shows(sameAs: other.timer)
    }

    /// The timer as it will look at `date`, for a timeline entry drawn ahead
    /// of time: a running interval whose end has passed shows as done (the
    /// app redraws the widgets as soon as it moves on).
    public func timer(at date: Date) -> WidgetTimer {
        var shown = timer
        if shown.status == .running, let end = shown.endsAt, date >= end {
            shown.endsAt = nil
            shown.remainingSeconds = 0
            shown.status = .ended
            shown.actions = []
        }
        return shown
    }

    /// When a widget should next ask for a fresh snapshot: soon after the
    /// running interval ends, and every 15 minutes for the day's totals.
    public func nextRefresh(after now: Date) -> Date {
        let regular = now.addingTimeInterval(15 * 60)
        guard timer.status == .running, let end = timer.endsAt, end > now else { return regular }
        return min(regular, end.addingTimeInterval(2))
    }
}
