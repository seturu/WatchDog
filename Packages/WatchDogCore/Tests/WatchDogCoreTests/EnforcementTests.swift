import Foundation
import Testing
@testable import WatchDogCore

struct HostsFileTests {
    /// Shaped like the real file on this Mac: system lines, a third-party
    /// blocklist, local dev sites, a LAN host.
    let original = """
    ##
    # Host Database
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost
    # --- my ad blocklist ---
    0.0.0.0 ads.tracker.example.net
    127.0.0.1 myapp.test
    192.168.1.20 nas.local

    """

    @Test func addingAndRemovingOurSectionLeavesTheFileByteIdentical() {
        let blocked = HostsFile.render(original, blocking: ["example.org", "example.com"])
        #expect(blocked.hasPrefix(original))
        #expect(blocked.contains("0.0.0.0 example.com\n:: example.com\n0.0.0.0 www.example.com\n:: www.example.com"))
        #expect(HostsFile.render(blocked, blocking: []) == original)
        #expect(HostsFile.strip(blocked) == original)
    }

    @Test func renderingIsIdempotentAndReplacesAnOldSection() {
        let once = HostsFile.render(original, blocking: ["example.com"])
        #expect(HostsFile.render(once, blocking: ["example.com"]) == once)
        let changed = HostsFile.render(once, blocking: ["example.org"])
        #expect(!changed.contains("example.com"))
        #expect(changed.components(separatedBy: HostsFile.begin).count == 2)   // exactly one section
    }

    @Test func aTamperedSectionIsRestoredAndOutsideEditsAreKept() {
        let ours = HostsFile.render(original, blocking: ["example.com"])
        // The user deletes a line inside our section and adds one of their own outside it.
        let tampered = ours.replacingOccurrences(of: "0.0.0.0 example.com\n", with: "")
            .replacingOccurrences(of: "127.0.0.1 myapp.test", with: "127.0.0.1 myapp.test\n127.0.0.1 new.test")
        let repaired = HostsFile.render(tampered, blocking: ["example.com"])
        #expect(repaired.contains("0.0.0.0 example.com\n"))
        #expect(repaired.contains("127.0.0.1 new.test"))
    }

    @Test func aDeletedEndMarkerDoesNotSwallowWhatFollows() {
        // The user removes our end marker and adds their own entries below.
        let blocked = HostsFile.render(original, blocking: ["example.com"])
        let broken = blocked.replacingOccurrences(of: HostsFile.end + "\n", with: "") + "10.0.0.9 printer.lan\n# my note\n"
        let stripped = HostsFile.strip(broken)
        #expect(stripped.contains("10.0.0.9 printer.lan"))
        #expect(stripped.contains("# my note"))
        #expect(!stripped.contains("0.0.0.0 example.com"))
        // Re-rendering repairs the section and keeps their lines.
        let repaired = HostsFile.render(broken, blocking: ["example.com"])
        #expect(repaired.contains("10.0.0.9 printer.lan"))
        #expect(repaired.components(separatedBy: HostsFile.begin).count == 2)
        #expect(repaired.hasSuffix(HostsFile.end + "\n"))
        #expect(HostsFile.isSafeReplacement(old: broken, new: repaired))
    }

    @Test func aForeignLineInsideTheSectionIsKept() {
        let blocked = HostsFile.render(original, blocking: ["example.com"])
        let edited = blocked.replacingOccurrences(of: "0.0.0.0 www.example.com\n", with: "127.0.0.1 mine.test\n0.0.0.0 www.example.com\n")
        #expect(HostsFile.strip(edited).contains("127.0.0.1 mine.test"))
    }

    @Test func aFileWithoutATrailingNewlineGetsOneBeforeTheSection() {
        let ragged = "127.0.0.1 localhost"
        let blocked = HostsFile.render(ragged, blocking: ["example.com"])
        #expect(blocked.hasPrefix("127.0.0.1 localhost\n" + HostsFile.begin))
    }

    @Test func theSafetyCheckRejectsAnythingThatTouchesOtherLines() {
        let good = HostsFile.render(original, blocking: ["example.com"])
        #expect(HostsFile.isSafeReplacement(old: original, new: good))
        #expect(HostsFile.isSafeReplacement(old: good, new: original))
        #expect(!HostsFile.isSafeReplacement(old: original, new: good.replacingOccurrences(of: "myapp.test", with: "x.test")))
        #expect(!HostsFile.isSafeReplacement(old: original, new: ""))
        #expect(!HostsFile.isSafeReplacement(old: "", new: HostsFile.render("", blocking: ["example.com"])))  // no localhost
    }
}

