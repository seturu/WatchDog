import Foundation

/// Decides which rules have reached their limit. Pure logic: it is given the
/// recent history and the time, touches nothing, and is fully unit-tested.
public enum RuleEngine {

    /// In `.continuous` mode, stepping away from the activity for up to this
    /// long does not reset the count (glancing at a chat, switching a tab).
    public static let breakTolerance: TimeInterval = 20

    /// Does this span count toward the rule? Idle time never does.
    public static func matches(_ rule: Rule, _ span: Span) -> Bool {
        // A pomodoro rule does its own timer bookkeeping (see `pomodoroStatus`).
        if rule.mode != .pomodoro, let condition = rule.timerCondition,
           !condition.allows(span.timerState) { return false }
        return matchesActivity(rule, span)
    }

    /// Is `domain` one of the rule's sites (subdomains included)?
    public static func matchesDomain(_ rule: Rule, _ domain: String) -> Bool {
        rule.domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// Is this span the rule's app / site / title, whatever the timer says?
    public static func matchesActivity(_ rule: Rule, _ span: Span) -> Bool {
        if span.isIdle { return false }
        if rule.apps.contains(span.bundleID) { return true }
        if let domain = span.domain,
           rule.domains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
            return true
        }
        if let title = span.windowTitle?.lowercased(),
           rule.titleKeywords.contains(where: { !$0.isEmpty && title.contains($0.lowercased()) }) {
            return true
        }
        return false
    }

    /// Time that counts toward the rule's limit right now.
    /// Zero unless the user is on the activity at this moment: there is no
    /// point reacting to something that is no longer on screen.
    /// `spans` must be in chronological order.
    public static func matchedSeconds(_ rule: Rule, spans: [Span], now: Date) -> TimeInterval {
        guard isOnActivity(rule, spans: spans, now: now), let current = spans.last else { return 0 }

        switch rule.mode {
        case .pomodoro:
            return pomodoroStatus(rule, spans: spans, now: now).used

        case .continuous:
            var total: TimeInterval = 0
            var interruption: TimeInterval = 0     // length of the break being walked through
            var newerStart = current.endedAt
            for span in spans.reversed() {
                // A hole in the history (sleep, app not running) ends the sitting.
                if newerStart.timeIntervalSince(span.endedAt) > UsageStore.maxGap { break }
                // Spans written by older versions can run backwards after a
                // clock change; they count as nothing, never as negative time.
                let seconds = max(0, span.seconds)
                if matches(rule, span) {
                    total += seconds
                    interruption = 0
                } else {
                    // A break made of many short spans (flicking between tabs)
                    // is still one break: judge it by its total length.
                    interruption += seconds
                    if interruption > breakTolerance { break }
                }
                newerStart = span.startedAt
            }
            return total

        case .cumulative:
            let windowStart = now.addingTimeInterval(-TimeInterval(rule.windowSeconds))
            return spans.reduce(0) { total, span in
                guard matches(rule, span) else { return total }
                let start = max(span.startedAt, windowStart)
                return total + max(0, span.endedAt.timeIntervalSince(start))
            }
        }
    }

    /// Is the user on this rule's activity at this moment?
    public static func isOnActivity(_ rule: Rule, spans: [Span], now: Date) -> Bool {
        guard let current = spans.last else { return false }
        return now.timeIntervalSince(current.endedAt) <= UsageStore.maxGap && matches(rule, current)
    }

    /// Rules that fire now. `lastFired` is when each rule last fired, by rule ID.
    public static func evaluate(rules: [Rule], spans: [Span], now: Date,
                                lastFired: [String: Date] = [:],
                                calendar: Calendar = .current) -> [Verdict] {
        guard let current = spans.last else { return [] }
        return rules.compactMap { rule in
            guard rule.isEnabled, rule.schedule.contains(now, calendar: calendar) else { return nil }
            if let fired = lastFired[rule.id],
               now.timeIntervalSince(fired) < TimeInterval(rule.cooldownSeconds) { return nil }

            // Checked separately because a limit of zero is met by zero seconds.
            guard isOnActivity(rule, spans: spans, now: now) else { return nil }

            if rule.mode == .pomodoro {
                let status = pomodoroStatus(rule, spans: spans, now: now, calendar: calendar)
                guard let reason = status.denial else { return nil }
                return Verdict(ruleID: rule.id, ruleName: rule.name, action: rule.action,
                               blockMinutes: rule.blockMinutes, at: now, matchedSeconds: status.used,
                               subject: current.domain ?? current.appName, reason: reason.rawValue)
            }
            let seconds = matchedSeconds(rule, spans: spans, now: now)
            guard seconds >= TimeInterval(rule.limitSeconds) else { return nil }
            return Verdict(ruleID: rule.id, ruleName: rule.name, action: rule.action,
                           blockMinutes: rule.blockMinutes, at: now, matchedSeconds: seconds,
                           subject: current.domain ?? current.appName)
        }
    }

