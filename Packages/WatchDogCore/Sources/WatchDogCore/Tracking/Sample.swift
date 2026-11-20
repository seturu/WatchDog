import Foundation

/// One observation of "what is the user doing right now".
/// The tracker produces one every couple of seconds; the store merges
/// consecutive identical ones into a single row (a "span").
public struct Sample: Sendable, Equatable {
    public var time: Date
    public var bundleID: String
    public var appName: String
    public var windowTitle: String?
    public var url: String?
    public var isIdle: Bool
    /// What the pomodoro timer was doing at this moment.
    public var timerState: TimerState

    public init(time: Date, bundleID: String, appName: String,
                windowTitle: String? = nil, url: String? = nil, isIdle: Bool = false,
                timerState: TimerState = .none) {
        self.time = time
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.isIdle = isIdle
        self.timerState = timerState
    }

    /// "https://www.youtube.com/watch?v=x" -> "youtube.com".
    /// Nil for anything that is not a web page (brave://newtab, file://...).
    public var domain: String? { Self.domain(of: url) }

    /// "https://www.youtube.com/watch?v=x" -> "https://www.youtube.com": the
    /// site without the page, query or fragment, which can hold search terms,
    /// document names or message IDs. Nil for anything that is not a web page.
    /// This is what history keeps unless full addresses are switched on.
    public static func siteAddress(of url: String?) -> String? {
        guard let url, let parts = URLComponents(string: url),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host)" + (parts.port.map { ":\($0)" } ?? "")
    }

    public static func domain(of url: String?) -> String? {
        guard let url, let parts = URLComponents(string: url),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// One observation of "this app is producing sound right now".
public struct MediaSample: Sendable, Equatable {
    public var time: Date
    public var sourceBundleID: String
    public var title: String?
    public var artist: String?

    public init(time: Date, sourceBundleID: String, title: String? = nil, artist: String? = nil) {
        self.time = time
        self.sourceBundleID = sourceBundleID
        self.title = title
        self.artist = artist
    }
}
