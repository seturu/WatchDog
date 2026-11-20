import Foundation
import Testing
@testable import WatchDogCore

/// Each test gets its own in-memory database.
struct UsageStoreTests {
    let store = try! UsageStore()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func sample(_ offset: TimeInterval, app: String = "com.brave.Browser", title: String? = "Docs",
                url: String? = nil, idle: Bool = false) -> Sample {
        Sample(time: t0.addingTimeInterval(offset), bundleID: app, appName: app,
               windowTitle: title, url: url, isIdle: idle)
    }

    @Test func identicalSamplesBecomeOneSpan() throws {
        for offset in stride(from: 0.0, through: 10, by: 2) { try store.record(sample(offset)) }
        let spans = try store.recentSpans()
        #expect(spans.count == 1)
        #expect(spans[0].seconds == 10)
    }

    @Test func aChangeClosesTheOldSpanAtThatMoment() throws {
        try store.record(sample(0, title: "A"))
        try store.record(sample(2, title: "A"))
        try store.record(sample(4, title: "B"))
        try store.record(sample(6, title: "B"))
        let spans = try store.recentSpans().reversed() as [Span]
        #expect(spans.map(\.windowTitle) == ["A", "B"])
        #expect(spans.map(\.seconds) == [4, 2])   // no time lost between them
    }

    @Test func aLongGapIsNotCountedAsUsage() throws {
        try store.record(sample(0))
        try store.record(sample(2))
        try store.record(sample(3600))            // e.g. the Mac slept for an hour
        try store.record(sample(3602))
        let spans = try store.recentSpans()
        #expect(spans.count == 2)
        #expect(spans.map(\.seconds).reduce(0, +) == 4)
    }

    @Test func urlChangeStartsANewSpanAndDomainIsStored() throws {
        try store.record(sample(0, url: "https://www.youtube.com/watch?v=1"))
        try store.record(sample(2, url: "https://www.youtube.com/watch?v=2"))
        let spans = try store.recentSpans()
        #expect(spans.count == 2)
        #expect(spans.allSatisfy { $0.domain == "youtube.com" })
    }

    @Test func totalsExcludeIdleAndGroupByAppAndDomain() throws {
        // Samples arrive every 2 s, as they do from the real tracker.
        for t in stride(from: 0.0, to: 60, by: 2) {
            try store.record(sample(t, app: "com.brave.Browser", url: "https://youtube.com/a"))
        }
        for t in stride(from: 60.0, to: 90, by: 2) {
            try store.record(sample(t, app: "com.brave.Browser", url: "https://github.com/x"))
        }
        for t in stride(from: 90.0, to: 100, by: 2) {
            try store.record(sample(t, app: "com.apple.dt.Xcode", title: "main.swift"))
        }
        for t in stride(from: 100.0, through: 110, by: 2) {
            try store.record(sample(t, app: "com.apple.dt.Xcode", title: nil, idle: true))
        }

        let day = DateInterval(start: t0.addingTimeInterval(-1), duration: 86_400)
        let apps = try store.totalsByApp(in: day)
        #expect(apps.map(\.key) == ["com.brave.Browser", "com.apple.dt.Xcode"])
        #expect(apps.map { $0.seconds.rounded() } == [90, 10])

        let sites = try store.totalsByDomain(in: day)
        #expect(sites.map(\.key) == ["youtube.com", "github.com"])
        #expect(sites.map { $0.seconds.rounded() } == [60, 30])

        #expect(try store.idleSeconds(in: day).rounded() == 10)
    }

    @Test func mediaSpansMergePerSourceAndSplitOnTrackChange() throws {
        func media(_ offset: TimeInterval, _ source: String, _ title: String?) -> MediaSample {
            MediaSample(time: t0.addingTimeInterval(offset), sourceBundleID: source, title: title)
        }
        try store.record(media(0, "com.spotify.client", nil))
        try store.record(media(2, "com.spotify.client", "Song A"))   // title arrives late
        try store.record(media(2, "com.brave.Browser", nil))
        try store.record(media(4, "com.spotify.client", "Song A"))
        try store.record(media(6, "com.spotify.client", "Song B"))

        let spans = try store.recentMedia()
        let spotify = spans.filter { $0.sourceBundleID == "com.spotify.client" }.reversed() as [MediaSpan]
        #expect(spotify.map(\.title) == ["Song A", "Song B"])
        #expect(spotify.first?.seconds == 6)
        #expect(spans.filter { $0.sourceBundleID == "com.brave.Browser" }.count == 1)
    }

