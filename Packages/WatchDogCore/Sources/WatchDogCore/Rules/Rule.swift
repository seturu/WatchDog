import Foundation

/// One rule: "this activity, at these times, for longer than this, gets that response".
public struct Rule: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var isEnabled: Bool

    // What counts as the activity. A span matches if ANY of these match.
    /// App bundle IDs, e.g. "com.spotify.client".
    public var apps: [String]
    /// Sites, e.g. "youtube.com". Subdomains are included (m.youtube.com).
    public var domains: [String]
    /// Words to look for in the window title, case-insensitive.
    public var titleKeywords: [String]

    public var schedule: Schedule
    /// Restricts the rule by pomodoro timer state. Nil means "any time".
    /// (Optional so rule files written before this existed still load.)
    public var timerCondition: TimerCondition?

    public var mode: Mode
    /// How much matching time is allowed before the rule fires.
    /// Zero means "not at all": the rule fires the moment the activity is seen.
    public var limitSeconds: Int
    /// For `.cumulative`: the look-back period the limit applies to.
    public var windowSeconds: Int

    /// For `.pomodoro`. Nil means the classic 25 / 5 / 15 / every 4.
    public var pomodoro: PomodoroSettings?

    public var action: Action
    /// For `.block`: how long the block should last.
    public var blockMinutes: Int
    /// After firing, the rule stays quiet for this long.
    public var cooldownSeconds: Int

    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// In one sitting: uninterrupted matching time (short breaks are forgiven).
        case continuous
        /// In total: matching time added up over the look-back period.
        case cumulative
        /// "Pomodoro it": allowed only during breaks, and only for as much time
        /// as focus work has earned. See `PomodoroSettings`.
        case pomodoro
    }

    public enum Action: String, Codable, Sendable, CaseIterable {
        case warn, close, block
    }

    public enum TimerCondition: String, Codable, Sendable, CaseIterable {
        /// Applies always, EXCEPT while a break is running. "Only on my breaks."
        case exceptDuringBreak
        /// Applies only while a focus interval is running.
        case duringFocus
        /// Applies only while a break is running.
        case duringBreak

        public func allows(_ state: TimerState) -> Bool {
            switch self {
            case .exceptDuringBreak: state != .onBreak
            case .duringFocus: state == .focus
            case .duringBreak: state == .onBreak
            }
        }
    }

    public init(id: String = UUID().uuidString, name: String, isEnabled: Bool = true,
                apps: [String] = [], domains: [String] = [], titleKeywords: [String] = [],
                schedule: Schedule = .always, timerCondition: TimerCondition? = nil,
                mode: Mode = .continuous,
                limitSeconds: Int = 300, windowSeconds: Int = 3600,
                pomodoro: PomodoroSettings? = nil,
                action: Action = .warn, blockMinutes: Int = 30, cooldownSeconds: Int = 300) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.apps = apps
        self.domains = domains
        self.titleKeywords = titleKeywords
        self.schedule = schedule
        self.timerCondition = timerCondition
        self.mode = mode
        self.limitSeconds = limitSeconds
        self.windowSeconds = windowSeconds
        self.pomodoro = pomodoro
        self.action = action
        self.blockMinutes = blockMinutes
        self.cooldownSeconds = cooldownSeconds
    }

    /// The rule shipped on first run: on weekdays from 09:00 to 19:00 YouTube
    /// is only for pomodoro breaks, and only as much as focus time has earned.
    /// Outside those hours no rule applies, so it is free.
    public static let starter = Rule(
        name: "YouTube: breaks only in work hours",
        domains: ["youtube.com"],
        schedule: Schedule(isAlways: false, weekdays: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 19 * 60),
        mode: .pomodoro, limitSeconds: 0, pomodoro: .classic, action: .close, cooldownSeconds: 60)
}

/// The pomodoro rhythm a `.pomodoro` rule holds you to.
///
/// Break time is EARNED by focus time at the rhythm's own ratio. With the
/// classic numbers a cycle is 4 x 25 min of focus and 5 + 5 + 5 + 15 min of
/// breaks, so each minute of focus earns 0.3 minutes of break. Staying on a
/// break forever earns nothing, and one break can never exceed the long break.
public struct PomodoroSettings: Codable, Sendable, Equatable {
    public var focusMinutes: Int
    public var shortBreakMinutes: Int
    public var longBreakMinutes: Int
    /// The long break replaces the short one after this many focus intervals.
    public var longBreakEvery: Int

    public init(focusMinutes: Int = 25, shortBreakMinutes: Int = 5, longBreakMinutes: Int = 15, longBreakEvery: Int = 4) {
        self.focusMinutes = focusMinutes
        self.shortBreakMinutes = shortBreakMinutes
        self.longBreakMinutes = longBreakMinutes
        self.longBreakEvery = longBreakEvery
    }

    public static let classic = PomodoroSettings()

    /// Break seconds earned per second of focus.
    public var earnRatio: Double {
        let every = max(longBreakEvery, 1)
        let breaks = Double((every - 1) * shortBreakMinutes + longBreakMinutes)
        return breaks / Double(every * max(focusMinutes, 1))
    }

    /// Longest stretch on the activity within one break.
    public var maxSittingSeconds: TimeInterval { TimeInterval(longBreakMinutes * 60) }
}

/// When a rule applies.
public struct Schedule: Codable, Sendable, Equatable {
    public var isAlways: Bool
    /// Calendar weekday numbers: 1 = Sunday ... 7 = Saturday.
    public var weekdays: Set<Int>
    /// Minutes after midnight, local time. If end <= start the period runs past midnight.
    public var startMinute: Int
    public var endMinute: Int

    public init(isAlways: Bool, weekdays: Set<Int> = [2, 3, 4, 5, 6], startMinute: Int = 9 * 60, endMinute: Int = 17 * 60) {
        self.isAlways = isAlways
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public static let always = Schedule(isAlways: true)

    /// When the period containing `date` began: today at the start time (or
    /// yesterday's, for a period that runs past midnight). Midnight for "always".
    /// Budgets are counted from here, so they reset every day.
    public func periodStart(containing date: Date, calendar: Calendar = .current) -> Date {
        let midnight = calendar.startOfDay(for: date)
        if isAlways { return midnight }
        let start = midnight.addingTimeInterval(TimeInterval(startMinute * 60))
        // A same-day period that has not begun yet has nothing to count;
        // returning its (future) start keeps yesterday's totals out.
        if startMinute < endMinute { return start }
        // A period that runs past midnight may have begun yesterday evening.
        return start <= date ? start : start.addingTimeInterval(-86_400)
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        if isAlways { return true }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday else { return false }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute < endMinute {
            return weekdays.contains(weekday) && (startMinute..<endMinute).contains(minute)
        }
        // The period runs past midnight. The evening part belongs to today;
        // the small hours belong to the day it started on, i.e. yesterday.
        // (Friday 22:00-02:00 covers Saturday 01:00, not Friday 01:00.)
        if minute >= startMinute { return weekdays.contains(weekday) }
        if minute < endMinute { return weekdays.contains(weekday == 1 ? 7 : weekday - 1) }
        return false
    }
}

/// The engine's decision that a rule's limit has been reached.
public struct Verdict: Sendable, Equatable {
    public var ruleID: String
    public var ruleName: String
    public var action: Rule.Action
    public var blockMinutes: Int
    public var at: Date
    /// How much matching time triggered it.
    public var matchedSeconds: TimeInterval
    /// What the user was on: a site or an app name.
    public var subject: String
    /// Why, when the rule has more than one way to fire. Not stored.
    public var reason: String? = nil
}
