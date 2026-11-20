import Foundation

// The two blocking layers beyond /etc/hosts. As with HostsFile, everything
// here is pure text-in, text-out; the daemon does the privileged work.

/// Layer 2: browser policy.
///
/// Chromium-family browsers obey a "managed preferences" file. Measured on
/// this Mac (Brave 157): the file is read when the browser STARTS. A running
/// browser neither notices a new file nor forgets a removed one. So policy is
/// useless for timed site blocks (they would start late and outlive their
/// timer) and is used only for one steady setting: while enforcing, Brave's
/// private windows with Tor are disabled, because Tor resolves names remotely
/// and would walk past the hosts file.
///
/// Cost: Brave shows "Managed by your organization" while this is in place,
/// and both switching it on and off take effect at Brave's next launch.
public enum BrowserPolicy {
    public static let directory = "/Library/Managed Preferences"
    /// Browsers whose policy files this build has ever written (for clean-up).
    public static let bundleIDs = ["com.brave.Browser", "com.google.Chrome", "com.microsoft.edgemac"]

    public static func path(for bundleID: String) -> String { "\(directory)/\(bundleID).plist" }

    /// A file beside the policy holding a copy of what WatchDog wrote. A policy
    /// file without it, or one that no longer matches it, belongs to someone
    /// else and is never touched.
    public static func markerPath(for bundleID: String) -> String { "\(directory)/.\(WD.tag.lowercased()).\(bundleID)" }

    /// The policy file's contents, or nil when no file should exist.
    public static func plist(enforcing: Bool, bundleID: String) -> Data? {
        guard enforcing, bundleID == "com.brave.Browser" else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: ["TorDisabled": true], format: .xml, options: 0)
    }

    public enum Owner: Equatable, Sendable { case nobody, watchDog, someoneElse }

    /// Who the policy file belongs to, from its contents and our marker's.
    public static func owner(policy: Data?, marker: Data?, bundleID: String) -> Owner {
        guard let marker else { return policy == nil ? .nobody : .someoneElse }
        guard let policy else { return .watchDog }      // only our marker is left
        // Older builds left an empty marker; a policy that is exactly what
        // WatchDog writes is recognised by its contents.
        if (!marker.isEmpty && policy == marker) || policy == plist(enforcing: true, bundleID: bundleID) {
            return .watchDog
        }
        return .someoneElse
    }
}

/// Layer 3: the packet filter (pf), macOS's built-in firewall.
///
/// It blocks by IP address, for programs that ignore both hosts and browser
/// policy. It is OFF unless switched on in Settings, because address blocking
/// is blunt: sites that share addresses with a blocked one (anything on the
/// same CDN) are blocked too.
public enum PacketFilterRules {
    public static let anchor = WD.appBundleID
    public static let table = "watchdog_blocked"

    /// Rules for our own anchor (a named, separate rule group). Outbound only,
    /// to the listed addresses only: nothing here can touch loopback, the
    /// local network, or any other traffic.
    public static func anchorRules(ips: [String]) -> String {
        let list = ips.sorted().joined(separator: ", ")
        return """
        table <\(table)> { \(list) }
        block return out quick proto tcp to <\(table)>
        block drop out quick to <\(table)>

        """
    }

    private static let appleFilter = "anchor \"com.apple/*\""
    private static let appleScrub = "scrub-anchor \"com.apple/*\""

    /// Only change the filter portion of the root ruleset. Loading the full file
    /// would also reload NAT, tables, options and Apple's nested anchor file.
    public static func rootFilter(fromStock conf: String, includingWatchDog: Bool) -> String? {
        let directives = conf.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard directives == [
            appleScrub, "nat-anchor \"com.apple/*\"", "rdr-anchor \"com.apple/*\"",
            "dummynet-anchor \"com.apple/*\"", appleFilter,
            "load anchor \"com.apple\" from \"/etc/pf.anchors/com.apple\"",
        ] else { return nil }
        var rules = [appleScrub, appleFilter]
        if includingWatchDog { rules.append("anchor \"\(anchor)\"") }
        return rules.joined(separator: "\n") + "\n"
    }

    public enum LiveState: Equatable { case stock, watchDog(hasRules: Bool), unknown }

