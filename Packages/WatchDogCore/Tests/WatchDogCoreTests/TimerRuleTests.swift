import Foundation
import Testing
@testable import WatchDogCore

struct TimerRuleTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func youtube(_ start: TimeInterval, _ seconds: TimeInterval, _ timer: TimerState) -> Span {
        Span(id: nil, startedAt: t0.addingTimeInterval(start), endedAt: t0.addingTimeInterval(start + seconds),
             bundleID: "com.brave.Browser", appName: "Brave Browser", windowTitle: nil,
             url: "https://www.youtube.com/", domain: "youtube.com", isIdle: false, timerState: timer)
    }

    // MARK: Reading Session

    @Test func parsesSessionFocusBreakAndIdle() {
        let focus = #"{"duration_second":1500,"timer_variant":"timer","state":"session","title":"—","project":{"title":"Trabalho"},"pause_buffer":0,"start_date":"2026-11-18T00:06:34Z"}"#
        let reading = SessionTimer.parse(runningSession: Data(focus.utf8))
        #expect(reading.state == .focus)
        #expect(reading.project == "Trabalho")
        #expect(reading.title == nil)                 // "—" is Session's placeholder for no title
        #expect(reading.durationSeconds == 1500)
        #expect(reading.startedAt == ISO8601DateFormatter().date(from: "2026-11-18T00:06:34Z"))

        // Captured from a real break on 2026-11-17.
        let rest = #"{"pause_date":"2026-11-18T00:05:38Z","duration_second":300,"project":{"title":"Trabalho"},"state":"rest","start_date":"2026-11-18T00:10:56Z","timer_variant":"timer","title":"test","pause_buffer":0}"#
        let onBreak = SessionTimer.parse(runningSession: Data(rest.utf8))
        #expect(onBreak.state == .onBreak)
        #expect(onBreak.title == "test")
        #expect(onBreak.durationSeconds == 300)
        #expect(SessionTimer.parse(runningSession: Data("null".utf8)) == .none)
        #expect(SessionTimer.parse(runningSession: nil) == .none)
        #expect(SessionTimer.parse(runningSession: Data(#"{"state":"something-new"}"#.utf8)) == .none)
        #expect(SessionTimer.parse(runningSession: Data("not json".utf8)) == .none)
    }

    // MARK: The "only on my breaks" rule

    /// Weekdays 09:00-19:00, not at all, except during a break.
    var workHours: Rule {
        Rule(name: "YouTube in work hours, outside breaks", domains: ["youtube.com"],
             schedule: Schedule(isAlways: false, weekdays: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 19 * 60),
             timerCondition: .exceptDuringBreak, mode: .continuous, limitSeconds: 0, action: .close)
    }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// November 2026: the 17th is a Tuesday, the 21st a Saturday.
    func at(day: Int, hour: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    func verdicts(timer: TimerState, day: Int, hour: Int) -> [Verdict] {
        let now = at(day: day, hour: hour)
        let span = Span(id: nil, startedAt: now.addingTimeInterval(-4), endedAt: now,
                        bundleID: "com.brave.Browser", appName: "Brave Browser", windowTitle: nil,
                        url: "https://www.youtube.com/", domain: "youtube.com", isIdle: false, timerState: timer)
        return RuleEngine.evaluate(rules: [workHours], spans: [span], now: now, calendar: utc)
    }

    @Test func inWorkHoursYouTubeFiresImmediatelyUnlessOnABreak() {
        #expect(verdicts(timer: .focus, day: 17, hour: 10).count == 1)
        #expect(verdicts(timer: .none, day: 17, hour: 10).count == 1)   // no timer running is not a break
        #expect(verdicts(timer: .onBreak, day: 17, hour: 10).isEmpty)
    }

    @Test func outsideWorkHoursAndOnWeekendsYouTubeIsFree() {
        #expect(verdicts(timer: .none, day: 17, hour: 19).isEmpty)      // 19:00 sharp is already free
        #expect(verdicts(timer: .none, day: 17, hour: 8).isEmpty)
        #expect(verdicts(timer: .focus, day: 17, hour: 23).isEmpty)
        #expect(verdicts(timer: .none, day: 21, hour: 12).isEmpty)      // Saturday
        #expect(verdicts(timer: .none, day: 17, hour: 18).count == 1)   // 18:00 still restricted
    }

    @Test func aZeroLimitDoesNotFireWhenTheUserIsElsewhere() {
        let now = at(day: 17, hour: 10)
        let work = Span(id: nil, startedAt: now.addingTimeInterval(-60), endedAt: now,
                        bundleID: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: nil,
                        url: nil, domain: nil, isIdle: false, timerState: .focus)
        #expect(RuleEngine.evaluate(rules: [workHours], spans: [work], now: now, calendar: utc).isEmpty)
        #expect(RuleEngine.evaluate(rules: [workHours], spans: [], now: now, calendar: utc).isEmpty)
    }

    @Test func timeOnABreakDoesNotCountTowardALimit() {
        // "At most 2 minutes of YouTube outside breaks": 90 s focus, 300 s break, 60 s focus.
        let rule = Rule(name: "x", domains: ["youtube.com"], timerCondition: .exceptDuringBreak,
                        mode: .cumulative, limitSeconds: 120, windowSeconds: 3600)
        let spans = [youtube(0, 90, .focus), youtube(90, 300, .onBreak), youtube(390, 60, .focus)]
        let now = t0.addingTimeInterval(450)
        #expect(RuleEngine.matchedSeconds(rule, spans: spans, now: now) == 150)
    }

    @Test func timerConditionsAllowTheRightStates() {
        #expect(Rule.TimerCondition.duringFocus.allows(.focus))
        #expect(!Rule.TimerCondition.duringFocus.allows(.none))
        #expect(Rule.TimerCondition.duringBreak.allows(.onBreak))
        #expect(!Rule.TimerCondition.duringBreak.allows(.focus))
        #expect(Rule.TimerCondition.exceptDuringBreak.allows(.none))
    }

    // MARK: Storage

    @Test func aTimerChangeStartsANewSpanAndIsStored() throws {
        let store = try UsageStore()
        func sample(_ offset: TimeInterval, _ timer: TimerState) -> Sample {
            Sample(time: t0.addingTimeInterval(offset), bundleID: "b", appName: "B", timerState: timer)
        }
        try store.record(sample(0, .focus))
        try store.record(sample(2, .focus))
        try store.record(sample(4, .onBreak))
        try store.record(sample(6, .onBreak))
        let spans = try store.spans(since: t0)
        #expect(spans.map(\.timerState) == [.focus, .onBreak])
        #expect(spans.map(\.seconds) == [4, 2])
    }

    @Test func ruleFilesWithoutATimerConditionStillLoad() throws {
        let old = #"[{"id":"a","name":"Old","isEnabled":true,"apps":[],"domains":["x.com"],"titleKeywords":[],"schedule":{"isAlways":true,"weekdays":[2],"startMinute":0,"endMinute":60},"mode":"continuous","limitSeconds":300,"windowSeconds":3600,"action":"warn","blockMinutes":30,"cooldownSeconds":300}]"#
        let path = NSTemporaryDirectory() + "wd-old-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(old.utf8).write(to: URL(fileURLWithPath: path))
        let rules = try RuleFile.load(path: path)
        #expect(rules.first?.timerCondition == nil)
        #expect(rules.first?.domains == ["x.com"])
    }
}
