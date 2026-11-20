import AppKit

/// What an external pomodoro / focus-timer app says is going on.
public enum TimerState: String, Codable, Sendable, CaseIterable {
    /// A focus (work) interval is running.
    case focus
    /// A break interval is running.
    case onBreak = "break"
    /// No timer is running, or no supported timer app is open.
    case none
}

public struct TimerReading: Sendable, Equatable {
    /// What rules see. A paused break counts as `.none`, so pausing never
    /// stretches a break; a paused focus session still counts as focus.
    public var state: TimerState
    public var title: String?
    public var project: String?
    public var startedAt: Date?
    public var durationSeconds: Int?
    /// True while the interval is paused (built-in timer only).
    public var isPaused: Bool
    /// The interval the timer is on, paused or not. Nil means the same as `state`.
    public var interval: TimerState?
    /// Seconds left, when the source knows it better than `startedAt +
    /// durationSeconds` (the built-in timer, which excludes pauses).
    public var remainingSeconds: Double?

    public static let none = TimerReading(state: .none)

    public init(state: TimerState, title: String? = nil, project: String? = nil,
                startedAt: Date? = nil, durationSeconds: Int? = nil,
                isPaused: Bool = false, interval: TimerState? = nil, remainingSeconds: Double? = nil) {
        self.state = state
        self.title = title
        self.project = project
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.isPaused = isPaused
        self.interval = interval
        self.remainingSeconds = remainingSeconds
    }

    /// The interval shown to the user: a paused break is still a break here.
    public var shownInterval: TimerState { interval ?? state }
}

// MARK: Sources

/// Anything that can say what the pomodoro timer is doing right now. The
/// tracker asks the selected source on every sample and stores its `state`
/// on the span, so rules work the same whichever source is chosen.
@MainActor
public protocol TimerSource {
    func read() -> TimerReading
}

/// A pomodoro app WatchDog follows but does not control. To support another
/// app, add a reader that returns a `TimerReading` and list it in `all`.
@MainActor
public protocol ExternalTimerApp: TimerSource {
    /// Stored in the settings to remember the choice.
    var sourceID: String { get }
    var name: String { get }
    var bundleID: String { get }
}

extension ExternalTimerApp {
    public var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
    public var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// The timer sources WatchDog knows.
public enum TimerSources {
    /// The timer built into WatchDog (see `PomodoroMachine`).
    public static let builtInID = "builtin"

    @MainActor public static let external: [any ExternalTimerApp] = [SessionTimerApp()]

    @MainActor public static func external(id: String) -> (any ExternalTimerApp)? {
        external.first { $0.sourceID == id }
    }

    /// The choice when none was ever made: Session if it is installed (that
    /// is how WatchDog worked before it had a timer of its own), otherwise
    /// the built-in timer.
    @MainActor public static var defaultID: String {
        external.first { $0.isInstalled }?.sourceID ?? builtInID
    }
}

/// Session as a timer source.
public struct SessionTimerApp: ExternalTimerApp {
    public let sourceID = "session"
    public let name = "Session"
    public let bundleID = SessionTimer.bundleID
    public init() {}
    public func read() -> TimerReading { SessionTimer.read() }
}

/// Reads the state of Session (com.philipyoungg.session), a pomodoro app.
///
/// Session keeps its running timer in a preferences file shared with its
/// widget. We only read that file: no scripting, no Shortcut, nothing to
/// install on Session's side. `SessionTimerApp` makes it a `TimerSource`.
public enum SessionTimer {
    public static let bundleID = "com.philipyoungg.session"

    static var preferencesURL: URL {
        let group = "98JSB2MQB3.group.com.philipyoungg.translucent"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(group)/Library/Preferences/\(group).plist")
    }

    /// Current reading. `.none` unless Session is actually running: a file
    /// left behind by a quit or crashed app must not count as a break.
    public static func read() -> TimerReading {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
              let data = try? Data(contentsOf: preferencesURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return .none }
        return parse(runningSession: plist["RunningSession"] as? Data)
    }

    /// Decodes Session's "RunningSession" entry, which is JSON such as
    /// {"state":"session","duration_second":1500,"start_date":"2026-11-18T00:06:34Z",
    ///  "title":"—","project":{"title":"Work"}}.
    /// "state" is "session" for a focus interval and "rest" for a break.
    /// It is the JSON text `null` (or absent) when no timer is running.
    static func parse(runningSession data: Data?) -> TimerReading {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["state"] as? String else { return .none }

        let state: TimerState
        switch raw {
        case "session": state = .focus
        case "rest": state = .onBreak     // observed live: Session's name for a break
        default: return .none
        }
        let title = (json["title"] as? String).flatMap { $0 == "—" || $0.isEmpty ? nil : $0 }
        let started = (json["start_date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return TimerReading(state: state, title: title,
                            project: (json["project"] as? [String: Any])?["title"] as? String,
                            startedAt: started, durationSeconds: json["duration_second"] as? Int)
    }
}
