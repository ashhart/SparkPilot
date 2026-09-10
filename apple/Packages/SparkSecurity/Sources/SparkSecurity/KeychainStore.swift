import Foundation
import Security

/// Store grants and pinned identities in Keychain while signing keys remain protected by Keychain or Secure Enclave (§37.1).
public protocol SecureStore: Sendable {
    /// Store `data`, replacing anything already there.
    func set(_ data: Data, service: String, account: String) throws
    /// Add only when absent so a racing writer cannot replace an enrolled device identity.
    func add(_ data: Data, service: String, account: String) throws
    func data(service: String, account: String) throws -> Data?
    func delete(service: String, account: String) throws
    /// List account identifiers to resolve short discovery hints against already paired full node IDs.
    func accounts(service: String) throws -> [String]
}

/// Rely on the thread safety of individual SecItem operations without actor isolation.
public struct KeychainStore: SecureStore {
    typealias UpdateItem = @Sendable (CFDictionary, CFDictionary) -> OSStatus
    typealias AddItem = @Sendable (CFDictionary) -> OSStatus

    private let updateItem: UpdateItem
    private let addItem: AddItem

    public init() {
        self.updateItem = { SecItemUpdate($0, $1) }
        self.addItem = { SecItemAdd($0, nil) }
    }

    init(
        updateItem: @escaping UpdateItem,
        addItem: @escaping AddItem
    ) {
        self.updateItem = updateItem
        self.addItem = addItem
    }

    public func set(_ data: Data, service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = updateItem(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable] = false
        let addStatus = addItem(item as CFDictionary)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Use atomic SecItemAdd collision semantics for non-replacing key creation.
    public func add(_ data: Data, service: String, account: String) throws {
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            // §15.2: the private signing key must not sync through iCloud.
            kSecAttrSynchronizable: false,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            throw KeychainError.alreadyExists
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func data(service: String, account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return data
    }

    public func delete(service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Enumerate attributes without returning or unlocking stored secret data.
    public func accounts(service: String) throws -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[CFString: Any]] else {
            throw KeychainError.unexpectedStatus(status)
        }
        return items.compactMap { $0[kSecAttrAccount] as? String }
    }
}

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    /// `add` found something already stored under the same coordinates.
    case alreadyExists
}

/// Use internally locked in-memory storage for tests instead of the live Keychain (§37.1).
public final class InMemoryStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]

    public init() {}

    public func set(_ data: Data, service: String, account: String) throws {
        lock.lock()
        entries["\(service)/\(account)"] = data
        lock.unlock()
    }

    public func add(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(service)/\(account)"
        guard entries[key] == nil else { throw KeychainError.alreadyExists }
        entries[key] = data
    }

    public func data(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return entries["\(service)/\(account)"]
    }

    public func delete(service: String, account: String) throws {
        lock.lock()
        entries["\(service)/\(account)"] = nil
        lock.unlock()
    }

    public func accounts(service: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(service)/"
        return entries.keys.compactMap {
            $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil
        }
    }
}
