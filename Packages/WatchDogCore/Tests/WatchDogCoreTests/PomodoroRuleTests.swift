import Foundation
import Testing
@testable import WatchDogCore

/// "Pomodoro it": YouTube only on breaks, and only as much as focus has earned.
struct PomodoroRuleTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Tuesday 17 November 2026, 09:00 UTC: the start of the rule's period.
    var nine: Date { utc.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9))! }

    let rule = Rule.starter   // weekdays 09:00-19:00, classic 25 / 5 / 15 / every 4

    enum Kind { case work, youtube, away }

    /// Lays (minutes, kind, timer) pieces end to end starting at `start`.
    func day(from start: Date? = nil, _ parts: [(Double, Kind, TimerState)]) -> (spans: [Span], now: Date) {
        var clock = start ?? nine
        var spans: [Span] = []
        for (minutes, kind, timer) in parts {
            let end = clock.addingTimeInterval(minutes * 60)
            spans.append(Span(
                id: nil, startedAt: clock, endedAt: end,
                bundleID: kind == .youtube ? "com.brave.Browser" : "com.apple.dt.Xcode",
                appName: kind == .youtube ? "Brave Browser" : "Xcode", windowTitle: nil,
                url: kind == .youtube ? "https://www.youtube.com/" : nil,
                domain: kind == .youtube ? "youtube.com" : nil,
                isIdle: kind == .away, timerState: timer))
            clock = end
        }
        return (spans, clock)
    }

    func status(_ d: (spans: [Span], now: Date)) -> RuleEngine.PomodoroStatus {
        RuleEngine.pomodoroStatus(rule, spans: d.spans, now: d.now, calendar: utc)
    }

    func fires(_ d: (spans: [Span], now: Date)) -> String? {
        RuleEngine.evaluate(rules: [rule], spans: d.spans, now: d.now, calendar: utc).first?.reason
    }

    // MARK: The ratio

    @Test func classicRhythmEarnsThreeTenthsAndCapsABreakAtFifteenMinutes() {
        #expect(abs(PomodoroSettings.classic.earnRatio - 0.3) < 1e-9)       // (5+5+5+15) / (4x25)
        #expect(PomodoroSettings.classic.maxSittingSeconds == 900)
        let custom = PomodoroSettings(focusMinutes: 50, shortBreakMinutes: 10, longBreakMinutes: 30, longBreakEvery: 2)
        #expect(abs(custom.earnRatio - 0.4) < 1e-9)                         // (10+30) / (2x50)
    }

    // MARK: Earning and spending

    @Test func aBreakAfterFocusWorkAllowsYouTube() {
        let d = day([(25, .work, .focus), (3, .youtube, .onBreak)])
        let s = status(d)
        #expect(abs(s.earned - 450) < 0.001)     // 25 min x 0.3 = 7.5 min
        #expect(s.used == 180)
        #expect(s.denial == nil)
        #expect(fires(d) == nil)
    }

    @Test func theBudgetRunsOut() {
        let d = day([(25, .work, .focus), (7.5, .youtube, .onBreak)])
        #expect(status(d).denial == .budgetSpent)
        #expect(fires(d) == "break budget used up")
    }

    @Test func anEndlessBreakEarnsNothing() {
        // No focus work at all today, straight to a "break".
        let d = day([(30, .work, .none), (1, .youtube, .onBreak)])
        #expect(status(d).earned == 0)
        #expect(fires(d) == "break budget used up")
    }

    @Test func outsideABreakItIsNeverAllowedHoweverMuchIsBanked() {
        let focus = day([(100, .work, .focus), (1, .youtube, .focus)])
        #expect(fires(focus) == "not on a break")
        let noTimer = day([(100, .work, .focus), (1, .youtube, .none)])
        #expect(fires(noTimer) == "not on a break")
    }

    @Test func oneBreakCannotRunPastALongBreakEvenWithBudgetLeft() {
        // 100 min of focus banks 30 min, but a single break is capped at 15.
        let ok = day([(100, .work, .focus), (14, .youtube, .onBreak)])
        #expect(fires(ok) == nil)
        let tooLong = day([(100, .work, .focus), (15, .youtube, .onBreak)])
        #expect(status(tooLong).remaining == 900)
        #expect(fires(tooLong) == "this break has run past a long break")
    }

    @Test func aNewBreakAfterMoreFocusStartsAFreshSitting() {
        let d = day([(100, .work, .focus), (14, .youtube, .onBreak),
                     (25, .work, .focus), (5, .youtube, .onBreak)])
        let s = status(d)
        #expect(s.sitting == 300)                 // only the current break
        #expect(s.used == 19 * 60)
        #expect(abs(s.earned - 125 * 60 * 0.3) < 0.001)
        #expect(s.denial == nil)
    }

    @Test func otherThingsDoneOnABreakDoNotSpendTheBudget() {
        let d = day([(25, .work, .focus), (5, .work, .onBreak), (1, .youtube, .onBreak)])
        #expect(status(d).used == 60)
    }

    // MARK: What does not earn

    @Test func timeAwayFromTheKeyboardDuringFocusEarnsNothing() {
        let d = day([(25, .away, .focus), (1, .youtube, .onBreak)])
        #expect(status(d).earned == 0)
        #expect(fires(d) == "break budget used up")
    }

    @Test func watchingDuringFocusEarnsNothing() {
        let d = day([(25, .youtube, .focus), (1, .youtube, .onBreak)])
        #expect(status(d).earned == 0)
    }

    // MARK: The period

    @Test func focusBeforeThePeriodStartsDoesNotCount() {
        // 08:00-09:00 focus is outside the 09:00-19:00 period; only 09:00-09:10 counts.
        let d = day(from: nine.addingTimeInterval(-3600), [(70, .work, .focus), (1, .youtube, .onBreak)])
        #expect(abs(status(d).earned - 10 * 60 * 0.3) < 0.001)
    }

    @Test func outsideTheScheduleNothingFires() {
        let evening = utc.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 20))!
        let d = day(from: evening, [(5, .youtube, .none)])
        #expect(fires(d) == nil)
        let saturday = utc.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 11))!
        #expect(fires(day(from: saturday, [(5, .youtube, .none)])) == nil)
    }

    @Test func periodStartHandlesAlwaysAndOvernightSchedules() {
        let noon = utc.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12))!
        let midnight = utc.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        #expect(Schedule.always.periodStart(containing: noon, calendar: utc) == midnight)
        #expect(rule.schedule.periodStart(containing: noon, calendar: utc) == nine)

        let night = Schedule(isAlways: false, weekdays: [2, 3], startMinute: 22 * 60, endMinute: 2 * 60)
        let oneAM = utc.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 1))!
        let previous22 = utc.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 22))!
        #expect(night.periodStart(containing: oneAM, calendar: utc) == previous22)
    }

    @Test func yesterdaysBudgetIsNotShownBeforeTodaysPeriodBegins() {
        // Yesterday: an hour of focus and some watching. Now it is 00:05.
        let yesterday = day(from: nine.addingTimeInterval(-86_400), [(60, .work, .focus), (5, .youtube, .onBreak)])
        let justAfterMidnight = utc.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 0, minute: 5))!
        let s = RuleEngine.pomodoroStatus(rule, spans: yesterday.spans, now: justAfterMidnight, calendar: utc)
        #expect(s.earned == 0 && s.used == 0)
    }

    @Test func settingsSurviveSaveAndLoad() throws {
        var custom = rule
        custom.pomodoro = PomodoroSettings(focusMinutes: 50, shortBreakMinutes: 10, longBreakMinutes: 20, longBreakEvery: 3)
        let path = NSTemporaryDirectory() + "wd-pomo-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try RuleFile.save([custom], path: path)
        #expect(try RuleFile.load(path: path) == [custom])
    }

    @Test func aSpanThatRunsBackwardsNeverGivesBudgetBack() {
        // Written by an older version after a clock change: ends an hour before it starts.
        var d = day([(25, .work, .focus), (7.5, .youtube, .onBreak)])
        var backwards = d.spans[1]
        backwards.startedAt = d.now
        backwards.endedAt = d.now.addingTimeInterval(-3600)
        d.spans.insert(backwards, at: 1)
        #expect(status(d).used == 450)
        #expect(fires(d) == "break budget used up")
    }
}