    @Test func domainParsing() {
        #expect(Sample.domain(of: "https://www.YouTube.com/watch") == "youtube.com")
        #expect(Sample.domain(of: "https://m.youtube.com/") == "m.youtube.com")
        #expect(Sample.domain(of: "brave://newtab") == nil)        // browser pages are not sites
        #expect(Sample.domain(of: "file:///Users/x/a.html") == nil)
        #expect(Sample.domain(of: "http://localhost:8000/") == "localhost")
        #expect(Sample.domain(of: nil) == nil)
        #expect(Sample.domain(of: "") == nil)
    }

    @Test func aClockSteppingBackNeverMakesASpanRunBackwards() throws {
        try store.record(sample(0, title: "A"))
        try store.record(sample(10, title: "A"))
        // A small step back with the same thing in front changes nothing.
        try store.record(sample(9, title: "A"))
        // A small step back onto something else starts where the last span ended.
        try store.record(sample(8, title: "B"))
        // A big jump back (switching to the daemon's clock) starts a fresh span.
        try store.record(sample(-3600, title: "B"))
        let spans = try store.recentSpans().reversed() as [Span]
        #expect(spans.map(\.windowTitle) == ["A", "B", "B"])
        #expect(spans[0].seconds == 10)
        #expect(spans[1].startedAt == t0.addingTimeInterval(10))
        #expect(spans.allSatisfy { $0.seconds >= 0 })
    }
}

@Suite struct EncryptedStoreTests {
    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("wd-\(UUID().uuidString)/usage.sqlite").path
    }

    private func sample(_ title: String, at seconds: TimeInterval) -> Sample {
        Sample(time: Date(timeIntervalSince1970: 1_800_000_000 + seconds), bundleID: "com.example.app", appName: "Example",
               windowTitle: title, url: "https://secret.example.com")
    }

    @Test func anExistingHistoryIsEncryptedInPlaceAndKeepsItsRows() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let key = try DatabaseKey.random()

        // As an earlier version left it: readable by anything.
        do {
            let plain = try UsageStore(path: path)
            try plain.record(sample("Quarterly salaries.xlsx", at: 0))
            try plain.record(sample("Quarterly salaries.xlsx", at: 2))
            try plain.db.close()
        }
        #expect(UsageStore.isUnencrypted(path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).range(of: Data("Quarterly salaries".utf8)) != nil)

        do {
            let store = try UsageStore(path: path, key: key)
            #expect(try store.recentSpans().map(\.windowTitle) == ["Quarterly salaries.xlsx"])
            try store.record(sample("Another window", at: 4))
            try store.db.close()
        }
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(!UsageStore.isUnencrypted(path))
        for secret in ["Quarterly salaries", "Another window", "secret.example.com", "spans"] {
            #expect(onDisk.range(of: Data(secret.utf8)) == nil, "\(secret) is readable in the file")
        }
        #expect(!FileManager.default.fileExists(atPath: path + ".encrypting"))

        // Opens again with the key, and the migrations are not run twice.
        #expect(try UsageStore(path: path, key: key).recentSpans().count == 2)
        // Without the key it is not a database at all.
        #expect(throws: (any Error).self) { try UsageStore(path: path) }
    }

    @Test func aHistoryWhoseKeyIsLostIsSetAsideAndTrackingGoesOn() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        do {
            let store = try UsageStore(path: path, key: try DatabaseKey.random())
            try store.record(sample("Old", at: 0))
            try store.db.close()
        }
        let store = try UsageStore(path: path, key: try DatabaseKey.random())
        #expect(try store.recentSpans().isEmpty)
        try store.record(sample("New", at: 0))
        #expect(FileManager.default.fileExists(atPath: path + ".unreadable"))
    }
}