struct BlockStateTests {
    @Test func countsDownAndExpires() {
        var block = BlockState(domains: ["example.com"], seconds: 10)
        block.advance(by: 4)
        #expect(block.remainingSeconds == 6 && !block.isExpired)
        block.advance(by: -100)          // a clock that went backwards must not add time
        #expect(block.remainingSeconds == 6)
        block.advance(by: 60)
        #expect(block.remainingSeconds == 0 && block.isExpired)
    }

    @Test func mergingOnlyEverTightens() {
        let block = BlockState(domains: ["example.com"], seconds: 200)
        let shorter = block.merged(domains: ["example.org"], seconds: 30)
        #expect(shorter.domains == ["example.com", "example.org"])
        #expect(shorter.remainingSeconds == 200)                 // never shortened
        #expect(block.merged(domains: [], seconds: 250).remainingSeconds == 250)
        #expect(shorter.id == block.id)
    }

    @Test func survivesSaveAndLoad() throws {
        var block = BlockState(domains: ["example.org", "example.com"], seconds: 120)
        block.advance(by: 20)
        let restored = try JSONDecoder().decode(BlockState.self, from: JSONEncoder().encode(block))
        #expect(restored == block)
        #expect(restored.remainingSeconds == 100)
    }

    @Test func devCapsLimitDomainsAndDuration() throws {
        let ok = try Limits.validate(domains: [" Example.COM ", "example.org"], seconds: 9999).get()
        #expect(ok.domains == ["example.com", "example.org"])
        #expect(ok.seconds == Limits.maxBlockSeconds)

        func refusal(_ domains: [String], _ seconds: Double = 60) -> String? {
            if case .failure(let error) = Limits.validate(domains: domains, seconds: seconds) { return error.description }
            return nil
        }
        #expect(refusal(["youtube.com"])?.contains("development build") == true)
        #expect(refusal([]) != nil)
        #expect(refusal(["example.com"], 0) != nil)
    }

    @Test func armedLimitsAllowAnySiteExceptTheNeverBlockList() throws {
        func check(_ domains: [String], _ seconds: Double = 600) -> Result<(domains: [String], seconds: Double), Limits.Refusal> {
            Limits.validate(domains: domains, seconds: seconds, allowed: nil, never: Limits.neverBlock, maxSeconds: 4 * 3600)
        }
        #expect(try check(["youtube.com", "Reddit.com"]).get().domains == ["reddit.com", "youtube.com"])
        #expect(try check(["youtube.com"], 99_999).get().seconds == 4 * 3600)
        for protected in ["apple.com", "www.apple.com", "swcdn.apple.com", "icloud.com", "claude.ai", "api.anthropic.com"] {
            guard case .failure(let refusal) = check([protected]) else { Issue.record("accepted \(protected)"); continue }
            #expect(refusal.description.contains("never-block"))
        }
        // A lookalike is not protected.
        #expect(try check(["notapple.com"]).get().domains == ["notapple.com"])
        // One protected name refuses the whole request.
        guard case .failure = check(["youtube.com", "apple.com"]) else { Issue.record("mixed request accepted"); return }
        // Syntax rules still apply.
        guard case .failure = check(["you tube.com"]) else { Issue.record("bad syntax accepted"); return }
    }

    @Test func domainsThatCouldInjectHostsLinesAreRefused() {
        for hostile in ["example.com\n0.0.0.0 apple.com", "example.com 1.2.3.4", "example.com#x", "exa mple.com",
                        ".example.com", "example.com.", "localhost", "-example.com", "exämple.com"] {
            guard case .failure = Limits.validate(domains: [hostile], seconds: 60) else {
                Issue.record("accepted \(hostile.debugDescription)")
                continue
            }
        }
    }

    @Test func aRefusedDomainCannotForgeAuditLogLines() {
        let forged = "evil.com\n2026-11-18T10:00:00Z block finished"
        guard case .failure(let refusal) = Limits.validate(domains: [forged], seconds: 60,
                                                            allowed: nil, never: [], maxSeconds: 600) else {
            Issue.record("a domain with a line break was accepted")
            return
        }
        #expect(!refusal.description.contains("\n"))
        #expect(refusal.description.contains("\\n"))
        #expect(Limits.printable("a\u{2028}b\tc") == "a\\u{2028}b\\tc")
    }
}
