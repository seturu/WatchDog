import AppKit
import ApplicationServices
import CoreAudio
import Synchronization

/// Whether the app is inside a call that waits on a browser's answer to an
/// Apple Event. The first such call to a browser shows the Automation prompt
/// and does not return until it is answered. Readable from any thread.
public enum AppleEventWait {
    private static let depth = Mutex(0)

    public static func during<T>(_ body: () throws -> T) rethrows -> T {
        depth.withLock { $0 += 1 }
        defer { depth.withLock { $0 -= 1 } }
        return try body()
    }

    public static var isWaiting: Bool { depth.withLock { $0 > 0 } }
}

/// Milestone 0 probes: the smallest possible version of each tracking signal,
/// to prove it works on this Mac before the real tracker is built on it.
public enum Probes {

    // MARK: Frontmost app — no permission needed

    public struct FrontApp: Sendable {
        public let pid: pid_t
        public let bundleID: String
        public let name: String
    }

    public static func frontApp() -> FrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontApp(pid: app.processIdentifier,
                        bundleID: app.bundleIdentifier ?? "?",
                        name: app.localizedName ?? "?")
    }

    // MARK: Idle time — no permission needed

    /// Seconds since the last keyboard or mouse input in this login session.
    public static func idleSeconds() -> Double {
        let anyInput = CGEventType(rawValue: ~0)! // "any input event"
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    // MARK: Window title — needs Accessibility

    public static func accessibilityGranted() -> Bool { AXIsProcessTrusted() }

    /// Title of the focused window of `pid`, read through the Accessibility API.
    /// This is the route that does NOT need Screen Recording.
    public static func windowTitle(pid: pid_t) -> Result<String, ProbeError> {
        guard AXIsProcessTrusted() else { return .failure(.init("Accessibility not granted")) }
        let app = AXUIElementCreateApplication(pid)

        var window: CFTypeRef?
        let e1 = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
        guard e1 == .success, let window else { return .failure(.init("no focused window (AXError \(e1.rawValue))")) }

        var title: CFTypeRef?
        let e2 = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        guard e2 == .success else { return .failure(.init("no title (AXError \(e2.rawValue))")) }
        return .success(title as? String ?? "")
    }

    // MARK: Browser URL — needs Automation (one prompt per browser)

    /// Browsers whose current address can be read with AppleScript, and the
    /// expression that returns it. Firefox has no AppleScript support.
    public static let scriptableBrowsers: [String: String] = [
        "com.brave.Browser": "URL of active tab of front window",
        "com.google.Chrome": "URL of active tab of front window",
        "com.microsoft.edgemac": "URL of active tab of front window",
        "company.thebrowser.Browser": "URL of active tab of front window", // Arc
        "com.apple.Safari": "URL of front document",
    ]

    /// AppleScript error meaning "the user has not allowed, or has denied,
    /// Automation for this app".
    public static let automationDeniedCode = -1743

    @MainActor private static var compiledScripts: [String: NSAppleScript] = [:]

    /// Address of the front tab of a scriptable browser.
    /// Call on the main thread. Only asks when the browser is already running,
    /// because sending an Apple Event to a closed app would launch it.
    @MainActor
    public static func browserURL(bundleID: String) -> Result<String, ProbeError> {
        guard let expression = scriptableBrowsers[bundleID] else {
            return .failure(.init("not a scriptable browser"))
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            return .failure(.init("not running"))
        }
        let script: NSAppleScript
        if let cached = compiledScripts[bundleID] {
            script = cached
        } else {
            let source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return \(expression)
            end tell
            """
            guard let compiled = NSAppleScript(source: source) else { return .failure(.init("script did not compile")) }
            compiledScripts[bundleID] = compiled
            script = compiled
        }
        var error: NSDictionary?
        let result = AppleEventWait.during { script.executeAndReturnError(&error) }
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            return .failure(.init("AppleScript error \(code): \(message)", code: code))
        }
        return .success(result.stringValue ?? "")
    }

    @MainActor
    public static func braveURL() -> Result<String, ProbeError> { browserURL(bundleID: WD.braveBundleID) }

    // MARK: Who is making sound — no permission needed

    public struct AudioProcess: Sendable {
        public let pid: pid_t
        public let bundleID: String
        public let isPlaying: Bool
    }

    /// Processes known to the audio system and whether each is producing output
    /// right now. Reads metadata only; it does not capture audio.
    public static func audioProcesses() -> Result<[AudioProcess], ProbeError> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { return .failure(.init("process list size: OSStatus \(status)")) }

        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        guard status == noErr else { return .failure(.init("process list: OSStatus \(status)")) }

        return .success(ids.map { id in
            let pid: pid_t = read(id, kAudioProcessPropertyPID) ?? -1
            let playing: UInt32 = read(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            var bundle: CFString = "" as CFString
            var bundleSize = UInt32(MemoryLayout<CFString>.size)
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            _ = withUnsafeMutablePointer(to: &bundle) {
                AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, $0)
            }
            return AudioProcess(pid: pid, bundleID: bundle as String, isPlaying: playing != 0)
        })
    }

    private static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }
}

public struct ProbeError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public let code: Int?
    public init(_ description: String, code: Int? = nil) {
        self.description = description
        self.code = code
    }
}
