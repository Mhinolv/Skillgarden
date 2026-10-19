import Foundation
import Security

/// Why Skillgarden can't read, save or delete a provider secret (#151).
public enum CredentialError: Error, Equatable, Sendable {
    /// The learner or the system refused access to the Keychain item.
    case denied
    /// Another Keychain error, with its `OSStatus`.
    case failed(Int32)

    /// The design-note text of the Settings row.
    public var message: String {
        switch self {
        case .denied: "Skillgarden can't read the key from the Keychain."
        case .failed(let status): "Skillgarden can't use the Keychain (error \(status))."
        }
    }
}

/// The store of provider secrets: API keys and tokens. Profiles and logs never hold a secret.
public protocol CredentialStore: Sendable {
    /// The secret of `account`. Nil when no item exists.
    func secret(account: String) throws(CredentialError) -> String?
    func save(_ secret: String, account: String) throws(CredentialError)
    /// Deletes the item. It does nothing when no item exists.
    func delete(account: String) throws(CredentialError)
}

/// Provider secrets in the login Keychain (#151). The items do not sync to iCloud and stay on this Mac.
public struct KeychainCredentialStore: CredentialStore {
    public static let defaultService = "com.skillgarden.providers"
    public let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    /// The query of one item. `kSecAttrSynchronizable` false keeps the item out of iCloud Keychain.
    func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    /// The attributes of a new item: the secret, readable only while the Mac is unlocked, on this device only.
    func addQuery(_ secret: String, account: String) -> [String: Any] {
        query(account: account).merging([
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "Skillgarden provider key",
        ]) { $1 }
    }

    public func secret(account: String) throws(CredentialError) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(account: account).merging([
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 } as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if let error = Self.error(status) { throw error }
        guard let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func save(_ secret: String, account: String) throws(CredentialError) {
        let update = SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData as String: Data(secret.utf8)] as CFDictionary)
        if update == errSecItemNotFound {
            if let error = Self.error(SecItemAdd(addQuery(secret, account: account) as CFDictionary, nil)) { throw error }
        } else if let error = Self.error(update) {
            throw error
        }
    }

    public func delete(account: String) throws(CredentialError) {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        if status == errSecItemNotFound { return }
        if let error = Self.error(status) { throw error }
    }

    /// Nil for success. Refused access is `.denied`. The status text never holds the secret.
    static func error(_ status: OSStatus) -> CredentialError? {
        switch status {
        case errSecSuccess: nil
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecNoAccessForItem, errSecMissingEntitlement:
            .denied
        default: .failed(status)
        }
    }
}

/// Secrets in memory, for tests, previews and the snapshot harness. `deniedAccounts` act as refused Keychain items.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]
    private let deniedAccounts: Set<String>

    public init(secrets: [String: String] = [:], deniedAccounts: Set<String> = []) {
        self.secrets = secrets
        self.deniedAccounts = deniedAccounts
    }

    public func secret(account: String) throws(CredentialError) -> String? {
        if deniedAccounts.contains(account) { throw .denied }
        return lock.withLock { secrets[account] }
    }

    public func save(_ secret: String, account: String) throws(CredentialError) {
        if deniedAccounts.contains(account) { throw .denied }
        lock.withLock { secrets[account] = secret }
    }

    public func delete(account: String) throws(CredentialError) {
        if deniedAccounts.contains(account) { throw .denied }
        _ = lock.withLock { secrets.removeValue(forKey: account) }
    }
}
