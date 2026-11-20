import Foundation
import ServiceManagement
import UserNotifications
import WatchDogCore

/// Runs the rule engine against live tracking, and is the app's view of
/// what the daemon holds.
///
/// The rules and the enforcing switch are owned by the root daemon. This class
/// keeps two copies: `rules` is the draft you edit, `effective` is what is
/// actually in force. While enforcing, a draft that loosens anything sits as a
/// pending change until its delay runs out.
@MainActor
@Observable
final class RuleRunner {
    /// The draft, edited directly by the Rules screen; call `save()` after changes.
    var rules: [Rule]
    /// What is in force right now (from the daemon).
    private(set) var effective: DaemonConfig
    /// A loosening change waiting out its delay. Nil when there is none.
    private(set) var pending: PendingChange?
    /// The daemon's running block. Nil when none.
    private(set) var activeBlock: BlockState?
    /// Sites the daemon is blocking because this app was silent or blind.
    private(set) var penaltyDomains: [String] = []
    /// False when the daemon did not answer the last status request. Rules
    /// then run from the local copy, in dry run only.
    private(set) var daemonReachable = false
    /// The daemon's last answer to a change request, when it was not a plain "saved".
    private(set) var notice: String?

    /// Matching time counted toward each rule right now, by rule ID.
    private(set) var progress: [String: TimeInterval] = [:]
    /// Break budget of each "Pomodoro it" rule, by rule ID.
    private(set) var budgets: [String: RuleEngine.PomodoroStatus] = [:]
    private(set) var verdicts: [VerdictRecord] = []
    private(set) var error: String?

    var isEnforcing: Bool { effective.isEnforcing }
    /// The firewall layer as it will be once any pending change lands.
    var usesPacketFilter: Bool { (pending?.config ?? effective).packetFilterOn }
    /// True when enforcement is on but a switch back to dry run is counting down.
    var isEndingEnforcement: Bool { effective.isEnforcing && pending?.config.isEnforcing == false }

    /// Set by the app delegate: how to describe the tracker's health, and
    /// what to do with the daemon's trusted clock once it is known.
    var healthProvider: () -> AgentHealth = { AgentHealth(accessibilityGranted: true, deniedBrowsers: []) }
    var onTrustedClock: (TrustedClock) -> Void = { _ in }

    /// While enforcing, a closed tab that is reopened is closed again after
    /// this many seconds rather than after the rule's full quiet period.
    private let recloseSeconds: TimeInterval = 6
    private var lastNotified: [String: Date] = [:]

    private let store: UsageStore
    /// Shared with the tracker, so rules and recorded activity agree on the time.
    private var clock: TrustedClock
    private let path = RuleFile.defaultPath()
    private var lastFired: [String: Date]
    private var lastEvaluation = Date.distantPast
    private var saveTask: Task<Void, Never>?
    /// The draft as it was when it last agreed with the daemon. If the draft
    /// still equals this, you have not edited since, so it is safe to replace
    /// it when the daemon's rules change (a delayed change landing, say).
    private var syncedRules: [Rule] = []
    private var adoptedDaemonClock = false
    /// True once the daemon has answered at least once since launch.
    private var everConnected = false
    private let notifier = Notifier.shared
    private let heartbeat = HeartbeatSender()
    private var refreshTimer: Timer?
    /// The tail of the queue of change requests, so they reach the daemon one
    /// at a time and in the order they were made.
    private var submitChain: Task<Void, Never>?

    init(store: UsageStore, clock: TrustedClock) {
        self.store = store
        self.clock = clock
        // The local file is a cache: what to show, and what to run in dry run,
        // if the daemon cannot be reached.
        var cached: [Rule] = []
        do {
            cached = try RuleFile.load(path: path)
        } catch {
            self.error = "Could not read rules.json: \(error.localizedDescription)"
        }
        rules = cached
        syncedRules = cached
        effective = DaemonConfig(rules: cached, isEnforcing: false)
        lastFired = (try? store.lastFiredTimes()) ?? [:]
        verdicts = (try? store.recentVerdicts()) ?? []
    }

