import Foundation
import SystemConfiguration
import WatchDogCore

/// Runs a command and returns its exit status and combined output.
/// Output is read before waiting, so a chatty tool cannot stall on a full pipe.
@discardableResult
func run(_ tool: String, _ arguments: [String], input: String? = nil) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = out
    let stdin = Pipe()
    if input != nil { process.standardInput = stdin }
    do { try process.run() } catch { return (-1, "\(error)") }
    if let input {
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Layer 2: writes and removes the browser's managed-policy file.
/// Used only on the guardian queue.
final class BrowserPolicyLayer {
    private let audit: (String) -> Void
    private var applied: Bool?

    init(audit: @escaping (String) -> Void) { self.audit = audit }

    func apply(enforcing wanted: Bool) {
        guard wanted != applied else { return }
        applied = wanted

        for bundleID in BrowserPolicy.bundleIDs {
            let path = BrowserPolicy.path(for: bundleID)
            let marker = BrowserPolicy.markerPath(for: bundleID)
            let owner = BrowserPolicy.owner(policy: FileManager.default.contents(atPath: path),
                                            marker: FileManager.default.contents(atPath: marker), bundleID: bundleID)

            if let data = BrowserPolicy.plist(enforcing: wanted, bundleID: bundleID) {
                if owner == .someoneElse {
                    audit("browser policy: \(path) is not ours (or was changed since we wrote it); leaving it alone")
                    continue
                }
                try? FileManager.default.createDirectory(atPath: BrowserPolicy.directory, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o755])
                do {
                    // The marker first, so the policy never exists without proof it is ours.
                    try data.write(to: URL(fileURLWithPath: marker), options: .atomic)
                    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                    chmod(path, 0o644)
                } catch {
                    audit("browser policy: could not write \(path): \(error)")
                }
            } else if owner == .watchDog {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: marker)
            }
        }
        audit("browser policy: \(wanted ? "Tor windows disabled in Brave (from its next launch)" : "removed")")
    }
}

/// Layer 3: the packet filter. Optional, and conservative: it only acts when
/// pf is in its stock state, and only restores the stock ruleset if pf is
/// still in the state we left it in.
///
/// All state is touched on the guardian queue. Name lookups, which can take
/// seconds when offline, run on their own queue so they never delay the
/// daemon's tick or its answers to the app.
final class PacketFilterLayer {
    typealias Command = ([String], String?) -> (status: Int32, output: String)
    private let pfctl: Command
    private let resolveDomains: ([String]) -> Set<String>
    private let tokenURL: URL
    private let stockConfig: URL

    private let queue: DispatchQueue
    private let resolverQueue = DispatchQueue(label: "watchdog.resolver")
    private let audit: (String) -> Void

    private var active = false
    /// Set when pf turned out to be in use by something else; cleared when the block ends.
    private var standingDown = false
    private var resolving = false
    private var domains: [String] = []
    private var ips: Set<String> = []
    private var lastResolve = 0.0

    private var cleanupPending = false
    private var nextCleanupAttempt = 0.0
    private var generation = 0

    init(queue: DispatchQueue, state: URL = URL(fileURLWithPath: WD.daemonStateDirectory),
         stockConfig: URL = URL(fileURLWithPath: "/etc/pf.conf"),
         pfctl: @escaping Command = { run("/sbin/pfctl", $0, input: $1) },
         resolveDomains: @escaping ([String]) -> Set<String> = PacketFilterLayer.resolve,
         audit: @escaping (String) -> Void) {
        self.queue = queue
        self.audit = audit
        self.tokenURL = state.appendingPathComponent("pf.token")
        self.stockConfig = stockConfig
        self.pfctl = pfctl
        self.resolveDomains = resolveDomains
    }

    private func liveState() -> PacketFilterRules.LiveState {
        PacketFilterRules.inspect { pfctl($0, nil) }
    }

    /// Stock, or stock plus a reference to our empty anchor, which teardown
    /// leaves behind when other software held PF rules at the time.
    private func readyToInstall() -> Bool {
        let state = liveState()
        return state == .stock || state == .watchDog(hasRules: false)
    }

