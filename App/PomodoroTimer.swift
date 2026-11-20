import AppKit
import Observation
import WatchDogCore

/// The pomodoro timer as the app sees it: which source is chosen, and the
/// timer built into WatchDog.
///
/// The tracker reads this object (it is the tracker's `timerSource`), so
/// whichever source is selected feeds the `timer_state` stored on spans, and
/// with it the "Pomodoro timer" rule condition and "Pomodoro it" budgets.
///
/// The built-in timer itself is the pure `PomodoroMachine`. This class ticks
/// it once a second while it runs, saves it, stores finished focus sessions,
/// posts a notification when an interval ends, and holds the categories and
/// recent history for the Focus screen and the popover.
@MainActor
@Observable
final class PomodoroTimer: TimerSource {
    private(set) var machine: PomodoroMachine
    /// Lengths and auto-start. Changes apply from the next interval.
    var settings: BuiltInTimerSettings {
        didSet { if settings != oldValue { save() } }
    }
    /// `TimerSources.builtInID` or an external app's `sourceID`.
    private(set) var sourceID: String
    /// Categories on offer, in order.
    private(set) var categories: [SessionCategory] = []
    /// Every category ever made, removed ones included, so history can name them.
    private(set) var categoryByID: [Int64: SessionCategory] = [:]
    /// Focus sessions of the last `historyDays` days, newest first.
    private(set) var sessions: [FocusSession] = []
    /// The focus session that just ended, waiting for a rating. Cleared when
    /// the next focus session starts; it can still be edited in the history.
    private(set) var review: FocusSession?
    private(set) var error: String?

    static let historyDays = 60

    var usesBuiltIn: Bool { sourceID == TimerSources.builtInID }
    var externalApp: (any ExternalTimerApp)? { TimerSources.external(id: sourceID) }
    var selectedCategory: SessionCategory? { machine.categoryID.flatMap { categoryByID[$0] } }

    /// Called after every change of state, so the tracker samples at once.
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored private let store: UsageStore
    @ObservationIgnored private let clock: @MainActor () -> TrustedClock
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let path = TimerFile.defaultPath()
    @ObservationIgnored private let bootID = TrustedClock.bootSessionID()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var lastSaved = 0.0
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    /// `clock` returns the clock the tracker stamps activity with, which is
    /// the daemon's once it is known.
    init(store: UsageStore, clock: @escaping @MainActor () -> TrustedClock, notifier: Notifier) {
        self.store = store
        self.clock = clock
        self.notifier = notifier
        let file = TimerFile.load(path: path)
        machine = file.machine
        settings = file.settings
        sourceID = file.sourceID ?? TimerSources.defaultID
        reloadCategories()
        reloadSessions()
    }

