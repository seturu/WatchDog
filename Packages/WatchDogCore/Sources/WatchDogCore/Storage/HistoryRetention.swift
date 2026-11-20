import Foundation
import GRDB

/// How long activity history is kept.
///
/// Two limits. Details (window titles, page addresses, track names) say the
/// most about you and are cleared first; what remains (app, site, durations,
/// timer state) keeps the dashboard and charts working. Later the activity
/// itself is deleted. Pomodoro sessions are your own record and are kept.
///
/// Rules look back at most a day, so both limits have a floor well above
/// that: a short retention can never make a limit forget what it counted.
public struct HistoryRetention: Codable, Sendable, Equatable {
    /// Days to keep window titles, addresses and track names. Nil: forever.
    public var detailDays: Int?
    /// Days to keep activity at all. Nil: forever.
    public var historyDays: Int?

    public init(detailDays: Int? = 30, historyDays: Int? = 365) {
        self.detailDays = detailDays
        self.historyDays = historyDays
    }

    public static let standard = HistoryRetention()
    public static let forever = HistoryRetention(detailDays: nil, historyDays: nil)

    public static let minimumDetailDays = 7
    public static let minimumHistoryDays = 30

    /// The cut-off dates, after the floors are applied. Details are never
    /// kept longer than the activity they belong to.
    public func cutoffs(now: Date) -> (detail: Date?, history: Date?) {
        let history = historyDays.map { now.addingTimeInterval(-Double(max($0, Self.minimumHistoryDays)) * 86_400) }
        var detail = detailDays.map { now.addingTimeInterval(-Double(max($0, Self.minimumDetailDays)) * 86_400) }
        if let h = history, let d = detail, h > d { detail = h }
        return (detail, history)
    }
}

extension UsageStore {
    public struct PruneResult: Sendable, Equatable {
        /// Rows whose details were cleared.
        public var cleared: Int = 0
        /// Rows deleted (spans, sound and rule firings).
        public var deleted: Int = 0
    }

    /// Applies the retention limits. Safe to call often; it only touches rows
    /// that have crossed a limit.
    @discardableResult
    public func prune(_ retention: HistoryRetention, now: Date = Date()) throws -> PruneResult {
        let (detail, history) = retention.cutoffs(now: now)
        return try db.write { db in
            var result = PruneResult()
            if let history {
                for (table, column) in [("spans", "ended_at"), ("media_spans", "ended_at"), ("verdicts", "at")] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE \(column) < ?", arguments: [history])
                    result.deleted += db.changesCount
                }
            }
            if let detail {
                try db.execute(sql: """
                    UPDATE spans SET window_title = NULL, url = NULL
                    WHERE ended_at < ? AND (window_title IS NOT NULL OR url IS NOT NULL)
                    """, arguments: [detail])
                result.cleared += db.changesCount
                try db.execute(sql: """
                    UPDATE media_spans SET title = NULL, artist = NULL
                    WHERE ended_at < ? AND (title IS NOT NULL OR artist IS NOT NULL)
                    """, arguments: [detail])
                result.cleared += db.changesCount
            }
            return result
        }
    }

    /// Brings page addresses already in history down to what `detail` keeps,
    /// so choosing less detail also cleans what was recorded before. Run
    /// alongside `prune`; new rows are stored that way already, so after the
    /// first pass it only reads. Returns the number of rows changed.
    ///
    /// The addresses are worked out between a quick read and a quick write,
    /// so the tracker never waits on the cleaning itself; a row whose address
    /// changed in between (an expiry cleared it) is left alone.
    @discardableResult
    public func applyAddressDetail(_ detail: AddressDetail) throws -> Int {
        guard detail != .full else { return 0 }
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, url FROM spans WHERE url IS NOT NULL")
        }
        let changes: [(id: Int64, old: String, new: String?)] = rows.compactMap { row in
            let old: String = row["url"]
            let new = detail.apply(to: old)
            return new == old ? nil : (row["id"], old, new)
        }
        guard !changes.isEmpty else { return 0 }
        return try db.write { db in
            var changed = 0
            for change in changes {
                try db.execute(sql: "UPDATE spans SET url = ? WHERE id = ? AND url = ?",
                               arguments: [change.new, change.id, change.old])
                changed += db.changesCount
            }
            return changed
        }
    }
}
