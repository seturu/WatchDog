import Foundation
import Testing
@testable import WatchDogCore

struct OwnerAccessTests {
    private func login(_ uid: UInt32, _ id: Int32) -> ConsoleLogin? {
        ConsoleLogin(snapshot: ["Name": "user", "UID": uid, "SessionInfo": [
            ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": uid, "kCGSSessionAuditIDKey": id]
        ]])
    }

    @Test func onlyEnrolledUIDCanConnect() {
        #expect(OwnerRecord.enrolled(501).allows(501))
        #expect(!OwnerRecord.enrolled(501).allows(502))
        #expect(!OwnerRecord.enrolled(501).allows(0))
        #expect(!OwnerRecord.missing.allows(501))
        #expect(!OwnerRecord.invalid.allows(501))
    }

    @Test func recordMustBeAProtectedRegularFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("owner")
        #expect(OwnerRecord.read(at: path.path) == .missing)
        try Data("501\n".utf8).write(to: path)
        #expect(chmod(path.path, 0o666) == 0)
        #expect(OwnerRecord.read(at: path.path) == .invalid)
        #expect(chmod(path.path, 0o644) == 0)
        #expect(OwnerRecord.read(at: path.path) == (getuid() == 0 ? .enrolled(501) : .invalid))
        let link = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        #expect(OwnerRecord.read(at: link.path) == .invalid)
    }

    @Test func fastUserSwitchDiscardsHealthAndRestartsOwnerGrace() {
        var agent = OwnerHeartbeat()
        let owner = OwnerRecord.enrolled(501)
        agent.observe(login(501, 21), owner: owner, now: 0)
        agent.receive(owner: owner, uid: 501, auditID: 21, healthy: false, now: 1)
        agent.observe(login(502, 22), owner: owner, now: 2)
        #expect(agent.login == nil)
        agent.receive(owner: owner, uid: 501, auditID: 21, healthy: false, now: 3)
        agent.observe(login(501, 21), owner: owner, now: 120)
        #expect(agent.isHealthy(at: 121))
        #expect(!agent.isHealthy(at: 200))
    }

    @Test func onlyCurrentOwnerSessionCanReportHealth() {
        var agent = OwnerHeartbeat()
        agent.observe(login(501, 45), owner: .enrolled(501), now: 0)
        for (owner, uid, auditID): (OwnerRecord, uid_t, Int32) in [
            (.missing, 501, 45), (.enrolled(501), 502, 45), (.enrolled(501), 501, 46)
        ] {
            agent.receive(owner: owner, uid: uid, auditID: auditID, healthy: true, now: 60)
            #expect(!agent.isHealthy(at: 61))
        }
        agent.receive(owner: .enrolled(501), uid: 501, auditID: 45, healthy: true, now: 62)
        #expect(agent.isHealthy(at: 63))
        #expect(!agent.isHealthy(at: 120))
        agent.receive(owner: .enrolled(501), uid: 501, auditID: 45, healthy: false, now: 121)
        #expect(!agent.isHealthy(at: 121))

        // A new login of the same account gets its own grace period.
        agent.observe(login(501, 47), owner: .enrolled(501), now: 122)
        agent.receive(owner: .enrolled(501), uid: 501, auditID: 45, healthy: false, now: 124)
        #expect(agent.isHealthy(at: 125))
        #expect(!agent.isHealthy(at: 200))
        agent.observe(nil, owner: .enrolled(501), now: 201)
        #expect(agent.isHealthy(at: 300))
    }

    @Test func aHeartbeatCountsOnlyWhileTheRulesAreStillChecked() throws {
        func health(_ age: Double?, waiting: Bool? = nil, accessibility: Bool = true) -> AgentHealth {
            AgentHealth(accessibilityGranted: accessibility, deniedBrowsers: [],
                        secondsSinceEvaluation: age, waitingOnBrowser: waiting)
        }
        #expect(health(5).isHealthy)
        #expect(health(Limits.evaluationGraceSeconds).isHealthy)
        #expect(!health(Limits.evaluationGraceSeconds + 1).isHealthy)
        // A browser prompt on screen buys time, but not forever.
        #expect(health(Limits.evaluationGraceSeconds + 1, waiting: true).isHealthy)
        #expect(!health(Limits.browserPromptGraceSeconds + 1, waiting: true).isHealthy)
        #expect(!health(Limits.evaluationGraceSeconds + 1, waiting: false).isHealthy)
        // Being able to see still matters on its own.
        #expect(!health(5, accessibility: false).isHealthy)

        // Heartbeats without the new fields (the development command line) still decode.
        let old = try JSONDecoder().decode(AgentHealth.self, from: Data(#"{"accessibilityGranted":true,"deniedBrowsers":[]}"#.utf8))
        #expect(old.secondsSinceEvaluation == nil && old.isHealthy)
        let sent = health(12.5, waiting: true)
        #expect(try JSONDecoder().decode(AgentHealth.self, from: JSONEncoder().encode(sent)) == sent)
    }

    @Test func aStalledAppTriggersThePenaltyEvenWhileHeartbeatsArrive() {
        var agent = OwnerHeartbeat()
        let owner = OwnerRecord.enrolled(501)
        agent.observe(login(501, 21), owner: owner, now: 0)
        let stalled = AgentHealth(accessibilityGranted: true, deniedBrowsers: [],
                                  secondsSinceEvaluation: Limits.evaluationGraceSeconds + 10)
        let accepted = agent.receive(owner: owner, uid: 501, auditID: 21, healthy: stalled.isHealthy, now: 100)
        #expect(accepted)
        #expect(agent.isFresh(at: 101) && !agent.isHealthy(at: 101))
        let foreign = agent.receive(owner: owner, uid: 502, auditID: 21, healthy: true, now: 102)
        #expect(!foreign)
        #expect(!agent.isHealthy(at: 103))
    }

    @Test func missingAndBackgroundSessionInformationCannotAuthenticateAHeartbeat() {
        #expect(ConsoleLogin(snapshot: ["Name": "loginwindow", "UID": 0]) == nil)
        let snapshot: [String: Any] = ["Name": "user", "UID": NSNumber(value: 501), "SessionInfo": [
            ["kCGSSessionOnConsoleKey": false, "kCGSSessionUserIDKey": 501, "kCGSSessionAuditIDKey": 47],
            ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 502, "kCGSSessionAuditIDKey": 48]
        ]]
        var agent = OwnerHeartbeat()
        agent.observe(ConsoleLogin(snapshot: snapshot), owner: .enrolled(501), now: 0)
        #expect(agent.login?.uid == 501)
        #expect(agent.login?.auditID == nil)
        agent.receive(owner: .enrolled(501), uid: 501, auditID: 47, healthy: true, now: 60)
        #expect(!agent.isHealthy(at: 61))
    }
}

