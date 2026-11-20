import Foundation
import GRDB

// MARK: Rows

/// A stretch of time during which the same app, window title and address stayed
/// in front (or during which the user was idle).
public struct Span: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var startedAt: Date
    public var endedAt: Date
    public var bundleID: String
    public var appName: String
    public var windowTitle: String?
    public var url: String?
    public var domain: String?
    public var isIdle: Bool
    /// Pomodoro timer state during this span; a change of state starts a new span.
    public var timerState: TimerState = .none

    public static let databaseTableName = "spans"

    /// Swift property -> database column.
    enum CodingKeys: String, CodingKey {
        case id, url, domain
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case bundleID = "bundle_id"
        case appName = "app_name"
        case windowTitle = "window_title"
        case isIdle = "is_idle"
        case timerState = "timer_state"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var seconds: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// A stretch of time during which one app kept producing sound.
public struct MediaSpan: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var startedAt: Date
    public var endedAt: Date
    public var sourceBundleID: String
    public var title: String?
    public var artist: String?

    public static let databaseTableName = "media_spans"

    enum CodingKeys: String, CodingKey {
        case id, title, artist
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case sourceBundleID = "source_bundle_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var seconds: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// A logged rule decision. `dryRun` rows record what would have happened.
public struct VerdictRecord: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var at: Date
    public var ruleID: String
    public var ruleName: String
    public var action: String
    public var subject: String
    public var matchedSeconds: Double
    public var dryRun: Bool

    public static let databaseTableName = "verdicts"

    enum CodingKeys: String, CodingKey {
        case id, at, action, subject
        case ruleID = "rule_id"
        case ruleName = "rule_name"
        case matchedSeconds = "matched_seconds"
        case dryRun = "dry_run"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One line of a "time per app" or "time per site" summary.
public struct UsageTotal: Sendable, Identifiable, Equatable {
    public var key: String      // bundle ID or domain
    public var label: String    // app name or domain
    public var seconds: TimeInterval
    public var id: String { key }
}

// MARK: Store

/// The usage history database. Owned by the app, and encrypted with a key
/// only the app can take from the keychain (`DatabaseKey`), so it cannot be
/// read with a plain SQLite tool.
public final class UsageStore: Sendable {

    /// Two samples further apart than this are not joined into one span.
    /// Covers sleep, a quit-and-relaunch, or a stalled timer.
    public static let maxGap: TimeInterval = 15

    /// Internal so the other parts of the store (FocusSessions.swift) can reach it.
    let db: DatabaseQueue

    /// `path == nil` gives a throwaway in-memory database (used by tests).
    /// With a `key` the file is encrypted; a file left unencrypted by an
    /// earlier version is encrypted in place first.
    public convenience init(path: String? = nil, key: DatabaseKey? = nil) throws {
        try self.init(path: path, key: key, upTo: nil)
    }

    /// Tests: `upTo` stops after the named migration, to stand in for a
    /// database written by an earlier version.
    init(path: String?, key: DatabaseKey? = nil, upTo lastMigration: String?) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // The key comes before anything else touches the file.
            if let key { try db.usePassphrase(key.sqlCipherKey) }
            // Deleted or cleared history is overwritten on disk, not just unlinked.
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        if let path {
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if let key, Self.isUnencrypted(path) { try Self.encrypt(path, with: key) }
            do {
                db = try DatabaseQueue(path: path, configuration: configuration)
            } catch let error as DatabaseError where key != nil && error.resultCode == .SQLITE_NOTADB {
                // Encrypted with a key we no longer have. Keep the file, in
                // case the key turns up, and start a new history: without
                // one nothing is tracked and no rule can be checked.
                try Self.setAside(path)
                db = try DatabaseQueue(path: path, configuration: configuration)
            }
            // History is for this account only. The enclosing folders are
            // usually private already; this does not rely on it.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } else {
            db = try DatabaseQueue(configuration: configuration)
        }
        if let lastMigration {
            try Self.migrator.migrate(db, upTo: lastMigration)
        } else {
            try Self.migrator.migrate(db)
        }
    }

    // MARK: Encryption

    /// Every unencrypted SQLite file starts with these 16 bytes; an
    /// encrypted one starts with random ones.
    static func isUnencrypted(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }

    /// Replaces the unencrypted database at `path` with an encrypted copy.
    /// The copy is complete before it takes the original's place, so an
    /// interruption leaves the original as it was.
    static func encrypt(_ path: String, with key: DatabaseKey) throws {
        let files = FileManager.default
        let copy = path + ".encrypting"
        try? files.removeItem(atPath: copy)
        do {
            let plain = try DatabaseQueue(path: path)
            try plain.writeWithoutTransaction { db in
                // Fold any write-ahead log into the main file first.
                _ = try? Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                try db.execute(sql: "ATTACH DATABASE ? AS encrypted KEY ?", arguments: [copy, key.sqlCipherKey])
                try db.execute(sql: "SELECT sqlcipher_export('encrypted')")
                // sqlcipher_export leaves the schema version behind.
                let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
                try db.execute(sql: "PRAGMA encrypted.user_version = \(version)")
                try db.execute(sql: "DETACH DATABASE encrypted")
            }
            try plain.close()
        } catch {
            try? files.removeItem(atPath: copy)
            throw error
        }
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy)
        guard rename(copy, path) == 0 else {
            let code = errno
            try? files.removeItem(atPath: copy)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: POSIXError(.init(rawValue: code) ?? .EIO)])
        }
        for suffix in ["-wal", "-shm", "-journal"] { try? files.removeItem(atPath: path + suffix) }
    }

    /// Moves a database that cannot be opened out of the way (one is kept).
    static func setAside(_ path: String) throws {
        let files = FileManager.default
        let aside = path + ".unreadable"
        try? files.removeItem(atPath: aside)
        try files.moveItem(atPath: path, toPath: aside)
        for suffix in ["-wal", "-shm", "-journal"] { try? files.removeItem(atPath: path + suffix) }
    }

    /// usage.sqlite in the app's private container (see `UserData`).
    public static func defaultPath() -> String {
        UserData.folder.appendingPathComponent("usage.sqlite").path
    }

    /// Schema changes are append-only: never edit a shipped migration, add a new one.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("1-spans") { db in
            try db.create(table: "spans") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .datetime).notNull().indexed()
                t.column("ended_at", .datetime).notNull()
                t.column("bundle_id", .text).notNull()
                t.column("app_name", .text).notNull()
                t.column("window_title", .text)
                t.column("url", .text)
                t.column("domain", .text)
                t.column("is_idle", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "media_spans") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .datetime).notNull().indexed()
                t.column("ended_at", .datetime).notNull()
                t.column("source_bundle_id", .text).notNull()
                t.column("title", .text)
                t.column("artist", .text)
            }
        }
        migrator.registerMigration("2-verdicts") { db in
            try db.create(table: "verdicts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("at", .datetime).notNull().indexed()
                t.column("rule_id", .text).notNull()
                t.column("rule_name", .text).notNull()
                t.column("action", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("matched_seconds", .double).notNull()
                t.column("dry_run", .boolean).notNull()
            }
        }
        migrator.registerMigration("3-timer-state") { db in
            try db.alter(table: "spans") { t in
                t.add(column: "timer_state", .text).notNull().defaults(to: "none")
            }
        }
        // Pomodoro sessions from the built-in timer, and their categories.
        // `kind` leaves room for other kinds of session (PLAN.md §3).
        migrator.registerMigration("4-sessions") { db in
            try db.create(table: "session_categories") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("color", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("is_archived", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull().defaults(to: "focus")
                t.column("started_at", .datetime).notNull().indexed()
                t.column("ended_at", .datetime).notNull()
                t.column("planned_seconds", .double).notNull()
                t.column("focused_seconds", .double).notNull()
                t.column("completed", .boolean).notNull()
                t.column("category_id", .integer)
                    .references("session_categories", onDelete: .setNull)
                t.column("rating", .text).notNull().defaults(to: "neutral")
                t.column("note", .text)
            }
        }
        return migrator
    }

    // MARK: Writing

    /// Stores a sample. If it shows the same thing as the latest span, that span
    /// is stretched to cover it; otherwise the latest span is closed at this
    /// moment and a new one begins.
    ///
    /// A span never shrinks or runs backwards. Time can step back when the
    /// app switches to the daemon's clock after starting with a moved system
    /// clock; a span ending before it began would subtract from the totals
    /// rules count (and give break budget back).
    public func record(_ sample: Sample) throws {
        try db.write { db in
            var start = sample.time
            if var open = try Span.order(Column("id").desc).fetchOne(db) {
                let step = sample.time.timeIntervalSince(open.endedAt)
                if abs(step) <= Self.maxGap {
                    if step > 0 {
                        open.endedAt = sample.time
                        try open.update(db)
                    }
                    let same = open.bundleID == sample.bundleID
                        && open.windowTitle == sample.windowTitle
                        && open.url == sample.url
                        && open.isIdle == sample.isIdle
                        && open.timerState == sample.timerState
                    if same { return }
                    // A small step back: the next span starts where this one ends.
                    start = max(sample.time, open.endedAt)
                }
            }
            var span = Span(id: nil, startedAt: start, endedAt: start,
                            bundleID: sample.bundleID, appName: sample.appName,
                            windowTitle: sample.windowTitle, url: sample.url,
                            domain: sample.domain, isIdle: sample.isIdle,
                            timerState: sample.timerState)
            try span.insert(db)
        }
    }

    /// Same idea for sound: one open span per app that is currently audible.
    public func record(_ sample: MediaSample) throws {
        try db.write { db in
            let last = try MediaSpan
                .filter(Column("source_bundle_id") == sample.sourceBundleID)
                .order(Column("id").desc)
                .fetchOne(db)
            if var open = last, sample.time.timeIntervalSince(open.endedAt) <= Self.maxGap {
                open.endedAt = sample.time
                // A track title can arrive a moment after the sound starts.
                if open.title == nil { open.title = sample.title; open.artist = sample.artist }
                try open.update(db)
                if open.title == sample.title || sample.title == nil { return }
            }
            var span = MediaSpan(id: nil, startedAt: sample.time, endedAt: sample.time,
                                 sourceBundleID: sample.sourceBundleID,
                                 title: sample.title, artist: sample.artist)
            try span.insert(db)
        }
    }

    // MARK: Reading

    /// Active (non-idle) time per app for spans that started in `interval`.
    public func totalsByApp(in interval: DateInterval) throws -> [UsageTotal] {
        try totals(key: "bundle_id", label: "MAX(app_name)", extra: "", in: interval)
    }

    /// Active time per website for spans that started in `interval`.
    public func totalsByDomain(in interval: DateInterval) throws -> [UsageTotal] {
        try totals(key: "domain", label: "domain", extra: "AND domain IS NOT NULL", in: interval)
    }

    private func totals(key: String, label: String, extra: String, in interval: DateInterval) throws -> [UsageTotal] {
        try db.read { db in
            // julianday() turns a stored timestamp into days; x 86400 gives seconds.
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(key) AS key, \(label) AS label,
                       SUM((julianday(ended_at) - julianday(started_at)) * 86400.0) AS seconds
                FROM spans
                WHERE started_at >= ? AND started_at < ? AND is_idle = 0 \(extra)
                GROUP BY \(key)
                HAVING seconds >= 1
                ORDER BY seconds DESC
                """, arguments: [interval.start, interval.end])
            return rows.map { UsageTotal(key: $0["key"], label: $0["label"], seconds: $0["seconds"]) }
        }
    }

    /// Total idle time for spans that started in `interval`.
    public func idleSeconds(in interval: DateInterval) throws -> TimeInterval {
        try db.read { db in
            try Double.fetchOne(db, sql: """
                SELECT SUM((julianday(ended_at) - julianday(started_at)) * 86400.0)
                FROM spans WHERE started_at >= ? AND started_at < ? AND is_idle = 1
                """, arguments: [interval.start, interval.end]) ?? 0
        }
    }

    /// Spans that ended at or after `date`, oldest first (what the rule engine wants).
    public func spans(since date: Date) throws -> [Span] {
        try db.read { db in
            try Span.filter(Column("ended_at") >= date).order(Column("id")).fetchAll(db)
        }
    }

    // MARK: Verdicts

    public func record(_ verdict: Verdict, dryRun: Bool) throws {
        try db.write { db in
            var row = VerdictRecord(id: nil, at: verdict.at, ruleID: verdict.ruleID, ruleName: verdict.ruleName,
                                    action: verdict.action.rawValue, subject: verdict.subject,
                                    matchedSeconds: verdict.matchedSeconds, dryRun: dryRun)
            try row.insert(db)
        }
    }

    public func recentVerdicts(limit: Int = 50) throws -> [VerdictRecord] {
        try db.read { db in try VerdictRecord.order(Column("id").desc).limit(limit).fetchAll(db) }
    }

    /// When each rule last fired, by rule ID. Lets cooldowns survive an app restart.
    public func lastFiredTimes() throws -> [String: Date] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT rule_id, MAX(at) AS at FROM verdicts GROUP BY rule_id")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["rule_id"] as String, $0["at"] as Date) })
        }
    }

    public func recentSpans(limit: Int = 50) throws -> [Span] {
        try db.read { db in try Span.order(Column("id").desc).limit(limit).fetchAll(db) }
    }

    public func recentMedia(limit: Int = 20) throws -> [MediaSpan] {
        try db.read { db in try MediaSpan.order(Column("id").desc).limit(limit).fetchAll(db) }
    }
}
