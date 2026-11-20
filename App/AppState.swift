import AppKit
import WatchDogCore

/// Objects that live for the whole run of the app, independent of any window.
@MainActor
final class AppState {
    static let shared = AppState()

    let tracker: Tracker?
    let rules: RuleRunner?
    /// The timer source and the built-in pomodoro timer.
    let pomodoro: PomodoroTimer?
    /// Feeds the widgets and carries out their buttons. Nil without an App Group.
    let widgets: WidgetBridge?
    /// Set when the usage database could not be opened.
    let startupError: String?

    private init() {
        do {
            let store = try UsageStore(path: UsageStore.defaultPath(), key: DatabaseKey.forThisApp())
            let clock = TrustedClock()
            let tracker = Tracker(store: store, clock: clock)
            // The timer reads the tracker's clock, which becomes the daemon's
            // once it is known, so sessions and spans are stamped alike.
            let pomodoro = PomodoroTimer(store: store, clock: { [weak tracker] in tracker?.clock ?? clock },
                                         notifier: .shared)
            tracker.timerSource = pomodoro
            self.tracker = tracker
            self.pomodoro = pomodoro
            let rules = RuleRunner(store: store, clock: clock)
            self.rules = rules
            widgets = WidgetBridge(pomodoro: pomodoro, tracker: tracker, rules: rules)
            startupError = nil
        } catch {
            tracker = nil
            rules = nil
            pomodoro = nil
            widgets = nil
            startupError = "Could not open the usage database: \(error.localizedDescription)"
        }
    }
}

/// SwiftUI has no "app finished launching" hook, so the classic AppKit
/// delegate is used for that one job: start tracking as soon as the app is up,
/// whether or not any window is ever opened.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set when macOS announces logout, restart or shutdown.
    private var sessionIsEnding = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionIsEnding = true }
            // If we are still running a minute later, the logout was cancelled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                MainActor.assumeIsolated { self?.sessionIsEnding = false }
            }
        }
        // A cancelled logout leaves the session running: enforcement's quit
        // refusal applies again.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionIsEnding = false }
        }
        let state = AppState.shared
        // Every stored sample gives the rules a chance to fire.
        state.tracker?.onSample = { _ in
            state.rules?.sampleArrived()
            state.widgets?.sampleArrived()
        }
        // What the heartbeat tells the daemon about our ability to see.
        state.rules?.healthProvider = {
            AgentHealth(accessibilityGranted: state.tracker?.accessibilityGranted ?? false,
                        deniedBrowsers: (state.tracker?.browserAccess ?? [:]).filter { $0.value == .denied }.keys.sorted())
        }
        // Once the daemon's clock is known, the tracker stamps activity with it too.
        state.rules?.onTrustedClock = { clock in state.tracker?.adopt(clock: clock) }
        // What history keeps (Settings → History), and its expiry.
        state.tracker?.addressDetail = HistoryPrefs.addressDetail
        if let store = state.tracker?.store { HistoryPrefs.startPruning(store) }
        // A timer change is sampled at once, so spans split on the button press.
        state.pomodoro?.onChange = {
            state.tracker?.timerChanged()
            state.widgets?.timerChanged()
        }
        state.pomodoro?.startTicking()
        state.widgets?.start()
        state.tracker?.start()
        state.rules?.start()
    }

    /// True if the quit Apple event being handled comes from logout, restart
    /// or shutdown rather than from the user choosing Quit.
    private static func quitIsSessionEnding() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAERestart, kAEShutDown, kAEShowRestartDialog, kAEShowShutdownDialog]
            .contains(reason)
    }

    /// Opening the app while it is already running (Finder, Spotlight, Dock):
    /// macOS calls this on the running copy. Show the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            DistributedNotificationCenter.default().postNotificationName(
                .init(WD.showWindowNotification), object: nil, userInfo: nil, deliverImmediately: true)
        }
        return true
    }

    /// Quitting is how you would stop the watching, so it is refused while
    /// rules are being enforced. (Force-quitting restarts the app if "Start at
    /// login and keep running" is on, and the daemon notices the silence.)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Logging out or shutting down must always work: refusing here would
        // cancel it for the whole Mac. The daemon carries on across the restart.
        // The quit request itself says why it was sent, which is more reliable
        // than the order notifications happen to arrive in.
        if sessionIsEnding || Self.quitIsSessionEnding() { return .terminateNow }
        guard AppState.shared.rules?.isEnforcing == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "WatchDog is enforcing your rules"
        alert.informativeText = "It cannot be quit while enforcing. Switch to dry run first; that takes effect after the delay."
        alert.runModal()
        return .terminateCancel

    }
}

/// What usage history keeps, and for how long (Settings → History). Kept in
/// a file beside the history, in the app's private container, not in user
/// defaults: keeping less never loosens a rule (rules look back at most a
/// day, far below the shortest limits), but keeping more is a privacy
/// choice no other program should be able to make for you.
@MainActor
enum HistoryPrefs {
    static let defaultDetailDays = HistoryRetention.standard.detailDays ?? 0
    static let defaultHistoryDays = HistoryRetention.standard.historyDays ?? 0

    private static let url = HistorySettings.defaultURL()

    /// Read once per run. Edits go through `save`.
    private(set) static var current: HistorySettings = {
        if let stored = HistorySettings.load(from: url) { return stored }
        // First run of a version that keeps the settings here: take over what
        // the user chose before, but never more detail than "cleaned". The
        // old values sat where any program could have changed them.
        let old = UserDefaults.standard
        var settings = HistorySettings()
        if let detail = old.string(forKey: "history.addresses").flatMap(AddressDetail.init(rawValue:)) {
            settings.addresses = detail == .full ? .cleaned : detail
        }
        if let days = old.object(forKey: "history.detailDays") as? Int, days >= 0 { settings.detailDays = days }
        if let days = old.object(forKey: "history.historyDays") as? Int, days >= 0 { settings.historyDays = days }
        try? settings.save(to: url)
        for key in ["history.addresses", "history.detailDays", "history.historyDays"] { old.removeObject(forKey: key) }
        return settings
    }()

    static func save(_ settings: HistorySettings) {
        current = settings
        try? settings.save(to: url)
    }

    static var addressDetail: AddressDetail { current.addresses }

    /// Applies the limits and the address setting to stored history a minute
    /// after launch, then every six hours. The delay is deliberate: a setting
    /// picked by mistake and put back soon after has cost nothing.
    static func startPruning(_ store: UsageStore) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { MainActor.assumeIsolated { prune(store) } }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { _ in MainActor.assumeIsolated { prune(store) } }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Off the main thread; the store serialises it with the tracker's writes.
    private static func prune(_ store: UsageStore) {
        let retention = current.retention
        let addresses = current.addresses
        Task.detached(priority: .utility) {
            _ = try? store.applyAddressDetail(addresses)
            _ = try? store.prune(retention)
        }
    }
}

enum Format {
    /// Precise: 45 -> "45s", 190 -> "3m 10s", 3720 -> "1h 02m". For logs and limits.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }

    /// Glanceable: 45 -> "45s", 190 -> "3m", 3720 -> "1h 2m". For the dashboard.
    static func short(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let minutes = (s % 3600) / 60
        return minutes == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(minutes)m"
    }

    /// A running timer: 1499 -> "24:59", 3723 -> "1:02:03".
    static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// 540 -> "09:00"
    static func timeOfDay(minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }
}

enum SystemSettings {
    static func openAutomation() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    static func openNotifications() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    /// Shows the system dialog that leads to the Accessibility list.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
