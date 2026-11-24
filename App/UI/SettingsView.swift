import ServiceManagement
import SwiftUI
import WatchDogCore

/// Settings: how WatchDog stays running, the pomodoro timer, and the state
/// of its root daemon.
struct SettingsView: View {
    let runner: RuleRunner
    let pomodoro: PomodoroTimer

    @State private var startsAtLogin = LoginAgent.isRegistered
    @State private var loginError: String?
    @State private var daemonStatus = SMAppService.daemon(plistName: WD.daemonPlistName).status
    @State private var confirmingUninstall = false
    @State private var deleteHistory = false
    @State private var uninstallMessage: String?
    @State private var uninstalled = false

    var body: some View {
        Form {
            Section {
                Toggle("Start at login and keep running", isOn: $startsAtLogin)
                    .onChange(of: startsAtLogin) { _, on in
                        guard on != LoginAgent.isRegistered else { return }
                        loginError = LoginAgent.set(registered: on)
                        startsAtLogin = LoginAgent.isRegistered
                    }
                    // Switching it off would make the app killable, which is
                    // a way out; not while enforcing.
                    .disabled(runner.isEnforcing && startsAtLogin)
                if let loginError { Text(loginError).foregroundStyle(.red) }
            } footer: {
                Text("WatchDog opens when you log in and comes back if it is force-quit. While enforcing it cannot be quit at all.")
            }

            PomodoroSettingsSection(timer: pomodoro)

            HistorySettingsSection()

            Section("Enforcement") {
                LabeledContent("Mode", value: runner.isEnforcing ? "Enforcing" : "Dry run")
                LabeledContent("Changes that loosen rules", value: WD.isArmed ? "Refused while enforcing" : "Wait \(Format.duration(Limits.coolingOffSeconds)) while enforcing")
                if WD.isArmed {
                    LabeledContent("Back to dry run", value: "Not possible once enforcing")
                }
                LabeledContent("During a block", value: "Refused")
            }

            Section {
                LabeledContent("Hosts file", value: "Always")
                LabeledContent("Closing matching tabs and apps", value: "Always")
                LabeledContent("Brave's Tor windows", value: "Disabled while enforcing")
                Toggle("Also block by IP address (firewall)", isOn: Binding(
                    get: { runner.usesPacketFilter }, set: { runner.requestPacketFilter($0) }))
                    // Switching a layer off is loosening.
                    .disabled(!runner.daemonReachable || (runner.isLocked && runner.usesPacketFilter))
            } header: {
                Text("How sites are blocked")
            } footer: {
                Text("Tor windows are switched off through a browser policy, which Brave reads when it starts and shows as “Managed by your organization”. The firewall also stops programs that ignore the hosts file, but it is blunt: sites sharing addresses with a blocked one (anything on the same content network) are blocked too. It stands down if other software is already using the firewall.")
            }

            Section {
                LabeledContent("Daemon", value: daemonText)
                LabeledContent("Reachable", value: runner.daemonReachable ? "Yes" : "No")
                if daemonStatus == .requiresApproval {
                    Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
            } header: {
                Text("Background service")
            } footer: {
                Text("The daemon runs as root. It holds the rules, runs blocks and watches that this app is alive. Its log is at \(WD.daemonStateDirectory)/audit.log, readable with administrator rights (sudo).")
            }

            Section {
                LabeledContent("Longest block", value: Format.duration(Limits.maxBlockSeconds))
                LabeledContent("Never blocked", value: Limits.neverBlock.sorted().joined(separator: ", "))
            } header: {
                Text("Guard rails")
            }

            Section {
                Button("Uninstall WatchDog…", role: .destructive) { confirmingUninstall = true }
                    .disabled(runner.isEnforcing || runner.activeBlock != nil)
                if let uninstallMessage { Text(uninstallMessage).foregroundStyle(.red) }
            } footer: {
                Text(runner.isEnforcing || runner.activeBlock != nil
                     ? (runner.isLocked
                        ? "Not available: WatchDog is enforcing, and that cannot be switched off. The way out is in docs/RESCUE.md."
                        : "Not available while enforcing or during a block. Switch to dry run first; that takes effect after the delay.")
                     : "Removes everything WatchDog installed on this Mac.")
            }

            if Limits.isDevBuild {
                Section {
                    LabeledContent("Blockable sites", value: (Limits.blockableDomains ?? []).sorted().joined(separator: ", "))
                    LabeledContent("Daemon resets itself every", value: Format.duration(Limits.deadManSeconds ?? 0))
                } header: {
                    Text("Development limits")
                } footer: {
                    Text("Safety caps for a build that is still being written. To remove everything WatchDog installed: sudo scripts/uninstall.sh")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove WatchDog from this Mac?", isPresented: $confirmingUninstall) {
            Button("Remove and Keep My Usage History") { uninstall(deleteHistory: false) }
            Button("Remove and Delete My Usage History", role: .destructive) { uninstall(deleteHistory: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the background service, its rules and log, any block list it wrote, start at login, and WatchDog's privacy permissions. The app itself stays until you move it to the Trash.")
        }
        .alert("WatchDog has been removed", isPresented: $uninstalled) {
            Button("Quit") {
                // Unregistering the login agent stops this copy if launchd started
                // it; after an uninstall it must not come back.
                LoginAgent.set(registered: false, reopenAfterwards: false)
                exit(0)
            }
        } message: {
            Text("Everything it installed is gone. Move WatchDog to the Trash to finish.")
        }
        .navigationTitle("Settings")
        .toolbar { ModeSwitch(runner: runner) }
        .onAppear { daemonStatus = SMAppService.daemon(plistName: WD.daemonPlistName).status }
    }

    private func uninstall(deleteHistory: Bool) {
        Task {
            uninstallMessage = await runner.uninstall(deleteHistory: deleteHistory)
            uninstalled = uninstallMessage == nil
        }
    }

    private var daemonText: String {
        switch daemonStatus {
        case .enabled: "Installed"
        case .requiresApproval: "Waiting for approval in Login Items"
        case .notRegistered: "Not installed"
        case .notFound: "Missing from the app"
        @unknown default: "Unknown"
        }
    }
}

/// The launchd job that starts the app at login and restarts it if killed.
enum LoginAgent {
    private static var service: SMAppService { .agent(plistName: WD.agentPlistName) }

    static var isRegistered: Bool { service.status == .enabled }

    /// True when this process was started by the launchd job (as opposed to
    /// being opened from Finder or the Dock).
    static var isCurrentProcess: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == WD.agentLabel
    }

    /// Returns an error message, or nil on success.
    @discardableResult
    static func set(registered: Bool, reopenAfterwards: Bool = true) -> String? {
        do {
            if registered {
                // launchd starts a managed copy straight away; that copy
                // replaces this one (see Entry.main).
                try service.register()
            } else {
                // Unregistering stops the managed copy, which is us. Arrange
                // to come back as an ordinary app first.
                if isCurrentProcess && reopenAfterwards {
                    let relaunch = Process()
                    relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                    relaunch.arguments = ["-c", "sleep 2; /usr/bin/open \"$0\" --args --show-window", Bundle.main.bundlePath]
                    try? relaunch.run()
                }
                try service.unregister()
            }
            return nil
        } catch {
            return "Could not \(registered ? "enable" : "disable") start at login: \(error.localizedDescription)"
        }
    }
}

/// Settings → Pomodoro: which timer, and how the built-in one runs.
private struct PomodoroSettingsSection: View {
    @Bindable var timer: PomodoroTimer

    var body: some View {
        Section {
            Picker("Timer", selection: Binding(get: { timer.sourceID }, set: { timer.selectSource($0) })) {
                Text("Built-in").tag(TimerSources.builtInID)
                ForEach(TimerSources.external, id: \.sourceID) { app in
                    Text(app.isInstalled ? app.name : "\(app.name) (not installed)").tag(app.sourceID)
                }
            }
            if timer.usesBuiltIn {
                minutes("Focus", value: $timer.settings.rhythm.focusMinutes, range: 1...180, coarse: 5)
                minutes("Short break", value: $timer.settings.rhythm.shortBreakMinutes, range: 1...60, coarse: 1)
                minutes("Long break", value: $timer.settings.rhythm.longBreakMinutes, range: 1...90, coarse: 5)
                LabeledContent("Long break after") {
                    HStack(spacing: 8) {
                        let every = timer.settings.rhythm.longBreakEvery
                        Text("\(every) focus \(every == 1 ? "session" : "sessions")").monospacedDigit()
                        Stepper("Long break after", value: $timer.settings.rhythm.longBreakEvery, in: 1...12)
                            .labelsHidden()
                    }
                }
                Toggle("Start breaks automatically", isOn: $timer.settings.autoStartBreaks)
                Toggle("Start focus sessions automatically", isOn: $timer.settings.autoStartFocus)
            } else if let app = timer.externalApp {
                LabeledContent(app.name, value: !app.isInstalled ? "Not installed" : app.isRunning ? "Running" : "Not running")
            }
        } header: {
            Text("Pomodoro")
        } footer: {
            Text(footer)
        }

        if timer.usesBuiltIn {
            Section {
                ForEach(timer.categories) { category in
                    CategoryRow(category: category, timer: timer)
                }
                Button("Add Category", systemImage: "plus") { timer.addCategory() }
            } header: {
                Text("Session categories")
            } footer: {
                Text("Chosen when a focus session starts. Removing a category keeps it on past sessions.")
            }
        }
    }

    private var footer: String {
        if timer.usesBuiltIn {
            return "Its focus and break intervals drive the “Pomodoro timer” rule condition and “Pomodoro it” budgets. "
                + "Pausing never loosens a rule: a paused focus session still counts as focus, a paused break as no break. "
                + "Changed lengths apply from the next interval. Choosing another timer stops this one."
        }
        let name = timer.externalApp?.name ?? "The app"
        return "WatchDog reads \(name)'s timer and does not control it. Rules follow its focus and break intervals."
    }

    /// Minutes, a minute at a time up to five, then in `coarse` steps.
    private func minutes(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, coarse: Int) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text("\(value.wrappedValue) min").monospacedDigit()
                Stepper(title) {
                    let v = value.wrappedValue
                    value.wrappedValue = min(range.upperBound, v < 5 ? v + 1 : v + coarse)
                } onDecrement: {
                    let v = value.wrappedValue
                    value.wrappedValue = max(range.lowerBound, v <= 5 ? v - 1 : max(5, v - coarse))
                }
                .labelsHidden()
            }
        }
    }
}

/// One category: its colour, its name, and a way to remove it.
private struct CategoryRow: View {
    let category: SessionCategory
    let timer: PomodoroTimer