    private func rootFilter(includingWatchDog: Bool) -> String? {
        guard let conf = try? String(contentsOf: stockConfig, encoding: .utf8) else { return nil }
        return PacketFilterRules.rootFilter(fromStock: conf, includingWatchDog: includingWatchDog)
    }

    func recover() {
        guard FileManager.default.fileExists(atPath: tokenURL.path) else { return }
        // Kernel rules and enable references expire at boot. A receipt from an
        // earlier boot cannot establish ownership of today's same-named anchor.
        var boot = timeval()
        var size = MemoryLayout.size(ofValue: boot)
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0,
           let saved = try? tokenURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           saved.timeIntervalSince1970 < Double(boot.tv_sec) {
            try? FileManager.default.removeItem(at: tokenURL)
            return
        }
        active = true
        teardown()
    }

    func apply(domains wanted: [String]) {
        if cleanupPending {
            guard TrustedClock.continuousSeconds() >= nextCleanupAttempt, teardown() else { return }
        }
        guard !wanted.isEmpty else {
            if active { teardown() }
            standingDown = false
            return
        }
        guard !standingDown else { return }

        if !active {
            guard let main = rootFilter(includingWatchDog: true), readyToInstall() else {
                audit("firewall: could not confirm stock PF configuration and live rules; skipping PF for this block")
                standingDown = true
                return
            }
            // Arm crash recovery before installing the reference. An empty
            // receipt means we may own rules but have no recorded enable token.
            do { try "".write(to: tokenURL, atomically: true, encoding: .utf8) } catch {
                audit("firewall: could not save recovery marker: \(error)")
                standingDown = true
                return
            }
            guard readyToInstall(), pfctl(["-R", "-f", "-"], main).status == 0 else {
                try? FileManager.default.removeItem(at: tokenURL)
                audit("firewall: could not safely install our anchor; skipping PF")
                standingDown = true
                return
            }
            active = true
            guard liveState() == .watchDog(hasRules: false) else {
                standingDown = true
                cleanupPending = true
                nextCleanupAttempt = TrustedClock.continuousSeconds() + 60
                audit("firewall: could not confirm the installed anchor; skipping PF and deferring cleanup")
                return
            }
            let enable = pfctl(["-E"], nil)
            guard enable.status == 0, let token = PacketFilterRules.token(fromEnableOutput: enable.output) else {
                audit("firewall: could not acquire an enable token; skipping PF")
                standingDown = true
                teardown()
                return
            }
            do { try token.write(to: tokenURL, atomically: true, encoding: .utf8) } catch {
                _ = pfctl(["-X", token], nil)
                audit("firewall: could not save enable token: \(error)")
                standingDown = true
                teardown()
                return
            }
            generation += 1
            ips = []
            domains = []
            lastResolve = 0
            audit("firewall: enabled with our anchor")
        }

        let now = TrustedClock.continuousSeconds()
        guard !resolving, wanted != domains || now - lastResolve >= 60 else { return }
        resolving = true
        domains = wanted
        lastResolve = now
        let resolvingGeneration = generation
        resolverQueue.async { [self] in
            let found = resolveDomains(wanted)
            queue.async { [self] in
                resolving = false
                if resolvingGeneration == generation { install(found) }
            }
        }
    }

    /// Adds newly resolved addresses to the block table. Addresses only
    /// accumulate during a block: a CDN rotating its answers must not unblock
    /// the earlier ones.
    private func install(_ resolved: Set<String>) {
        guard active, !standingDown, !cleanupPending else { return }       // the block ended while we were resolving
        let fresh = PacketFilterRules.fitting(resolved.subtracting(ips), into: ips)
        guard !fresh.isEmpty else {
            if ips.isEmpty { audit("firewall: no addresses resolved for \(domains.joined(separator: ","))") }
            return
        }
        guard liveState() == .watchDog(hasRules: !ips.isEmpty) else {
            standingDown = true
            audit("firewall: could not verify ownership before updating the anchor; skipping PF for this block")
            return
        }
        let updated = ips.union(fresh)
        let load = pfctl(["-a", PacketFilterRules.anchor, "-f", "-"],
                         PacketFilterRules.anchorRules(ips: Array(updated)))
        guard load.status == 0 else {
            audit("firewall: could not load anchor rules: \(load.output.prefix(200))")
            return
        }
        ips = updated
        // Drop connections that were already open to the new addresses. The
        // "from anywhere" side must be the same family as the address, or
        // pfctl matches nothing.
        for ip in fresh { _ = pfctl(["-k", ip.contains(":") ? "::/0" : "0.0.0.0/0", "-k", ip], nil) }
        audit("firewall: blocking \(ips.count) address(es): \(ips.sorted().joined(separator: ","))")
    }