    /// Catches up with anything that happened while the app was closed, then
    /// keeps the timer ticking.
    func startTicking() {
        let now = clock().moment()
        let restored = machine.restore(bootID: bootID, at: now)
        handle(restored, notify: false)
        let caughtUp = machine.tick(at: now, settings: settings)
        handle(caughtUp, notify: false)
        save()
        updateTicker()
        // Timers do not fire during sleep; look again on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: TimerSource

    /// The selected source's reading. This is what the tracker stores.
    func read() -> TimerReading {
        guard usesBuiltIn else { return externalApp?.read() ?? .none }
        return machine.reading(at: clock().moment(), title: selectedCategory?.name)
    }

    /// Seconds left in the built-in timer's interval, read live.
    func remaining() -> Double { machine.remaining(at: clock().moment()) }

    /// The timer as the widgets show it. `external` is the tracker's latest
    /// reading of the external app, used when that app is the source.
    func widgetTimer(external: TimerReading) -> WidgetTimer {
        guard usesBuiltIn else {
            return WidgetTimer(external: external, appName: externalApp?.name ?? "Another app")
        }
        return WidgetTimer(machine: machine, settings: settings, category: selectedCategory,
                           moment: clock().moment(), now: Date())
    }

    // MARK: Controls

    func startOrResume() { step { $0.start(at: $1, settings: settings) } }
    func pause() { step { $0.pause(at: $1); return [] } }
    func resume() { step { $0.resume(at: $1); return [] } }
    func skip() { step { $0.skip(at: $1, settings: settings) } }
    func stop() { step { machine, now in machine.stop(at: now) } }

    /// The category of the running focus session, or of the next one.
    func setCategory(_ id: Int64?) {
        step { $0.setCategory(id); _ = $1; return [] }
    }

    /// Switching away from the built-in timer stops it (keeping a focus
    /// session that ran long enough), so no hidden timer keeps running.
    func selectSource(_ id: String) {
        guard id != sourceID else { return }
        if sourceID == TimerSources.builtInID && !machine.isIdle {
            step { machine, now in machine.stop(at: now) }
        }
        sourceID = id
        save()
        onChange()
    }

    // MARK: Rating and editing

    /// Sets a session's rating and note, keeping its category. Does nothing
    /// if neither changed, or if the session is gone.
    func rate(_ id: Int64, rating: SessionRating, note: String?) {
        guard let current = sessions.first(where: { $0.id == id }) ?? (review?.id == id ? review : nil) else { return }
        guard current.rating != rating || current.note != FocusSession.cleaned(note: note) else { return }
        update(id: id, rating: rating, note: note, categoryID: current.categoryID)
    }

    func dismissReview() { review = nil }

    func update(id: Int64, rating: SessionRating, note: String?, categoryID: Int64?) {
        perform {
            try store.updateSession(id: id, rating: rating, note: note, categoryID: categoryID)
        }
        reloadSessions()
        if review?.id == id { review = sessions.first { $0.id == id } }
    }

    func delete(_ session: FocusSession) {
        guard let id = session.id else { return }
        perform { try store.deleteSession(id: id) }
        if review?.id == id { review = nil }
        reloadSessions()
    }

    // MARK: Categories

    func addCategory() {
        let used = Set(categories.map(\.color))
        let color = CategoryColor.allCases.first { !used.contains($0) } ?? .blue
        perform { try store.save(SessionCategory(name: "New category", color: color)) }
        reloadCategories()
    }

    func updateCategory(_ category: SessionCategory) {
        guard !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform { try store.save(category) }
        reloadCategories()
    }

    func removeCategory(_ category: SessionCategory) {
        guard let id = category.id else { return }
        perform { try store.removeCategory(id: id) }
        if machine.categoryID == id { setCategory(nil) }
        reloadCategories()
    }

    // MARK: Inner workings

    /// Runs one step of the machine at the trusted time, then acts on it.
    private func step(_ change: (inout PomodoroMachine, TimerMoment) -> [PomodoroEvent]) {
        let now = clock().moment()
        var next = machine
        let events = change(&next, now)
        let changed = next != machine
        machine = next
        handle(events, notify: false)
        save()
        updateTicker()
        if changed { onChange() }
    }

    private func tick() {
        let now = clock().moment()
        var next = machine
        let events = next.tick(at: now, settings: settings)
        guard !events.isEmpty else {
            // Save now and then, so a restart of the Mac resumes close to here.
            if now.counter - lastSaved >= 15 { save() }
            return
        }
        machine = next
        handle(events, notify: true)
        save()
        updateTicker()
        onChange()
    }

    private func handle(_ events: [PomodoroEvent], notify: Bool) {
        for event in events {
            switch event {
            case .focusEnded(let finished):
                do {
                    review = try store.record(finished)
                    error = nil
                } catch {
                    self.error = "Could not save the session: \(error.localizedDescription)"
                }
                reloadSessions()
            case .started(.focus, _):
                review = nil
            case .started, .breakEnded:
                break
            }
        }
        if notify { postNotification(for: events) }
    }

    /// One notification per interval that ran out, saying what happens next.
    private func postNotification(for events: [PomodoroEvent]) {
        let autoStarted = events.contains { if case .started = $0 { true } else { false } }
        for event in events {
            switch event {
            case .focusEnded(let finished) where finished.completed:
                let length = "\(Int(settings.seconds(for: machine.phase) / 60))-minute"
                let kind = machine.phase == .longBreak ? "long break" : "break"
                notifier.post(title: "Focus session done",
                              body: autoStarted ? "Your \(length) \(kind) has started. How did it go?"
                                                : "Start your \(length) \(kind) when you are ready.")
            case .breakEnded(_, completed: true):
                notifier.post(title: "Break over",
                              body: autoStarted ? "The next focus session has started."
                                                : "Start the next focus session when you are ready.")
            default:
                break
            }
        }
    }

    private func save() {
        let now = clock().moment()
        machine.checkpoint(at: now, bootID: bootID)
        lastSaved = now.counter
        perform { try TimerFile(sourceID: sourceID, settings: settings, machine: machine).save(path: path) }
    }

    /// A one-second timer, only while an interval runs.
    private func updateTicker() {
        if machine.isRunning && usesBuiltIn {
            guard ticker == nil else { return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func reloadCategories() {
        perform {
            let all = try store.sessionCategories(includingArchived: true)
            categories = all.filter { !$0.isArchived }
            categoryByID = Dictionary(uniqueKeysWithValues: all.compactMap { c in c.id.map { ($0, c) } })
        }
    }

    private func reloadSessions() {
        let since = Calendar.current.date(byAdding: .day, value: -Self.historyDays, to: Date()) ?? .distantPast
        perform { sessions = try store.focusSessions(since: since) }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            self.error = "\(error.localizedDescription)"
        }
    }
}
