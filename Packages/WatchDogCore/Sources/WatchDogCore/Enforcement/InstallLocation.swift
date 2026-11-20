import Foundation

/// Is the app somewhere only root can change?
///
/// The daemon runs as root from inside the app bundle. If the bundle belongs
/// to the user (dragged into /Applications, or run from a build folder), any
/// program running as that user can swap files in it, and the next start of
/// the daemon runs them as root. scripts/install-armed.sh installs the bundle
/// owned by root; the armed app refuses to register its daemon from anywhere
/// else. The development build is exempt: it runs from the build folder, with
/// capped limits and a daemon that resets itself.
public enum InstallLocation {
    /// The parts of the bundle launchd reads to start the daemon.
    static let checked = ["", "Contents", "Contents/MacOS", "Contents/MacOS/WatchDogDaemon",
                          "Contents/Library", "Contents/Library/LaunchDaemons",
                          "Contents/Library/LaunchDaemons/" + WD.daemonPlistName]

    /// True if `path` is a plain file or folder owned by root that no one
    /// else may write to.
    public static func isRootOnly(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        let kind = info.st_mode & S_IFMT
        return (kind == S_IFREG || kind == S_IFDIR) && info.st_uid == 0 && info.st_mode & 0o022 == 0
    }

    /// Nil if the daemon may be registered from this bundle; otherwise why not.
    public static func problem(bundlePath: String, armed: Bool = WD.isArmed) -> String? {
        guard armed else { return nil }
        let bundle = URL(fileURLWithPath: bundlePath)
        let loose = checked.first { !isRootOnly($0.isEmpty ? bundle.path : bundle.appendingPathComponent($0).path) }
        guard loose != nil else { return nil }
        return "This copy of WatchDog is not owned by the system, so other programs could change the background service before it starts. Install it with scripts/install-armed.sh (see the README), then open it from /Applications."
    }
}
