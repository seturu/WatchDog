import AppKit
import ServiceManagement
import WatchDogCore

/// Process entry point. Starts the SwiftUI app. In the development build it
/// first checks for a test command (`--daemon ...`, `--rules`, `--login-agent
/// ...`, `--close-tabs ...`), runs it, prints the outcome and exits.
@main
enum Entry {
    static func main() {
        #if !ARMED
        // Development-only commands. They are compiled out of the armed build:
        // several of them (a fake heartbeat, switching the login agent off)
        // would otherwise be ways around enforcement.
        runDevelopmentCommandIfAny()
        #endif
        startApp()
    }

    #if !ARMED
    private static func runDevelopmentCommandIfAny() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--daemon"), i + 1 < args.count {
            exit(runDaemonCommand(args[i + 1], Array(args[(i + 2)...])))
        }
        if let i = args.firstIndex(of: "--login-agent"), i + 1 < args.count {
            // --login-agent on|off|status : the "Start at login and keep running" switch.
            if args[i + 1] == "on" || args[i + 1] == "off" {
                if let error = LoginAgent.set(registered: args[i + 1] == "on") { print(error) }
            }
            print("start at login: \(LoginAgent.isRegistered ? "on" : "off")")
            exit(0)
        }
        if let i = args.firstIndex(of: "--close-tabs"), i + 1 < args.count {
            // --close-tabs <domain> : runs the same tab-closing code a "Close it"
            // rule uses, without needing the site to be in front. Test aid.
            let closed = MainActor.assumeIsolated {
                Enforcer.close(for: Rule(name: "test", domains: [args[i + 1]]), front: nil)
            }
            print("closed \(closed.count) tab(s): \(closed.joined(separator: ", "))")
            exit(0)
        }
        if args.contains("--rules") {
            exit(printRules())
        }
    }
    #endif

    private static func startApp() {
        // One instance only: if launchd already started us at login, a second
        // launch (double-clicking the app) just steps aside.
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: WD.appBundleID)
            .filter { $0.processIdentifier != mine }
        if !others.isEmpty {
            if LoginAgent.isCurrentProcess {
                // We are the copy launchd keeps alive, so we are the one that
                // should run; the hand-launched copy makes way.
                others.forEach { $0.forceTerminate() }
            } else {
                // Opening the app again means "show me the window": ask the
                // running copy to do that, then step aside.
                DistributedNotificationCenter.default().postNotificationName(
                    .init(WD.showWindowNotification), object: nil, userInfo: nil, deliverImmediately: true)
                Thread.sleep(forTimeInterval: 0.3)
                exit(0)
            }
        }
        WatchDogApp.main()
    }

    #if !ARMED
    /// Prints each saved rule with the time currently counted toward it and
    /// whether it would fire now. Reads the same files as the running app.
    private static func printRules() -> Int32 {
        do {
            let rules = try RuleFile.load(path: RuleFile.defaultPath())
            let store = try UsageStore(path: UsageStore.defaultPath(), key: DatabaseKey.forThisApp())
            let now = Date()
            let history = try store.spans(since: now.addingTimeInterval(-RuleEngine.lookback(for: rules)))
            let lastFired = try store.lastFiredTimes()
            let firing = Set(RuleEngine.evaluate(rules: rules, spans: history, now: now, lastFired: lastFired).map(\.ruleID))
            print("\(rules.count) rule(s), \(history.count) span(s) of history")
            let file = TimerFile.load(path: TimerFile.defaultPath())
            let (source, timer) = MainActor.assumeIsolated { () -> (String, TimerReading) in
                let id = file.sourceID ?? TimerSources.defaultID
                let reading = id == TimerSources.builtInID
                    ? file.machine.reading(at: TrustedClock().moment())
                    : TimerSources.external(id: id)?.read() ?? .none
                return (id, reading)
            }
            print("pomodoro timer (\(source)): \(timer.state.rawValue)" + (timer.project.map { " (\($0))" } ?? "")
                  + (timer.isPaused ? ", paused" : ""))
            for rule in rules {
                let seconds = RuleEngine.matchedSeconds(rule, spans: history, now: now)
                var detail = rule.limitSeconds == 0 ? "not allowed" : "\(Int(seconds))s of \(rule.limitSeconds)s"
                if rule.mode == .pomodoro {
                    let budget = RuleEngine.pomodoroStatus(rule, spans: history, now: now)
                    detail = "break budget \(Int(budget.remaining))s left of \(Int(budget.earned))s earned, "
                        + "\(Int(budget.used))s used, this break \(Int(budget.sitting))s"
                        + (budget.denial.map { " [now: \($0.rawValue)]" } ?? " [now: allowed]")
                }
                print("  [\(rule.isEnabled ? "on" : "off")] \(rule.name): " + detail
                      + (rule.schedule.contains(now) ? "" : "  (outside its schedule)")
                      + (firing.contains(rule.id) ? "  -> FIRES" : "")
                      + (lastFired[rule.id].map { "  (last fired \($0.formatted(date: .omitted, time: .standard)))" } ?? ""))
            }
            return 0
        } catch {
            print("rules: FAILED — \(error)")
            return 1
        }
    }

    private static func runDaemonCommand(_ command: String, _ rest: [String]) -> Int32 {
        let service = SMAppService.daemon(plistName: WD.daemonPlistName)
        switch command {
        case "status":
            print("status: \(name(service.status))")
            return 0
        case "register":
            do { try service.register(); print("register: ok") }
            catch { print("register: FAILED — \(error)") }
            print("status: \(name(service.status))")
            return 0
        case "unregister":
            do { try service.unregister(); print("unregister: ok") }
            catch { print("unregister: FAILED — \(error)") }
            print("status: \(name(service.status))")
            return 0
        case "ping":
            return ping()
        case "restart":
            // After a rebuild launchd keeps running the old daemon binary;
            // re-registering makes it start the new one.
            try? service.unregister()
            Thread.sleep(forTimeInterval: 1)
            do { try service.register(); print("restart: ok") }
            catch { print("restart: FAILED — \(error)") }
            print("status: \(name(service.status))")
            return 0
        case "block-status":
            return wait {
                guard let status = await DaemonClient.status() else { print("daemon: not reachable"); return 1 }
                print("daemon: up \(Int(status.uptimeSeconds))s, dev build: \(status.isDevBuild)")
                if let block = status.block {
                    print("block: \(Int(block.remainingSeconds))s left of \(Int(block.totalSeconds))s on \(block.domains.joined(separator: ", "))")
                } else {
                    print("block: none")
                }
                if let config = status.config {
                    print("mode: \(config.isEnforcing ? "ENFORCING" : "dry run")\(config.packetFilterOn ? " +firewall" : ""), \(config.rules.count) rule(s): "
                          + config.rules.map { "\($0.name)[\($0.isEnabled ? "on" : "off")]" }.joined(separator: "; "))
                } else {
                    print("mode: no rules stored yet")
                }
                if let pending = status.pending {
                    print("pending: \(pending.config.isEnforcing ? "enforcing" : "dry run"), \(pending.config.rules.count) rule(s), in \(Int(pending.remainingSeconds))s")
                }
                print("app healthy: \(status.agentHealthy)   penalty block: \(status.penaltyDomains.isEmpty ? "none" : status.penaltyDomains.joined(separator: ", "))")
                print("trusted time: \(status.trustedNow.formatted(date: .abbreviated, time: .standard)) \(status.timeZoneID)"
                      + (status.clockChanged ? "  [system clock was changed]" : "") + (status.zoneChanged ? "  [time zone was changed]" : ""))
                return 0
            }
        case "propose":
            // --daemon propose <on|off> <rules.json> [firewall]   (test aid: submits a config the way the app would)
            guard rest.count >= 2, let data = FileManager.default.contents(atPath: rest[1]),
                  let rules = try? JSONDecoder().decode([Rule].self, from: data) else {
                print("usage: --daemon propose <on|off> <rules.json>")
                return 2
            }
            return wait {
                guard let answer = await DaemonClient.propose(DaemonConfig(
                    rules: rules, isEnforcing: rest[0] == "on", usePacketFilter: rest.contains("firewall"))) else {
                    print("daemon: not reachable"); return 1
                }
                print("\(answer.outcome): \(answer.message)")
                return 0
            }
        case "rules-json":
            // --daemon rules-json : the rules the daemon holds now, as JSON a
            // later `propose` accepts. The app's rules.json is only a draft.
            return wait {
                guard let status = await DaemonClient.status() else { print("daemon: not reachable"); return 1 }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                guard let data = try? encoder.encode(status.config?.rules ?? []) else { return 1 }
                print(String(decoding: data, as: UTF8.self))
                return 0
            }
        case "cancel-pending":
            return wait { await DaemonClient.cancelPending(); print("pending change discarded"); return 0 }
        case "heartbeat":
            // --daemon heartbeat <healthy|blind>
            let health = AgentHealth(accessibilityGranted: rest.first != "blind", deniedBrowsers: [])
            DaemonClient.heartbeat((try? JSONEncoder().encode(health)) ?? Data())
            Thread.sleep(forTimeInterval: 1)
            print("heartbeat sent (\(health.canSee ? "healthy" : "blind"))")
            return 0
        case "block":
            // --daemon block <seconds> <domain> [<domain>...]
            guard rest.count >= 2, let seconds = Int(rest[0]) else {
                print("usage: --daemon block <seconds> <domain> [<domain>...]")
                return 2
            }
            return wait {
                let result = await DaemonClient.startBlock(domains: Array(rest[1...]), seconds: seconds)
                print("\(result.accepted ? "accepted" : "REFUSED"): \(result.message)")
                return result.accepted ? 0 : 1
            }
        case "enroll":
            // --daemon enroll : the same enrollment as Setup's "Enroll This
            // Account…", including the administrator password dialog.
            return wait {
                do {
                    try await OwnerSetup.enroll()
                    print("enroll: ok, owner record: \(OwnerRecord.read())")
                    return 0
                } catch {
                    print("enroll: FAILED — \(error.localizedDescription)")
                    return 1
                }
            }
        case "enroll-probe":
            // --daemon enroll-probe : asks to enroll with an authorization that
            // was never authenticated. Expected: refused. Accepted means any
            // team-signed program at the desktop can enroll without a password.
            return wait {
                do {
                    let accepted = try await OwnerSetup.probeWithoutPassword()
                    print("enroll without password: \(accepted ? "ACCEPTED (admin check does not hold)" : "refused")")
                    print("owner record: \(OwnerRecord.read())")
                    return 0
                } catch {
                    print("enroll-probe: FAILED — \(error)")
                    return 1
                }
            }
        default:
            print("unknown command: \(command)")
            return 2
        }
    }

    /// Runs async work from this synchronous command-line path.
    private static func wait(_ work: @escaping @Sendable () async -> Int32) -> Int32 {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var code: Int32 = 1
        Task.detached {
            code = await work()
            done.signal()
        }
        done.wait()
        return code
    }

    private static func ping() -> Int32 {
        let connection = NSXPCConnection(machServiceName: WD.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: WatchDogDaemonXPC.self)
        connection.resume()

        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var code: Int32 = 1
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            print("ping: FAILED — \(error.localizedDescription)")
            done.signal()
        } as? WatchDogDaemonXPC
        proxy?.ping { answer in
            print("ping: \(answer)")
            code = 0
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut { print("ping: FAILED — no answer in 5 s") }
        return code
    }

    private static func name(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }
#endif
}
