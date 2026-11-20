import Foundation
import notify

// MARK: Commands

/// A widget button press, left in the App Group container for the app.
///
/// A widget's buttons run in the widget extension, which cannot reach the
/// app's timer. So a press only writes this request; the app checks it
/// (`WidgetCommandPolicy`) and, if it still makes sense, carries it out with
/// the same calls as the Focus screen's buttons.
public struct WidgetCommand: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var action: WidgetAction
    /// `WidgetTimer.token` of the timer the button was drawn for.
    public var token: String
    /// When the button was pressed, on the system clock.
    public var issuedAt: Date

    public init(id: UUID = UUID(), action: WidgetAction, token: String, issuedAt: Date) {
        self.id = id
        self.action = action
        self.token = token
        self.issuedAt = issuedAt
    }
}

/// What the app did with a command, published in the next snapshot.
public struct WidgetCommandReceipt: Codable, Sendable, Equatable {
    public var id: UUID
    public var applied: Bool
    /// Why it was refused, in words for the widget.
    public var reason: String?
    public var at: Date

    public init(id: UUID, applied: Bool, reason: String? = nil, at: Date) {
        self.id = id
        self.applied = applied
        self.reason = reason
        self.at = at
    }
}

/// Decides whether a widget command is carried out. Pure.
///
/// The widget can only do what the Focus screen offers at that moment, to
/// the timer it was drawn for, shortly after the press. Pausing never
/// loosens a rule (that is the machine's own rule), and nothing here touches
/// rules, enforcement or the timer source.
public enum WidgetCommandPolicy {
    /// A press older than this is dropped: the app was not running, and
    /// starting a timer much later would surprise.
    public static let maximumAge: TimeInterval = 30

    public enum Refusal: String, Sendable, Equatable {
        case expired = "The tap came too late."
        case notBuiltIn = "The pomodoro timer in use is another app's."
        case timerMoved = "The timer changed before the tap arrived."
        case notOffered = "That is not possible right now."
    }

    public enum Decision: Sendable, Equatable {
        case apply(WidgetAction)
        case refuse(Refusal)
    }

    /// `timer` is the timer as it is now, built the same way as the snapshot's.
    public static func decide(_ command: WidgetCommand, timer: WidgetTimer, now: Date) -> Decision {
        guard abs(now.timeIntervalSince(command.issuedAt)) <= maximumAge else { return .refuse(.expired) }
        guard timer.isBuiltIn else { return .refuse(.notBuiltIn) }
        guard command.token == timer.token else { return .refuse(.timerMoved) }
        guard timer.actions.contains(command.action) else { return .refuse(.notOffered) }
        return .apply(command.action)
    }

    /// Handles waiting commands in order. `current` gives the timer as it is
    /// at that point (each command applied changes it, so a second press of
    /// the same button finds the timer moved on); `apply` carries one out.
    /// Commands already handled (by ID) are skipped without a receipt.
    public static func run(_ commands: [WidgetCommand], now: Date, handled: Set<UUID>,
                           current: () -> WidgetTimer, apply: (WidgetAction) -> Void) -> [WidgetCommandReceipt] {
        var seen = handled
        var receipts: [WidgetCommandReceipt] = []
        for command in commands where seen.insert(command.id).inserted {
            switch decide(command, timer: current(), now: now) {
            case .apply(let action):
                apply(action)
                receipts.append(WidgetCommandReceipt(id: command.id, applied: true, at: now))
            case .refuse(let refusal):
                receipts.append(WidgetCommandReceipt(id: command.id, applied: false, reason: refusal.rawValue, at: now))
            }
        }
        return receipts
    }
}

// MARK: Files

/// The shared App Group container, as both sides use it:
///
///     <container>/WatchDog/snapshot.json       written by the app, read by the widgets
///     <container>/WatchDog/commands/*.json     written by widget buttons, taken by the app
///
/// The app is told about a new command by a Darwin notification
/// (`WD.widgetCommandNotification`) and also looks every few seconds, so a
/// lost notification only delays a press.
public struct WidgetChannel: Sendable {
    public let folder: URL

    /// A command file larger than this is not one of ours.
    static let maximumCommandSize = 4096
    /// At most this many commands are taken at once; the rest are dropped.
    static let maximumCommands = 8

    public init(container: URL) {
        folder = container.appendingPathComponent("WatchDog", isDirectory: true)
    }

    /// The channel in this process's App Group container, if it has one.
    public static func shared() -> WidgetChannel? {
        guard let group = WD.appGroupID,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return WidgetChannel(container: container)
    }

    var snapshotURL: URL { folder.appendingPathComponent("snapshot.json") }
    var commandsFolder: URL { folder.appendingPathComponent("commands", isDirectory: true) }

    // MARK: Snapshot

    public func write(_ snapshot: WidgetSnapshot) throws {
        try prepare(folder)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    /// Nil if there is none yet, or it is from a newer version.
    public func readSnapshot() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }

    // MARK: Commands

    /// Leaves a command for the app. Each command is its own file, so a
    /// press never has to read and rewrite what another left.
    public func send(_ command: WidgetCommand) throws {
        try prepare(folder)
        try prepare(commandsFolder)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(command).write(to: commandURL(command.id), options: .atomic)
    }

    /// Takes back a command the app has not picked up.
    public func withdraw(_ id: UUID) {
        try? FileManager.default.removeItem(at: commandURL(id))
    }

    /// Takes every waiting command, oldest first, and removes the files.
    /// Files that are not well-formed commands are removed too.
    public func takeCommands() -> [WidgetCommand] {
        guard Self.isPlainDirectory(folder), Self.isPlainDirectory(commandsFolder),
              let names = try? FileManager.default.contentsOfDirectory(atPath: commandsFolder.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var commands: [WidgetCommand] = []
        for name in names where name.hasSuffix(".json") {
            let url = commandsFolder.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: url) }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? .max) <= Self.maximumCommandSize,
                  let data = try? Data(contentsOf: url),
                  let command = try? decoder.decode(WidgetCommand.self, from: data),
                  name == "\(command.id.uuidString).json" else { continue }
            commands.append(command)
        }
        return Array(commands.sorted { $0.issuedAt < $1.issuedAt }.suffix(Self.maximumCommands))
    }

    /// True if `url` is a folder itself, not a link to one. Both sides only
    /// ever make plain folders here. A link could aim the app, which is not
    /// sandboxed, at files elsewhere: it removes the files it takes.
    static func isPlainDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Makes the folder if it is missing; refuses one that is not a plain folder.
    private func prepare(_ url: URL) throws {
        if Self.isPlainDirectory(url) { return }
        var info = stat()
        guard lstat(url.path, &info) != 0 else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path]) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func commandURL(_ id: UUID) -> URL {
        commandsFolder.appendingPathComponent("\(id.uuidString).json")
    }
}

// MARK: Signal

/// The Darwin notification a widget button posts after leaving a command,
/// so the app picks it up at once instead of at its next look.
public enum WidgetSignal {
    public static func post() {
        notify_post(WD.widgetCommandNotification)
    }

    /// Calls `handler` on the main queue each time a widget posts. Keep the
    /// returned token for as long as the handler should run.
    public static func observe(_ handler: @escaping @Sendable () -> Void) -> Int32? {
        var token: Int32 = 0
        let status = notify_register_dispatch(WD.widgetCommandNotification, &token, .main) { _ in handler() }
        return status == UInt32(NOTIFY_STATUS_OK) ? token : nil
    }
}
