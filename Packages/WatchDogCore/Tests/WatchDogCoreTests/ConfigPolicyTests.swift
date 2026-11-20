import Foundation
import Testing
@testable import WatchDogCore

struct ConfigPolicyTests {
    let youtube = Rule(id: "yt", name: "YouTube", domains: ["youtube.com"], limitSeconds: 300, action: .close)
    let example = Rule(id: "ex", name: "Example", domains: ["example.com"], limitSeconds: 0, action: .block)
    var off: Rule { var r = Rule(id: "off", name: "Dormant", domains: ["reddit.com"]); r.isEnabled = false; return r }

    func enforcing(_ rules: [Rule]) -> DaemonConfig { DaemonConfig(rules: rules, isEnforcing: true) }
    func dryRun(_ rules: [Rule]) -> DaemonConfig { DaemonConfig(rules: rules, isEnforcing: false) }

    func decide(_ current: DaemonConfig?, _ proposed: DaemonConfig, block: Bool = false) -> ConfigPolicy.Decision {
        ConfigPolicy.decide(current: current, proposed: proposed, blockActive: block)
    }

    @Test func inDryRunEverythingAppliesAtOnce() {
        #expect(decide(nil, dryRun([youtube])) == .applyNow)                 // first save
        #expect(decide(dryRun([youtube]), dryRun([])) == .applyNow)          // delete a rule
        #expect(decide(dryRun([youtube]), enforcing([youtube])) == .applyNow) // switch enforcement on
        #expect(decide(dryRun([youtube]), dryRun([]), block: true) == .applyNow)
    }

    @Test func whileEnforcingTighteningAppliesAtOnce() {
        let current = enforcing([youtube, off])
        #expect(decide(current, enforcing([youtube, off, example])) == .applyNow)   // add a rule
        var enabled = off; enabled.isEnabled = true
        #expect(decide(current, enforcing([youtube, enabled])) == .applyNow)        // switch a dormant rule on
        var edited = off; edited.limitSeconds = 9999
        #expect(decide(current, enforcing([youtube, edited])) == .applyNow)         // edit a dormant rule
        var renamed = youtube; renamed.name = "YT"
        #expect(decide(current, enforcing([renamed, off])) == .applyNow)            // a rename weakens nothing
        #expect(decide(current, enforcing([youtube])) == .applyNow)                 // delete a dormant rule
        #expect(decide(current, current) == .applyNow)
    }

    @Test func whileEnforcingLooseningWaits() {
        let current = enforcing([youtube, example])
        #expect(decide(current, dryRun([youtube, example])) == .delay)       // back to dry run
        #expect(decide(current, enforcing([example])) == .delay)             // delete an active rule
        var disabled = youtube; disabled.isEnabled = false
        #expect(decide(current, enforcing([disabled, example])) == .delay)   // switch one off
        var relaxed = youtube; relaxed.limitSeconds = 3600
        #expect(decide(current, enforcing([relaxed, example])) == .delay)    // raise a limit
        var narrowed = youtube; narrowed.domains = []
        #expect(decide(current, enforcing([narrowed, example])) == .delay)   // empty its site list
        var stricter = youtube; stricter.limitSeconds = 60
        // Any edit to an active rule waits, even a stricter one: the policy
        // does not try to judge direction field by field.
        #expect(decide(current, enforcing([stricter, example])) == .delay)
    }

    @Test func duringABlockLooseningIsRefused() {
        let current = enforcing([youtube])
        #expect(decide(current, dryRun([youtube]), block: true) == .reject("Locked until the current block ends."))
        #expect(decide(current, enforcing([]), block: true) == .reject("Locked until the current block ends."))
        #expect(decide(current, enforcing([youtube, example]), block: true) == .applyNow)   // tightening still fine
    }

    @Test func penaltyCoversEnabledRulesSitesThatThisBuildMayBlock() {
        #expect(ConfigPolicy.penaltyDomains(for: enforcing([youtube, example, off])) == ["example.com"])
        #expect(ConfigPolicy.penaltyDomains(for: dryRun([example])) == [])
        #expect(ConfigPolicy.penaltyDomains(for: nil) == [])
    }

    @Test func penaltyDomainsAreCleanedNotCopiedFromTheRuleText() {
        var messy = example
        messy.domains = [" Example.COM ", "example.org\n", "bad domain.com"]
        #expect(ConfigPolicy.penaltyDomains(for: enforcing([messy])) == ["example.com", "example.org"])
    }

    @Test func statusSurvivesTheTripAcrossXPC() throws {
        let status = DaemonStatus(
            block: BlockState(domains: ["example.com"], seconds: 60),
            config: enforcing([youtube]), pending: PendingChange(config: dryRun([youtube]), seconds: 120),
            penaltyDomains: ["example.com"], agentHealthy: false,
            trustedNow: Date(timeIntervalSince1970: 1_800_000_000), timeZoneID: "America/Sao_Paulo",
            clockChanged: true, zoneChanged: false, isDevBuild: true, uptimeSeconds: 12.5)
        #expect(try JSONDecoder().decode(DaemonStatus.self, from: JSONEncoder().encode(status)) == status)
    }

    @Test func aBlindAppIsNotHealthy() {
        #expect(AgentHealth(accessibilityGranted: true, deniedBrowsers: []).canSee)
        #expect(!AgentHealth(accessibilityGranted: false, deniedBrowsers: []).canSee)
        #expect(!AgentHealth(accessibilityGranted: true, deniedBrowsers: ["com.brave.Browser"]).canSee)
    }

    @Test func twoRulesWithTheSameIDAreRefused() {
        // A quiet "warn" twin under the ID of an enforcing "close" rule.
        var twin = youtube
        twin.action = .warn
        twin.limitSeconds = 0
        twin.cooldownSeconds = 0
        let current = enforcing([youtube])
        #expect(decide(current, enforcing([youtube, twin])) == .reject("Two rules share the same ID."))
        #expect(decide(dryRun([youtube]), dryRun([youtube, twin])) == .reject("Two rules share the same ID."))
        #expect(decide(current, enforcing([youtube, example])) == .applyNow)
    }
}
