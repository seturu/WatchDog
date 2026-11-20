import Foundation
import Security
import SystemConfiguration
import WatchDogCore

func consoleLogin() -> ConsoleLogin? {
    let snapshot = SCDynamicStoreCopyValue(nil, SCDynamicStoreKeyCreateConsoleUser(nil)) as? [String: Any]
    return ConsoleLogin(snapshot: snapshot)
}

final class EnrollmentService: NSObject, NSXPCListenerDelegate, WatchDogEnrollmentXPC {
    let guardian: Guardian

    init(guardian: Guardian) { self.guardian = guardian }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection peer: NSXPCConnection) -> Bool {
        guard PeerHardening.accepts(peer), OwnerRecord.read() == .missing, isAtConsole(peer) else { return false }
        peer.exportedInterface = NSXPCInterface(with: WatchDogEnrollmentXPC.self)
        peer.exportedObject = self
        peer.resume()
        return true
    }

    func enroll(authorization data: Data, reply: @escaping @Sendable (Bool) -> Void) {
        guard let peer = NSXPCConnection.current(), OwnerRecord.read() == .missing,
              data.count == MemoryLayout<AuthorizationExternalForm>.size else { reply(false); return }

        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { data.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess,
              let reference else { reply(false); return }
        defer { AuthorizationFree(reference, []) }
        guard OwnerRecord.requestAdminRight(reference, flags: []) == errAuthorizationSuccess else { reply(false); return }
        guardian.enroll(uid: peer.effectiveUserIdentifier, auditID: peer.auditSessionIdentifier, reply)
    }

    static func storeOwner(_ uid: uid_t) -> Bool {
        // link() publishes the complete record only if its name is still free,
        // including when the installer or another enrollment is racing us.
        let path = OwnerRecord.path
        var template = Array((path + ".XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { return false }
        defer { close(fd); unlink(template) }
        let bytes = Array("\(uid)\n".utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count, fchmod(fd, 0o644) == 0, fsync(fd) == 0 else { return false }
        return link(template, path) == 0 || OwnerRecord.read().allows(uid)
    }

    private func isAtConsole(_ peer: NSXPCConnection) -> Bool {
        guard let login = consoleLogin() else { return false }
        return login.uid == peer.effectiveUserIdentifier && login.auditID == peer.auditSessionIdentifier
    }
}
