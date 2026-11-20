import Foundation
import WatchDogCore

/// The app's side of the XPC connection to the root daemon.
/// Each call opens a short-lived connection; calls are rare (a few per minute).
enum DaemonClient {

    /// Nil when the daemon cannot be reached (not registered, not approved, or crashed).
    static func status() async -> DaemonStatus? {
        await call { proxy, finish in
            proxy.status { data in finish(try? JSONDecoder().decode(DaemonStatus.self, from: data)) }
        } ?? nil
    }

    /// Returns (accepted, message). A refusal carries the daemon's reason.
    static func startBlock(domains: [String], seconds: Int) async -> (accepted: Bool, message: String) {
        await call { proxy, finish in
            proxy.startBlock(domains: domains, seconds: seconds) { accepted, message in finish((accepted, message)) }
        } ?? (false, "the WatchDog daemon is not reachable")
    }

    /// Asks the daemon to adopt new rules / a new mode. Nil if unreachable.
    /// `outcome` is "applied", "delayed" or "rejected".
    static func propose(_ config: DaemonConfig) async -> (outcome: String, message: String)? {
        guard let data = try? JSONEncoder().encode(config) else { return nil }
        return await call { proxy, finish in
            proxy.propose(config: data) { outcome, message in finish((outcome, message)) }
        }
    }

    static func cancelPending() async {
        let _: Bool? = await call { proxy, finish in proxy.cancelPending { finish(true) } }
    }

    /// Asks the daemon to undo everything it installed. (done, message); nil if unreachable.
    static func prepareUninstall() async -> (done: Bool, message: String)? {
        await call { proxy, finish in
            proxy.prepareUninstall { done, message in finish((done, message)) }
        }
    }

    /// Fire and forget: there is nothing useful to do if it fails.
    static func heartbeat(_ health: Data) {
        let connection = NSXPCConnection(machServiceName: WD.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: WatchDogDaemonXPC.self)
        connection.resume()
        (connection.remoteObjectProxyWithErrorHandler { _ in } as? WatchDogDaemonXPC)?.heartbeat(health: health)
        // Give the message a moment to leave before the connection is torn down.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [connection] in connection.invalidate() }
    }

    /// Runs one request. Returns nil if the connection fails or nothing
    /// answers within 5 seconds.
    private static func call<T: Sendable>(
        _ body: @escaping (WatchDogDaemonXPC, @escaping @Sendable (T) -> Void) -> Void
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            // `.privileged` = the service lives in the system (root) domain.
            // NSXPCConnection is thread-safe but not declared Sendable.
            nonisolated(unsafe) let connection = NSXPCConnection(machServiceName: WD.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: WatchDogDaemonXPC.self)
            connection.resume()

            // Exactly one of: reply, connection error, timeout.
            let once = Once { value in
                connection.invalidate()
                continuation.resume(returning: value)
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in once.fire(nil) }) as? WatchDogDaemonXPC else {
                once.fire(nil)
                return
            }
            body(proxy) { value in once.fire(value) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { once.fire(nil) }
        }
    }
}

/// Runs its action the first time `fire` is called and ignores later calls.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable (T?) -> Void)?

    init(_ action: @escaping @Sendable (T?) -> Void) { self.action = action }

    func fire(_ value: T?) {
        lock.lock()
        let run = action
        action = nil
        lock.unlock()
        run?(value)
    }
}
