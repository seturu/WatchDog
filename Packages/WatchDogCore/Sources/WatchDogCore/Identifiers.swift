import Foundation
import Security

/// Every name the system knows us by, in one place.
///
/// There are two complete sets. The development build carries ".dev" /
/// "-dev" everywhere; the armed build (Xcode's Release configuration, which
/// defines ARMED) carries none. Because nothing is shared, a development build
/// can never touch the armed install's daemon, rules, hosts section or history.
public enum WD {
    #if ARMED
    public static let isArmed = true
    private static let suffix = ""
    /// Used in file and folder names and in the hosts-file markers.
    public static let tag = "WatchDog"
    #else
    public static let isArmed = false
    private static let suffix = ".dev"
    public static let tag = "WatchDog-dev"
    #endif

    public static let appBundleID = "local.watchdog" + suffix
    public static let daemonLabel = appBundleID + ".daemon"
    /// The XPC endpoint name. Must match `MachServices` in the daemon's launchd plist.
    public static let machServiceName = daemonLabel
    public static let enrollmentServiceName = daemonLabel + ".enrollment"
    /// File name inside the app's Contents/Library/LaunchDaemons.
    public static let daemonPlistName = daemonLabel + ".plist"
    /// The login agent: launchd label, and file name in Contents/Library/LaunchAgents.
    public static let agentLabel = appBundleID + ".agent"
    public static let agentPlistName = agentLabel + ".plist"

    /// Trust the team in our own running code signature. This also works for
    /// builds signed by another developer using their own Xcode team.
    private static let signerRequirement: String? = {
        var code: SecCode?
        var executable: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &executable) == errSecSuccess, let executable,
              SecCodeCopySigningInformation(executable, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any],
              let team = fields[kSecCodeInfoTeamIdentifier as String] as? String,
              team.utf8.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) })
        else { return nil }
        // The on-disk signature suggests a team. Confirm it against the live
        // process before using that team as the authority for XPC.
        let signer = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(signer as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        return signer
    }()

    public static let clientRequirement = signingRequirement(identifier: appBundleID)
    public static let daemonRequirement = signingRequirement(identifier: daemonLabel)

    private static func signingRequirement(identifier: String) -> String {
        guard let signerRequirement else { return "never" }
        return "identifier \"\(identifier)\" and \(signerRequirement)"
    }

    /// Root-owned folder for the daemon's state.
    public static let daemonStateDirectory = "/Library/Application Support/" + tag
    /// Folder name for usage history and the rules cache: inside the private
    /// App Group container, or under ~/Library/Application Support for a
    /// build without one (see `UserData`).
    public static let userDataFolder = tag

    /// Posted by a second launch of the app to make the running one show its window.
    public static let showWindowNotification = appBundleID + ".show-window"

    /// The App Group the app shares with its widget extension:
    /// "<team ID>.<app bundle ID>". A macOS-style group, which needs no
    /// registration and no provisioning profile, and which macOS lets the
    /// team's own apps open without asking. The build writes it into each
    /// bundle's Info.plist (`WDAppGroup`) from the signing team. Nil for a
    /// build without a team; the widgets then show nothing.
    public static let appGroupID: String? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WDAppGroup") as? String,
              isAppGroup(value) else { return nil }
        return value
    }()

    /// A second App Group that only the app's entitlement names, never the
    /// widget's: "<team ID>.<app bundle ID>.private". Usage history, the
    /// rules draft, the timer and the history settings live in its container,
    /// because macOS keeps other developers' programs out of group containers
    /// (it asks the user first), which it does not do for a folder in
    /// ~/Library/Application Support. Nil for a build without a team.
    public static let privateGroupID: String? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WDPrivateGroup") as? String,
              isAppGroup(value, suffix: ".private") else { return nil }
        return value
    }()

    /// "<10 capitals or digits>.<this build's app bundle ID><suffix>".
    public static func isAppGroup(_ value: String, suffix: String = "") -> Bool {
        let parts = value.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[1] == appBundleID + suffix else { return false }
        let team = parts[0].utf8
        return team.count == 10 && team.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }

    /// Darwin notification a widget button posts after leaving a command.
    public static let widgetCommandNotification = appBundleID + ".widget-command"

    public static let braveBundleID = "com.brave.Browser"
}
