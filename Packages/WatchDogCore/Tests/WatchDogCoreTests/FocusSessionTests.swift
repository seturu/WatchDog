import Foundation
import Testing
@testable import WatchDogCore

/// Focus sessions and their categories in the usage database.
struct FocusSessionTests {
    let store = try! UsageStore()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func finished(at offset: TimeInterval, minutes: Double = 25, completed: Bool = true,
                  category: Int64? = nil) -> FinishedFocus {
        FinishedFocus(startedAt: t0.addingTimeInterval(offset), endedAt: t0.addingTimeInterval(offset + minutes * 60),
                      plannedSeconds: 1500, focusedSeconds: minutes * 60, completed: completed, categoryID: category)
    }

    @Test func aFinishedSessionIsStoredUnratedAndCanBeRatedAndNotedLater() throws {
        let writing = try store.save(SessionCategory(name: " Writing ", color: .purple))
        #expect(writing.name == "Writing")
        let row = try store.record(finished(at: 0, category: writing.id))
        #expect(row.id != nil)
        #expect(row.rating == .neutral)
        #expect(row.note == nil)

        try store.updateSession(id: row.id!, rating: .focused, note: "  Drafted the intro  ", categoryID: writing.id)
        var saved = try store.focusSessions(since: t0).first
        #expect(saved?.rating == .focused)
        #expect(saved?.note == "Drafted the intro")
        #expect(saved?.categoryID == writing.id)

        // Edited again afterwards: a blank note clears it.
        try store.updateSession(id: row.id!, rating: .distracted, note: "   ", categoryID: nil)
        saved = try store.focusSessions(since: t0).first
        #expect(saved?.rating == .distracted)
        #expect(saved?.note == nil)
        #expect(saved?.categoryID == nil)
    }

    @Test func sessionsComeBackNewestFirstFromTheGivenTime() throws {
        try store.record(finished(at: 0))
        try store.record(finished(at: 3600))
        try store.record(finished(at: -86_400))
        let rows = try store.focusSessions(since: t0)
        #expect(rows.map(\.startedAt) == [t0.addingTimeInterval(3600), t0])
        try store.deleteSession(id: rows[0].id!)
        #expect(try store.focusSessions(since: t0).count == 1)
    }

    @Test func categoriesKeepTheirOrderAndAUsedOneIsHiddenNotDeleted() throws {
        let a = try store.save(SessionCategory(name: "Study", color: .blue))
        let b = try store.save(SessionCategory(name: "Code", color: .green))
        #expect(try store.sessionCategories().map(\.name) == ["Study", "Code"])
        #expect(b.sortOrder > a.sortOrder)

        var renamed = b
        renamed.name = "Coding"
        renamed.color = .orange
        try store.save(renamed)
        #expect(try store.sessionCategories().last == renamed)

        try store.record(finished(at: 0, category: a.id))
        try store.removeCategory(id: a.id!)            // used: hidden
        try store.removeCategory(id: b.id!)            // unused: deleted
        #expect(try store.sessionCategories().isEmpty)
        let all = try store.sessionCategories(includingArchived: true)
        #expect(all.map(\.name) == ["Study"])
        #expect(all.first?.isArchived == true)
        // The history still points at it.
        #expect(try store.focusSessions(since: t0).first?.categoryID == a.id)
    }

    @Test func anExistingDatabaseGainsTheSessionTablesAndKeepsItsHistory() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            // A database as the previous version left it.
            let old = try UsageStore(path: path, upTo: "3-timer-state")
            try old.record(Sample(time: t0, bundleID: "com.apple.dt.Xcode", appName: "Xcode", timerState: .focus))
            try old.record(Sample(time: t0.addingTimeInterval(2), bundleID: "com.apple.dt.Xcode", appName: "Xcode", timerState: .focus))
        }
        let upgraded = try UsageStore(path: path)
        #expect(try upgraded.recentSpans().count == 1)
        #expect(try upgraded.recentSpans().first?.timerState == .focus)
        try upgraded.record(finished(at: 0))
        #expect(try upgraded.focusSessions(since: t0).count == 1)
    }

    // MARK: Grouping

    @Test func historyIsGroupedByDayNewestFirst() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let monday = utc.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9))!
        func session(_ hours: Double, _ minutes: Double, _ rating: SessionRating) -> FocusSession {
            let start = monday.addingTimeInterval(hours * 3600)
            return FocusSession(startedAt: start, endedAt: start.addingTimeInterval(minutes * 60), plannedSeconds: 1500,
                                focusedSeconds: minutes * 60, completed: minutes == 25, rating: rating)
        }
        let days = SessionDay.group([session(0, 25, .focused), session(1, 25, .distracted),
                                     session(2, 10, .neutral), session(24, 25, .focused)], calendar: utc)
        #expect(days.count == 2)
        #expect(days[0].day == utc.startOfDay(for: monday.addingTimeInterval(86_400)))
        let first = days[1]
        #expect(first.sessions.map(\.startedAt) == [monday.addingTimeInterval(7200), monday.addingTimeInterval(3600), monday])
        #expect(first.focusedSeconds == 60 * 60)
        #expect(first.completedCount == 2)
        #expect(first.count(.distracted) == 1)
        #expect(abs(first.focusedShare - 25.0 / 60.0) < 1e-9)
    }
}
