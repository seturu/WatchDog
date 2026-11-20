import Foundation
import Testing
@testable import WatchDogCore

struct BlockLayerTests {
    // MARK: Browser policy

    @Test func whileEnforcingBraveGetsTorDisabledAndNothingElse() throws {
        let brave = try #require(BrowserPolicy.plist(enforcing: true, bundleID: "com.brave.Browser"))
        let parsed = try #require(try PropertyListSerialization.propertyList(from: brave, format: nil) as? [String: Any])
        #expect(parsed.count == 1)
        #expect(parsed["TorDisabled"] as? Bool == true)
        // No site lists: a running browser would apply them late and keep them too long.
        #expect(parsed["URLBlocklist"] == nil)
    }

    @Test func noPolicyFileInDryRunOrForOtherBrowsers() {
        #expect(BrowserPolicy.plist(enforcing: false, bundleID: "com.brave.Browser") == nil)
        #expect(BrowserPolicy.plist(enforcing: true, bundleID: "com.google.Chrome") == nil)
        #expect(BrowserPolicy.path(for: "com.brave.Browser") == "/Library/Managed Preferences/com.brave.Browser.plist")
    }

    // MARK: Packet filter

    /// The real /etc/pf.conf on this Mac, comments removed.
    let stockConf = """
    scrub-anchor "com.apple/*"
    nat-anchor "com.apple/*"
    rdr-anchor "com.apple/*"
    dummynet-anchor "com.apple/*"
    anchor "com.apple/*"
    load anchor "com.apple" from "/etc/pf.anchors/com.apple"

    """

