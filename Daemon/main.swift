import Foundation
import WatchDogCore

// WatchDogDaemon — the root daemon. (Not "watchdogd": macOS has its own
// system process by that name.)
//
// launchd starts this binary as root at boot and restarts it if it exits.
// It is the part you cannot casually override. It owns:
//   - the active block (which domains, for how much longer),
//   - the rules and the enforcing switch, and the delay on loosening them,
//   - the trusted clock that schedules run on,
//   - the watch on the app: if the app goes silent or blind while enforcing,
//     the rules' sites are blocked here until it is healthy again.
// Everything it changes on the system is listed in scripts/uninstall.sh.

/// All state is touched only on `queue`, so there is no locking elsewhere.
final class Guardian: @unchecked Sendable {
    private let queue = DispatchQueue(label: "watchdog.guardian")
    private let hostsPath = "/etc/hosts"
    private let directory = URL(fileURLWithPath: WD.daemonStateDirectory)
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var configURL: URL { directory.appendingPathComponent("config.json") }
    private var pendingURL: URL { directory.appendingPathComponent("pending.json") }
    private var backupURL: URL { directory.appendingPathComponent("hosts.backup") }
    private var auditURL: URL { directory.appendingPathComponent("audit.log") }

    private var block: BlockState?
    private var config: DaemonConfig?
    private var pending: PendingChange?
    private var penaltyDomains: [String] = []
    private lazy var browserPolicy = BrowserPolicyLayer { [unowned self] in audit($0) }
    private lazy var packetFilter = PacketFilterLayer(queue: queue) { [unowned self] in audit($0) }
    /// The last reason for not writing hosts, so it is logged once, not every 2 seconds.
    private var hostsComplaint: String?
    /// Set once an uninstall has cleaned everything up; the tick then does nothing.
    private var uninstalled = false
    private var termination: DispatchSourceSignal?

    /// Pinned when the daemon starts, i.e. at boot. Restarting the app does not move it.
    private let clock = TrustedClock()
    private let startedAt = TrustedClock.continuousSeconds()
    private var lastTick = TrustedClock.continuousSeconds()
    private var lastCheckpoint = TrustedClock.continuousSeconds()
    private var timer: DispatchSourceTimer?

    private var agent = OwnerHeartbeat()
    /// The last heartbeat the owner's session sent, to say why a penalty began.
    private var lastHealth: AgentHealth?

    /// Serialize admission and initial enrollment with uninstall.
    func accepts(uid: uid_t) -> Bool {
        queue.sync { !uninstalled && OwnerRecord.read().allows(uid) }
    }

