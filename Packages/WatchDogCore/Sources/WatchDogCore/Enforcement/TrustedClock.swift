import Foundation

/// The time of day, as rule schedules should see it.
///
/// A block's countdown never looks at the wall clock, but a schedule
/// ("weekdays 09:00 to 19:00") has to. That makes "set the clock to 20:00" or
/// "switch to a time zone where it is evening" an obvious dodge.
///
/// This clock remembers the wall time and time zone at start, then measures
/// elapsed time on a counter the user cannot set (it also runs during sleep).
/// If the wall clock later disagrees with "start + elapsed" by more than
/// ordinary drift, the clock was changed: schedules keep running on the
/// original timeline, and the change is reported. Undoing the change clears it.
public struct TrustedClock: Sendable {
    private let anchorWall: Date
    private let anchorContinuous: Double
    /// The zone schedules are read in, fixed at start.
    public let timeZone: TimeZone

    /// Seconds on the non-settable counter. Same clock the daemon's block timer uses.
    public static func continuousSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    public init(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds(),
                timeZone: TimeZone = .current) {
        anchorWall = wall
        anchorContinuous = continuous
        self.timeZone = timeZone
    }

    public struct Reading: Sendable, Equatable {
        /// The time to use for schedules and for stamping activity.
        public var now: Date
        /// A calendar in the pinned time zone.
        public var calendar: Calendar
        public var clockChanged: Bool
        public var zoneChanged: Bool
        public var isTampered: Bool { clockChanged || zoneChanged }
    }

    /// How far the wall clock may stray from the counter before it counts as
    /// a change: 30 s, plus 0.05% of the time elapsed (network time
    /// corrections and oscillator drift are far smaller than that).
    static func tolerance(elapsed: Double) -> Double { 30 + abs(elapsed) * 0.0005 }

    public func read(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds(),
                     timeZone current: TimeZone = .current) -> Reading {
        let elapsed = continuous - anchorContinuous
        let expected = anchorWall.addingTimeInterval(elapsed)
        let clockChanged = abs(wall.timeIntervalSince(expected)) > Self.tolerance(elapsed: elapsed)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return Reading(now: clockChanged ? expected : wall, calendar: calendar,
                       clockChanged: clockChanged,
                       zoneChanged: current.identifier != timeZone.identifier)
    }
}
