import Foundation
import Security
import WatchDogCore

enum OwnerSetup {
    private static func check(_ status: OSStatus) throws {
        guard status == errAuthorizationSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func enroll() async throws {
        var reference: AuthorizationRef?
        try check(AuthorizationCreate(nil, nil, [], &reference))
        guard let reference else { throw CocoaError(.userCancelled) }
        defer { AuthorizationFree(reference, [.destroyRights]) }

        try check(OwnerRecord.requestAdminRight(reference, flags: [.extendRights, .interactionAllowed]))
        let accepted = try await send(reference)
        guard accepted || OwnerRecord.read().allows(getuid()) else {
            throw NSError(domain: "WatchDog.OwnerSetup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Enrollment failed. Check that the updated background service is enabled and this account is at the desktop."
            ])
        }
    }

    #if !ARMED
    /// Test aid: offers the daemon an authorization nobody authenticated. The
    /// daemon must refuse it; if it accepts, its admin check is not a check.
    static func probeWithoutPassword() async throws -> Bool {
        var reference: AuthorizationRef?
        try check(AuthorizationCreate(nil, nil, [], &reference))
        guard let reference else { throw CocoaError(.userCancelled) }
        defer { AuthorizationFree(reference, [.destroyRights]) }
        return try await send(reference)
    }
    #endif

    private static func send(_ reference: AuthorizationRef) async throws -> Bool {
        var form = AuthorizationExternalForm()
        try check(AuthorizationMakeExternalForm(reference, &form))
        let ticket = withUnsafeBytes(of: form) { Data($0) }

        return await withCheckedContinuation { continuation in
            nonisolated(unsafe) let connection = NSXPCConnection(machServiceName: WD.enrollmentServiceName, options: .privileged)
            connection.setCodeSigningRequirement(WD.daemonRequirement)
            connection.remoteObjectInterface = NSXPCInterface(with: WatchDogEnrollmentXPC.self)
            connection.resume()
            let once = Once<Bool> { result in
                connection.invalidate()
                continuation.resume(returning: result ?? false)
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in once.fire(false) })
                    as? WatchDogEnrollmentXPC else { once.fire(false); return }
            proxy.enroll(authorization: ticket) { once.fire($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { once.fire(false) }
        }
    }
}