    func start() {
        notifier.requestPermission()
        heartbeat.start()
        // Status is pulled on a timer of its own, so it does not depend on
        // samples arriving or on rule evaluation succeeding.
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDaemonStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        Task { await connect() }
    }

    /// First contact with the daemon: take its clock and its rules. If it has
    /// never been given rules, hand it the local ones.
    private func connect() async {
        guard let status = await DaemonClient.status() else {
            daemonReachable = false
            return
        }
        if status.config == nil {
            _ = await DaemonClient.propose(DaemonConfig(rules: rules, isEnforcing: false))
        }
        await refresh()
        rules = pending?.config.rules ?? effective.rules
        syncedRules = rules
    }

    // MARK: Changing things

    /// Called on every edit in the Rules screen. Waits for a pause in typing,
    /// then asks the daemon to adopt the draft.
    func save() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            enqueue { runner in
                // Read the switches when this request's turn comes, after any
                // switch change queued before it has been answered.
                await runner.submit(isEnforcing: runner.pending?.config.isEnforcing ?? runner.effective.isEnforcing,
                                    packetFilter: runner.usesPacketFilter)
            }
        }
    }

    /// Runs change requests strictly one after another. Without this, an edit
    /// saved just as a switch is flipped could reach the daemon carrying the
    /// switch's old position, and quietly undo it.
    private func enqueue(_ work: @escaping @MainActor (RuleRunner) async -> Void) {
        let previous = submitChain
        submitChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// The Settings switch for the firewall layer. Switching it off while
    /// enforcing is a loosening change.
    func requestPacketFilter(_ on: Bool) {
        enqueue { runner in
            await runner.submit(isEnforcing: runner.pending?.config.isEnforcing ?? runner.effective.isEnforcing, packetFilter: on)
        }
    }

    /// The toolbar switch. Turning enforcement off is a loosening change.
    func requestEnforcing(_ on: Bool) {
        enqueue { runner in await runner.submit(isEnforcing: on, packetFilter: runner.usesPacketFilter) }
    }

    func discardPending() {
        saveTask?.cancel()
        enqueue { runner in
            await DaemonClient.cancelPending()
            await runner.refresh()
            runner.rules = runner.effective.rules
            runner.syncedRules = runner.rules
            runner.notice = nil
        }
    }

    private func submit(isEnforcing: Bool, packetFilter: Bool) async {
        try? RuleFile.save(rules, path: path)
        let proposed = DaemonConfig(rules: rules, isEnforcing: isEnforcing, usePacketFilter: packetFilter)
        guard let answer = await DaemonClient.propose(proposed) else {
            daemonReachable = false
            if everConnected {
                // A missed request changes nothing: what was in force stays in
                // force, and the draft is kept so it can be sent again.
                notice = "The background service did not answer, so this change is not saved yet. It is retried with your next edit."
            } else {
                // The daemon has never been reachable in this run (not
                // installed yet): the draft is simply the local dry-run rules.
                effective = DaemonConfig(rules: rules, isEnforcing: false)
            }
            return
        }
        switch answer.outcome {
        case "rejected":
            notice = answer.message
            await refresh()
            rules = effective.rules      // the edit did not happen
            syncedRules = rules
        default:
            notice = nil
            syncedRules = proposed.rules
            await refresh()
        }
    }

    /// Pulls the daemon's state and sends it a heartbeat.
    func refresh() async {
        // Hand the heartbeat sender a fresh description of what we can see.
        heartbeat.update(healthProvider())
        guard let status = await DaemonClient.status() else {
            daemonReachable = false
            return
        }
        daemonReachable = true
        everConnected = true
        activeBlock = status.block
        pending = status.pending
        penaltyDomains = status.penaltyDomains
        if let config = status.config, config != effective { effective = config }
        // Keep an untouched draft in step with the daemon.
        let target = pending?.config.rules ?? effective.rules
        if rules == syncedRules, target != rules {
            rules = target
            syncedRules = target
        }

        // Schedules run on the daemon's clock, which is pinned at boot and so
        // is not reset by restarting this app.
        if !adoptedDaemonClock {
            adoptedDaemonClock = true
            let zone = TimeZone(identifier: status.timeZoneID) ?? .current
            clock = TrustedClock(wall: status.trustedNow, timeZone: zone)
            onTrustedClock(clock)
        }
    }

    func refreshDaemonStatus() {
        Task {
            if everConnected { await refresh() } else { await connect() }
        }
    }

    // MARK: Removal

    /// Removes everything WatchDog installed. Returns nil on success, or the
    /// reason it did not happen (enforcing, a block running, daemon silent).
    func uninstall(deleteHistory: Bool) async -> String? {
        guard let answer = await DaemonClient.prepareUninstall() else {
            return "The background service did not answer, so nothing was removed. To remove WatchDog by hand, run scripts/uninstall.sh with sudo."
        }
        guard answer.done else { return answer.message }

        // The daemon has cleaned up after itself; now take it out of launchd.
        try? await SMAppService.daemon(plistName: WD.daemonPlistName).unregister()
        refreshTimer?.invalidate()
        if deleteHistory {
            try? FileManager.default.removeItem(at: UserData.folder)
            try? FileManager.default.removeItem(at: UserData.legacyFolder)
        }
        // Forget the privacy permissions macOS granted us.
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "All", WD.appBundleID]
        try? reset.run()
        reset.waitUntilExit()
        return nil
    }

    // MARK: Evaluation

    /// Called by the tracker after every stored sample (about every 2 s).
    func sampleArrived() {
        // Schedules are read on the trusted clock and in the pinned time zone,
        // so changing the system date or zone does not move them.
        let trusted = clock.read()
        let now = trusted.now
        let calendar = trusted.calendar
        guard abs(now.timeIntervalSince(lastEvaluation)) >= 4 else { return }
        lastEvaluation = now
        let active = effective.rules
        do {
            let history = try store.spans(since: now.addingTimeInterval(-RuleEngine.lookback(for: active)))
            progress = Dictionary(active.map { ($0.id, RuleEngine.matchedSeconds($0, spans: history, now: now)) },
                                  uniquingKeysWith: { first, _ in first })
            budgets = Dictionary(active.filter { $0.mode == .pomodoro }.map {
                ($0.id, RuleEngine.pomodoroStatus($0, spans: history, now: now, calendar: calendar))
            }, uniquingKeysWith: { first, _ in first })
            // Enforcing: closing and blocking must repeat promptly if you go
            // straight back, so only the notification honours the quiet period.
            var gate = lastFired
            if isEnforcing {
                for rule in active where rule.action != .warn {
                    if let fired = gate[rule.id], now.timeIntervalSince(fired) >= recloseSeconds { gate[rule.id] = nil }
                }
            }
            let fired = RuleEngine.evaluate(rules: active, spans: history, now: now, lastFired: gate, calendar: calendar)
            for verdict in fired {
                lastFired[verdict.ruleID] = verdict.at
                try store.record(verdict, dryRun: !isEnforcing)
                let rule = active.first { $0.id == verdict.ruleID }
                var outcome: String?
                if isEnforcing, let rule { outcome = enforce(verdict, rule: rule, front: history.last) }

                let quiet = TimeInterval(rule?.cooldownSeconds ?? 60)
                if lastNotified[verdict.ruleID].map({ now.timeIntervalSince($0) >= quiet }) ?? true {
                    lastNotified[verdict.ruleID] = now
                    notifier.post(title: verdict.ruleName, body: outcome ?? Self.describe(verdict))
                }
            }
            if !fired.isEmpty { verdicts = try store.recentVerdicts() }
            heartbeat.markEvaluated()
        } catch {
            self.error = "Rule check failed: \(error.localizedDescription)"
        }
    }

    // MARK: Enforcement

    /// Carries out a verdict. Returns the notification text.
    private func enforce(_ verdict: Verdict, rule: Rule, front: Span?) -> String? {
        let why = verdict.reason.map { " (\($0))" } ?? ""
        switch rule.action {
        case .warn:
            return nil
        case .close:
            let closed = Enforcer.close(for: rule, front: frontSample(front))
            return closed.isEmpty ? nil : "Closed \(Set(closed).sorted().joined(separator: ", "))\(why)."
        case .block:
            _ = Enforcer.close(for: rule, front: frontSample(front))
            guard !rule.domains.isEmpty else { return "Closed \(verdict.subject)\(why)." }
            // If a block already covers this rule's sites, leave its timer
            // alone. Asking again would restart it every few seconds for as
            // long as the page stays in front, and the block would never end.
            if let running = activeBlock, Set(rule.domains.map { $0.lowercased() }).isSubset(of: running.domains) {
                return nil
            }
            let domains = rule.domains
            let seconds = rule.blockMinutes * 60
            Task {
                let result = await DaemonClient.startBlock(domains: domains, seconds: seconds)
                if !result.accepted { notifier.post(title: "Block not started", body: result.message) }
                refreshDaemonStatus()
            }
            return "Closed \(verdict.subject) and asked for a \(rule.blockMinutes)-minute block\(why)."
        }
    }

    private func frontSample(_ span: Span?) -> Sample? {
        span.map { Sample(time: $0.endedAt, bundleID: $0.bundleID, appName: $0.appName) }
    }

    static func describe(_ verdict: Verdict) -> String {
        if let reason = verdict.reason {
            let what = "\(verdict.subject): \(reason)."
            switch verdict.action {
            case .warn: return what
            case .close: return "Dry run: would have closed \(what)"
            case .block: return "Dry run: would have blocked \(verdict.subject) for \(verdict.blockMinutes) minutes (\(reason))."
            }
        }
        let time = Format.duration(verdict.matchedSeconds)
        switch verdict.action {
        case .warn: return "You have been on \(verdict.subject) for \(time)."
        case .close: return "Dry run: would have closed \(verdict.subject) after \(time)."
        case .block: return "Dry run: would have blocked \(verdict.subject) for \(verdict.blockMinutes) minutes after \(time)."
        }
    }
}