    /// Succeeds once nothing of ours is blocking. Only that can fail: then the
    /// receipt is kept and reconciliation retries at most once a minute,
    /// never using a pending anchor for a new block.
    @discardableResult
    func teardown() -> Bool {
        guard active else { return true }
        cleanupPending = true
        nextCleanupAttempt = TrustedClock.continuousSeconds() + 60
        // Our anchor's name is ours alone, so emptying it cannot touch anyone
        // else's rules. Do it whatever else PF holds: a block must not outlive
        // its end because other software changed PF in the meantime.
        _ = pfctl(["-a", PacketFilterRules.anchor, "-f", "-"], "")
        _ = pfctl(["-a", PacketFilterRules.anchor, "-t", PacketFilterRules.table, "-T", "kill"], nil)  // normally gone already
        guard PacketFilterRules.ownAnchorIsClear(read: { pfctl($0, nil) }) else {
            audit("firewall: could not confirm our rules were removed; cleanup deferred")
            return false
        }
        // The main filter is shared. Put the stock one back only if it is
        // exactly stock plus our reference; otherwise leave it as it is. A
        // reference to our empty anchor matches nothing, and the next block
        // can reuse it.
        switch liveState() {
        case .watchDog(hasRules: false):
            if rootFilter(includingWatchDog: false).map({ pfctl(["-R", "-f", "-"], $0).status == 0 }) != true {
                audit("firewall: our rules are removed; the stock filter could not be put back (harmless, cleared at restart)")
            }
        case .stock:
            break // Already restored, e.g. by a reboot.
        case .watchDog(hasRules: true), .unknown:
            audit("firewall: our rules are removed; PF also holds other software's rules, so its main rules are left as they are")
        }
        // Hand back our hold on PF. If that fails, PF merely stays switched on,
        // with nothing of ours in it, until the next restart.
        if let token = try? String(contentsOf: tokenURL, encoding: .utf8), !token.isEmpty,
           UInt64(token) == nil || pfctl(["-X", token], nil).status != 0 {
            audit("firewall: could not release our enable reference; it expires at restart")
        }
        try? FileManager.default.removeItem(at: tokenURL)
        // Previous releases stored a generated pf.main.conf beside the token.
        try? FileManager.default.removeItem(at: tokenURL.deletingLastPathComponent().appendingPathComponent("pf.main.conf"))
        active = false
        cleanupPending = false
        ips = []
        domains = []
        audit("firewall: cleanup complete")
        return true
    }

    /// Current public addresses of the domains and their www. forms. Uses
    /// `dig`, which asks the configured DNS servers directly and ignores
    /// /etc/hosts (where these names now point at 0.0.0.0).
    ///
    /// The answers are chosen by whoever runs the blocked site, or by anyone
    /// able to forge DNS on this network, so each is filtered and capped
    /// (`PacketFilterRules.admit`) before it can become a firewall rule.
    private static func resolve(_ domains: [String]) -> Set<String> {
        let protected = configuredResolvers()
        var found: Set<String> = []
        for domain in domains {
            for name in [domain, "www." + domain] {
                for type in ["A", "AAAA"] {
                    let answer = run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", type, name])
                    guard answer.status == 0 else { continue }
                    let lines = answer.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    found.formUnion(PacketFilterRules.admit(answer: lines, protected: protected))
                }
            }
        }
        return found
    }

    /// The DNS servers this Mac is using now, from the system configuration.
    private static func configuredResolvers() -> Set<String> {
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/DNS" as CFString) as? [String: Any]
        return Set(global?["ServerAddresses"] as? [String] ?? [])
    }
}
