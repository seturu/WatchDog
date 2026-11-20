import Foundation
import WatchDogCore
import WidgetKit

/// Feeds the desktop and Notification Center widgets, and carries out their
/// buttons.
///
/// The widget extension is sandboxed and never opens the usage database.
/// Instead this writes a small `WidgetSnapshot` (focus and break totals, the
/// break budget, the timer) to the shared App Group container: at once when
/// the timer changes, and every minute otherwise. A widget button leaves a
/// `WidgetCommand` there and posts a Darwin notification; the command is
/// checked by `WidgetCommandPolicy` and carried out with the same calls as
/// the Focus screen's buttons, so a widget can do nothing the Focus screen
/// cannot, and nothing beyond the built-in timer.
///
/// WidgetKit limits how often an app may redraw its widgets, so they are
/// redrawn only when the timer changes or a command was handled. The widgets
/// fetch the day's totals themselves every 15 minutes.
@MainActor
final class WidgetBridge {
    private let channel: WidgetChannel
    private let pomodoro: PomodoroTimer
    private let tracker: Tracker
    private let rules: RuleRunner

    private var signal: Int32?
    private var published: WidgetSnapshot?
    private var lastWrite = Date.distantPast
    /// Set while commands are carried out, so their timer changes are
    /// published once, with the receipts.
    private var handlingCommands = false
    /// IDs of the latest commands handled, so none is carried out twice.
    private var handled: [UUID] = []
    /// The six days before today, worked out once an hour.
    private var earlier: [FocusTally] = []
    private var earlierWorkedOut = Date.distantPast
    private var earlierFor: Date?

    /// Nil when this build has no App Group (no signing team).
    init?(pomodoro: PomodoroTimer, tracker: Tracker, rules: RuleRunner) {
        guard let channel = WidgetChannel.shared() else { return nil }
        self.channel = channel
        self.pomodoro = pomodoro
        self.tracker = tracker
        self.rules = rules
    }

    func start() {
        signal = WidgetSignal.observe { [weak self] in
            MainActor.assumeIsolated { self?.takeCommands() }
        }
        // Presses made while the app was not running are dropped (they are
        // stale by now, and the widget took them back).
        _ = channel.takeCommands()
        workOutEarlierDays()
        publish()
    }

    /// After every stored sample (about every 2 s). An external timer
    /// changes without telling anyone, so its state is compared here.
    func sampleArrived() {
        // A command's timer change makes the tracker sample at once; the
        // command's own publish covers it.
        guard !handlingCommands else { return }
        takeCommands()
        let timer = currentTimer()
        let moved = published.map { !timer.shows(sameAs: $0.timer) } ?? true
        if moved || Date().timeIntervalSince(lastWrite) >= WidgetSnapshot.refreshInterval { publish() }
    }

    /// The built-in timer changed (a button, an interval running out).
    func timerChanged() {
        guard !handlingCommands else { return }
        publish()
    }

    // MARK: Commands

    private func takeCommands() {
        let commands = channel.takeCommands()
        guard !commands.isEmpty else { return }
        handlingCommands = true
        let receipts = WidgetCommandPolicy.run(commands, now: Date(), handled: Set(handled),
                                               current: { currentTimer() }, apply: perform)
        handlingCommands = false
        handled = Array((handled + commands.map(\.id)).suffix(64))
        publish(adding: receipts)
    }

    /// Exactly what the Focus screen's buttons call.
    private func perform(_ action: WidgetAction) {
        switch action {
        case .start: pomodoro.startOrResume()
        case .pause: pomodoro.pause()
        case .resume: pomodoro.resume()
        case .skip: pomodoro.skip()
        case .stop: pomodoro.stop()
        }
    }

    // MARK: Publishing

    private func currentTimer() -> WidgetTimer {
        pomodoro.widgetTimer(external: tracker.focusTimer)
    }

    private func publish(adding receipts: [WidgetCommandReceipt] = []) {
        let now = Date()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let day = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
        if earlierFor != start || now.timeIntervalSince(earlierWorkedOut) >= 3600 { workOutEarlierDays() }

        let spans = (try? tracker.store.spans(since: start)) ?? []
        let today = FocusTally(spans: spans, day: day)
        let snapshot = WidgetSnapshot.make(at: now, timer: currentTimer(), today: today, earlier: earlier,
                                           budget: budget(), rhythm: pomodoro.settings.rhythm,
                                           receipts: published?.receipts ?? [], newReceipts: receipts)
        if let published, snapshot.looksLike(published),
           now.timeIntervalSince(lastWrite) < WidgetSnapshot.refreshInterval { return }
        do {
            try channel.write(snapshot)
        } catch {
            return
        }
        // After a long silence (sleep, a stalled app) a widget may be showing
        // "WatchDog is not running": redraw it too.
        let silent = now.timeIntervalSince(lastWrite) > WidgetSnapshot.staleAfter
        lastWrite = now
        let redraw = silent || published.map {
            !snapshot.timer.shows(sameAs: $0.timer) || snapshot.receipts != $0.receipts
        } ?? true
        published = snapshot
        if redraw { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// The first enabled "Pomodoro it" rule's budget, as the rest of the app shows it.
    private func budget() -> (status: RuleEngine.PomodoroStatus, ruleName: String)? {
        for rule in rules.effective.rules where rule.isEnabled && rule.mode == .pomodoro {
            if let status = rules.budgets[rule.id] { return (status, rule.name) }
        }
        return nil
    }

    /// Up to a week of spans is read away from the main thread, once an hour.
    private func workOutEarlierDays() {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        earlierWorkedOut = now
        earlierFor = today
        guard let since = calendar.date(byAdding: .day, value: -6, to: today) else { return }
        let store = tracker.store
        Task.detached(priority: .utility) {
            let spans = (try? store.spans(since: since)) ?? []
            let days = Array(FocusTally.days(7, endingOn: now, spans: spans, calendar: calendar).dropLast())
            await MainActor.run { [weak self] in
                guard let self, self.earlierFor == today else { return }
                self.earlier = days
            }
        }
    }
}
