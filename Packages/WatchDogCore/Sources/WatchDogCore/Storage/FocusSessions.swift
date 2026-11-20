import Foundation
import GRDB

// MARK: Rows

/// How a focus session went, in the user's own words. Neutral until rated.
public enum SessionRating: String, Codable, Sendable, CaseIterable {
    case neutral, focused, distracted
}

/// Colours a category can have. Named system colours, so they adapt to light
/// and dark mode instead of being fixed RGB values.
public enum CategoryColor: String, Codable, Sendable, CaseIterable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, cyan, brown, gray
}

/// A user-defined kind of focus session ("Writing", "Study"), chosen when a
/// session starts. Removing one that sessions use only hides it, so the
/// history keeps its name and colour.
public struct SessionCategory: Codable, Sendable, Identifiable, Equatable, Hashable,
                               FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var color: CategoryColor
    public var sortOrder: Int
    public var isArchived: Bool

    public static let databaseTableName = "session_categories"

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case sortOrder = "sort_order"
        case isArchived = "is_archived"
    }

    public init(id: Int64? = nil, name: String, color: CategoryColor, sortOrder: Int = 0, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A focus session from the built-in timer.
public struct FocusSession: Codable, Sendable, Identifiable, Equatable,
                            FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var startedAt: Date
    public var endedAt: Date
    public var plannedSeconds: Double
    /// Time the timer ran, pauses excluded.
    public var focusedSeconds: Double
    /// False when skipped or stopped before its time was up.
    public var completed: Bool
    public var categoryID: Int64?
    public var rating: SessionRating
    public var note: String?

    public static let databaseTableName = "sessions"

    enum CodingKeys: String, CodingKey {
        case id, completed, rating, note
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case plannedSeconds = "planned_seconds"
        case focusedSeconds = "focused_seconds"
        case categoryID = "category_id"
    }

    public init(id: Int64? = nil, startedAt: Date, endedAt: Date, plannedSeconds: Double, focusedSeconds: Double,
                completed: Bool, categoryID: Int64? = nil, rating: SessionRating = .neutral, note: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedSeconds = plannedSeconds
        self.focusedSeconds = focusedSeconds
        self.completed = completed
        self.categoryID = categoryID
        self.rating = rating
        self.note = note
    }

    public init(_ finished: FinishedFocus) {
        self.init(startedAt: finished.startedAt, endedAt: finished.endedAt, plannedSeconds: finished.plannedSeconds,
                  focusedSeconds: finished.focusedSeconds, completed: finished.completed,
                  categoryID: finished.categoryID)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Empty or blank notes are stored as no note.
    public static func cleaned(note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: History, grouped

/// One day of focus sessions, for the history list. Pure.
public struct SessionDay: Sendable, Equatable, Identifiable {
    /// Midnight at the start of the day.
    public var day: Date
    /// Newest first.
    public var sessions: [FocusSession]

    public var id: Date { day }
    public var focusedSeconds: TimeInterval { sessions.reduce(0) { $0 + $1.focusedSeconds } }
    public var completedCount: Int { sessions.filter(\.completed).count }

    public func count(_ rating: SessionRating) -> Int { sessions.filter { $0.rating == rating }.count }

    /// Share of the day's focus time in sessions rated "focused", 0...1.
    public var focusedShare: Double {
        let total = focusedSeconds
        guard total > 0 else { return 0 }
        return sessions.filter { $0.rating == .focused }.reduce(0) { $0 + $1.focusedSeconds } / total
    }

    /// Sessions grouped by the day they started, newest day first.
    public static func group(_ sessions: [FocusSession], calendar: Calendar = .current) -> [SessionDay] {
        Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startedAt) }
            .map { SessionDay(day: $0.key, sessions: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }
}

// MARK: Store

extension UsageStore {

    // MARK: Categories

    /// Categories in their display order. Hidden (removed) ones only on request.
    public func sessionCategories(includingArchived: Bool = false) throws -> [SessionCategory] {
        try db.read { db in
            var request = SessionCategory.order(Column("sort_order"), Column("id"))
            if !includingArchived { request = request.filter(Column("is_archived") == false) }
            return try request.fetchAll(db)
        }
    }

    /// Adds a category (no id yet, placed last) or updates one.
    @discardableResult
    public func save(_ category: SessionCategory) throws -> SessionCategory {
        try db.write { db in
            var row = category
            row.name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if row.id == nil {
                let last = try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM session_categories") ?? -1
                row.sortOrder = last + 1
                try row.insert(db)
            } else {
                try row.update(db)
            }
            return row
        }
    }

    /// Removes a category from the choices. If sessions use it, it is only
    /// hidden, so the history still shows it; otherwise it is deleted.
    public func removeCategory(id: Int64) throws {
        try db.write { db in
            let used = try FocusSession.filter(Column("category_id") == id).fetchCount(db) > 0
            if used {
                try db.execute(sql: "UPDATE session_categories SET is_archived = 1 WHERE id = ?", arguments: [id])
            } else {
                _ = try SessionCategory.deleteOne(db, key: id)
            }
        }
    }

    // MARK: Sessions

    /// Stores a finished focus session, unrated.
    @discardableResult
    public func record(_ finished: FinishedFocus) throws -> FocusSession {
        try db.write { db in
            var row = FocusSession(finished)
            try row.insert(db)
            return row
        }
    }

    /// Rating, note and category can all be changed afterwards.
    public func updateSession(id: Int64, rating: SessionRating, note: String?, categoryID: Int64?) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE sessions SET rating = ?, note = ?, category_id = ? WHERE id = ?",
                           arguments: [rating.rawValue, FocusSession.cleaned(note: note), categoryID, id])
        }
    }

    public func deleteSession(id: Int64) throws {
        try db.write { db in _ = try FocusSession.deleteOne(db, key: id) }
    }

    /// Focus sessions that started at or after `date`, newest first.
    public func focusSessions(since date: Date) throws -> [FocusSession] {
        try db.read { db in
            try FocusSession
                .filter(Column("kind") == "focus" && Column("started_at") >= date)
                .order(Column("started_at").desc)
                .fetchAll(db)
        }
    }
}
