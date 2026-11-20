import Foundation

// MARK: Time

/// A moment as the built-in timer sees it.
public struct TimerMoment: Sendable, Equatable {
    /// Seconds on the trusted clock's counter. Nobody can set it and it keeps
    /// counting during sleep, so it alone decides how long an interval ran.
    /// Changing the system date or time zone has no effect on it.
    public var counter: Double
    /// Trusted time of day. Only used to stamp sessions in the history.
    public var date: Date

    public init(counter: Double, date: Date) {
        self.counter = counter
        self.date = date
    }
}

extension TrustedClock {
    /// The counter and the trusted time of day, read together.
    public func moment() -> TimerMoment {
        let counter = Self.continuousSeconds()
        return TimerMoment(counter: counter, date: read(continuous: counter).now)
    }

    /// Changes at every boot, which is when the counter starts again from zero.
    public static func bootSessionID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: Settings

/// One interval of the built-in timer.
public enum PomodoroPhase: String, Codable, Sendable, CaseIterable {
    case focus
    case shortBreak = "short_break"
    case longBreak = "long_break"

    public var isBreak: Bool { self != .focus }
    /// What rules see while this interval runs.
    public var timerState: TimerState { isBreak ? .onBreak : .focus }
}

/// How the built-in timer runs. The lengths reuse `PomodoroSettings`, the
/// same four numbers a "Pomodoro it" rule has.
public struct BuiltInTimerSettings: Codable, Sendable, Equatable {
    /// Focus, short break, long break, and focus sessions until the long break.
    public var rhythm: PomodoroSettings
    /// Start the break as soon as a focus session ends.
    public var autoStartBreaks: Bool
    /// Start the next focus session as soon as a break ends.
    public var autoStartFocus: Bool

    public init(rhythm: PomodoroSettings = .classic, autoStartBreaks: Bool = false, autoStartFocus: Bool = false) {
        self.rhythm = rhythm
        self.autoStartBreaks = autoStartBreaks
        self.autoStartFocus = autoStartFocus
    }

    public static let standard = BuiltInTimerSettings()

    /// Length of an interval, in seconds. Never less than a minute.
    public func seconds(for phase: PomodoroPhase) -> Double {
        let minutes = switch phase {
        case .focus: rhythm.focusMinutes
        case .shortBreak: rhythm.shortBreakMinutes
        case .longBreak: rhythm.longBreakMinutes
        }
        return Double(max(1, minutes) * 60)
    }

    /// Focus sessions in a round (at least one).
    public var roundLength: Int { max(1, rhythm.longBreakEvery) }

    // Written by hand so a settings file from an older version still loads.
    enum CodingKeys: String, CodingKey { case rhythm, autoStartBreaks, autoStartFocus }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rhythm = (try? c.decodeIfPresent(PomodoroSettings.self, forKey: .rhythm)) ?? .classic
        autoStartBreaks = (try? c.decodeIfPresent(Bool.self, forKey: .autoStartBreaks)) ?? false
        autoStartFocus = (try? c.decodeIfPresent(Bool.self, forKey: .autoStartFocus)) ?? false
    }
}

// MARK: The machine

/// A focus session that has ended and belongs in the history.
public struct FinishedFocus: Sendable, Equatable {
    public var startedAt: Date
    public var endedAt: Date
    public var plannedSeconds: Double
    /// Time the timer actually ran, pauses excluded.
    public var focusedSeconds: Double
    /// False when it was skipped or stopped before its time was up.
    public var completed: Bool
    public var categoryID: Int64?

    public init(startedAt: Date, endedAt: Date, plannedSeconds: Double, focusedSeconds: Double,
                completed: Bool, categoryID: Int64?) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedSeconds = plannedSeconds
        self.focusedSeconds = focusedSeconds
        self.completed = completed
        self.categoryID = categoryID
    }
}

/// What a step of the machine did, for the app to act on (store a session,
/// show a notification, ask for a rating).
public enum PomodoroEvent: Sendable, Equatable {
    case focusEnded(FinishedFocus)
    case breakEnded(PomodoroPhase, completed: Bool)
    case started(PomodoroPhase, automatically: Bool)
}

