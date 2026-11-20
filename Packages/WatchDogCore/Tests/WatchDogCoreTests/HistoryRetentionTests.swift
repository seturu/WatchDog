import Foundation
import Testing
@testable import WatchDogCore

/// What history keeps, and for how long.
struct HistoryRetentionTests {
    let store = try! UsageStore()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    /// One span `daysAgo` days back, 10 s long, on a page with a title.
    func visit(daysAgo: Double, title: String = "Inbox (3) - private@example.com") throws {
        let start = now.addingTimeInterval(-daysAgo * day)
        for offset in [0.0, 10] {
            try store.record(Sample(time: start.addingTimeInterval(offset), bundleID: "com.brave.Browser",
                                    appName: "Brave Browser", windowTitle: title,
                                    url: "https://mail.example.com/u/0/#inbox/FMfcgz?q=secret"))
        }
    }

    func spans() throws -> [Span] { try store.recentSpans(limit: 100).sorted { $0.startedAt < $1.startedAt } }

    // MARK: Addresses

    @Test func onlyTheSiteOfAnAddressIsKeptByDefault() {
        #expect(Sample.siteAddress(of: "https://www.YouTube.com/watch?v=x#t=10") == "https://www.youtube.com")
        #expect(Sample.siteAddress(of: "http://localhost:8080/admin?token=abc") == "http://localhost:8080")
        #expect(Sample.siteAddress(of: "file:///Users/me/Secret.pdf") == nil)
        #expect(Sample.siteAddress(of: "brave://newtab") == nil)
        #expect(Sample.siteAddress(of: nil) == nil)
        // Rules match on the domain, which the short form still gives.
        #expect(Sample.domain(of: Sample.siteAddress(of: "https://m.youtube.com/shorts/abc")) == "m.youtube.com")
    }

    // MARK: Expiry

    @Test func oldDetailsAreClearedButTheActivityStays() throws {
        try visit(daysAgo: 40)
        try visit(daysAgo: 2)
        let result = try store.prune(.standard, now: now)          // details 30 days, activity a year
        #expect(result.cleared == 1)
        #expect(result.deleted == 0)
        let rows = try spans()
        #expect(rows.count == 2)
        #expect(rows[0].windowTitle == nil && rows[0].url == nil)
        #expect(rows[0].domain == "mail.example.com")              // the site and the time remain
        #expect(rows[0].seconds == 10)
        #expect(rows[1].windowTitle != nil && rows[1].url != nil)   // recent history untouched
    }

    @Test func oldActivityIsDeletedWithItsSoundAndRuleFirings() throws {
        try visit(daysAgo: 400)
        try visit(daysAgo: 3)
        try store.record(MediaSample(time: now.addingTimeInterval(-400 * day), sourceBundleID: "com.spotify.client",
                                     title: "Song", artist: "Band"))
        try store.record(Verdict(ruleID: "r", ruleName: "Rule", action: .warn, blockMinutes: 0,
                                 at: now.addingTimeInterval(-400 * day), matchedSeconds: 60, subject: "youtube.com"),
                         dryRun: true)
        let result = try store.prune(.standard, now: now)
        #expect(result.deleted == 3)
        #expect(try spans().count == 1)
        #expect(try store.recentMedia().isEmpty)
        #expect(try store.recentVerdicts().isEmpty)
    }

    @Test func limitsHaveFloorsSoRulesNeverLoseWhatTheyCount() throws {
        try visit(daysAgo: 20)
        try visit(daysAgo: 5)
        // Asking for one day of either is treated as the floors: 7 and 30 days.
        let result = try store.prune(HistoryRetention(detailDays: 1, historyDays: 1), now: now)
        #expect(result.deleted == 0)
        #expect(result.cleared == 1)
        #expect(try spans().map { $0.windowTitle == nil } == [true, false])
    }

    @Test func foreverKeepsEverythingAndDetailsNeverOutliveTheirActivity() throws {
        try visit(daysAgo: 1000)
        #expect(try store.prune(.forever, now: now) == UsageStore.PruneResult())
        #expect(try spans().first?.windowTitle != nil)

        let cut = HistoryRetention(detailDays: 365, historyDays: 60).cutoffs(now: now)
        #expect(cut.detail == cut.history)
        #expect(cut.history == now.addingTimeInterval(-60 * day))
    }

    @Test func theDatabaseFileIsPrivateToItsOwner() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("usage.sqlite").path
        _ = try UsageStore(path: path)
        let fileMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(folderMode == 0o700)
    }
}
