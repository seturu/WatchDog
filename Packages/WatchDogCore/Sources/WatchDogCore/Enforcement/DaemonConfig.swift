import Foundation

/// What the daemon holds on your behalf: the rules, and whether they bite.
/// Stored in a root-owned file, so changing it means asking the daemon.
public struct DaemonConfig: Codable, Sendable, Equatable {
    public var rules: [Rule]
    public var isEnforcing: Bool
    /// Also block by IP address with the firewall. Nil (older files) means off.
    public var usePacketFilter: Bool?

    public init(rules: [Rule], isEnforcing: Bool, usePacketFilter: Bool = false) {
        self.rules = rules
        self.isEnforcing = isEnforcing
        self.usePacketFilter = usePacketFilter
    }

    public var packetFilterOn: Bool { usePacketFilter ?? false }
}

/// A requested change that loosens things, waiting out its cooling-off delay.
public struct PendingChange: Codable, Sendable, Equatable {
    public var config: DaemonConfig
    public var remainingSeconds: Double
    public var totalSeconds: Double

    public init(config: DaemonConfig, seconds: Double) {
        self.config = config
        self.remainingSeconds = seconds
        self.totalSeconds = seconds
    }
}

/// What the app reports about itself in each heartbeat.
public struct AgentHealth: Codable, Sendable, Equatable {
    /// Without Accessibility the app cannot read window titles.
    public var accessibilityGranted: Bool
    /// Browsers the app is running but not allowed to read addresses from.
    public var deniedBrowsers: [String]
    /// Awake seconds since the rules were last checked successfully, measured
    /// when the heartbeat was sent. nil from the development command line.
    public var secondsSinceEvaluation: Double?
    /// True while the app is waiting on a browser's answer to an Apple Event.
    public var waitingOnBrowser: Bool?

    public init(accessibilityGranted: Bool, deniedBrowsers: [String],
                secondsSinceEvaluation: Double? = nil, waitingOnBrowser: Bool? = nil) {
        self.accessibilityGranted = accessibilityGranted
        self.deniedBrowsers = deniedBrowsers
        self.secondsSinceEvaluation = secondsSinceEvaluation
        self.waitingOnBrowser = waitingOnBrowser
    }

    /// Can the app still see what it needs to judge the rules?
    public var canSee: Bool { accessibilityGranted && deniedBrowsers.isEmpty }

    /// Is the app still checking the rules, not just sending heartbeats?
    public var isEvaluating: Bool {
        guard let age = secondsSinceEvaluation else { return true }
        let grace = waitingOnBrowser == true ? Limits.browserPromptGraceSeconds : Limits.evaluationGraceSeconds
        return age <= grace
    }

    public var isHealthy: Bool { canSee && isEvaluating }
}

/// Everything the app needs to know about the daemon, in one answer.
public struct DaemonStatus: Codable, Sendable, Equatable {
    public var block: BlockState?
    /// Nil until rules have been stored for the first time.
    public var config: DaemonConfig?
    public var pending: PendingChange?
    /// Sites blocked right now because the app is silent or blind while enforcing.
    public var penaltyDomains: [String]
    public var agentHealthy: Bool
    /// The daemon's trusted clock: pinned at boot, immune to date changes.
    public var trustedNow: Date
    public var timeZoneID: String
    public var clockChanged: Bool
    public var zoneChanged: Bool
    public var isDevBuild: Bool
    public var uptimeSeconds: Double

    public init(block: BlockState?, config: DaemonConfig?, pending: PendingChange?, penaltyDomains: [String],
                agentHealthy: Bool, trustedNow: Date, timeZoneID: String, clockChanged: Bool, zoneChanged: Bool,
                isDevBuild: Bool, uptimeSeconds: Double) {
        self.block = block
        self.config = config
        self.pending = pending
        self.penaltyDomains = penaltyDomains
        self.agentHealthy = agentHealthy
        self.trustedNow = trustedNow
        self.timeZoneID = timeZoneID
        self.clockChanged = clockChanged
        self.zoneChanged = zoneChanged
        self.isDevBuild = isDevBuild
        self.uptimeSeconds = uptimeSeconds
    }
}