    /// How far back history is needed to evaluate these rules.
    public static func lookback(for rules: [Rule]) -> TimeInterval {
        let longest = rules.map { rule -> TimeInterval in
            switch rule.mode {
            case .pomodoro: 86_400      // budgets count from the start of the day's period
            case .cumulative: TimeInterval(rule.windowSeconds)
            case .continuous: TimeInterval(rule.limitSeconds * 3)
            }
        }.max() ?? 0
        return max(longest, 600)
    }

    // MARK: Pomodoro budget

    public struct PomodoroStatus: Sendable, Equatable {
        /// Break seconds earned by focus work since the period began.
        public var earned: TimeInterval
        /// Seconds already spent on the activity during breaks.
        public var used: TimeInterval
        /// Seconds on the activity within the break that is running now.
        public var sitting: TimeInterval
        public var onBreak: Bool
        /// Why the activity is not allowed right now; nil when it is allowed.
        public var denial: Denial?

        public enum Denial: String, Sendable {
            case notOnBreak = "not on a break"
            case budgetSpent = "break budget used up"
            case breakTooLong = "this break has run past a long break"
        }

        public var remaining: TimeInterval { max(0, earned - used) }
    }

    /// The break budget of a `.pomodoro` rule right now.
    ///
    /// Earned: time in a focus interval, at the keyboard, NOT on the activity
    /// itself, times the rhythm's break ratio. Used: time on the activity
    /// during breaks. Both are counted from the start of today's period.
    /// `spans` must be in chronological order.
    public static func pomodoroStatus(_ rule: Rule, spans: [Span], now: Date,
                                      calendar: Calendar = .current) -> PomodoroStatus {
        let settings = rule.pomodoro ?? .classic
        let periodStart = rule.schedule.periodStart(containing: now, calendar: calendar)

        var focus: TimeInterval = 0
        var used: TimeInterval = 0
        for span in spans where span.endedAt > periodStart && !span.isIdle {
            let seconds = max(0, span.endedAt.timeIntervalSince(max(span.startedAt, periodStart)))
            let activity = matchesActivity(rule, span)
            if span.timerState == .focus && !activity { focus += seconds }
            if span.timerState == .onBreak && activity { used += seconds }
        }

        // The break running now: walk back while the timer stayed on "break".
        var sitting: TimeInterval = 0
        var newerStart = spans.last?.endedAt ?? now
        for span in spans.reversed() {
            guard span.timerState == .onBreak,
                  newerStart.timeIntervalSince(span.endedAt) <= UsageStore.maxGap else { break }
            if matchesActivity(rule, span) { sitting += max(0, span.seconds) }
            newerStart = span.startedAt
        }

        let earned = focus * settings.earnRatio
        let onBreak = spans.last?.timerState == .onBreak
        let denial: PomodoroStatus.Denial? =
            !onBreak ? .notOnBreak
            : used >= earned ? .budgetSpent
            : sitting >= settings.maxSittingSeconds ? .breakTooLong
            : nil
        return PomodoroStatus(earned: earned, used: used, sitting: sitting, onBreak: onBreak, denial: denial)
    }
}

/// Rules on disk as JSON.
///
/// Milestone 2 keeps them in a user-owned file so the dry run can be tuned
/// freely. In milestone 3 they move to the root daemon, because a file you can
/// edit is a block you can lift.
public enum RuleFile {
    /// rules.json in the app's private container (see `UserData`).
    public static func defaultPath() -> String {
        UserData.folder.appendingPathComponent("rules.json").path
    }

    /// A missing file yields the starter rule.
    public static func load(path: String) throws -> [Rule] {
        guard FileManager.default.fileExists(atPath: path) else { return [.starter] }
        return try JSONDecoder().decode([Rule].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public static func save(_ rules: [Rule], path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rules).write(to: url, options: .atomic)
    }
}
