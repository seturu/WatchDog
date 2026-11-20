import Foundation
import Testing
@testable import WatchDogCore

/// The built-in pomodoro timer's state machine.
struct PomodoroMachineTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let classic = BuiltInTimerSettings.standard
    let auto = BuiltInTimerSettings(autoStartBreaks: true, autoStartFocus: true)

    /// `seconds` after the start, on both clocks.
    func at(_ seconds: Double) -> TimerMoment {
        TimerMoment(counter: 10_000 + seconds, date: t0.addingTimeInterval(seconds))
    }

    func started(_ settings: BuiltInTimerSettings? = nil) -> PomodoroMachine {
        var machine = PomodoroMachine()
        _ = machine.start(at: at(0), settings: settings ?? classic)
        return machine
    }

    func focusEnded(_ events: [PomodoroEvent]) -> FinishedFocus? {
        for case .focusEnded(let finished) in events { return finished }
        return nil
    }

    // MARK: Defaults

    @Test func defaultsAreTwentyFiveFiveFifteenEveryFour() {
        #expect(classic.seconds(for: .focus) == 1500)
        #expect(classic.seconds(for: .shortBreak) == 300)
        #expect(classic.seconds(for: .longBreak) == 900)
        #expect(classic.roundLength == 4)
        #expect(!classic.autoStartBreaks && !classic.autoStartFocus)
        // The rhythm is the same type a "Pomodoro it" rule uses, so the earn ratio applies.
        #expect(abs(classic.rhythm.earnRatio - 0.3) < 1e-9)
    }

    @Test func lengthsAreNeverShorterThanAMinute() {
        var settings = classic
        settings.rhythm.focusMinutes = 0
        settings.rhythm.longBreakEvery = 0
        #expect(settings.seconds(for: .focus) == 60)
        #expect(settings.roundLength == 1)
    }

    // MARK: A focus session

    @Test func startingRunsAFocusSessionThatRulesSeeAsFocus() {
        var machine = PomodoroMachine()
        #expect(machine.timerState == .none)
        #expect(machine.reading(at: at(0)) == .none)
        let events = machine.start(at: at(0), settings: classic)
        #expect(events == [.started(.focus, automatically: false)])
        #expect(machine.isRunning)
        #expect(machine.timerState == .focus)
        #expect(machine.remaining(at: at(60)) == 1440)

        let reading = machine.reading(at: at(60), title: "Writing")
        #expect(reading.state == .focus)
        #expect(reading.title == "Writing")
        #expect(reading.remainingSeconds == 1440)
        #expect(reading.durationSeconds == 1500)
        #expect(!reading.isPaused)
    }

    @Test func aFocusSessionEndsOnTimeAndIsRecordedAsCompleted() {
        var machine = started()
        machine.setCategory(7)
        #expect(machine.tick(at: at(1499), settings: classic).isEmpty)
        let events = machine.tick(at: at(1502), settings: classic)
        let finished = focusEnded(events)
        #expect(finished?.completed == true)
        #expect(finished?.focusedSeconds == 1500)
        #expect(finished?.startedAt == t0)
        #expect(finished?.endedAt == t0.addingTimeInterval(1500))   // when it ran out, not when noticed
        #expect(finished?.categoryID == 7)
        // Without auto-start it waits, offering the break; rules see no timer.
        #expect(machine.isIdle)
        #expect(machine.phase == .shortBreak)
        #expect(machine.completedInRound == 1)
        #expect(machine.timerState == .none)
    }

    @Test func autoStartRunsTheBreakFromTheMomentFocusEnded() {
        var machine = started(auto)
        let events = machine.tick(at: at(1503), settings: auto)
        #expect(events.contains(.started(.shortBreak, automatically: true)))
        #expect(machine.phase == .shortBreak)
        #expect(machine.timerState == .onBreak)
        #expect(machine.remaining(at: at(1503)) == 297)              // no drift
        // ...and the next focus session after the break.
        let next = machine.tick(at: at(1800), settings: auto)
        #expect(next == [.breakEnded(.shortBreak, completed: true), .started(.focus, automatically: true)])
        #expect(machine.timerState == .focus)
    }

    @Test func autoStartCanBeOnForBreaksOnly() {
        let settings = BuiltInTimerSettings(autoStartBreaks: true, autoStartFocus: false)
        var machine = started(settings)
        _ = machine.tick(at: at(1500), settings: settings)
        #expect(machine.isRunning && machine.phase == .shortBreak)
        _ = machine.tick(at: at(1800), settings: settings)
        #expect(machine.isIdle && machine.phase == .focus)
    }

    // MARK: The long break

    @Test func theLongBreakComesAfterFourCompletedSessionsAndClosesTheRound() {
        var machine = started(auto)
        var clock = 0.0
        var breaks: [PomodoroPhase] = []
        for _ in 0..<4 {
            clock += 1500
            _ = machine.tick(at: at(clock), settings: auto)
            breaks.append(machine.phase)
            clock += auto.seconds(for: machine.phase)
            _ = machine.tick(at: at(clock), settings: auto)
        }
        #expect(breaks == [.shortBreak, .shortBreak, .shortBreak, .longBreak])
        #expect(machine.completedInRound == 0)          // the long break closed the round
        #expect(machine.phase == .focus && machine.isRunning)
    }

    @Test func aSkippedFocusSessionLeadsToABreakButDoesNotCountTowardTheLongOne() {
        var machine = started()
        let events = machine.skip(at: at(600), settings: classic)
        let finished = focusEnded(events)
        #expect(finished?.completed == false)
        #expect(finished?.focusedSeconds == 600)
        #expect(machine.phase == .shortBreak && machine.isIdle)
        #expect(machine.completedInRound == 0)
    }

    @Test func theRoundLengthIsSettable() {
        var settings = classic
        settings.rhythm.longBreakEvery = 2
        var machine = started(settings)
        _ = machine.tick(at: at(1500), settings: settings)
        #expect(machine.phase == .shortBreak)
        _ = machine.start(at: at(1500), settings: settings)
        _ = machine.skip(at: at(1600), settings: settings)            // skip the break
        _ = machine.start(at: at(1600), settings: settings)
        _ = machine.tick(at: at(3100), settings: settings)
        #expect(machine.phase == .longBreak)
    }

    @Test func skippingTheOfferedLongBreakAlsoClosesTheRound() {
        var settings = classic
        settings.rhythm.longBreakEvery = 1
        var machine = started(settings)
        _ = machine.tick(at: at(1500), settings: settings)
        #expect(machine.phase == .longBreak && machine.completedInRound == 1)
        #expect(machine.skip(at: at(1510), settings: settings).isEmpty)
        #expect(machine.phase == .focus && machine.isIdle && machine.completedInRound == 0)
    }

    // MARK: Pause, skip, stop

    @Test func pausedTimeDoesNotCount() {
        var machine = started()
        machine.pause(at: at(300))
        #expect(machine.isPaused)
        #expect(machine.tick(at: at(5000), settings: classic).isEmpty)   // an hour later, still paused
        #expect(machine.remaining(at: at(5000)) == 1200)
        machine.resume(at: at(5000))
        let finished = focusEnded(machine.tick(at: at(6200), settings: classic))
        #expect(finished?.focusedSeconds == 1500)
        #expect(finished?.endedAt == t0.addingTimeInterval(6200))
    }

    @Test func startResumesAPausedInterval() {
        var machine = started()
        machine.pause(at: at(100))
        #expect(machine.start(at: at(200), settings: classic).isEmpty)
        #expect(machine.isRunning)
        #expect(machine.remaining(at: at(200)) == 1400)
    }

    @Test func pausingNeverLoosensARule() {
        var focus = started()
        focus.pause(at: at(10))
        // A paused focus session still counts as focus...
        #expect(focus.timerState == .focus)
        #expect(focus.reading(at: at(10)).isPaused)

        var rest = started(BuiltInTimerSettings(autoStartBreaks: true))
        _ = rest.tick(at: at(1500), settings: BuiltInTimerSettings(autoStartBreaks: true))
        #expect(rest.timerState == .onBreak)
        rest.pause(at: at(1510))
        // ...and a paused break is no break: "only on my breaks" stops applying.
        #expect(rest.timerState == .none)
        #expect(rest.reading(at: at(1510)).shownInterval == .onBreak)
        #expect(!Rule.TimerCondition.duringBreak.allows(rest.timerState))
        #expect(Rule.TimerCondition.exceptDuringBreak.allows(rest.timerState))
    }

    @Test func stopEndsTheRoundAndKeepsTheSessionIfItRanAMinute() {
        var machine = started()
        _ = machine.tick(at: at(1500), settings: classic)
        _ = machine.start(at: at(1500), settings: classic)               // the break
        _ = machine.tick(at: at(1800), settings: classic)
        _ = machine.start(at: at(1800), settings: classic)               // focus session 2
        #expect(machine.completedInRound == 1)
        let finished = focusEnded(machine.stop(at: at(1800 + 400)))
        #expect(finished?.focusedSeconds == 400)
        #expect(finished?.completed == false)
        #expect(machine.isIdle && machine.phase == .focus && machine.completedInRound == 0)
    }

    @Test func aSessionShorterThanAMinuteIsNotKept() {
        var stopped = started()
        #expect(stopped.stop(at: at(59)).isEmpty)
        var skipped = started()
        #expect(focusEnded(skipped.skip(at: at(30), settings: classic)) == nil)
        #expect(skipped.phase == .shortBreak)
    }

    // MARK: Trusted time

    @Test func changingTheSystemDateDoesNotMoveTheTimer() {
        var machine = started()
        // The wall clock jumps a day ahead, but only a minute passes on the counter.
        let jumped = TimerMoment(counter: 10_060, date: t0.addingTimeInterval(86_400))
        #expect(machine.tick(at: jumped, settings: classic).isEmpty)
        #expect(machine.remaining(at: jumped) == 1440)
    }

    @Test func afterSleepTheNextIntervalWaitsInsteadOfRunningUnattended() {
        var machine = started(auto)
        // The Mac slept through the end of the session; two hours on the counter.
        let events = machine.tick(at: at(7200), settings: auto)
        #expect(focusEnded(events)?.endedAt == t0.addingTimeInterval(1500))
        #expect(!events.contains { if case .started = $0 { true } else { false } })
        #expect(machine.isIdle && machine.phase == .shortBreak)
    }

    @Test func aRestartOfTheAppCarriesOn() {
        var machine = started()
        machine.checkpoint(at: at(100), bootID: "boot-1")
        #expect(machine.restore(bootID: "boot-1", at: at(400)).isEmpty)
        #expect(machine.isRunning)
        #expect(machine.remaining(at: at(400)) == 1100)
    }

    @Test func aRestartOfTheMacPausesFocusAtTheLastSave() {
        var machine = started()
        machine.checkpoint(at: at(600), bootID: "boot-1")
        // New boot: the counter starts again near zero.
        let afterBoot = TimerMoment(counter: 30, date: t0.addingTimeInterval(4000))
        #expect(machine.restore(bootID: "boot-2", at: afterBoot).isEmpty)
        #expect(machine.isPaused)
        #expect(machine.remaining(at: afterBoot) == 900)
        machine.resume(at: afterBoot)
        #expect(machine.remaining(at: TimerMoment(counter: 130, date: afterBoot.date)) == 800)
    }

    @Test func aRestartOfTheMacEndsABreak() {
        var machine = started(BuiltInTimerSettings(autoStartBreaks: true))
        _ = machine.tick(at: at(1500), settings: BuiltInTimerSettings(autoStartBreaks: true))
        machine.checkpoint(at: at(1560), bootID: "boot-1")
        let events = machine.restore(bootID: "boot-2", at: TimerMoment(counter: 20, date: t0))
        #expect(events == [.breakEnded(.shortBreak, completed: false)])
        #expect(machine.isIdle && machine.phase == .focus)
        #expect(machine.completedInRound == 1)
    }

    // MARK: On disk

    @Test func theTimerFileRoundTripsAndToleratesMissingParts() throws {
        var file = TimerFile(sourceID: TimerSources.builtInID,
                             settings: BuiltInTimerSettings(rhythm: PomodoroSettings(focusMinutes: 50), autoStartBreaks: true))
        file.machine = started()
        file.machine.checkpoint(at: at(10), bootID: "boot-1")
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("timer-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try file.save(path: path)
        #expect(TimerFile.load(path: path) == file)

        // A file from an older version, or a damaged part, falls back part by part.
        let partial = #"{"sourceID":"session","settings":{"autoStartFocus":true},"machine":{"bogus":1}}"#
        let decoded = try JSONDecoder().decode(TimerFile.self, from: Data(partial.utf8))
        #expect(decoded.sourceID == "session")
        #expect(decoded.settings.autoStartFocus)
        #expect(decoded.settings.rhythm == .classic)
        #expect(decoded.machine == PomodoroMachine())
        #expect(TimerFile.load(path: path + ".missing") == TimerFile())
    }
}
