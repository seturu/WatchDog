import Foundation
import Testing
@testable import WatchDogCore

/// What the app publishes for the widgets, and how widget buttons are handled.
struct WidgetTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    var midnight: Date { utc.date(from: DateComponents(year: 2026, month: 11, day: 19))! }
    var day: DateInterval { DateInterval(start: midnight, duration: 86_400) }

    func span(_ startMinute: Double, _ minutes: Double, idle: Bool = false, timer: TimerState) -> Span {
        Span(id: nil, startedAt: midnight.addingTimeInterval(startMinute * 60),
             endedAt: midnight.addingTimeInterval((startMinute + minutes) * 60),
             bundleID: "id.app", appName: "App", windowTitle: "secret title", url: "https://example.com/secret",
             domain: "example.com", isIdle: idle, timerState: timer)
    }

    // Machine helpers, as in PomodoroMachineTests.
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let classic = BuiltInTimerSettings.standard
    func at(_ seconds: Double) -> TimerMoment {
        TimerMoment(counter: 10_000 + seconds, date: t0.addingTimeInterval(seconds))
    }
    /// The system clock the widget counts down on: deliberately not the trusted one.
    let wall = Date(timeIntervalSince1970: 1_900_000_000)

    func timer(_ machine: PomodoroMachine, _ seconds: Double = 0, category: SessionCategory? = nil) -> WidgetTimer {
        WidgetTimer(machine: machine, settings: classic, category: category, moment: at(seconds),
                    now: wall.addingTimeInterval(seconds))
    }

    // MARK: Day totals

    @Test func focusIsAtTheKeyboardButBreaksIncludeTimeAway() {
        let tally = FocusTally(spans: [
            span(540, 25, timer: .focus),
            span(565, 2, timer: .onBreak),
            span(567, 3, idle: true, timer: .onBreak),
            span(570, 10, idle: true, timer: .focus),     // away during focus: not focus
            span(580, 20, timer: .none),
        ], day: day)
        #expect(tally.day == midnight)
        #expect(tally.focusSeconds == 25 * 60)
        #expect(tally.breakSeconds == 5 * 60)
        #expect(tally.focusIntervals == 2)               // the break separates them; away time still counts as an interval
        #expect(tally.breaks == 1)
    }

    @Test func breaksAndFocusIntervalsAreCountedAsSeparateRuns() {
        let tally = FocusTally(spans: [
            span(540, 25, timer: .focus),
            span(565, 5, timer: .onBreak),
            span(570, 25, timer: .focus),
            span(595, 5, timer: .onBreak),
            span(600, 25, timer: .focus),
            span(625, 15, timer: .onBreak),
        ], day: day)
        #expect(tally.focusIntervals == 3)
        #expect(tally.breaks == 3)
        #expect(tally.breakSeconds == 25 * 60)
        #expect(tally.focusSeconds == 75 * 60)
    }

    @Test func aShortPauseInsideABreakIsStillOneBreak() {
        // A paused break reads as no timer.
        let short = FocusTally(spans: [
            span(600, 3, timer: .onBreak),
            span(603, 2, timer: .none),
            span(605, 3, timer: .onBreak),
        ], day: day)
        #expect(short.breaks == 1)
        #expect(short.breakSeconds == 6 * 60)

        // Over five minutes apart: two breaks.
        let long = FocusTally(spans: [
            span(600, 3, timer: .onBreak),
            span(603, 6, timer: .none),
            span(609, 3, timer: .onBreak),
        ], day: day)
        #expect(long.breaks == 2)

        // A hole in the history (app closed) works the same way.
        let hole = FocusTally(spans: [span(600, 3, timer: .onBreak), span(604, 3, timer: .onBreak)], day: day)
        #expect(hole.breaks == 1)
    }

    @Test func spansAreClippedToTheDayAndBackwardsSpansCountForNothing() {
        let crossing = Span(id: nil, startedAt: midnight.addingTimeInterval(-600), endedAt: midnight.addingTimeInterval(600),
                            bundleID: "a", appName: "A", isIdle: false, timerState: .focus)
        let backwards = Span(id: nil, startedAt: midnight.addingTimeInterval(4000), endedAt: midnight.addingTimeInterval(3000),
                             bundleID: "a", appName: "A", isIdle: false, timerState: .onBreak)
        let tally = FocusTally(spans: [crossing, backwards], day: day)
        #expect(tally.focusSeconds == 600)
        #expect(tally.breakSeconds == 0)
        #expect(tally.breaks == 0)
    }

    @Test func daysGivesOneTallyPerDayOldestFirst() {
        let yesterday = Span(id: nil, startedAt: midnight.addingTimeInterval(-3600), endedAt: midnight.addingTimeInterval(-1800),
                             bundleID: "a", appName: "A", isIdle: false, timerState: .focus)
        let tallies = FocusTally.days(3, endingOn: midnight.addingTimeInterval(3600), spans: [yesterday, span(60, 10, timer: .focus)],
                                      calendar: utc)
        #expect(tallies.map(\.day) == [midnight.addingTimeInterval(-2 * 86_400), midnight.addingTimeInterval(-86_400), midnight])
        #expect(tallies.map(\.focusSeconds) == [0, 1800, 600])
    }

    // MARK: Breaks earned

    @Test func breaksEarnedComeFromThePomodoroRuleWhenThereIsOne() {
        let status = RuleEngine.PomodoroStatus(earned: 1800, used: 600, sitting: 0, onBreak: true, denial: nil)
        let snapshot = WidgetSnapshot.make(at: wall, timer: timer(PomodoroMachine()), today: FocusTally(day: midnight),
                                           earlier: [], budget: (status, "YouTube"), rhythm: .classic, receipts: [])
        #expect(snapshot.breaksEarned == WidgetBreaks(earnedSeconds: 1800, usedSeconds: 600, ruleName: "YouTube"))
        #expect(snapshot.breaksEarned.remainingSeconds == 1200)
    }

    @Test func withoutARuleBreaksEarnedFollowTheTimersRhythm() {
        let today = FocusTally(day: midnight, focusSeconds: 3600)
        let snapshot = WidgetSnapshot.make(at: wall, timer: timer(PomodoroMachine()), today: today, earlier: [],
                                           budget: nil, rhythm: .classic, receipts: [])
        #expect(abs(snapshot.breaksEarned.earnedSeconds - 18 * 60) < 1e-6)   // 25/5/15 every 4: 18 min an hour
        #expect(snapshot.breaksEarned.usedSeconds == nil)
        #expect(snapshot.breaksEarned.remainingSeconds == nil)
    }

    // MARK: The timer

    @Test func theButtonsAreTheFocusScreens() {
        var machine = PomodoroMachine()
        #expect(WidgetAction.available(for: machine) == [.start])
        _ = machine.start(at: at(0), settings: classic)
        #expect(WidgetAction.available(for: machine) == [.pause, .skip, .stop])
        machine.pause(at: at(10))
        #expect(WidgetAction.available(for: machine) == [.resume, .skip, .stop])
        _ = machine.skip(at: at(20), settings: classic)       // a short break is on offer
        #expect(machine.isIdle && machine.phase == .shortBreak)
        #expect(WidgetAction.available(for: machine) == [.start, .skip])
    }

    @Test func anIdleTimerOffersTheNextIntervalsLength() {
        let shown = timer(PomodoroMachine())
        #expect(shown.isBuiltIn && shown.status == .idle)
        #expect(shown.interval == .focus && shown.phase == .focus)
        #expect(shown.remainingSeconds == 1500 && shown.plannedSeconds == 1500)
        #expect(shown.endsAt == nil)
        #expect(shown.roundLength == 4 && shown.completedInRound == 0)
    }

    @Test func aRunningTimerCountsDownOnTheSystemClock() {
        var machine = PomodoroMachine()
        _ = machine.start(at: at(0), settings: classic)
        let shown = timer(machine, 100)
        #expect(shown.status == .running)
        // 1400 s left, from the widget's clock, whatever the trusted clock says.
        #expect(shown.endsAt == wall.addingTimeInterval(100 + 1400))
        #expect(shown.remainingSeconds == nil)
        #expect(shown.plannedSeconds == 1500)
    }

    @Test func aPausedTimerShowsTheTimeLeftFrozen() {
        var machine = PomodoroMachine()
        _ = machine.start(at: at(0), settings: classic)
        machine.pause(at: at(300))
        let shown = timer(machine, 900)
        #expect(shown.status == .paused)
        #expect(shown.remainingSeconds == 1200)
        #expect(shown.endsAt == nil)
    }

    @Test func theCategoryIsShownForFocusOnly() {
        let writing = SessionCategory(id: 1, name: "Writing", color: .teal)
        var machine = PomodoroMachine()
        machine.setCategory(1)
        #expect(timer(machine, category: writing).categoryName == "Writing")
        #expect(timer(machine, category: writing).categoryColor == .teal)
        _ = machine.start(at: at(0), settings: classic)
        _ = machine.skip(at: at(120), settings: classic)
        #expect(timer(machine, 120, category: writing).categoryName == nil)
    }

    @Test func theTokenChangesWhenTheTimerMovesOn() {
        var machine = PomodoroMachine()
        let idle = WidgetTimer.token(for: machine)
        _ = machine.start(at: at(0), settings: classic)
        let running = WidgetTimer.token(for: machine)
        machine.pause(at: at(10))
        let paused = WidgetTimer.token(for: machine)
        machine.resume(at: at(20))
        #expect(Set([idle, running, paused]).count == 3)
        #expect(WidgetTimer.token(for: machine) == running)   // resumed: the same interval again
        _ = machine.stop(at: at(30))
        #expect(WidgetTimer.token(for: machine) == idle)
    }

    @Test func anExternalTimerIsShownButCannotBeControlled() {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let reading = TimerReading(state: .onBreak, title: nil, project: "Work", startedAt: start, durationSeconds: 300)
        let shown = WidgetTimer(external: reading, appName: "Session")
        #expect(!shown.isBuiltIn && shown.sourceName == "Session")
        #expect(shown.status == .running && shown.interval == .onBreak)
        #expect(shown.endsAt == start.addingTimeInterval(300))
        #expect(shown.categoryName == "Work")
        #expect(shown.actions.isEmpty)

        let off = WidgetTimer(external: .none, appName: "Session")
        #expect(off.status == .idle && off.interval == .none && off.endsAt == nil)
    }

    // MARK: Commands

    func command(_ action: WidgetAction, for shown: WidgetTimer, at date: Date? = nil) -> WidgetCommand {
        WidgetCommand(action: action, token: shown.token, issuedAt: date ?? wall)
    }

    @Test func aFreshPressOfAnOfferedButtonIsCarriedOut() {
        let shown = timer(PomodoroMachine())
        #expect(WidgetCommandPolicy.decide(command(.start, for: shown), timer: shown, now: wall.addingTimeInterval(1))
                == .apply(.start))
    }

    @Test func aLatePressIsDropped() {
        let shown = timer(PomodoroMachine())
        let pressed = command(.start, for: shown)
        #expect(WidgetCommandPolicy.decide(pressed, timer: shown, now: wall.addingTimeInterval(31)) == .refuse(.expired))
        // A press dated in the future (clock changed) is not kept for later either.
        #expect(WidgetCommandPolicy.decide(pressed, timer: shown, now: wall.addingTimeInterval(-31)) == .refuse(.expired))
    }

    @Test func anExternalTimerRefusesEveryCommand() {
        let shown = WidgetTimer(external: .none, appName: "Session")
        for action in WidgetAction.allCases {
            #expect(WidgetCommandPolicy.decide(command(action, for: shown), timer: shown, now: wall) == .refuse(.notBuiltIn))
        }
    }

    @Test func aPressForATimerThatMovedOnIsRefused() {
        var machine = PomodoroMachine()
        _ = machine.start(at: at(0), settings: classic)
        let drawn = timer(machine)
        // The session ran out and the break started on its own before the press arrived.
        _ = machine.tick(at: at(1500), settings: BuiltInTimerSettings(autoStartBreaks: true))
        #expect(machine.phase == .shortBreak && machine.isRunning)
        #expect(WidgetCommandPolicy.decide(command(.skip, for: drawn), timer: timer(machine, 1500), now: wall)
                == .refuse(.timerMoved))
    }

    @Test func onlyWhatTheFocusScreenOffersIsAllowed() {
        let idle = timer(PomodoroMachine())
        for action in [WidgetAction.pause, .resume, .skip, .stop] {
            #expect(WidgetCommandPolicy.decide(command(action, for: idle), timer: idle, now: wall) == .refuse(.notOffered))
        }
    }

    @Test func runAppliesInOrderAndASecondPressFindsTheTimerMoved() {
        var machine = PomodoroMachine()
        _ = machine.start(at: at(0), settings: classic)
        let drawn = timer(machine)
        let first = command(.pause, for: drawn)
        let second = WidgetCommand(action: .pause, token: drawn.token, issuedAt: wall.addingTimeInterval(0.5))
        var applied: [WidgetAction] = []
        let receipts = WidgetCommandPolicy.run([first, second], now: wall.addingTimeInterval(1), handled: [],
                                               current: { timer(machine) },
                                               apply: { action in
                                                   applied.append(action)
                                                   if action == .pause { machine.pause(at: at(1)) }
                                               })
        #expect(applied == [.pause])
        #expect(receipts.map(\.applied) == [true, false])
        #expect(receipts.last?.reason == WidgetCommandPolicy.Refusal.timerMoved.rawValue)
    }

    @Test func runSkipsCommandsAlreadyHandled() {
        let shown = timer(PomodoroMachine())
        let pressed = command(.start, for: shown)
        var applied = 0
        let receipts = WidgetCommandPolicy.run([pressed, pressed], now: wall, handled: [], current: { shown },
                                               apply: { _ in applied += 1 })
        #expect(applied == 1 && receipts.count == 1)
        let again = WidgetCommandPolicy.run([pressed], now: wall, handled: [pressed.id], current: { shown },
                                            apply: { _ in applied += 1 })
        #expect(applied == 1 && again.isEmpty)
    }

    // MARK: The snapshot

    func snapshot(_ shown: WidgetTimer, writtenAt: Date? = nil) -> WidgetSnapshot {
        WidgetSnapshot(writtenAt: writtenAt ?? wall, timer: shown, today: FocusTally(day: midnight),
                       breaksEarned: WidgetBreaks(earnedSeconds: 0))
    }

    @Test func aSnapshotNotRewrittenForThreeMinutesMeansTheAppIsNotRunning() {
        let written = snapshot(timer(PomodoroMachine()))
        #expect(!written.isStale(at: wall.addingTimeInterval(179)))
        #expect(written.isStale(at: wall.addingTimeInterval(181)))
        #expect(written.isStale(at: wall.addingTimeInterval(-181)))
    }

    @Test func anIntervalDrawnPastItsEndShowsAsEndedWithoutButtons() {
        var machine = PomodoroMachine()
        _ = machine.start(at: at(0), settings: classic)
        let written = snapshot(timer(machine))
        let end = wall.addingTimeInterval(1500)
        #expect(written.timer(at: end.addingTimeInterval(-1)).status == .running)
        let after = written.timer(at: end)
        #expect(after.status == .ended && after.actions.isEmpty && after.remainingSeconds == 0)
    }

    @Test func widgetsRefreshSoonAfterTheIntervalEndsAndEveryFifteenMinutes() {
        var machine = PomodoroMachine()
        #expect(snapshot(timer(machine)).nextRefresh(after: wall) == wall.addingTimeInterval(900))
        _ = machine.start(at: at(0), settings: classic)
        let running = snapshot(timer(machine))
        #expect(running.nextRefresh(after: wall.addingTimeInterval(1000)) == wall.addingTimeInterval(1502))
        #expect(running.nextRefresh(after: wall) == wall.addingTimeInterval(900))
    }

    @Test func rewritingTheSameStateIsNotAChange() {
        var machine = PomodoroMachine()
        _ = machine.start(at: at(0), settings: classic)
        let first = snapshot(timer(machine))
        // Ten seconds later: same end time (to within a second), new write time.
        var later = snapshot(timer(machine, 10), writtenAt: wall.addingTimeInterval(10))
        later.timer.endsAt = later.timer.endsAt?.addingTimeInterval(0.4)
        #expect(later.looksLike(first))
        machine.pause(at: at(20))
        #expect(!snapshot(timer(machine, 20)).looksLike(first))
        // New totals are a change too.
        var busier = first
        busier.today.focusSeconds += 60
        #expect(!busier.looksLike(first))
    }

    @Test func aCountdownWorkedOutAfreshIsTheSameTimer() {
        var machine = PomodoroMachine()
        _ = machine.start(at: at(0), settings: classic)
        let drawn = timer(machine)
        var again = timer(machine, 30)
        #expect(again.shows(sameAs: drawn))
        again.endsAt = again.endsAt?.addingTimeInterval(2)      // the system clock was moved
        #expect(!again.shows(sameAs: drawn))
        machine.pause(at: at(40))
        #expect(!timer(machine, 40).shows(sameAs: drawn))
    }

    @Test func receiptsKeepTheLatestEight() {
        let old = (0..<7).map { WidgetCommandReceipt(id: UUID(), applied: true, at: wall.addingTimeInterval(Double($0))) }
        let new = (0..<3).map { WidgetCommandReceipt(id: UUID(), applied: false, at: wall.addingTimeInterval(10 + Double($0))) }
        let made = WidgetSnapshot.make(at: wall, timer: timer(PomodoroMachine()), today: FocusTally(day: midnight),
                                       earlier: [], budget: nil, rhythm: .classic, receipts: old, newReceipts: new)
        #expect(made.receipts == Array((old + new).suffix(8)))
        #expect(made.receipt(for: new[2].id) == new[2])
        #expect(made.receipt(for: old[0].id) == nil)
    }

    @Test func theSnapshotCarriesNoActivityDetails() throws {
        let today = FocusTally(spans: [span(540, 25, timer: .focus)], day: day)
        let made = WidgetSnapshot.make(at: wall, timer: timer(PomodoroMachine()), today: today, earlier: [],
                                       budget: nil, rhythm: .classic, receipts: [])
        let json = String(decoding: try JSONEncoder().encode(made), as: UTF8.self)
        #expect(!json.contains("secret") && !json.contains("example.com") && !json.contains("id.app"))
    }

    // MARK: Files

    func temporaryChannel() throws -> (WidgetChannel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (WidgetChannel(container: root), root)
    }

    @Test func theSnapshotRoundTripsThroughTheContainer() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(channel.readSnapshot() == nil)
        var machine = PomodoroMachine()
        _ = machine.start(at: at(0), settings: classic)
        let written = snapshot(timer(machine))
        try channel.write(written)
        #expect(channel.readSnapshot() == written)
    }

    @Test func aSnapshotFromAnotherVersionIsIgnored() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        var future = snapshot(timer(PomodoroMachine()))
        future.version = WidgetSnapshot.currentVersion + 1
        try channel.write(future)
        #expect(channel.readSnapshot() == nil)
    }

    @Test func commandsAreTakenOnceOldestFirst() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let shown = timer(PomodoroMachine())
        let later = command(.start, for: shown, at: wall.addingTimeInterval(2))
        let earlier = command(.skip, for: shown, at: wall)
        try channel.send(later)
        try channel.send(earlier)
        #expect(channel.takeCommands() == [earlier, later])
        #expect(channel.takeCommands().isEmpty)
    }

    @Test func aWithdrawnCommandIsNotTaken() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let pressed = command(.start, for: timer(PomodoroMachine()))
        try channel.send(pressed)
        channel.withdraw(pressed.id)
        #expect(channel.takeCommands().isEmpty)
    }

    @Test func filesThatAreNotCommandsAreRemovedAndIgnored() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let pressed = command(.start, for: timer(PomodoroMachine()))
        try channel.send(pressed)
        let folder = channel.commandsFolder
        try Data("not json".utf8).write(to: folder.appendingPathComponent("junk.json"))
        try Data(repeating: 32, count: 10_000).write(to: folder.appendingPathComponent("\(UUID().uuidString).json"))
        // A valid command under another command's name.
        let copied = try Data(contentsOf: folder.appendingPathComponent("\(pressed.id.uuidString).json"))
        try copied.write(to: folder.appendingPathComponent("\(UUID().uuidString).json"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir.json"), withIntermediateDirectories: true)
        #expect(channel.takeCommands() == [pressed])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func aFloodOfCommandsKeepsOnlyTheLatest() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let shown = timer(PomodoroMachine())
        let pressed = (0..<12).map { command(.start, for: shown, at: wall.addingTimeInterval(Double($0))) }
        for c in pressed { try channel.send(c) }
        #expect(channel.takeCommands() == Array(pressed.suffix(8)))
        #expect(channel.takeCommands().isEmpty)
    }

    @Test func aLinkedFolderIsNeverUsed() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        // Someone replaces the commands folder with a link to a folder of their choosing.
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let precious = elsewhere.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: precious)
        try FileManager.default.createDirectory(at: channel.folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: channel.commandsFolder, withDestinationURL: elsewhere)
        #expect(channel.takeCommands().isEmpty)
        #expect(FileManager.default.fileExists(atPath: precious.path))
        #expect(throws: (any Error).self) { try channel.send(command(.start, for: timer(PomodoroMachine()))) }

        // The same for the channel's own folder.
        let (other, otherRoot) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try FileManager.default.createSymbolicLink(at: other.folder, withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try other.write(snapshot(timer(PomodoroMachine()))) }
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("snapshot.json").path))
    }

    // MARK: The App Group

    @Test func theAppGroupIsTheTeamAndThisBuildsBundleID() {
        #expect(WD.isAppGroup("ABCDE12345.\(WD.appBundleID)"))
        #expect(!WD.isAppGroup("group.\(WD.appBundleID)"))
        #expect(!WD.isAppGroup(".\(WD.appBundleID)"))                       // a build without a team
        #expect(!WD.isAppGroup("abcde12345.\(WD.appBundleID)"))
        #expect(!WD.isAppGroup("ABCDE12345.\(WD.appBundleID).other"))
        #expect(!WD.isAppGroup("ABCDE12345.local.watchdog.something"))
    }
}