/// Tells the daemon "the app is alive, and this is what it can see", every
/// ten seconds, from a background queue.
///
/// It deliberately does not run on the main thread: that thread can be held up
/// for a long time by things that are not the app failing (a browser slow to
/// answer AppleScript, a permission prompt), and a penalty block for that
/// would be wrong. The health it sends is the latest the main thread handed over.
///
/// Because it keeps going while the main thread is stuck, each heartbeat also
/// says how long ago the rules were last checked, and whether the app is
/// waiting on a browser. The daemon decides from that whether the app still
/// works. Times are awake time, so sleep does not count.
final class HeartbeatSender: @unchecked Sendable {
    private let lock = NSLock()
    private var health: AgentHealth?
    /// Launch counts as a check, so the app gets the usual grace to start up.
    private var lastEvaluated = ProcessInfo.processInfo.systemUptime
    private var timer: DispatchSourceTimer?

    func update(_ health: AgentHealth) {
        lock.lock()
        self.health = health
        lock.unlock()
    }

    /// Called on the main thread after each successful rule check.
    func markEvaluated() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        lastEvaluated = now
        lock.unlock()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 10)
        timer.setEventHandler { [self] in
            lock.lock()
            var health = self.health
            let age = ProcessInfo.processInfo.systemUptime - lastEvaluated
            lock.unlock()
            health?.secondsSinceEvaluation = max(0, age)
            health?.waitingOnBrowser = AppleEventWait.isWaiting
            if let health, let data = try? JSONEncoder().encode(health) { DaemonClient.heartbeat(data) }
        }
        timer.resume()
        self.timer = timer
    }
}

/// Local notifications (the banners at the top right of the screen).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// One for the whole app: it is the notification centre's delegate.
    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    /// macOS asks the user once whether WatchDog may show notifications.
    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Without this, banners are suppressed while one of our own windows is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