    func enroll(uid: uid_t, auditID: Int32, _ reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard !uninstalled, OwnerRecord.read() == .missing, let login = consoleLogin(),
                  login.uid == uid, login.auditID == auditID else { reply(false); return }
            reply(EnrollmentService.storeOwner(uid))
        }
    }

    /// Seconds the Mac has been awake. Heartbeats are judged on this clock so
    /// that waking from a long sleep does not look like a silent app.
    private static func awakeSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    func start() {
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            restrictStateToRoot()
            loadConfig()
            pending = load(PendingChange.self, from: pendingURL)
            // The armed build never loosens. A change left waiting by an
            // earlier build that still allowed it must not come due.
            if !Limits.isDevBuild, pending != nil {
                pending = nil
                try? FileManager.default.removeItem(at: pendingURL)
                audit("discarded a waiting change: the armed build does not loosen")
            }
            if let saved = load(BlockState.self, from: stateURL), !saved.isExpired {
                block = saved
                audit("resumed block: \(Int(saved.remainingSeconds))s left on \(saved.domains.joined(separator: ","))")
            }
            audit("daemon started (enforcing: \(config?.isEnforcing ?? false), rules: \(config?.rules.count ?? 0))")
            packetFilter.recover()
            reconcile()

            // launchd sends SIGTERM when the job is stopped (uninstall, logout
            // of the system, shutdown). The hosts section deliberately stays:
            // stopping the daemon must not be a way to end a block. Firewall
            // rules are different: they live in memory and nothing else would
            // clear them, so they are taken down.
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
            source.setEventHandler { [self] in
                checkpoint()
                packetFilter.teardown()
                audit("daemon stopping")
                exit(0)
            }
            source.resume()
            termination = source

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [self] in tick() }
            timer.resume()
            self.timer = timer
        }
    }

    // MARK: The 2-second tick

    /// The rules, the audit log and the hosts backup are root's alone. Earlier
    /// builds left the folder and its files readable by every account, so
    /// tighten whatever is already there. New files are private by umask.
    private func restrictStateToRoot() {
        _ = chown(directory.path, 0, 0)
        _ = chmod(directory.path, 0o700)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            _ = chmod(path, 0o600)
        }
    }

    /// Reads the stored rules. A file that exists but cannot be read must not
    /// look like "no rules yet": that would let anything be proposed without
    /// delay. It is set aside, and the daemon comes up enforcing with no
    /// rules, so getting back to dry run is as hard as it was before.
    private func loadConfig() {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        if let stored = load(DaemonConfig.self, from: configURL) {
            config = stored
            return
        }
        let aside = directory.appendingPathComponent("config.unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: configURL, to: aside)
        config = DaemonConfig(rules: [], isEnforcing: true)
        save(config, to: configURL)
        audit("config.json could not be read; set aside as config.unreadable.json. Enforcing with no rules until new ones are saved.")
    }

    private func tick() {
        guard !uninstalled else { return }
        let now = TrustedClock.continuousSeconds()
        let elapsed = now - lastTick
        lastTick = now

        if let deadline = Limits.deadManSeconds, now - startedAt >= deadline {
            audit("dead-man switch: clearing blocks and exiting")
            block = nil
            penaltyDomains = []
            try? FileManager.default.removeItem(at: stateURL)
            reconcile()
            exit(0)
        }

        if var current = block {
            current.advance(by: elapsed)
            if current.isExpired {
                audit("block finished")
                block = nil
                try? FileManager.default.removeItem(at: stateURL)
            } else {
                block = current
                if now - lastCheckpoint >= 10 { checkpoint() }
            }
        }

        if var waiting = pending {
            waiting.remainingSeconds = max(0, waiting.remainingSeconds - max(0, elapsed))
            pending = waiting
            // A change that comes due during a block waits for the block to end.
            if waiting.remainingSeconds <= 0, block == nil {
                config = waiting.config
                pending = nil
                save(config, to: configURL)
                try? FileManager.default.removeItem(at: pendingURL)
                audit("delayed change took effect (enforcing: \(waiting.config.isEnforcing), rules: \(waiting.config.rules.count))")
            } else if now - lastCheckpoint >= 10 {
                save(pending, to: pendingURL)
            }
        }

        updatePenalty()
        // Runs every tick, so a manual edit of our section is undone within 2 s.
        reconcile()
    }

    private func updatePenalty() {
        let now = Self.awakeSeconds()
        agent.observe(consoleLogin(), owner: OwnerRecord.read(), now: now)
        let wanted: [String]
        if config?.isEnforcing == true, agent.login != nil, !agent.isHealthy(at: now) {
            wanted = ConfigPolicy.penaltyDomains(for: config)
        } else {
            wanted = []
        }
        guard wanted != penaltyDomains else { return }
        if wanted.isEmpty {
            audit("owner session no longer needs a penalty block")
        } else {
            let why = !agent.isFresh(at: now) ? "no heartbeat from the app"
                : lastHealth?.canSee == false ? "the app lost a permission"
                : "the app stopped checking the rules"
            audit("penalty block (\(why)): \(wanted.joined(separator: ","))")
        }
        penaltyDomains = wanted
    }

    // MARK: hosts

    /// Brings all three blocking layers in line with what should be blocked now.
    private func reconcile() {
        let domains = Array(Set(block?.domains ?? []).union(penaltyDomains)).sorted()
        writeHosts(blocking: domains)                                   // layer 1: every program
        browserPolicy.apply(enforcing: config?.isEnforcing == true)             // layer 2: steady browser settings
        packetFilter.apply(domains: config?.packetFilterOn == true ? domains : [])   // layer 3: optional
    }

    /// Makes /etc/hosts say exactly what is wanted, touching only our section.
    private func writeHosts(blocking domains: [String]) {
        guard let current = try? String(contentsOfFile: hostsPath, encoding: .utf8) else {
            complainOnce("cannot read \(hostsPath); leaving it alone")
            return
        }
        let wanted = HostsFile.render(current, blocking: domains)
        guard wanted != current else { hostsComplaint = nil; return }
        guard HostsFile.isSafeReplacement(old: current, new: wanted) else {
            complainOnce("refusing to write hosts: the change would touch lines outside our section, or the file has no localhost entry")
            return
        }
        hostsComplaint = nil
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try? current.write(to: backupURL, atomically: true, encoding: .utf8)
        }
        do {
            // Write beside the target, fix permissions, then swap in one step.
            let temp = hostsPath + ".watchdog-tmp"
            try wanted.write(toFile: temp, atomically: false, encoding: .utf8)
            chmod(temp, 0o644)
            chown(temp, 0, 0)
            guard rename(temp, hostsPath) == 0 else { throw CocoaError(.fileWriteUnknown) }
            flushDNS()
            audit("hosts updated: \(domains.isEmpty ? "section removed" : domains.sorted().joined(separator: ","))")
        } catch {
            audit("failed to write hosts: \(error)")
        }
    }

    private func complainOnce(_ message: String) {
        guard message != hostsComplaint else { return }
        hostsComplaint = message
        audit(message)
    }

    private func flushDNS() {
        for (tool, arguments) in [("/usr/bin/dscacheutil", ["-flushcache"]), ("/usr/bin/killall", ["-HUP", "mDNSResponder"])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            try? process.run()
            process.waitUntilExit()
        }
    }

    // MARK: Requests from the app

    func status(_ reply: @escaping @Sendable (DaemonStatus) -> Void) {
        queue.async { [self] in
            let reading = clock.read()
            reply(DaemonStatus(
                block: block, config: config, pending: pending, penaltyDomains: penaltyDomains,
                agentHealthy: agent.isHealthy(at: Self.awakeSeconds()), trustedNow: reading.now, timeZoneID: clock.timeZone.identifier,
                clockChanged: reading.clockChanged, zoneChanged: reading.zoneChanged,
                isDevBuild: Limits.isDevBuild, uptimeSeconds: TrustedClock.continuousSeconds() - startedAt))
        }
    }

    func startBlock(domains: [String], seconds: Double, _ reply: @escaping @Sendable (Bool, String) -> Void) {
        queue.async { [self] in
            guard !uninstalled else { reply(false, "WatchDog has been removed."); return }
            switch Limits.validate(domains: domains, seconds: seconds) {
            case .failure(let refusal):
                audit("refused block: \(refusal)")
                reply(false, refusal.description)
            case .success(let request):
                let next = block?.merged(domains: request.domains, seconds: request.seconds)
                    ?? BlockState(domains: request.domains, seconds: request.seconds)
                block = next
                checkpoint()
                reconcile()
                audit("block: \(Int(next.remainingSeconds))s on \(next.domains.joined(separator: ","))")
                reply(true, "blocking \(next.domains.joined(separator: ", ")) for \(Int(next.remainingSeconds))s")
            }
        }
    }

    func propose(_ proposed: DaemonConfig, _ reply: @escaping @Sendable (String, String) -> Void) {
        queue.async { [self] in
            guard !uninstalled else { reply("rejected", "WatchDog has been removed."); return }
            switch ConfigPolicy.decide(current: config, proposed: proposed, blockActive: block != nil) {
            case .applyNow:
                let changed = config != proposed
                config = proposed
                save(config, to: configURL)
                // A newer request replaces whatever was waiting.
                if pending != nil {
                    pending = nil
                    try? FileManager.default.removeItem(at: pendingURL)
                }
                if changed { audit("change applied (enforcing: \(proposed.isEnforcing), rules: \(proposed.rules.count), firewall: \(proposed.packetFilterOn))") }
                reply("applied", "Saved.")
            case .delay:
                // Asking again for the same thing does not restart the wait.
                if pending?.config != proposed {
                    pending = PendingChange(config: proposed, seconds: Limits.coolingOffSeconds)
                    save(pending, to: pendingURL)
                    audit("loosening change delayed \(Int(Limits.coolingOffSeconds))s (enforcing: \(proposed.isEnforcing), rules: \(proposed.rules.count))")
                }
                reply("delayed", "Takes effect in \(Int(pending?.remainingSeconds ?? 0)) seconds.")
            case .reject(let reason):
                audit("change rejected: \(reason)")
                reply("rejected", reason)
            }
        }
    }

    func cancelPending(_ reply: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if pending != nil {
                pending = nil
                try? FileManager.default.removeItem(at: pendingURL)
                audit("pending change discarded")
            }
            reply()
        }
    }

    /// Undoes everything the daemon has put on the system and deletes its
    /// state, ready for the app to unregister it. Refused whenever it would be
    /// a way out: during a block, or while enforcing.
    func prepareUninstall(_ reply: @escaping @Sendable (Bool, String) -> Void) {
        queue.async { [self] in
            if block != nil {
                reply(false, "A block is running. WatchDog can be removed when it ends.")
                return
            }
            if config?.isEnforcing == true {
                reply(false, Limits.isDevBuild
                      ? "WatchDog is enforcing. Switch to dry run first; that takes effect after the delay."
                      : "WatchDog is enforcing, and that cannot be switched off. See docs/RESCUE.md for the way out.")
                return
            }
            audit("uninstall requested: removing hosts section, browser policy, firewall rules and state")
            penaltyDomains = []
            writeHosts(blocking: [])
            browserPolicy.apply(enforcing: false)
            guard packetFilter.teardown() else {
                reply(false, "WatchDog could not confirm its firewall rules were removed and will retry. scripts/uninstall.sh removes them directly.")
                return
            }
            // Already gone is fine: there is nothing left to undo.
            if unlink(OwnerRecord.path) != 0 && errno != ENOENT {
                reply(false, "Could not remove owner enrollment: \(String(cString: strerror(errno)))")
                return
            }
            uninstalled = true
            config = nil
            pending = nil
            try? FileManager.default.removeItem(at: directory)
            reply(true, "Removed.")
        }
    }

    func heartbeat(_ health: AgentHealth, uid: uid_t, auditID: Int32) {
        queue.async { [self] in
            guard !uninstalled else { return }
            let owner = OwnerRecord.read()
            let now = Self.awakeSeconds()
            agent.observe(consoleLogin(), owner: owner, now: now)
            if agent.receive(owner: owner, uid: uid, auditID: auditID, healthy: health.isHealthy, now: now) {
                lastHealth = health
            }
        }
    }

    // MARK: Files

    private func checkpoint() {
        lastCheckpoint = TrustedClock.continuousSeconds()
        save(block, to: stateURL)
        if pending != nil { save(pending, to: pendingURL) }
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func save<T: Encodable>(_ value: T?, to url: URL) {
        guard let value, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Appends a line to the root-owned audit log, the record of what the
    /// daemon did and of every attempt to loosen things.
    private func audit(_ text: String) {
        // One event per line, whatever the text carries.
        let message = Limits.printable(text)
        NSLog("WatchDogDaemon: %@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: auditURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: auditURL)
        }
    }
}

final class DaemonService: NSObject, WatchDogDaemonXPC, NSXPCListenerDelegate {
    let guardian: Guardian

    init(guardian: Guardian) { self.guardian = guardian }

    func ping(reply: @escaping @Sendable (String) -> Void) {
        reply("uid=\(getuid()) pid=\(getpid())")
    }

    func status(reply: @escaping @Sendable (Data) -> Void) {
        guardian.status { status in reply((try? JSONEncoder().encode(status)) ?? Data()) }
    }

    func startBlock(domains: [String], seconds: Int, reply: @escaping @Sendable (Bool, String) -> Void) {
        guardian.startBlock(domains: domains, seconds: Double(seconds), reply)
    }

    func propose(config: Data, reply: @escaping @Sendable (String, String) -> Void) {
        guard let proposed = try? JSONDecoder().decode(DaemonConfig.self, from: config) else {
            reply("rejected", "The request could not be read.")
            return
        }
        guardian.propose(proposed, reply)
    }

    func cancelPending(reply: @escaping @Sendable () -> Void) {
        guardian.cancelPending(reply)
    }

    func prepareUninstall(reply: @escaping @Sendable (Bool, String) -> Void) {
        guardian.prepareUninstall(reply)
    }

    func heartbeat(health: Data) {
        // Capture kernel-supplied credentials while this XPC invocation is current.
        guard let peer = NSXPCConnection.current(), let health = try? JSONDecoder().decode(AgentHealth.self, from: health) else { return }
        guardian.heartbeat(health, uid: peer.effectiveUserIdentifier, auditID: peer.auditSessionIdentifier)
    }

    /// Called for every incoming connection. Returning false refuses it.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard PeerHardening.accepts(connection), guardian.accepts(uid: connection.effectiveUserIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: WatchDogDaemonXPC.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

// Everything the daemon creates is private unless it says otherwise. The files
// other programs must read (hosts, browser policy) set their own permissions.
umask(0o077)
let guardian = Guardian()
guardian.start()

let service = DaemonService(guardian: guardian)
let listener = NSXPCListener(machServiceName: WD.machServiceName)
// Only our own signed app may talk to this root process. The system checks
// the caller's code signature before any message is delivered; each listener
// then also refuses a caller that code could be injected into (PeerHardening).
listener.setConnectionCodeSigningRequirement(WD.clientRequirement)
listener.delegate = service
listener.resume()
let enrollmentService = EnrollmentService(guardian: guardian)
let enrollmentListener = NSXPCListener(machServiceName: WD.enrollmentServiceName)
enrollmentListener.setConnectionCodeSigningRequirement(WD.clientRequirement)
enrollmentListener.delegate = enrollmentService
enrollmentListener.resume()
RunLoop.main.run()
