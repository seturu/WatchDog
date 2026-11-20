import Foundation
import Testing
@testable import WatchDogCore

struct DaySummaryTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    var midnight: Date { utc.date(from: DateComponents(year: 2026, month: 11, day: 17))! }
    var day: DateInterval { DateInterval(start: midnight, duration: 86_400) }

    /// A span starting `startMinute` minutes after midnight.
    func span(_ startMinute: Double, _ minutes: Double, app: String, domain: String? = nil,
              idle: Bool = false, timer: TimerState = .none) -> Span {
        Span(id: nil, startedAt: midnight.addingTimeInterval(startMinute * 60),
             endedAt: midnight.addingTimeInterval((startMinute + minutes) * 60),
             bundleID: "id." + app, appName: app, windowTitle: nil, url: nil,
             domain: domain, isIdle: idle, timerState: timer)
    }

    @Test func totalsSeparateActiveAwayFocusAndBreak() {
        let summary = DaySummary(spans: [
            span(540, 25, app: "Xcode", timer: .focus),
            span(565, 5, app: "Brave", domain: "youtube.com", timer: .onBreak),
            span(570, 10, app: "Brave", idle: true, timer: .focus),
            span(580, 20, app: "Xcode"),
        ], day: day, calendar: utc)
        #expect(summary.active == 50 * 60)
        #expect(summary.away == 10 * 60)
        #expect(summary.focus == 25 * 60)      // away time during focus is not focus
        #expect(summary.onBreak == 5 * 60)
        #expect(summary.apps.map(\.label) == ["Xcode", "Brave"])
        #expect(summary.apps.first?.seconds == 2700.0)
        #expect(summary.sites.map(\.key) == ["youtube.com"])
    }

    @Test func aSpanCrossingAnHourIsSplitBetweenTheHours() {
        // 09:50 to 10:20
        let summary = DaySummary(spans: [span(590, 30, app: "Xcode")], day: day, calendar: utc)
        #expect(summary.hours == [
            .init(hour: 9, series: "Xcode", seconds: 600),
            .init(hour: 10, series: "Xcode", seconds: 1200),
        ])
        #expect(summary.series == ["Xcode"])
    }

    @Test func spansAreClippedToTheDay() {
        // 23:30 the day before to 00:30, and 23:45 to 00:15 the day after.
        let summary = DaySummary(spans: [span(-30, 60, app: "Xcode"), span(1425, 30, app: "Xcode")],
                                 day: day, calendar: utc)
        #expect(summary.active == 45 * 60)
        #expect(summary.hours.map(\.hour) == [0, 23])
    }

    @Test func onlyTheBusiestAppsGetASeriesTheRestBecomeOther() {
        let summary = DaySummary(spans: [
            span(600, 30, app: "A"), span(630, 20, app: "B"), span(650, 5, app: "C"), span(655, 4, app: "D"),
        ], day: day, calendar: utc, topApps: 2)
        #expect(summary.series == ["A", "B", "Other"])
        let other = summary.hours.filter { $0.series == "Other" }.map(\.seconds).reduce(0, +)
        #expect(other == 9 * 60)
        // Every active second lands in exactly one slice.
        #expect(summary.hours.map(\.seconds).reduce(0, +) == summary.active)
    }

    @Test func anEmptyDayIsEmpty() {
        #expect(DaySummary(spans: [], day: day, calendar: utc) == .empty)
    }
}