/// The rules about changing the rules. Pure and unit-tested.
public enum ConfigPolicy {

    public enum Decision: Sendable, Equatable {
        /// Takes effect immediately.
        case applyNow
        /// Takes effect after the cooling-off delay.
        case delay
        case reject(String)
    }

    /// What happens to a requested change.
    ///
    /// In dry run nothing is at stake, so everything applies at once. While
    /// enforcing, a change that only tightens applies at once. Anything else
    /// is refused outright by the armed build: once it enforces there is no
    /// way back to dry run and nothing can be removed, changed or switched
    /// off. The development build makes such a change wait instead, and
    /// refuses it while a block is running.
    public static func decide(current: DaemonConfig?, proposed: DaemonConfig, blockActive: Bool,
                              armed: Bool = !Limits.isDevBuild) -> Decision {
        // Rule IDs key cooldowns and the tightening check. A second rule
        // under an enabled rule's ID would pass as "unchanged" and could keep
        // the real one quiet by refreshing their shared cooldown.
        if Set(proposed.rules.map(\.id)).count != proposed.rules.count {
            return .reject("Two rules share the same ID.")
        }
        guard let current, current.isEnforcing else { return .applyNow }
        if current.rules == proposed.rules && current.isEnforcing == proposed.isEnforcing
            && current.packetFilterOn == proposed.packetFilterOn { return .applyNow }
        if isTightening(from: current, to: proposed) { return .applyNow }
        if armed { return .reject(armedRefusal) }
        if blockActive { return .reject("Locked until the current block ends.") }
        return .delay
    }

    /// What the armed build answers to anything that is not tightening.
    public static let armedRefusal = "WatchDog is enforcing. Rules can gain sites, new rules can be added and "
        + "rules that are off can be switched on. Nothing can be removed, changed or switched off."

    /// True if nothing that currently bites is weakened: enforcement stays on,
    /// and every enabled rule is still there, unchanged apart from its name
    /// and any sites added to it. Adding rules, or switching on or editing
    /// rules that were off, is fine.
    public static func isTightening(from current: DaemonConfig, to proposed: DaemonConfig) -> Bool {
        guard proposed.isEnforcing else { return false }
        // Switching a blocking layer off is loosening.
        if current.packetFilterOn && !proposed.packetFilterOn { return false }
        let proposedByID = Dictionary(proposed.rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return current.rules.filter(\.isEnabled).allSatisfy { rule in
            guard var match = proposedByID[rule.id] else { return false }
            match.name = rule.name
            // More sites only widen what the rule catches, as long as every
            // site it already had is still there and each new one can be
            // blocked: a block request is refused as a whole if one of its
            // sites is malformed or on the never-block list, so such an
            // addition would switch the rule's blocks off.
            let had = Set(rule.domains)
            guard had.isSubset(of: match.domains) else { return false }
            for added in match.domains where !had.contains(added) {
                guard case .success(let ok) = Limits.validate(domains: [added], seconds: 1), ok.domains == [added] else { return false }
            }
            match.domains = rule.domains
            return match == rule
        }
    }

    /// Sites to block while the app cannot do its job: every site named by an
    /// enabled rule (that this build is allowed to block).
    public static func penaltyDomains(for config: DaemonConfig?) -> [String] {
        guard let config, config.isEnforcing else { return [] }
        let all = Set(config.rules.filter(\.isEnabled).flatMap(\.domains))
        // Use the validator's cleaned output: the raw rule text may carry
        // whitespace or capitals, and these strings go into /etc/hosts.
        let cleaned = all.flatMap { domain -> [String] in
            if case .success(let ok) = Limits.validate(domains: [domain], seconds: 1) { return ok.domains }
            return []
        }
        return Array(Set(cleaned)).sorted()
    }
}
