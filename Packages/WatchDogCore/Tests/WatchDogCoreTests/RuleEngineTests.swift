import Foundation
import Testing
@testable import WatchDogCore

struct RuleEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Builds a chronological history from (seconds, kind) pairs laid end to end.
    enum Kind { case youtube, work, idle, hole }
    func history(_ parts: [(TimeInterval, Kind)]) -> (spans: [Span], now: Date) {
        var spans: [Span] = []
        var clock = t0
        for (seconds, kind) in parts {
            let end = clock.addingTimeInterval(seconds)
            switch kind {
            case .hole: break   // nothing recorded: Mac asleep or app not running
            case .youtube:
                spans.append(Span(id: nil, startedAt: clock, endedAt: end, bundleID: "com.brave.Browser",
                                  appName: "Brave Browser", windowTitle: "Cats - YouTube",
                                  url: "https://www.youtube.com/watch", domain: "youtube.com", isIdle: false))
            case .work:
                spans.append(Span(id: nil, startedAt: clock, endedAt: end, bundleID: "com.apple.dt.Xcode",
                                  appName: "Xcode", windowTitle: "main.swift", url: nil, domain: nil, isIdle: false))
            case .idle:
                spans.append(Span(id: nil, startedAt: clock, endedAt: end, bundleID: "com.brave.Browser",
                                  appName: "Brave Browser", windowTitle: nil, url: nil, domain: nil, isIdle: true))
            }
            clock = end
        }
        return (spans, clock)
    }

    let youtube5min = Rule(id: "yt", name: "YouTube 5 min", domains: ["youtube.com"],
                           mode: .continuous, limitSeconds: 300)

    // MARK: Matching

    @Test func matchesByDomainIncludingSubdomainsButNotLookalikes() {
        func span(_ domain: String?) -> Span {
            Span(id: nil, startedAt: t0, endedAt: t0, bundleID: "b", appName: "B",
                 windowTitle: nil, url: nil, domain: domain, isIdle: false)
        }
        #expect(RuleEngine.matches(youtube5min, span("youtube.com")))
        #expect(RuleEngine.matches(youtube5min, span("m.youtube.com")))
        #expect(!RuleEngine.matches(youtube5min, span("notyoutube.com")))
        #expect(!RuleEngine.matches(youtube5min, span(nil)))
    }

    @Test func matchesByAppAndByTitleKeywordAndNeverWhenIdle() {
        let (spans, _) = history([(10, .work), (10, .idle)])
        #expect(RuleEngine.matches(Rule(name: "x", apps: ["com.apple.dt.Xcode"]), spans[0]))
        #expect(RuleEngine.matches(Rule(name: "x", titleKeywords: ["MAIN.swift"]), spans[0]))
        #expect(!RuleEngine.matches(Rule(name: "x", titleKeywords: [""]), spans[0]))
        #expect(!RuleEngine.matches(Rule(name: "x", apps: ["com.brave.Browser"]), spans[1]))
    }

    // MARK: Continuous

    @Test func firesOnlyOnceTheLimitIsReached() {
        let short = history([(60, .work), (299, .youtube)])
        #expect(RuleEngine.evaluate(rules: [youtube5min], spans: short.spans, now: short.now).isEmpty)

        let long = history([(60, .work), (300, .youtube)])
        let verdicts = RuleEngine.evaluate(rules: [youtube5min], spans: long.spans, now: long.now)
        #expect(verdicts.count == 1)
        #expect(verdicts.first?.subject == "youtube.com")
        #expect(verdicts.first?.matchedSeconds == 300)
    }

    @Test func aShortBreakIsForgivenButNotCounted() {
        let h = history([(200, .youtube), (15, .work), (100, .youtube)])
        #expect(RuleEngine.matchedSeconds(youtube5min, spans: h.spans, now: h.now) == 300)
    }

    @Test func aBreakMadeOfManyShortSpansStillResetsTheSitting() {
        // Two minutes away, but as twelve 10-second flicks between things.
        let flicks = Array(repeating: (10.0, Kind.work), count: 12)
        let h = history([(250, .youtube)] + flicks + [(100, .youtube)])
        #expect(RuleEngine.matchedSeconds(youtube5min, spans: h.spans, now: h.now) == 100)
        // Two short flicks (15 s in total) are still forgiven.
        let brief = history([(200, .youtube), (8, .work), (7, .work), (100, .youtube)])
        #expect(RuleEngine.matchedSeconds(youtube5min, spans: brief.spans, now: brief.now) == 300)
    }

    @Test func aRealBreakResetsTheSitting() {
        let h = history([(250, .youtube), (120, .work), (100, .youtube)])
        #expect(RuleEngine.matchedSeconds(youtube5min, spans: h.spans, now: h.now) == 100)
    }

    @Test func goingIdleResetsTheSitting() {
        let h = history([(250, .youtube), (180, .idle), (100, .youtube)])
        #expect(RuleEngine.matchedSeconds(youtube5min, spans: h.spans, now: h.now) == 100)
    }

    @Test func aHoleInTheHistoryResetsTheSitting() {
        let h = history([(250, .youtube), (3600, .hole), (100, .youtube)])
        #expect(RuleEngine.matchedSeconds(youtube5min, spans: h.spans, now: h.now) == 100)
    }

    @Test func nothingCountsOnceTheUserHasLeft() {
        let h = history([(600, .youtube), (30, .work)])
        #expect(RuleEngine.matchedSeconds(youtube5min, spans: h.spans, now: h.now) == 0)
        // ...or when the history is stale (tracker stopped a while ago).
        let stale = history([(600, .youtube)])
        #expect(RuleEngine.matchedSeconds(youtube5min, spans: stale.spans, now: stale.now.addingTimeInterval(60)) == 0)
    }

    // MARK: Cumulative

    @Test func cumulativeAddsUpAcrossBreaksWithinTheWindow() {
        let rule = Rule(id: "c", name: "10 min per hour", domains: ["youtube.com"],
                        mode: .cumulative, limitSeconds: 600, windowSeconds: 3600)
        let h = history([(300, .youtube), (900, .work), (200, .youtube), (900, .work), (100, .youtube)])
        #expect(RuleEngine.matchedSeconds(rule, spans: h.spans, now: h.now) == 600)
        #expect(RuleEngine.evaluate(rules: [rule], spans: h.spans, now: h.now).count == 1)
    }

    @Test func cumulativeIgnoresTimeBeforeTheWindow() {
        let rule = Rule(id: "c", name: "x", domains: ["youtube.com"],
                        mode: .cumulative, limitSeconds: 600, windowSeconds: 600)
        // 500 s long ago, then a span that straddles the window start, then now.
        let h = history([(500, .youtube), (400, .work), (300, .youtube)])
        #expect(RuleEngine.matchedSeconds(rule, spans: h.spans, now: h.now) == 300)
        let straddle = history([(700, .youtube)])
        #expect(RuleEngine.matchedSeconds(rule, spans: straddle.spans, now: straddle.now) == 600)
    }

    // MARK: Gates

    @Test func disabledRulesAndCooldownsSuppressFiring() {
        let h = history([(400, .youtube)])
        var off = youtube5min
        off.isEnabled = false
        #expect(RuleEngine.evaluate(rules: [off], spans: h.spans, now: h.now).isEmpty)

        let justFired = ["yt": h.now.addingTimeInterval(-100)]
        #expect(RuleEngine.evaluate(rules: [youtube5min], spans: h.spans, now: h.now, lastFired: justFired).isEmpty)
        let firedLongAgo = ["yt": h.now.addingTimeInterval(-301)]
        #expect(RuleEngine.evaluate(rules: [youtube5min], spans: h.spans, now: h.now, lastFired: firedLongAgo).count == 1)
    }

    @Test func scheduleLimitsWhenARuleApplies() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            // November 2026: the 16th is a Monday, the 21st a Saturday.
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        let office = Schedule(isAlways: false, weekdays: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 17 * 60)
        #expect(office.contains(date(16, 9), calendar: calendar))
        #expect(office.contains(date(16, 16, 59), calendar: calendar))
        #expect(!office.contains(date(16, 17), calendar: calendar))
        #expect(!office.contains(date(16, 8, 59), calendar: calendar))
        #expect(!office.contains(date(21, 12), calendar: calendar))

        // Monday night, 22:00 to 02:00: Monday evening and Tuesday's small hours.
        let night = Schedule(isAlways: false, weekdays: [2], startMinute: 22 * 60, endMinute: 2 * 60)
        #expect(night.contains(date(16, 23), calendar: calendar))        // Monday 23:00
        #expect(night.contains(date(17, 1), calendar: calendar))         // Tuesday 01:00, still Monday's period
        #expect(!night.contains(date(16, 1), calendar: calendar))        // Monday 01:00 belongs to Sunday night
        #expect(!night.contains(date(17, 23), calendar: calendar))       // Tuesday evening
        #expect(!night.contains(date(16, 12), calendar: calendar))
        // Saturday night wraps into Sunday (weekday 7 -> 1).
        let saturday = Schedule(isAlways: false, weekdays: [7], startMinute: 22 * 60, endMinute: 2 * 60)
        #expect(saturday.contains(date(22, 1), calendar: calendar))      // Sunday 22 Nov, 01:00

        #expect(Schedule.always.contains(date(21, 3), calendar: calendar))
    }

    // MARK: Storage round trips

    @Test func rulesSurviveSaveAndLoadAndMissingFileGivesStarter() throws {
        let path = NSTemporaryDirectory() + "wd-rules-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try RuleFile.load(path: path) == [.starter])

        let rules = [youtube5min, Rule(name: "Slack", apps: ["com.tinyspeck.slackmacgap"],
                                       schedule: Schedule(isAlways: false), mode: .cumulative, action: .block)]
        try RuleFile.save(rules, path: path)
        #expect(try RuleFile.load(path: path) == rules)
    }

    @Test func verdictsAreLoggedAndGiveLastFiredTimes() throws {
        let store = try UsageStore()
        let verdict = Verdict(ruleID: "yt", ruleName: "YouTube 5 min", action: .close, blockMinutes: 30,
                              at: t0, matchedSeconds: 312, subject: "youtube.com")
        try store.record(verdict, dryRun: true)
        var later = verdict
        later.at = t0.addingTimeInterval(900)
        try store.record(later, dryRun: true)

        let rows = try store.recentVerdicts()
        #expect(rows.count == 2)
        #expect(rows[0].action == "close" && rows[0].dryRun)
        #expect(try store.lastFiredTimes() == ["yt": later.at])
    }
}
