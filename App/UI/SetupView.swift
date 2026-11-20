import ServiceManagement
import SwiftUI
import UserNotifications
import WatchDogCore

/// First-run checklist: everything WatchDog needs from macOS, each with its
/// current state and the one button that moves it forward. Nothing here needs
/// a terminal.
struct SetupView: View {
    let tracker: Tracker
    let runner: RuleRunner
    let pomodoro: PomodoroTimer

    @State private var daemon = SMAppService.daemon(plistName: WD.daemonPlistName).status
    @State private var notifications = UNAuthorizationStatus.notDetermined
    @State private var startsAtLogin = LoginAgent.isRegistered
    @State private var owner = OwnerRecord.read()
    @State private var enrolling = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                step("Background service", state: daemonState, detail: daemonDetail) { daemonButton }
                step("Accessibility", state: tracker.accessibilityGranted ? .done : .needed,
                     detail: "Lets WatchDog read window titles, so rules can match on them.") {
                    if !tracker.accessibilityGranted {
                        Button("Grant Access…", action: SystemSettings.requestAccessibility)
                    }
                }
                ForEach(browsers, id: \.bundleID) { browser in
                    step("Addresses from \(browser.name)", state: browser.state, detail: browser.detail) {
                        if browser.state == .needed {
                            Button("Open Settings…", action: SystemSettings.openAutomation)
                        }
                    }
                }
                step("Notifications", state: notificationState,
                     detail: "Warnings, and a note whenever a rule closes or blocks something.") {
                    switch notifications {
                    case .notDetermined:
                        Button("Allow…") {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                        }
                    case .denied:
                        Button("Open Settings…", action: SystemSettings.openNotifications)
                    default:
                        EmptyView()
                    }
                }
            } header: {
                Text("Required")
            } footer: {
                if let message { Text(message).foregroundStyle(.red) }
            }

            Section("Recommended") {
                step("Start at login and keep running", state: startsAtLogin ? .done : .optional,
                     detail: "Without it, tracking stops at the next restart until you open WatchDog again.") {
                    if !startsAtLogin {
                        Button("Turn On") {
                            message = LoginAgent.set(registered: true)
                            startsAtLogin = LoginAgent.isRegistered
                        }
                    }
                }
                step("Pomodoro timer", state: timerReady ? .done : .optional, detail: timerDetail) { EmptyView() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .navigationSubtitle(remaining == 0 ? "Everything is in place" : "\(remaining) to go")
        .task {
            // These states change outside the app (in System Settings), so poll.
            while !Task.isCancelled {
                owner = OwnerRecord.read()
                daemon = SMAppService.daemon(plistName: WD.daemonPlistName).status
                notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                startsAtLogin = LoginAgent.isRegistered
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// How many required steps are still open. Shown as the sidebar badge.
    static func remaining(tracker: Tracker, runner: RuleRunner) -> Int {
        var count = 0
        if !runner.daemonReachable { count += 1 }
        if !tracker.accessibilityGranted { count += 1 }
        count += tracker.browserAccess.values.filter { $0 == .denied }.count
        return count
    }

    private var remaining: Int {
        Self.remaining(tracker: tracker, runner: runner) + (notificationState == .needed ? 1 : 0)
    }

    // MARK: Rows

    private enum StepState { case done, needed, optional, waiting }

    private func step<Action: View>(_ title: String, state: StepState, detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol(state))
                .font(.title2)
                .foregroundStyle(color(state))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ state: StepState) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .needed: "exclamationmark.circle.fill"
        case .waiting: "clock.fill"
        case .optional: "circle.dashed"
        }
    }

    private func color(_ state: StepState) -> Color {
        switch state {
        case .done: .green
        case .needed: Theme.warning
        case .waiting: .blue
        case .optional: .secondary
        }
    }

    // MARK: Background service

    private var daemonState: StepState {
        if !owner.allows(getuid()) { return .needed }
        if runner.daemonReachable { return .done }
        return daemon == .requiresApproval ? .waiting : .needed
    }

    private var daemonDetail: String {
        switch owner {
        case .missing where daemon == .enabled: return "Choose the account that will manage systemwide blocks. An administrator must approve this once."
        case .invalid: return "The owner record is invalid. Use the administrator recovery instructions."
        case .enrolled(let uid) where uid != getuid(): return "WatchDog is managed by another account on this Mac."
        default: break
        }
        if runner.daemonReachable { return "Installed and answering. It holds your rules and runs the blocks." }
        switch daemon {
        case .requiresApproval: return "Waiting for you to allow WatchDog under Login Items & Extensions."
        case .enabled: return "Installed, but not answering yet. It can take a few seconds after approval."
        default: return "The part that enforces blocks and cannot be casually switched off. Installing it asks for approval once."
        }
    }

    @ViewBuilder private var daemonButton: some View {
        if owner == .missing && daemon == .enabled {
            Button("Enroll This Account…") {
                enrolling = true
                Task {
                    defer { enrolling = false; owner = OwnerRecord.read() }
                    do {
                        try await OwnerSetup.enroll()
                        message = nil
                        runner.refreshDaemonStatus()
                    } catch { message = error.localizedDescription }
                }
            }
            .disabled(enrolling)
        } else if (owner != .missing && !owner.allows(getuid())) || runner.daemonReachable {
            EmptyView()
        } else if daemon == .requiresApproval {
            Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        } else if daemon != .enabled {
            Button("Install") {
                // The daemon runs as root from inside this bundle.
                if let problem = InstallLocation.problem(bundlePath: Bundle.main.bundlePath) {
                    message = problem
                    return
                }
                do {
                    try SMAppService.daemon(plistName: WD.daemonPlistName).register()
                    message = nil
                } catch {
                    // The first registration reports "not permitted" while it
                    // waits for approval; that is the normal path, not a failure.
                    let status = SMAppService.daemon(plistName: WD.daemonPlistName).status
                    message = status == .requiresApproval ? nil : "Could not install: \(error.localizedDescription)"
                    if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                }
                daemon = SMAppService.daemon(plistName: WD.daemonPlistName).status
                runner.refreshDaemonStatus()
            }
        }
    }

    // MARK: Browsers

    private struct BrowserRow {
        let bundleID: String
        let name: String
        let state: StepState
        let detail: String
    }

    /// One row per scriptable browser that is installed.
    private var browsers: [BrowserRow] {
        Probes.scriptableBrowsers.keys.sorted().compactMap { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            switch tracker.browserAccess[bundleID] ?? .notAsked {
            case .granted:
                return BrowserRow(bundleID: bundleID, name: name, state: .done, detail: "WatchDog can read the current tab's address.")
            case .denied:
                return BrowserRow(bundleID: bundleID, name: name, state: .needed,
                                  detail: "Not allowed. Switch \(name) on for WatchDog under Automation.")
            case .notAsked, .failing:
                return BrowserRow(bundleID: bundleID, name: name, state: .optional,
                                  detail: "macOS asks the first time you use \(name) while WatchDog is running.")
            }
        }
    }

    private var notificationState: StepState {
        switch notifications {
        case .authorized, .provisional, .ephemeral: .done
        case .denied: .needed
        default: .optional
        }
    }

    /// The built-in timer is always there; an external one must be installed.
    private var timerReady: Bool {
        pomodoro.usesBuiltIn || pomodoro.externalApp?.isInstalled == true
    }

    private var timerDetail: String {
        if pomodoro.usesBuiltIn {
            return "Using WatchDog's own timer. Rules can follow its focus and break intervals."
        }
        let name = pomodoro.externalApp?.name ?? "The timer app"
        return pomodoro.externalApp?.isInstalled == true
            ? "\(name) is installed. Rules can follow its focus and break intervals."
            : "Install \(name), or choose the built-in timer under Settings → Pomodoro."
    }
}
