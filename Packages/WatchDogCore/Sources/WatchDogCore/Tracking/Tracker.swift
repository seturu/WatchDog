import AppKit
import Observation

/// Watches what you are doing and writes it to the usage store.
///
/// Runs on the main thread. It wakes on a 2-second timer and immediately
/// whenever a different app comes to the front. `@Observable` lets SwiftUI
/// views redraw when the published properties change.
@MainActor
@Observable
public final class Tracker {

    public enum BrowserAccess: Sendable, Equatable {
        case notAsked, granted, denied
        case failing(String)
    }

    // What the UI can show
    public private(set) var isRunning = false
    public private(set) var current: Sample?
    public private(set) var nowPlaying: [MediaSample] = []
    /// Latest reading from the pomodoro timer (see `timerSource`).
    public private(set) var focusTimer = TimerReading.none
    public private(set) var accessibilityGranted = false
    public private(set) var browserAccess: [String: BrowserAccess] = [:]
    public private(set) var lastError: String?
    /// Increases on every stored sample; views watch it to know when to reload.
    public private(set) var revision = 0

    // Tuning
    /// No keyboard or mouse input for this long counts as "away".
    public var idleThreshold: TimeInterval = 120
    private let interval: TimeInterval = 2
    /// After a denied Automation request, wait this long before asking the
    /// browser again (each attempt costs an Apple Event).
    private let deniedRetry: TimeInterval = 60

    public let store: UsageStore
    /// Time source that cannot be moved by changing the system clock or zone.
    @ObservationIgnored public private(set) var clock: TrustedClock
    /// Latest clock check; views show a warning when `isTampered`.
    public private(set) var clockReading: TrustedClock.Reading

    /// Called after each sample is stored. The rule runner hooks in here.
    @ObservationIgnored public var onSample: ((Sample) -> Void)?

    /// How much of a browser page's address is stored: the site only (the
    /// default), the full address with likely secrets removed, or all of it.
    /// Rules match sites either way; this only decides what history keeps.
    @ObservationIgnored public var addressDetail: AddressDetail = .site

    /// Where the pomodoro timer state comes from: the Session app, or the
    /// timer built into WatchDog. Whichever it is, its state is stored on
    /// every span, so rules work the same with either.
    @ObservationIgnored public var timerSource: any TimerSource = SessionTimerApp()

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var deniedUntil: [String: Date] = [:]
    /// Latest track announced by Spotify / Music, keyed by their bundle ID.
    @ObservationIgnored private var lastTrack: [String: (title: String?, artist: String?)] = [:]

    public init(store: UsageStore, clock: TrustedClock = TrustedClock()) {
        self.store = store
        self.clock = clock
        self.clockReading = clock.read()
    }

    /// Switches to the daemon's clock once it is known (it is pinned at boot,
    /// so unlike our own it is not reset by restarting the app).
    public func adopt(clock: TrustedClock) {
        self.clock = clock
        clockReading = clock.read()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        // `.common` keeps the timer firing while a menu or scroll is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }))

        // Spotify and Music announce track changes to every app. No permission needed.
        let distributed = DistributedNotificationCenter.default()
        let players = ["com.spotify.client.PlaybackStateChanged": "com.spotify.client",
                       "com.apple.Music.playerInfo": "com.apple.Music"]
        for (name, bundleID) in players {
            observers.append((distributed, distributed.addObserver(
                forName: .init(name), object: nil, queue: .main
            ) { [weak self] note in
                let title = note.userInfo?["Name"] as? String
                let artist = note.userInfo?["Artist"] as? String
                MainActor.assumeIsolated { self?.lastTrack[bundleID] = (title, artist) }
            }))
        }
        tick()
    }

    /// Takes a sample now instead of at the next tick. Call it when the timer
    /// changes state, so the span boundary lands on the button press.
    public func timerChanged() {
        guard isRunning else { return }
        tick()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        isRunning = false
    }

    // MARK: One observation

    private func tick() {
        let trusted = clock.read()
        if trusted != clockReading { clockReading = trusted }
        let now = trusted.now
        accessibilityGranted = Probes.accessibilityGranted()

        let reading = timerSource.read()
        if reading != focusTimer { focusTimer = reading }

        guard let app = Probes.frontApp() else { return }
        var sample = Sample(time: now, bundleID: app.bundleID, appName: app.name, timerState: reading.state)

        if Probes.idleSeconds() >= idleThreshold {
            // Away: one span per absence, whatever happens to be in front.
            sample.isIdle = true
        } else {
            if case .success(let title) = Probes.windowTitle(pid: app.pid), !title.isEmpty {
                sample.windowTitle = title
            }
            let url = browserURL(for: app.bundleID, now: now)
            sample.url = addressDetail.apply(to: url)
        }

        do {
            try store.record(sample)
            for media in audibleApps(now: now) { try store.record(media) }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        current = sample
        revision += 1
        onSample?(sample)
    }

    private func browserURL(for bundleID: String, now: Date) -> String? {
        guard Probes.scriptableBrowsers[bundleID] != nil else { return nil }
        if let until = deniedUntil[bundleID], now < until { return nil }

        switch Probes.browserURL(bundleID: bundleID) {
        case .success(let url):
            browserAccess[bundleID] = .granted
            return url.isEmpty ? nil : url
        case .failure(let error) where error.code == Probes.automationDeniedCode:
            browserAccess[bundleID] = .denied
            deniedUntil[bundleID] = now.addingTimeInterval(deniedRetry)
            return nil
        case .failure(let error):
            browserAccess[bundleID] = .failing(error.description)
            return nil
        }
    }

    // MARK: Sound

    private func audibleApps(now: Date) -> [MediaSample] {
        guard case .success(let processes) = Probes.audioProcesses() else { return [] }
        // Skip nameless tools and the process that plays system alert sounds.
        let playing = Set(processes.filter(\.isPlaying).map(\.bundleID)
            .filter { !$0.isEmpty && $0 != "systemsoundserverd" })
        guard !playing.isEmpty else {
            if !nowPlaying.isEmpty { nowPlaying = [] }
            return []
        }
        // Browsers and Electron apps play sound from helper processes such as
        // "com.brave.Browser.helper". Credit the app the helper belongs to: the
        // running app with the shortest bundle ID that the helper's ID extends.
        // (Shortest, because the helper is itself listed as a running app.)
        let apps = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let owners = Set(playing.map { id in
            apps.filter { id == $0 || id.hasPrefix($0 + ".") }.min(by: { $0.count < $1.count }) ?? id
        })
        let samples = owners.sorted().map { owner in
            MediaSample(time: now, sourceBundleID: owner,
                        title: lastTrack[owner]?.title, artist: lastTrack[owner]?.artist)
        }
        if samples != nowPlaying { nowPlaying = samples }
        return samples
    }
}