/// The built-in pomodoro timer. Pure logic: it is handed the time, touches
/// nothing, and is fully unit-tested.
///
/// - Time is measured on the trusted clock's counter (`TimerMoment.counter`),
///   so changing the system date cannot shorten or stretch an interval.
/// - Pausing never loosens a rule: a paused focus session still counts as
///   focus, and a paused break counts as no timer at all.
/// - Only focus sessions that run their full length count toward the long
///   break. Skipping a focus session still leads to a (short) break.
/// - Stop ends the round: the next start is focus session 1 again.
/// - An interval only starts on its own if the previous one ended moments
///   ago. After sleep, or while the app was closed, the timer waits for you
///   instead of running sessions nobody was there for.
public struct PomodoroMachine: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case idle, running, paused }

    /// A focus session that is skipped or stopped before this is not kept.
    public static let minimumRecordedSeconds: Double = 60
    /// How late an interval may be noticed to have ended for the next one to
    /// still start on its own.
    public static let autoStartGrace: Double = 60

    public private(set) var status: Status = .idle
    /// The interval running or paused. When idle: the one Start begins.
    public private(set) var phase: PomodoroPhase = .focus
    /// Length of the interval in progress, fixed when it started.
    public private(set) var plannedSeconds: Double = 0
    /// Trusted time the interval began, for the history.
    public private(set) var phaseStartedAt: Date?
    /// Focus sessions run in full since the last long break.
    public private(set) var completedInRound = 0
    /// Category of the focus session in progress, or of the next one.
    public var categoryID: Int64?

    /// Seconds run before the current stretch (pauses excluded).
    private var banked: Double = 0
    /// Counter reading when the current stretch began. Nil unless running.
    private var runningSince: Double?
    /// How far the interval had run when last saved, and in which boot.
    private var checkpointElapsed: Double = 0
    private var bootID: String?

    public init() {}

    // MARK: Reading

    public var isIdle: Bool { status == .idle }
    public var isRunning: Bool { status == .running }
    public var isPaused: Bool { status == .paused }

    /// Seconds the interval has run, pauses excluded.
    public func elapsed(at now: TimerMoment) -> Double {
        banked + (runningSince.map { max(0, now.counter - $0) } ?? 0)
    }

    public func remaining(at now: TimerMoment) -> Double {
        max(0, plannedSeconds - elapsed(at: now))
    }

    /// What rules see.
    public var timerState: TimerState {
        switch status {
        case .idle: .none
        case .running: phase.timerState
        case .paused: phase.isBreak ? .none : .focus
        }
    }

    public func reading(at now: TimerMoment, title: String? = nil) -> TimerReading {
        guard status != .idle else { return .none }
        return TimerReading(state: timerState, title: title, startedAt: phaseStartedAt,
                            durationSeconds: Int(plannedSeconds), isPaused: status == .paused,
                            interval: phase.timerState, remainingSeconds: remaining(at: now))
    }

    // MARK: Controls

    /// Starts the interval on offer, or resumes a paused one.
    public mutating func start(at now: TimerMoment, settings: BuiltInTimerSettings) -> [PomodoroEvent] {
        switch status {
        case .running:
            return []
        case .paused:
            resume(at: now)
            return []
        case .idle:
            begin(phase, at: now, settings: settings)
            return [.started(phase, automatically: false)]
        }
    }

    public mutating func pause(at now: TimerMoment) {
        guard status == .running else { return }
        banked = elapsed(at: now)
        runningSince = nil
        status = .paused
    }

    public mutating func resume(at now: TimerMoment) {
        guard status == .paused else { return }
        runningSince = now.counter
        status = .running
    }

    /// Ends the interval now and moves on, exactly as if its time were up,
    /// except that a skipped focus session does not count toward the long
    /// break. When idle with a break on offer, skips that break.
    public mutating func skip(at now: TimerMoment, settings: BuiltInTimerSettings) -> [PomodoroEvent] {
        switch status {
        case .idle:
            guard phase.isBreak else { return [] }
            if phase == .longBreak { completedInRound = 0 }
            phase = .focus
            guard settings.autoStartFocus else { return [] }
            begin(.focus, at: now, settings: settings)
            return [.started(.focus, automatically: true)]
        case .running, .paused:
            return finish(completed: false, at: now, overrun: 0, settings: settings)
        }
    }

    /// Ends the interval and the round. The next start is a first focus session.
    public mutating func stop(at now: TimerMoment) -> [PomodoroEvent] {
        let events = status == .idle ? [] : endEvents(completed: false, at: now)
        goIdle(offering: .focus)
        completedInRound = 0
        return events
    }

    /// Ends the interval when its time is up. Call it every second or so
    /// while running, and on wake from sleep.
    public mutating func tick(at now: TimerMoment, settings: BuiltInTimerSettings) -> [PomodoroEvent] {
        guard status == .running else { return [] }
        let over = elapsed(at: now) - plannedSeconds
        guard over >= 0 else { return [] }
        // The moment it ran out, on both clocks.
        let end = TimerMoment(counter: now.counter - over, date: now.date.addingTimeInterval(-over))
        return finish(completed: true, at: end, overrun: over, settings: settings)
    }

    /// Changes the category of the focus session in progress (or the next one).
    public mutating func setCategory(_ id: Int64?) { categoryID = id }

    // MARK: Saving and restoring

    /// Notes how far the interval has run. Call before saving.
    public mutating func checkpoint(at now: TimerMoment, bootID: String) {
        checkpointElapsed = elapsed(at: now)
        self.bootID = bootID
    }

    /// Brings a saved machine up to date when the app starts. Within the same
    /// boot the counter has carried on, so nothing changes. After a restart of
    /// the Mac the counter began again from zero and the time the Mac was off
    /// is unknown: a focus session pauses where it was last saved, and a break
    /// is over (restarting must not be a way to get a longer break).
    public mutating func restore(bootID current: String, at now: TimerMoment) -> [PomodoroEvent] {
        guard status != .idle else {
            bootID = current
            return []
        }
        let sameBoot = !current.isEmpty && bootID == current && (runningSince.map { now.counter >= $0 } ?? true)
        if sameBoot { return [] }
        bootID = current
        if phase.isBreak {
            let ended = phase
            goIdle(offering: .focus)
            return [.breakEnded(ended, completed: false)]
        }
        banked = min(max(checkpointElapsed, status == .paused ? banked : 0), plannedSeconds)
        runningSince = nil
        status = .paused
        return []
    }

    // MARK: Steps

    private mutating func finish(completed: Bool, at end: TimerMoment, overrun: Double,
                                 settings: BuiltInTimerSettings) -> [PomodoroEvent] {
        var events = endEvents(completed: completed, at: end)
        let next: PomodoroPhase
        if phase == .focus {
            if completed { completedInRound += 1 }
            next = completedInRound >= settings.roundLength ? .longBreak : .shortBreak
        } else {
            next = .focus
        }
        let automatic = next == .focus ? settings.autoStartFocus : settings.autoStartBreaks
        if automatic && overrun <= Self.autoStartGrace {
            // Starts where the last one ended, so the rhythm does not drift.
            begin(next, at: end, settings: settings)
            events.append(.started(next, automatically: true))
        } else {
            goIdle(offering: next)
        }
        return events
    }

    /// What ending the current interval at `end` produces.
    private func endEvents(completed: Bool, at end: TimerMoment) -> [PomodoroEvent] {
        if phase.isBreak { return [.breakEnded(phase, completed: completed)] }
        let focused = min(elapsed(at: end), plannedSeconds)
        guard completed || focused >= Self.minimumRecordedSeconds, let started = phaseStartedAt else { return [] }
        return [.focusEnded(FinishedFocus(startedAt: started, endedAt: end.date, plannedSeconds: plannedSeconds,
                                          focusedSeconds: focused, completed: completed, categoryID: categoryID))]
    }

    private mutating func begin(_ next: PomodoroPhase, at moment: TimerMoment, settings: BuiltInTimerSettings) {
        // Taking the long break (or skipping it) closes the round.
        if next == .longBreak { completedInRound = 0 }
        phase = next
        status = .running
        plannedSeconds = settings.seconds(for: next)
        banked = 0
        runningSince = moment.counter
        phaseStartedAt = moment.date
        checkpointElapsed = 0
    }

    private mutating func goIdle(offering next: PomodoroPhase) {
        phase = next
        status = .idle
        plannedSeconds = 0
        banked = 0
        runningSince = nil
        phaseStartedAt = nil
        checkpointElapsed = 0
    }
}

