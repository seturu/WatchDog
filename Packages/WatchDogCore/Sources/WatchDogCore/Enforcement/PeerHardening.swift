import Foundation
import Security

/// A second check on whoever connects to the daemon, beyond "signed by our
/// team under the app's name".
///
/// That requirement is also met by any build of the app that was ever signed,
/// including ones another program can load code into: a build without the
/// Hardened Runtime (DYLD_INSERT_LIBRARIES works on it), or one carrying the
/// debugger entitlement. Whoever injects into such a build would speak to the
/// daemon as the app. The code-requirement language cannot express either
/// property, so they are read from the kernel's view of the running peer.
///
/// The daemon asks of its peers what holds for itself: the armed build is
/// hardened, so its clients must be; the development build is not, and
/// accepts development clients.
public enum PeerHardening {
    /// Kernel code-signing status bits (<kern/cs_blobs.h>).
    static let getTaskAllow: UInt32 = 0x4          // CS_GET_TASK_ALLOW
    static let hardenedRuntime: UInt32 = 0x10000   // CS_RUNTIME

    /// Pure: is a process with this status safe from code injection?
    public static func isHardened(status: UInt32) -> Bool {
        status & hardenedRuntime != 0 && status & getTaskAllow == 0
    }

    /// The status of the running code `code` refers to. Nil if it cannot be read.
    static func status(of code: SecCode) -> UInt32? {
        var information: CFDictionary?
        // The call is declared for static code but accepts running code; the
        // dynamic flag asks for the kernel's status rather than the file's.
        let target = unsafeBitCast(code, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(target, SecCSFlags(rawValue: kSecCSDynamicInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any],
              let status = fields[kSecCodeInfoStatus as String] as? NSNumber else { return nil }
        return status.uint32Value
    }

    /// Is this very process hardened? Decides whether peers must be.
    public static let selfIsHardened: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code, let status = status(of: code) else { return false }
        return isHardened(status: status)
    }()

    /// True if the connecting process may be trusted as a client. Identifies
    /// the peer by its audit token, which, unlike a process ID, cannot come
    /// to mean a different program between the check and the message.
    public static func accepts(_ peer: NSXPCConnection) -> Bool {
        guard selfIsHardened else { return true }
        guard let token = auditToken(of: peer) else { return false }
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              let status = status(of: code) else { return false }
        return isHardened(status: status)
    }

    /// NSXPCConnection has carried `auditToken` since macOS 10.7 but does not
    /// declare it publicly, so it is read by name. If that ever stops
    /// working the answer is nil and a hardened daemon refuses the peer.
    static func auditToken(of peer: NSXPCConnection) -> Data? {
        guard peer.responds(to: NSSelectorFromString("auditToken")),
              let value = peer.value(forKey: "auditToken") as? NSValue else { return nil }
        var size = 0
        NSGetSizeAndAlignment(value.objCType, &size, nil)
        guard size == MemoryLayout<audit_token_t>.size else { return nil }
        var token = audit_token_t()
        value.getValue(&token, size: size)
        return withUnsafeBytes(of: token) { Data($0) }
    }
}
