import Foundation

/// What the app can ask the daemon to do.
///
/// XPC is macOS's built-in inter-process calling: the app calls these methods on
/// a proxy object and they run inside the daemon. It needs an Objective-C
/// protocol (`@objc`), and results come back through a `reply` closure because
/// the call is asynchronous. Only simple types cross the boundary, so structs
/// travel as JSON `Data`.
///
/// There is deliberately no "stop block" call: the only way a block ends is by
/// running out.
@objc public protocol WatchDogDaemonXPC {
    /// Returns a line describing the daemon process, e.g. "uid=0 pid=123".
    /// uid 0 means it really is running as root.
    func ping(reply: @escaping @Sendable (String) -> Void)

    /// Returns a JSON-encoded `DaemonStatus`.
    func status(reply: @escaping @Sendable (Data) -> Void)

    /// Starts a block, or tightens the running one. Replies (accepted, message).
    func startBlock(domains: [String], seconds: Int, reply: @escaping @Sendable (Bool, String) -> Void)

    /// Asks to replace the rules and enforcement mode (a JSON `DaemonConfig`).
    /// Replies ("applied" | "delayed" | "rejected", message).
    func propose(config: Data, reply: @escaping @Sendable (String, String) -> Void)

    /// Drops a change that is waiting out its cooling-off delay.
    func cancelPending(reply: @escaping @Sendable () -> Void)

    /// Removes everything the daemon put on the system, so the app can then
    /// unregister it. Refused during a block and while enforcing.
    /// Replies (done, message).
    func prepareUninstall(reply: @escaping @Sendable (Bool, String) -> Void)

    /// "I am alive, and this is what I can see" (a JSON `AgentHealth`).
    func heartbeat(health: Data)
}

/// Separate Mach service for initial administrator-approved enrollment. It
/// exposes no daemon state or controls. The daemon obtains the UID from XPC.
@objc public protocol WatchDogEnrollmentXPC {
    func enroll(authorization: Data, reply: @escaping @Sendable (Bool) -> Void)
}
