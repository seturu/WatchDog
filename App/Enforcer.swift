import AppKit
import WatchDogCore

/// The app-side half of enforcement: things only a process in your login
/// session can do, because they involve other apps' windows.
@MainActor
enum Enforcer {

    /// Browsers whose tabs can be listed and closed by ID (the Chromium family).
    private static let tabBrowsers = ["com.brave.Browser", "com.google.Chrome", "com.microsoft.edgemac"]

    /// Closes what the rule is about: matching tabs in every supported browser,
    /// and the front app if it is one of the rule's apps. Returns what was closed.
    static func close(for rule: Rule, front: Sample?) -> [String] {
        var closed: [String] = []
        if !rule.domains.isEmpty {
            for browser in tabBrowsers { closed += closeTabs(in: browser, matching: rule) }
        }
        if let front, rule.apps.contains(front.bundleID) {
            // `terminate` is a polite quit: the app can still ask to save work.
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: front.bundleID)
            where app.terminate() {
                closed.append(front.appName)
            }
        }
        return closed
    }

    /// Lists every tab as "windowID<TAB>tabID<TAB>URL", decides in Swift which
    /// ones match (so matching is exactly the rule engine's), then closes those
    /// by ID. Closing by ID avoids hitting the wrong tab if the user switches.
    private static func closeTabs(in bundleID: String, matching rule: Rule) -> [String] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return [] }
        // The separator is built outside the `tell`: inside it, the word
        // "tab" means the browser's tab object, not a tab character.
        let listing = run("""
            set sep to character id 9
            set newline to character id 10
            set out to ""
            tell application id "\(bundleID)"
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & ((id of w) as text) & sep & ((id of t) as text) & sep & (URL of t) & newline
                    end repeat
                end repeat
            end tell
            return out
            """)
        var closed: [String] = []
        for line in (listing ?? "").split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard fields.count == 3, let window = Int(fields[0]), let tab = Int(fields[1]),
                  let domain = Sample.domain(of: fields[2]), RuleEngine.matchesDomain(rule, domain) else { continue }
            if run("tell application id \"\(bundleID)\" to close (tab id \(tab) of window id \(window))") != nil {
                closed.append(domain)
            }
        }
        return closed
    }

    /// Runs AppleScript; nil on any error (browser quit meanwhile, permission denied).
    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = AppleEventWait.during { NSAppleScript(source: source)?.executeAndReturnError(&error) }
        return error == nil ? (result?.stringValue ?? "") : nil
    }
}
