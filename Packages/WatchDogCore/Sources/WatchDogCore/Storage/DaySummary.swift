import Foundation

/// Everything the dashboard shows about one day, computed from that day's spans.
/// Pure: no database, no clock. Spans are clipped to the day.
public struct DaySummary: Sendable, Equatable {
    /// At the keyboard.
    public var active: TimeInterval = 0
    public var away: TimeInterval = 0
    /// At the keyboard while the pomodoro timer was on a focus interval.
    public var focus: TimeInterval = 0
    /// At the keyboard while the pomodoro timer was on a break.
    public var onBreak: TimeInterval = 0
    public var apps: [UsageTotal] = []
    public var sites: [UsageTotal] = []
    /// Active time per hour and series, for the stacked chart. Only the
    /// busiest apps get their own series; the rest are folded into "Other".
    public var hours: [HourSlice] = []
    /// Chart series in drawing order (busiest first, "Other" last if present).
    public var series: [String] = []

    public struct HourSlice: Sendable, Equatable, Identifiable {
        public var hour: Int          // 0...23, local time
        public var series: String     // app name, or "Other"
        public var seconds: TimeInterval
        public var id: String { "\(hour)-\(series)" }
    }

    public static let otherSeries = "Other"
    public static let empty = DaySummary()

    public init() {}

    public init(spans: [Span], day: DateInterval, calendar: Calendar = .current, topApps: Int = 5) {
        var appSeconds: [String: (label: String, seconds: TimeInterval)] = [:]
        var siteSeconds: [String: TimeInterval] = [:]
        var hourly: [Int: [String: TimeInterval]] = [:]   // hour -> bundle ID -> seconds

        for span in spans {
            let start = max(span.startedAt, day.start)
            let end = min(span.endedAt, day.end)
            let seconds = end.timeIntervalSince(start)
            guard seconds > 0 else { continue }

            if span.isIdle { away += seconds; continue }
            active += seconds
            if span.timerState == .focus { focus += seconds }
            if span.timerState == .onBreak { onBreak += seconds }

            appSeconds[span.bundleID, default: (span.appName, 0)].seconds += seconds
            if let domain = span.domain { siteSeconds[domain, default: 0] += seconds }

            // A span can cross one or more hour boundaries; give each hour its share.
            var cursor = start
            while cursor < end {
                let hour = calendar.component(.hour, from: cursor)
                let nextHour = calendar.dateInterval(of: .hour, for: cursor)?.end ?? end
                let pieceEnd = min(nextHour, end)
                hourly[hour, default: [:]][span.bundleID, default: 0] += pieceEnd.timeIntervalSince(cursor)
                cursor = pieceEnd
            }
        }

        apps = appSeconds
            .map { UsageTotal(key: $0.key, label: $0.value.label, seconds: $0.value.seconds) }
            .filter { $0.seconds >= 1 }
            .sorted { ($0.seconds, $1.key) > ($1.seconds, $0.key) }
        sites = siteSeconds
            .map { UsageTotal(key: $0.key, label: $0.key, seconds: $0.value) }
            .filter { $0.seconds >= 1 }
            .sorted { ($0.seconds, $1.key) > ($1.seconds, $0.key) }

        let top = Array(apps.prefix(topApps))
        let labels = Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.label) })
        var hasOther = false
        for hour in hourly.keys.sorted() {
            var perSeries: [String: TimeInterval] = [:]
            for (bundleID, seconds) in hourly[hour] ?? [:] {
                if let label = labels[bundleID] {
                    perSeries[label, default: 0] += seconds
                } else {
                    perSeries[Self.otherSeries, default: 0] += seconds
                    hasOther = true
                }
            }
            for (name, seconds) in perSeries.sorted(by: { $0.key < $1.key }) where seconds >= 1 {
                hours.append(HourSlice(hour: hour, series: name, seconds: seconds))
            }
        }
        series = top.map(\.label) + (hasOther ? [Self.otherSeries] : [])
    }
}

extension UsageStore {
    /// The summary for the day containing `date`.
    public func summary(for date: Date = Date(), calendar: Calendar = .current) throws -> DaySummary {
        let start = calendar.startOfDay(for: date)
        let day = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
        return DaySummary(spans: try spans(since: day.start), day: day, calendar: calendar)
    }
}
