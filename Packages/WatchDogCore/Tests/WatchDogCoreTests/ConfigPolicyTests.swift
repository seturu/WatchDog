import Foundation
import Testing
@testable import WatchDogCore

struct ConfigPolicyTests {
    let youtube = Rule(id: "yt", name: "YouTube", domains: ["youtube.com"], limitSeconds: 300, action: .close)
    let example = Rule(id: "ex", name: "Example", domains: ["example.com"], limitSeconds: 0, action: .block)
    var off: Rule { var r = Rule(id: "off", name: "Dormant", domains: ["reddit.com"]); r.isEnabled = false; return r }

    func enforcing(_ rules: [Rule]) -> DaemonConfig { DaemonConfig(rules: rules, isEnforcing: true) }
    func dryRun(_ rules: [Rule]) -> DaemonConfig { DaemonConfig(rules: rules, isEnforcing: false) }

    func decide(_ current: DaemonConfig?, _ proposed: DaemonConfig, block: Bool = false, armed: Bool = false) -> ConfigPolicy.Decision {
        ConfigPolicy.decide(current: current, proposed: proposed, blockActive: block, armed: armed)
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

    @Test func addingSitesToAnActiveRuleIsTightening() {
        let current = enforcing([youtube, example])
        var more = example; more.domains = ["example.com", "example.org"]
        #expect(decide(current, enforcing([youtube, more])) == .applyNow)
        #expect(decide(current, enforcing([youtube, more]), block: true, armed: true) == .applyNow)
        var swapped = example; swapped.domains = ["example.org"]              // one in, one out
        #expect(decide(current, enforcing([youtube, swapped])) == .delay)
        // A site no block request would accept would switch the rule's blocks off.
        var never = example; never.domains = ["example.com", "apple.com"]
        #expect(decide(current, enforcing([youtube, never])) == .delay)
        var malformed = example; malformed.domains = ["example.com", "not a site"]
        #expect(decide(current, enforcing([youtube, malformed])) == .delay)
        var shouting = example; shouting.domains = ["example.com", "Example.ORG"]
        #expect(decide(current, enforcing([youtube, shouting])) == .delay)
        // Sites added together with any other edit are still an edit.
        var edited = more; edited.limitSeconds = 600
        #expect(decide(current, enforcing([youtube, edited])) == .delay)
    }

    @Test func armedRefusesEveryLooseningOutright() {
        let current = enforcing([youtube, example, off])
        let refused = ConfigPolicy.Decision.reject(ConfigPolicy.armedRefusal)
        #expect(decide(current, dryRun([youtube, example, off]), armed: true) == refused)     // back to dry run
        #expect(decide(current, enforcing([example, off]), armed: true) == refused)           // delete an active rule
        var disabled = youtube; disabled.isEnabled = false
        #expect(decide(current, enforcing([disabled, example, off]), armed: true) == refused) // switch one off
        var relaxed = youtube; relaxed.limitSeconds = 3600
        #expect(decide(current, enforcing([relaxed, example, off]), armed: true) == refused)  // raise a limit
        var narrowed = example; narrowed.domains = []
        #expect(decide(current, enforcing([youtube, narrowed, off]), armed: true) == refused) // remove a site
        let firewall = DaemonConfig(rules: [youtube], isEnforcing: true, usePacketFilter: true)
        #expect(decide(firewall, enforcing([youtube]), armed: true) == refused)               // firewall layer off
        #expect(decide(current, dryRun([youtube, example, off]), block: true, armed: true) == refused)

        // What stays possible: more rules, dormant rules, and the first switch to enforcing.
        var enabled = off; enabled.isEnabled = true
        #expect(decide(current, enforcing([youtube, example, enabled]), armed: true) == .applyNow)
        #expect(decide(current, enforcing([youtube, example]), armed: true) == .applyNow)
        #expect(decide(current, enforcing([youtube, example, off, Rule(id: "new", name: "New")]), armed: true) == .applyNow)
        #expect(decide(dryRun([youtube]), enforcing([youtube]), armed: true) == .applyNow)
        #expect(decide(dryRun([youtube]), dryRun([]), armed: true) == .applyNow)
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
