import Foundation

/// A running block: these domains, for this much longer.
///
/// Time is kept as "seconds remaining" and counted down from a clock that
/// cannot be set by the user, so changing the system date does nothing and a
/// reboot resumes from the last saved value.
public struct BlockState: Codable, Sendable, Equatable {
    public var id: String
    public var domains: [String]
    public var remainingSeconds: Double
    /// The longest duration this block was ever asked for, for progress display.
    public var totalSeconds: Double

    public init(id: String = UUID().uuidString, domains: [String], seconds: Double) {
        self.id = id
        self.domains = domains.sorted()
        self.remainingSeconds = seconds
        self.totalSeconds = seconds
    }

    public var isExpired: Bool { remainingSeconds <= 0 }

    public mutating func advance(by seconds: Double) {
        remainingSeconds = max(0, remainingSeconds - max(0, seconds))
    }

    /// Adding to a running block can only make it stricter: more domains, and
    /// never less time than is already left.
    public func merged(domains more: [String], seconds: Double) -> BlockState {
        var next = self
        next.domains = Array(Set(domains).union(more)).sorted()
        next.remainingSeconds = max(remainingSeconds, seconds)
        next.totalSeconds = max(totalSeconds, seconds)
        return next
    }
}

/// Limits compiled into the build.
///
/// Development builds are capped hard, so a bug in half-built enforcement
/// cannot lock the developer out of anything real. The armed build (ARMED,
/// Xcode's Release configuration) lifts the caps but keeps two guard rails:
/// a longest block, and a list of sites that can never be blocked.
public enum Limits {
    #if ARMED
    public static let isDevBuild = false
    /// No single block may run longer than this.
    public static let maxBlockSeconds: Double = 4 * 3600
    /// Nil: any site may be blocked, except `neverBlock`.
    public static let blockableDomains: Set<String>? = nil
    /// No dead-man switch: the daemon runs until the Mac shuts down.
    public static let deadManSeconds: Double? = nil
    /// How long a loosening change waits before it takes effect while enforcing.
    public static let coolingOffSeconds: Double = 2 * 3600
    #else
    public static let isDevBuild = true
    public static let maxBlockSeconds: Double = 300
    /// Only these reserved test domains may be blocked.
    public static let blockableDomains: Set<String>? = ["example.com", "example.org", "example.net"]
    /// Dead-man switch: the daemon removes everything it applied and exits
    /// this long after starting, whatever its state says.
    public static let deadManSeconds: Double? = 900
    /// Two minutes, so the delay can be tested.
    public static let coolingOffSeconds: Double = 120
    #endif

    /// Sites that can never be blocked, whatever a rule says: without them the
    /// Mac cannot update, sign in to iCloud, or (for the last two) let you fix
    /// a broken rule with help. Subdomains are included.
    public static let neverBlock: Set<String> = [
        "apple.com", "icloud.com", "cdn-apple.com", "mzstatic.com", "anthropic.com", "claude.ai",
    ]

    /// The app counts as silent after this long without a heartbeat
    /// (measured in awake time, so waking from sleep is not a violation).
    public static let heartbeatGraceSeconds: Double = 45

    /// A heartbeat only counts if the rules were also checked recently. The
    /// background heartbeat keeps going when the app's main thread is stuck,
    /// so it reports how long ago the last successful check was (awake time).
    public static let evaluationGraceSeconds: Double = 90
    /// Longer allowance while the app waits on a browser, for instance while
    /// a first-time Automation prompt is on screen. A prompt left unanswered
    /// for longer than this is treated like any other stall.
    public static let browserPromptGraceSeconds: Double = 300

    public struct Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The text with line breaks and other control characters shown as
    /// escapes, so a refused string cannot forge lines in the audit log.
    public static func printable<S: StringProtocol>(_ text: S) -> String {
        String(text).unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}"
                ? scalar.escaped(asASCII: true) : String(scalar)
        }.joined()
    }

    /// Checks a block request against this build's limits.
    public static func validate(domains: [String], seconds: Double) -> Result<(domains: [String], seconds: Double), Refusal> {
        validate(domains: domains, seconds: seconds, allowed: blockableDomains, never: neverBlock, maxSeconds: maxBlockSeconds)
    }

    /// The same check with the limits passed in, so both builds' behaviour can be tested.
    ///
    /// Domain syntax is checked strictly even though the caller is our own
    /// app: these strings are written into /etc/hosts by a root process, so a
    /// space or newline in one would let it inject arbitrary host entries.
    public static func validate(domains: [String], seconds: Double, allowed: Set<String>?, never: Set<String>,
                                maxSeconds: Double) -> Result<(domains: [String], seconds: Double), Refusal> {
        let cleaned = Set(domains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).sorted()
        guard !cleaned.isEmpty else { return .failure(.init(description: "no domains given")) }
        for domain in cleaned {
            let wellFormed = domain.count <= 253
                && domain.contains(".")
                && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.hasPrefix("-")
                && domain.unicodeScalars.allSatisfy { scalar in
                    ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "." || scalar == "-"
                }
            guard wellFormed else { return .failure(.init(description: "not a valid domain name: \(printable(domain.prefix(60)))")) }
            if let allowed {
                guard allowed.contains(domain) else {
                    return .failure(.init(description: "development build: only \(allowed.sorted().joined(separator: ", ")) can be blocked, not \(domain)"))
                }
            } else if never.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
                return .failure(.init(description: "\(domain) is on the never-block list"))
            }
        }
        guard seconds >= 1 else { return .failure(.init(description: "duration must be at least one second")) }
        return .success((cleaned, min(seconds, maxSeconds)))
    }
}