    /// pfctl writes two informational ALTQ messages to stderr on some Macs.
    /// Every other nonblank line is significant. nil if pfctl failed.
    private static func significantLines(_ result: (status: Int32, output: String)) -> [String]? {
        guard result.status == 0 else { return nil }
        return result.output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "No ALTQ support in kernel" && $0 != "ALTQ related functions disabled" }
    }

    /// Is nothing of ours loaded? True when our anchor is gone or empty,
    /// whatever else PF holds: the anchor's name is ours alone, so this needs
    /// no view of anyone else's rules.
    public static func ownAnchorIsClear(read: ([String]) -> (status: Int32, output: String)) -> Bool {
        guard let anchors = significantLines(read(["-s", "Anchors"])) else { return false }
        guard anchors.contains(anchor) else { return true }
        let scope = ["-a", anchor]
        return [["-sr"], ["-sn"], ["-s", "dummynet"], ["-s", "Tables"], ["-s", "Anchors"]]
            .allSatisfy { significantLines(read(scope + $0)) == [] }
    }

    /// Inspect each rule family separately.
    public static func inspect(read: ([String]) -> (status: Int32, output: String)) -> LiveState {
        func lines(_ arguments: [String]) -> [String]? { significantLines(read(arguments)) }

        let stock = [appleScrub + " all fragment reassemble", appleFilter + " all"]
        guard let filter = lines(["-sr"]),
              lines(["-sn"]) == ["nat-anchor \"com.apple/*\" all", "rdr-anchor \"com.apple/*\" all"],
              lines(["-s", "dummynet"]) == ["dummynet-anchor \"com.apple/*\" all"],
              lines(["-s", "Tables"]) == [],
              let anchors = lines(["-s", "Anchors"]) else { return .unknown }
        if filter == stock && anchors == ["com.apple"] { return .stock }

        let scope = ["-a", anchor]
        guard filter == stock + ["anchor \"\(anchor)\" all"],
              anchors.sorted() == ["com.apple", anchor].sorted(),
              lines(scope + ["-sn"]) == [], lines(scope + ["-s", "dummynet"]) == [],
              lines(scope + ["-s", "Anchors"]) == [],
              let rules = lines(scope + ["-sr"]), let tables = lines(scope + ["-s", "Tables"])
        else { return .unknown }

        let blockRules = ["block return out quick proto tcp from any to <\(table)>",
                          "block drop out quick from any to <\(table)>"]
        if rules.isEmpty && tables.isEmpty { return .watchDog(hasRules: false) }
        return rules == blockRules && tables == [table] ? .watchDog(hasRules: true) : .unknown
    }

    /// `pfctl -E` prints "Token : 1234567890" when it enables pf. The token is
    /// handed back later so we release only our own hold on pf.
    public static func token(fromEnableOutput output: String) -> String? {
        let tokens = output.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "Token" else { return nil }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(value) != nil else { return nil }
            return value
        }
        return tokens.count == 1 ? tokens[0] : nil
    }

    /// Accepts only public unicast IPv4/IPv6 literals. The addresses come
    /// from DNS answers, which whoever runs a blocked site controls, and end
    /// up in a root-loaded rules file: an answer such as `ff02::2` or
    /// `::ffff:127.0.0.1` must never become a firewall rule. Checked on the
    /// parsed bytes, not the text.
    public static func isBlockableIP(_ text: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return isPublic(v4: withUnsafeBytes(of: v4.s_addr) { Array($0) })
        }
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }        // 16 bytes, network order
        if b[0..<12].allSatisfy({ $0 == 0 }) { return false }  // ::, ::1, IPv4-compatible
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return false }  // IPv4-mapped
        if b[0...11].elementsEqual([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]) {
            return isPublic(v4: Array(b[12...15]))            // NAT64: judge the IPv4 address inside
        }
        if b[0] == 0xff { return false }                      // multicast (neighbour discovery lives here)
        if b[0] == 0xfe && b[1] & 0x80 == 0x80 { return false }  // link-local fe80::/10, old site-local fec0::/10
        if b[0] & 0xfe == 0xfc { return false }               // unique local fc00::/7
        if b[0...3].elementsEqual([0x20, 0x01, 0x0d, 0xb8]) { return false }  // documentation 2001:db8::/32
        // Apple's own networks. The never-block list protects Apple by name;
        // a blocked site's DNS answer must not reach it by address instead.
        if [[0x26, 0x20, 0x01, 0x49], [0x24, 0x03, 0x03, 0x00], [0x2a, 0x01, 0xb7, 0x40]]
            .contains(where: { b[0...3].elementsEqual($0) }) { return false }
        return true
    }

    /// Most addresses taken from one DNS answer, and held for one block.
    /// Real sites answer with a handful; a hostile answer could otherwise
    /// carry hundreds, and addresses only accumulate while a block runs.
    public static let maxAddressesPerAnswer = 16
    public static let maxAddresses = 256

    /// The same address always as the same text, so it can be compared.
    public static func canonical(_ text: String) -> String? {
        var v4 = in_addr()
        var v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, text, &v4) == 1, inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil {
            return String(cString: buffer)
        }
        if inet_pton(AF_INET6, text, &v6) == 1, inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil {
            return String(cString: buffer)
        }
        return nil
    }

    /// What one DNS answer may add to the block table: public addresses
    /// only, never one in `protected` (the Mac's own DNS servers: blocking
    /// those would take every site down for the length of the block), and
    /// only the first few.
    public static func admit(answer lines: [String], protected: Set<String>) -> [String] {
        let shielded = Set(protected.compactMap(canonical))
        var admitted: [String] = []
        for line in lines {
            guard admitted.count < maxAddressesPerAnswer else { break }
            guard isBlockableIP(line), let address = canonical(line),
                  !shielded.contains(address), !admitted.contains(address) else { continue }
            admitted.append(address)
        }
        return admitted
    }

    /// The part of `fresh` that still fits under the limit for one block.
    public static func fitting(_ fresh: Set<String>, into current: Set<String>) -> Set<String> {
        Set(fresh.sorted().prefix(max(0, maxAddresses - current.count)))
    }

    /// Public unicast IPv4 only. `b` is the address in network order.
    private static func isPublic(v4 b: [UInt8]) -> Bool {
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _): false        // "this network", private, loopback
        case (17, _, _): false                                // Apple (see the IPv6 ranges above)
        case (100, 64...127, _): false                        // shared address space (carrier NAT, Tailscale)
        case (169, 254, _): false                             // link-local
        case (172, 16...31, _), (192, 168, _): false          // private
        case (192, 0, 0), (192, 0, 2), (198, 51, 100), (203, 0, 113): false  // protocol use, documentation
        case (198, 18...19, _): false                         // benchmarking, also proxy apps' fake addresses
        case (224...255, _, _): false                         // multicast, reserved, broadcast
        default: true
        }
    }
}