// MARK: On disk

/// The timer source chosen, the built-in timer's settings, and its state.
/// Kept as timer.json in the app's private container (see `UserData`).
///
/// This file belongs to the user, like the timer itself: an external timer
/// app can be set to any lengths too. The rule that cannot be argued with is
/// "Pomodoro it", whose break budget is earned by focus time on the rule's
/// own rhythm, whichever timer runs.
public struct TimerFile: Codable, Sendable, Equatable {
    /// `TimerSources.builtInID` or an external app's `sourceID`. Nil until chosen.
    public var sourceID: String?
    public var settings: BuiltInTimerSettings
    public var machine: PomodoroMachine

    public init(sourceID: String? = nil, settings: BuiltInTimerSettings = .standard,
                machine: PomodoroMachine = PomodoroMachine()) {
        self.sourceID = sourceID
        self.settings = settings
        self.machine = machine
    }

    enum CodingKeys: String, CodingKey { case sourceID, settings, machine }

    /// Each part falls back to its default on its own, so one unreadable part
    /// (a newer version's timer state, say) does not lose the others.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try? c.decodeIfPresent(String.self, forKey: .sourceID)
        settings = (try? c.decodeIfPresent(BuiltInTimerSettings.self, forKey: .settings)) ?? .standard
        machine = (try? c.decodeIfPresent(PomodoroMachine.self, forKey: .machine)) ?? PomodoroMachine()
    }

    public static func defaultPath() -> String {
        UserData.folder.appendingPathComponent("timer.json").path
    }

    /// A missing or unreadable file gives the defaults.
    public static func load(path: String) -> TimerFile {
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(TimerFile.self, from: data) else { return TimerFile() }
        return file
    }

    public func save(path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
