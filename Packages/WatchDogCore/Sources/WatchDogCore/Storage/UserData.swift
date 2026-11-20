import Foundation

/// Where the app keeps what it knows about you: usage history, the rules
/// draft, the timer and the history settings.
///
/// Window titles and page addresses are only readable with the Accessibility
/// and Automation permissions. Stored under ~/Library/Application Support
/// they would be readable by every program running as you, permission or
/// not. So they live in the container of an App Group that only the app's
/// entitlement names (`WD.privateGroupID`): macOS asks the user before it
/// lets another developer's program into a group container. A build without
/// a signing team has no group and keeps using Application Support.
public enum UserData {
    /// Worked out once per run; the first use also moves files left in the
    /// old place by an earlier version.
    public static let folder: URL = {
        guard let group = WD.privateGroupID,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return legacyFolder }
        let folder = container.appendingPathComponent(WD.userDataFolder, isDirectory: true)
        migrate(from: legacyFolder, to: folder)
        return folder
    }()

    /// ~/Library/Application Support/WatchDog: where everything was before.
    public static var legacyFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(WD.userDataFolder, isDirectory: true)
    }

    /// The database first: its presence in `new` is what marks the move as
    /// done, so an interrupted move is finished on the next launch and a
    /// file that reappears in the old place later is never taken.
    static let fileNames = ["rules.json", "timer.json", "usage.sqlite-wal", "usage.sqlite-shm",
                            "usage.sqlite-journal", "usage.sqlite"]

    /// Moves the known files from `old` to `new`, unless `new` already has a
    /// database. Only plain files are moved: `old` is writable by any program
    /// running as the user, and a link there must not be followed.
    static func migrate(from old: URL, to new: URL) {
        let files = FileManager.default
        guard isPlain(old, S_IFDIR), !files.fileExists(atPath: new.appendingPathComponent("usage.sqlite").path)
        else { return }
        do {
            try files.createDirectory(at: new, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return }
        for name in fileNames {
            let source = old.appendingPathComponent(name)
            let target = new.appendingPathComponent(name)
            guard isPlain(source, S_IFREG) else { continue }
            try? files.removeItem(at: target)
            do {
                try files.moveItem(at: source, to: target)
                try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            } catch {
                // Leave it where it is; the database goes last, so the move
                // is tried again next time.
                return
            }
        }
        // Gone if empty; anything else in there is not ours to delete.
        rmdir(old.path)
    }

    private static func isPlain(_ url: URL, _ kind: mode_t) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == kind
    }
}

/// The history settings (Settings → History), kept as a small file beside
/// the history itself. They used to be user defaults, which any program can
/// change with `defaults write`: one could have switched "site only" to full
/// addresses without the user noticing.
public struct HistorySettings: Codable, Sendable, Equatable {
    public var addresses: AddressDetail
    /// Days; 0 means forever.
    public var detailDays: Int
    public var historyDays: Int

    public init(addresses: AddressDetail = .site,
                detailDays: Int = HistoryRetention.standard.detailDays ?? 0,
                historyDays: Int = HistoryRetention.standard.historyDays ?? 0) {
        self.addresses = addresses
        self.detailDays = detailDays
        self.historyDays = historyDays
    }

    public var retention: HistoryRetention {
        HistoryRetention(detailDays: detailDays > 0 ? detailDays : nil,
                         historyDays: historyDays > 0 ? historyDays : nil)
    }

    public static func defaultURL() -> URL { UserData.folder.appendingPathComponent("history-settings.json") }

    /// Nil when there is no readable file yet.
    public static func load(from url: URL) -> HistorySettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HistorySettings.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
