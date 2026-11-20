import Foundation
import Testing
@testable import WatchDogCore

struct TrustedClockTests {
    let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// Tuesday 17 November 2026, 10:00 in São Paulo (13:00 UTC): inside work hours.
    var start: Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 13))!
    }

    var clock: TrustedClock { TrustedClock(wall: start, continuous: 1000, timeZone: saoPaulo) }

    let workHours = Schedule(isAlways: false, weekdays: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 19 * 60)

    @Test func anHonestClockPassesStraightThrough() {
        let later = start.addingTimeInterval(3600)
        let reading = clock.read(wall: later, continuous: 4600, timeZone: saoPaulo)
        #expect(reading.now == later)
        #expect(!reading.isTampered)
    }

    @Test func ordinaryDriftAndTimeSyncAreNotTampering() {
        // 20 s off after an hour; 4 minutes off after a week (0.04%).
        #expect(!clock.read(wall: start.addingTimeInterval(3620), continuous: 4600, timeZone: saoPaulo).clockChanged)
        let week = 7.0 * 86_400
        #expect(!clock.read(wall: start.addingTimeInterval(week + 240), continuous: 1000 + week, timeZone: saoPaulo).clockChanged)
    }

    @Test func settingTheClockForwardDoesNotEndWorkHours() {
        // One minute in, the user sets the clock ten hours ahead (to 20:01).
        let faked = start.addingTimeInterval(60 + 10 * 3600)
        let reading = clock.read(wall: faked, continuous: 1060, timeZone: saoPaulo)
        #expect(reading.clockChanged)
        #expect(reading.now == start.addingTimeInterval(60))
        #expect(!workHours.contains(faked, calendar: reading.calendar))          // what the dodge hoped for
        #expect(workHours.contains(reading.now, calendar: reading.calendar))     // what the rules see
    }

    @Test func settingTheClockBackIsAlsoCaughtAndUndoingItClearsTheFlag() {
        let back = clock.read(wall: start.addingTimeInterval(60 - 6 * 3600), continuous: 1060, timeZone: saoPaulo)
        #expect(back.clockChanged && back.now == start.addingTimeInterval(60))
        let undone = clock.read(wall: start.addingTimeInterval(120), continuous: 1120, timeZone: saoPaulo)
        #expect(!undone.isTampered)
    }

    @Test func timeAsleepCountsAsElapsedNotAsAJump() {
        // Lid closed for 8 hours: both the wall clock and the counter moved on.
        let reading = clock.read(wall: start.addingTimeInterval(8 * 3600), continuous: 1000 + 8 * 3600, timeZone: saoPaulo)
        #expect(!reading.isTampered)
    }

    @Test func changingTheTimeZoneDoesNotMoveTheSchedule() {
        // Same instant, but the Mac now claims to be in Tokyo (22:00 there).
        let reading = clock.read(wall: start, continuous: 1000, timeZone: tokyo)
        #expect(reading.zoneChanged && !reading.clockChanged)
        #expect(reading.calendar.timeZone == saoPaulo)
        #expect(workHours.contains(reading.now, calendar: reading.calendar))

        var tokyoCalendar = Calendar(identifier: .gregorian)
        tokyoCalendar.timeZone = tokyo
        #expect(!workHours.contains(start, calendar: tokyoCalendar))             // the dodge, had we followed the system
    }

    @Test func aSleepThatOutlastsABlockEndsIt() {
        // The daemon's countdown uses the same counter: an 8-hour sleep is 8 hours.
        var block = BlockState(domains: ["example.com"], seconds: 3600)
        block.advance(by: 8 * 3600)
        #expect(block.isExpired)
    }
}
