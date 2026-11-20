import Foundation
import Security

/// Publicly readable so Setup can explain what is needed. Only root can create
/// or replace this record in the system preferences directory.
public enum OwnerRecord: Equatable, Sendable {
    case missing, invalid, enrolled(uid_t)

    public static var path: String { "/Library/Preferences/" + WD.appBundleID + ".owner-uid" }

    public static func read() -> Self { read(at: path) }

    static func read(at path: String) -> Self {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .invalid }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0, (2...11).contains(info.st_size) else { return .invalid }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count, bytes.last == 10,
              let uid = uid_t(String(decoding: bytes.dropLast(), as: UTF8.self)),
              uid > 0, uid < uid_t.max, bytes == Array("\(uid)\n".utf8) else { return .invalid }
        return .enrolled(uid)
    }

    /// The app acquires the right interactively. The helper checks the same
    /// right without allowing interaction or authorizing additional rights.
    public static func requestAdminRight(_ reference: AuthorizationRef, flags: AuthorizationFlags) -> OSStatus {
        "system.privilege.admin".withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(reference, &rights, nil, flags, nil)
            }
        }
    }

    public func allows(_ uid: uid_t) -> Bool { self == .enrolled(uid) }
}

/// A single snapshot of the system console. The UID can be known even if
/// WindowServer hasn't published its audit session number yet.
public struct ConsoleLogin: Equatable, Sendable {
    public let uid: uid_t
    public let auditID: Int32?

    public init?(snapshot: [String: Any]?) {
        guard let snapshot, let name = snapshot["Name"] as? String, !name.isEmpty,
              name != "loginwindow", let uid = snapshot["UID"] as? uid_t, uid > 0 else { return nil }
        self.uid = uid
        let sessions = snapshot["SessionInfo"] as? [[String: Any]] ?? []
        let active = sessions.filter {
            $0["kCGSSessionOnConsoleKey"] as? Bool == true && $0["kCGSSessionUserIDKey"] as? uid_t == uid
        }
        let id = active.count == 1 ? active[0]["kCGSSessionAuditIDKey"] as? Int32 : nil
        auditID = id.flatMap { $0 > 0 ? $0 : nil }
    }
}

public struct OwnerHeartbeat: Sendable {
    public private(set) var login: ConsoleLogin?
    private var began = 0.0
    private var received: Double?
    /// What the last accepted heartbeat said: able to see, and still checking rules.
    private var healthy = true

    public init() {}

    public mutating func observe(_ console: ConsoleLogin?, owner: OwnerRecord, now: Double) {
        let current: ConsoleLogin?
        if case .enrolled(let uid) = owner, console?.uid != uid {
            current = nil
        } else {
            // Existing enforcing installations still watch for silence until enrolled.
            current = console
        }
        guard current != login else { return }
        login = current
        began = now
        received = nil
        healthy = true
    }

    /// Records a heartbeat from the owner's active session. Returns false,
    /// changing nothing, for any other account or session.
    @discardableResult
    public mutating func receive(owner: OwnerRecord, uid: uid_t, auditID: Int32, healthy: Bool, now: Double) -> Bool {
        guard owner.allows(uid), login?.uid == uid, login?.auditID == auditID else { return false }
        received = now
        self.healthy = healthy
        return true
    }

    public func isFresh(at now: Double) -> Bool {
        guard login != nil else { return true }
        if let received { return now - received <= Limits.heartbeatGraceSeconds }
        return now - began < Limits.heartbeatGraceSeconds
    }

    public func isHealthy(at now: Double) -> Bool { healthy && isFresh(at: now) }
}
