import Foundation
import Security

/// The key the usage history is encrypted with.
///
/// 32 random bytes, made on first launch and kept in the login keychain.
/// The keychain lets the program that stored an item read it back without
/// asking, recognised by its code signature; any other program makes macOS
/// ask the user first. So the history file is useless to a program that
/// merely can read files, and to anyone holding a copy or a backup of it.
///
/// Lose the key (a deleted or reset keychain) and the history is lost with
/// it: `UsageStore` then sets the unreadable file aside and starts afresh,
/// so tracking and rules keep working.
public struct DatabaseKey: Sendable, Equatable {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    public static func random() throws -> DatabaseKey {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess, let key = DatabaseKey(bytes: bytes) else { throw KeychainError(status: status) }
        return key
    }

    /// SQLCipher's form for a ready-made key, which skips its slow
    /// passphrase stretching: there is nothing to stretch in random bytes.
    var sqlCipherKey: String { "x'" + bytes.map { String(format: "%02x", $0) }.joined() + "'" }

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            "Keychain: " + (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")
        }
    }

    // MARK: Keychain

    private static var service: String { WD.appBundleID + ".history-key" }
    private static let account = "usage.sqlite"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The stored key, or nil if none was ever stored. Throws when the
    /// keychain refuses (locked, or the user said no): that must not look
    /// like "no key yet", or a new key would replace the one the history
    /// is encrypted with.
    public static func stored() throws -> DatabaseKey? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true,
                                                        kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let key = DatabaseKey(bytes: data) else {
            throw KeychainError(status: status == errSecSuccess ? errSecDecode : status)
        }
        return key
    }

    /// The key for this app's history: the stored one, or a new one stored now.
    public static func forThisApp() throws -> DatabaseKey {
        if let key = try stored() { return key }
        let key = try random()
        let status = SecItemAdd(query.merging([
            kSecValueData as String: key.bytes,
            kSecAttrLabel as String: "\(WD.tag) usage history key",
            kSecAttrDescription as String: "Encrypts WatchDog's usage history. Deleting it makes the history unreadable.",
        ]) { $1 } as CFDictionary, nil)
        // Another copy of the app got there first: use its key.
        if status == errSecDuplicateItem, let key = try stored() { return key }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return key
    }
}