    @Test func rootFilterLoadsOnlyVerifiedFilterDirectives() {
        let base = "scrub-anchor \"com.apple/*\"\nanchor \"com.apple/*\"\n"
        #expect(PacketFilterRules.rootFilter(fromStock: "# comment\n" + stockConf, includingWatchDog: true)
                == base + "anchor \"\(PacketFilterRules.anchor)\"\n")
        #expect(PacketFilterRules.rootFilter(fromStock: stockConf, includingWatchDog: false) == base)
        for conf in ["", "anchor \"com.apple/*\"", stockConf + "pass all\n"] {
            for installing in [true, false] {
                #expect(PacketFilterRules.rootFilter(fromStock: conf, includingWatchDog: installing) == nil)
            }
        }
    }

    @Test func anchorRulesOnlyBlockOutboundToTheTable() {
        let rules = PacketFilterRules.anchorRules(ips: ["93.184.216.34", "2606:2800:220:1::1"])
        #expect(rules.contains("table <watchdog_blocked> { 2606:2800:220:1::1, 93.184.216.34 }"))
        let ruleLines = rules.split(separator: "\n").filter { $0.hasPrefix("block") }
        #expect(ruleLines.count == 2)
        #expect(ruleLines.allSatisfy { $0.contains(" out ") && $0.hasSuffix("to <watchdog_blocked>") })
        #expect(!rules.contains("pass"))
        #expect(!rules.contains(" in "))
    }

    private typealias Reply = (status: Int32, output: String)
    private let filter = "scrub-anchor \"com.apple/*\" all fragment reassemble\nanchor \"com.apple/*\" all"
    private let nat = "nat-anchor \"com.apple/*\" all\nrdr-anchor \"com.apple/*\" all"

    private func snapshot(owned: Bool) -> [[String]: Reply] {
        let anchor = PacketFilterRules.anchor
        let scope = ["-a", anchor]
        var replies: [[String]: Reply] = [
            ["-sr"]: (0, owned ? filter + "\nanchor \"\(anchor)\" all" : filter),
            ["-sn"]: (0, nat),
            ["-s", "dummynet"]: (0, "dummynet-anchor \"com.apple/*\" all"),
            ["-s", "Tables"]: (0, ""),
            ["-s", "Anchors"]: (0, owned ? "com.apple\n" + anchor : "com.apple"),
        ]
        if owned {
            for query in [["-sr"], ["-sn"], ["-s", "dummynet"], ["-s", "Tables"], ["-s", "Anchors"]] {
                replies[scope + query] = (0, "")
            }
        }
        return replies
    }

    @Test func onlyCompleteStockAndWatchDogSnapshotsAreRecognized() {
        for owned in [false, true] {
            var replies = snapshot(owned: owned)
            replies[["-sr"]]!.output += "\nNo ALTQ support in kernel\nALTQ related functions disabled\n"
            let state = PacketFilterRules.inspect { replies[$0] ?? (-1, "") }
            #expect(state == (owned ? .watchDog(hasRules: false) : .stock))
        }
        var installed = snapshot(owned: true)
        let scope = ["-a", PacketFilterRules.anchor]
        installed[scope + ["-sr"]] = (0, "block return out quick proto tcp from any to <watchdog_blocked>\nblock drop out quick from any to <watchdog_blocked>")
        installed[scope + ["-s", "Tables"]] = (0, "watchdog_blocked")
        #expect(PacketFilterRules.inspect { installed[$0] ?? (-1, "") } == .watchDog(hasRules: true))
    }

    @Test func failedIncompleteOrAmbiguousInspectionNeverAuthorizesPF() {
        for owned in [false, true] {
            let good = snapshot(owned: owned)
            for (query, reply) in good {
                var invalid: [Reply] = [(1, reply.output), (-1, ""), (0, reply.output + "\nunrecognized directive")]
                if !reply.output.isEmpty { invalid += [(0, ""), (0, reply.output + "\n" + reply.output)] }
                for bad in invalid {
                    let state = PacketFilterRules.inspect { $0 == query ? bad : good[$0] ?? (-1, "") }
                    #expect(state == .unknown)
                }
            }
        }
        for filters in ["anchor \"com.apple/*\" all", nat + "\n" + filter, filter + "\npass all"] {
            var replies = snapshot(owned: false)
            replies[["-sr"]] = (0, filters)
            #expect(PacketFilterRules.inspect { replies[$0] ?? (-1, "") } == .unknown)
        }
    }

    @Test func aPolicyIsOursOnlyWhileItIsWhatWeWrote() throws {
        let brave = "com.brave.Browser"
        let ours = try #require(BrowserPolicy.plist(enforcing: true, bundleID: brave))
        let theirs = try PropertyListSerialization.data(fromPropertyList: ["URLBlocklist": ["example.com"]], format: .xml, options: 0)
        #expect(BrowserPolicy.owner(policy: nil, marker: nil, bundleID: brave) == .nobody)
        #expect(BrowserPolicy.owner(policy: theirs, marker: nil, bundleID: brave) == .someoneElse)
        #expect(BrowserPolicy.owner(policy: ours, marker: ours, bundleID: brave) == .watchDog)
        #expect(BrowserPolicy.owner(policy: nil, marker: ours, bundleID: brave) == .watchDog)       // a stale marker
        #expect(BrowserPolicy.owner(policy: ours, marker: Data(), bundleID: brave) == .watchDog)    // older builds' empty marker
        // Replaced by another manager after we wrote ours: theirs now.
        #expect(BrowserPolicy.owner(policy: theirs, marker: ours, bundleID: brave) == .someoneElse)
        #expect(BrowserPolicy.owner(policy: theirs, marker: Data(), bundleID: brave) == .someoneElse)
        #expect(BrowserPolicy.owner(policy: theirs, marker: Data(), bundleID: "com.google.Chrome") == .someoneElse)
    }

    @Test func ourAnchorIsClearWhateverElsePFHolds() {
        let scope = ["-a", PacketFilterRules.anchor]
        // Gone entirely, or present and empty, with or without other software's anchors.
        #expect(PacketFilterRules.ownAnchorIsClear { snapshot(owned: false)[$0] ?? (-1, "") })
        var shared = snapshot(owned: true)
        shared[["-s", "Anchors"]]!.output += "\ncom.vendor"
        shared[["-s", "Tables"]] = (0, "vendor_table")
        #expect(PacketFilterRules.ownAnchorIsClear { shared[$0] ?? (-1, "") })

        // Anything left inside our anchor, or a failed query, means not clear.
        for (query, leftover) in [(["-sr"], "block drop out quick from any to <watchdog_blocked>"),
                                  (["-s", "Tables"], "watchdog_blocked")] {
            var replies = shared
            replies[scope + query] = (0, leftover)
            #expect(!PacketFilterRules.ownAnchorIsClear { replies[$0] ?? (-1, "") })
        }
        for query in [["-s", "Anchors"], scope + ["-sr"], scope + ["-s", "Tables"]] {
            var replies = shared
            replies[query] = (1, "")
            #expect(!PacketFilterRules.ownAnchorIsClear { replies[$0] ?? (-1, "") })
        }
    }

    @Test func enableTokenIsParsed() {
        #expect(PacketFilterRules.token(fromEnableOutput: "No ALTQ support in kernel\nALTQ related functions disabled\npf enabled\nToken : 18446744071562067947\n") == "18446744071562067947")
        for bad in ["pfctl: pf already enabled\n", "Bad Token 123", "Token : 123x", "Token : 12\nToken : 34"] {
            #expect(PacketFilterRules.token(fromEnableOutput: bad) == nil)
        }
    }

    @Test func onlyPublicAddressLiteralsAreBlockable() {
        for ok in ["93.184.216.34", "104.20.23.154", "2606:4700:10::6814:179a", "172.66.147.243", "172.32.0.1",
                   "100.63.0.1", "100.128.0.1", "198.20.0.1", "64:ff9b::5db8:d822", "fe8::1", "fc0::1"] {
            #expect(PacketFilterRules.isBlockableIP(ok), "\(ok)")
        }
        for bad in ["0.0.0.0", "127.0.0.1", "10.0.0.5", "192.168.1.20", "172.16.4.4", "172.31.255.1", "169.254.1.1",
                    "224.0.0.251", "255.255.255.255", "::", "::1", "fe80::1", "FEBF::1", "fec0::1", "fd00::1", "fc00::1",
                    // What a hostile DNS answer could carry: multicast (IPv6 neighbour discovery), loopback in
                    // IPv6 clothing, shared and documentation ranges, and NAT64 wrapping a private address.
                    "ff02::1", "ff02::2", "ff02::1:ff00:1", "::ffff:127.0.0.1", "::ffff:8.8.8.8", "::127.0.0.1",
                    "100.64.0.1", "100.100.100.100", "198.18.0.1", "192.0.2.1", "203.0.113.9", "2001:db8::1",
                    "64:ff9b::7f00:1", "64:ff9b::a00:1",
                    // Apple's networks: protected by name on the never-block list, so by address too.
                    "17.253.144.10", "2620:149:a44::10", "2403:300:a42::1", "2a01:b740:a42::1", "64:ff9b::11fd:900a",
                    "example.com", "1.2.3.4 }\npass all", "1.2.3", "", "1.2.3.4/0", "any"] {
            #expect(!PacketFilterRules.isBlockableIP(bad), "\(bad.debugDescription)")
        }
    }

    @Test func aDNSAnswerCannotBlockTheResolverOrFloodTheTable() {
        // The Mac's own DNS server is never admitted, however it is written.
        #expect(PacketFilterRules.admit(answer: ["1.1.1.1", "93.184.216.34", "2606:4700:4700:0:0:0:0:1111", "10.0.0.1", "junk"],
                                        protected: ["1.1.1.1", "2606:4700:4700::1111"]) == ["93.184.216.34"])
        // Duplicates collapse, and only the first few of a long answer are taken.
        let many = (1...200).map { "93.184.\($0 / 250).\($0 % 250 + 1)" }
        #expect(PacketFilterRules.admit(answer: ["93.184.0.2"] + many, protected: []).count == PacketFilterRules.maxAddressesPerAnswer)
        // Over a whole block the table stops growing at its limit.
        let held = Set((0..<250).map { "198.20.0.\($0)" })
        let fresh = Set((0..<50).map { "198.21.0.\($0)" })
        #expect(PacketFilterRules.fitting(fresh, into: held).count == 6)
        #expect(PacketFilterRules.fitting(fresh, into: held.union(fresh)).isEmpty)
    }

    // MARK: Config

    @Test func switchingTheFirewallLayerOffWhileEnforcingIsLoosening() {
        let rule = Rule(id: "a", name: "A", domains: ["example.com"])
        let on = DaemonConfig(rules: [rule], isEnforcing: true, usePacketFilter: true)
        let off = DaemonConfig(rules: [rule], isEnforcing: true, usePacketFilter: false)
        #expect(ConfigPolicy.decide(current: on, proposed: off, blockActive: false) == .delay)
        #expect(ConfigPolicy.decide(current: off, proposed: on, blockActive: false) == .applyNow)
        #expect(ConfigPolicy.decide(current: on, proposed: off, blockActive: true) == .reject("Locked until the current block ends."))
    }

    @Test func configFilesFromBeforeTheFirewallSwitchStillLoad() throws {
        let old = Data(#"{"rules":[],"isEnforcing":true}"#.utf8)
        let config = try JSONDecoder().decode(DaemonConfig.self, from: old)
        #expect(config.isEnforcing && !config.packetFilterOn)
    }
}