@Suite struct InstallLocationTests {
    @Test func onlyARootOwnedBundleMayHostTheDaemon() throws {
        // A system file: root's, and no one else may write to it.
        #expect(InstallLocation.isRootOnly("/usr/bin/true"))
        #expect(InstallLocation.isRootOnly("/usr/bin"))
        // /Applications is writable by the admin group; a link is never accepted.
        #expect(!InstallLocation.isRootOnly("/Applications"))
        #expect(!InstallLocation.isRootOnly("/etc"))
        #expect(!InstallLocation.isRootOnly("/nonexistent"))

        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("wd-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(InstallLocation.problem(bundlePath: bundle.path, armed: true) != nil)
        #expect(InstallLocation.problem(bundlePath: bundle.path, armed: false) == nil)
    }
}

@Suite struct PeerHardeningTests {
    @Test func hardenedMeansRuntimeAndNoDebuggerEntitlement() {
        #expect(PeerHardening.isHardened(status: 0x10000 | 0x1 | 0x200))
        #expect(!PeerHardening.isHardened(status: 0x1))                // signed, no Hardened Runtime
        #expect(!PeerHardening.isHardened(status: 0x10000 | 0x4))      // runtime, but debuggable
        #expect(!PeerHardening.isHardened(status: 0))
    }
}

@Suite struct UserDataTests {
    @Test func oldFilesMoveOnceAndLinksAreLeftAlone() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("wd-\(UUID().uuidString)")
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try files.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try Data("db".utf8).write(to: old.appendingPathComponent("usage.sqlite"))
        try Data("[]".utf8).write(to: old.appendingPathComponent("rules.json"))
        try files.createSymbolicLink(at: old.appendingPathComponent("timer.json"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))

        UserData.migrate(from: old, to: new)
        #expect(try Data(contentsOf: new.appendingPathComponent("usage.sqlite")) == Data("db".utf8))
        #expect(files.fileExists(atPath: new.appendingPathComponent("rules.json").path))
        #expect(!files.fileExists(atPath: new.appendingPathComponent("timer.json").path))
        #expect(try files.attributesOfItem(atPath: new.appendingPathComponent("usage.sqlite").path)[.posixPermissions] as? Int == 0o600)

        // A database planted in the old place later never replaces the real one.
        try Data("planted".utf8).write(to: old.appendingPathComponent("usage.sqlite"))
        UserData.migrate(from: old, to: new)
        #expect(try Data(contentsOf: new.appendingPathComponent("usage.sqlite")) == Data("db".utf8))
    }

    @Test func historySettingsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wd-\(UUID().uuidString)/history-settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(HistorySettings.load(from: url) == nil)
        let chosen = HistorySettings(addresses: .cleaned, detailDays: 0, historyDays: 90)
        try chosen.save(to: url)
        #expect(HistorySettings.load(from: url) == chosen)
        #expect(chosen.retention == HistoryRetention(detailDays: nil, historyDays: 90))
    }
}
