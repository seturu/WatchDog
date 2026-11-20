import AppKit
import ServiceManagement
import SwiftUI
import WatchDogCore

/// State behind the checks window. `@Observable` makes SwiftUI redraw any view
/// that reads a property when it changes (similar to Vue's reactivity).
@MainActor
@Observable
final class SpikeModel {

    // Tracking
    var frontApp = "—"
    var windowTitle = "—"
    var braveURL = "—"
    var idle = "—"
    var accessibilityGranted = false
    private var pollBrave = false

    // Media
    var playingNow = "—"
    var lastMediaNotification = "none received yet"

    // Daemon
    var daemonStatus = "—"
    var daemonLog = ""

    private let daemon = SMAppService.daemon(plistName: WD.daemonPlistName)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Spotify and Music announce track changes system-wide. Listening
        // needs no permission.
        let center = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            observers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                let state = info["Player State"] as? String ?? "?"
                let title = info["Name"] as? String ?? "?"
                let artist = info["Artist"] as? String ?? "?"
                let source = name.contains("spotify") ? "Spotify" : "Music"
                Task { @MainActor in
                    self?.lastMediaNotification = "\(source): \(state) — \(title) / \(artist)"
                }
            })
        }
    }

    func stop() {
        timer?.invalidate()
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers = []
    }

    private func refresh() {
        accessibilityGranted = Probes.accessibilityGranted()
        idle = String(format: "%.0f s", Probes.idleSeconds())

        if let app = Probes.frontApp() {
            frontApp = "\(app.name)  (\(app.bundleID))"
            windowTitle = text(Probes.windowTitle(pid: app.pid))
        }
        if pollBrave { braveURL = text(Probes.braveURL()) }

        switch Probes.audioProcesses() {
        case .failure(let error): playingNow = "failed: \(error)"
        case .success(let all):
            let names = all.filter(\.isPlaying).map(\.bundleID)
            playingNow = names.isEmpty ? "nothing (\(all.count) audio clients idle)" : names.joined(separator: ", ")
        }
        daemonStatus = describe(daemon.status)
    }

    private func text(_ result: Result<String, ProbeError>) -> String {
        switch result {
        case .success(let value): value.isEmpty ? "(empty)" : value
        case .failure(let error): "failed: \(error)"
        }
    }

    // MARK: Permissions

    /// Shows the system dialog that sends you to the Accessibility pane.
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The first call makes macOS ask "WatchDog wants to control Brave".
    /// Polling starts only after you press the button, so the prompt never
    /// appears unasked.
    func readBraveURL() {
        pollBrave = true
        braveURL = text(Probes.braveURL())
    }

    // MARK: Daemon (spike A)

    func registerDaemon() {
        do {
            try daemon.register()
            log("register(): ok")
        } catch {
            log("register() failed: \(error.localizedDescription)")
        }
        refresh()
    }

    func unregisterDaemon() {
        do {
            try daemon.unregister()
            log("unregister(): ok")
        } catch {
            log("unregister() failed: \(error.localizedDescription)")
        }
        refresh()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    func pingDaemon() {
        // `.privileged` = the service lives in the system (root) domain.
        pingConnection?.invalidate()
        let connection = NSXPCConnection(machServiceName: WD.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: WatchDogDaemonXPC.self)
        connection.resume()
        pingConnection = connection

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in self?.log("ping failed: \(error.localizedDescription)") }
        } as? WatchDogDaemonXPC

        proxy?.ping { [weak self] answer in
            Task { @MainActor in self?.log("ping answered: \(answer)") }
        }
    }

    private var pingConnection: NSXPCConnection?

    private func log(_ line: String) {
        daemonLog = daemonLog.isEmpty ? line : daemonLog + "\n" + line
    }

    private func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "waiting for your approval in Login Items"
        case .notFound: "not found (plist missing from the app bundle?)"
        @unknown default: "unknown"
        }
    }
}