    @State private var name: String
    @State private var choosingColor = false

    init(category: SessionCategory, timer: PomodoroTimer) {
        self.category = category
        self.timer = timer
        _name = State(initialValue: category.name)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { choosingColor = true } label: {
                CategoryDot(color: category.color, size: 14)
                    .padding(3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Change colour")
            .accessibilityLabel("Colour: \(category.color.name)")
            .popover(isPresented: $choosingColor) {
                ColorGrid(selection: category.color) { color in
                    var changed = category
                    changed.color = color
                    timer.updateCategory(changed)
                    choosingColor = false
                }
            }
            TextField("Category name", text: $name)
                .labelsHidden()
                .onChange(of: name) {
                    var changed = category
                    changed.name = name
                    timer.updateCategory(changed)
                }
            Button("Remove \(category.name)", systemImage: "minus.circle") { timer.removeCategory(category) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove this category")
        }
    }
}

/// Settings → History: what activity history keeps, and for how long.
private struct HistorySettingsSection: View {
    @State private var addresses = HistoryPrefs.current.addresses
    @State private var detailDays = HistoryPrefs.current.detailDays
    @State private var historyDays = HistoryPrefs.current.historyDays

    private func store() {
        HistoryPrefs.save(HistorySettings(addresses: addresses, detailDays: detailDays, historyDays: historyDays))
    }

    var body: some View {
        Section {
            Picker("Page addresses", selection: $addresses) {
                Text("Site only").tag(AddressDetail.site)
                Text("Full, sensitive parts removed").tag(AddressDetail.cleaned)
                Text("Full").tag(AddressDetail.full)
            }
            .onChange(of: addresses) {
                store()
                AppState.shared.tracker?.addressDetail = addresses
            }
            .onChange(of: detailDays) { store() }
            .onChange(of: historyDays) { store() }
            Picker("Keep window titles and addresses", selection: $detailDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("Forever").tag(0)
            }
            Picker("Keep activity", selection: $historyDays) {
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
                Text("Forever").tag(0)
            }
        } header: {
            Text("History")
        } footer: {
            Text("Site only keeps youtube.com, not the video or search. With sensitive parts removed, the whole address is kept minus what looks like a password, token, key, session ID, email address or card number; it can miss some. Rules match sites and window titles either way. "
                 + "Past the first limit, window titles, addresses and track names are cleared; past the second, the activity itself is deleted. "
                 + "Choosing less also tidies what is already stored, within a few hours. Pomodoro sessions are kept. History never leaves this Mac.")
        }
    }
}
