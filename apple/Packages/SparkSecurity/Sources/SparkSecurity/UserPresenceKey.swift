import CryptoKit
import Foundation
@preconcurrency import LocalAuthentication
import Security

/// Use a separate P-256 key for local user-presence authorization.
public final class SystemUserPresenceAuthorizer: UserPresenceAuthorizing, @unchecked Sendable {
    public static let defaultApplicationTag =
        "app.spark.user-presence-key".data(using: .utf8)!

    private let applicationTag: Data
    private let secureEnclaveAvailable: @Sendable () -> Bool

    public init(applicationTag: Data = defaultApplicationTag) {
        self.applicationTag = applicationTag
        self.secureEnclaveAvailable = { SecureEnclave.isAvailable }
    }

    init(
        applicationTag: Data,
        secureEnclaveAvailable: @escaping @Sendable () -> Bool
    ) {
        self.applicationTag = applicationTag
        self.secureEnclaveAvailable = secureEnclaveAvailable
    }

    public func keyInfo() async throws -> UserPresenceKeyInfo {
        try SystemPresenceKeyStore.ensureKeyInfo(
            applicationTag: applicationTag,
            secureEnclaveAvailable: secureEnclaveAvailable(),
            context: nil
        )
    }

    public func authorize(
        localizedReason: String
    ) async throws -> any UserPresenceProofSigning {
        #if targetEnvironment(simulator)
            // Use software presence keys only under a compile-time simulator target, never a device runtime preference.
            let keyInfo: UserPresenceKeyInfo
            do {
                keyInfo = try SystemPresenceKeyStore.ensureKeyInfo(
                    applicationTag: applicationTag,
                    secureEnclaveAvailable: false,
                    context: nil
                )
            } catch {
                throw UserPresenceAuthorizationError.keyUnavailable
            }
            // Retain previously enrolled simulator keys even when their existing protection still prompts for a passcode.
            guard keyInfo.protection == .softwareTestOnly else {
                return try await authorizeWithSystemPrompt(localizedReason: localizedReason)
            }
            do {
                let material = try SystemPresenceKeyStore.softwareSigningMaterial(
                    applicationTag: applicationTag
                )
                return UserPresenceSigningSession(
                    keyInfo: material.keyInfo,
                    signing: material.sign
                )
            } catch {
                throw UserPresenceAuthorizationError.keyUnavailable
            }
        #else
            return try await authorizeWithSystemPrompt(localizedReason: localizedReason)
        #endif
    }

    private func authorizeWithSystemPrompt(
        localizedReason: String
    ) async throws -> any UserPresenceProofSigning {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            context.invalidate()
            throw UserPresenceAuthorizationError.unavailable
        }

        do {
            guard
                try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: localizedReason
                )
            else {
                context.invalidate()
                throw UserPresenceAuthorizationError.declined
            }
        } catch let error as LAError {
            context.invalidate()
            switch error.code {
            case .appCancel, .authenticationFailed, .systemCancel, .userCancel:
                throw UserPresenceAuthorizationError.declined
            default:
                throw UserPresenceAuthorizationError.unavailable
            }
        } catch {
            context.invalidate()
            throw error
        }

        do {
            _ = try SystemPresenceKeyStore.ensureKeyInfo(
                applicationTag: applicationTag,
                secureEnclaveAvailable: secureEnclaveAvailable(),
                context: context
            )
            let material = try SystemPresenceKeyStore.authorizedSigningMaterial(
                applicationTag: applicationTag,
                context: context
            )
            return UserPresenceSigningSession(
                keyInfo: material.keyInfo,
                signing: material.sign,
                invalidate: { context.invalidate() }
            )
        } catch {
            context.invalidate()
            throw UserPresenceAuthorizationError.keyUnavailable
        }
    }

    static func preferredProtection(secureEnclaveAvailable: Bool) -> UserPresenceKeyProtection {
        #if targetEnvironment(simulator)
            return .softwareTestOnly
        #else
            return secureEnclaveAvailable ? .secureEnclaveUserPresence : .keychainUserPresence
        #endif
    }
}

private struct AuthorizedPresenceSigningMaterial: @unchecked Sendable {
    let keyInfo: UserPresenceKeyInfo
    let sign: @Sendable (Data) throws -> Data
}

private enum SystemPresenceKeyStore {
    private static let metadataService = "app.spark.user-presence.metadata.v1"
    private static let privateKeyService = "app.spark.user-presence.private.v1"

    private struct Metadata: Codable {
        let publicKeySPKI: Data
        let protection: UserPresenceKeyProtection

        var keyInfo: UserPresenceKeyInfo {
            UserPresenceKeyInfo(publicKeySPKI: publicKeySPKI, protection: protection)
        }
    }

    static func ensureKeyInfo(
        applicationTag: Data,
        secureEnclaveAvailable: Bool,
        context: LAContext?
    ) throws -> UserPresenceKeyInfo {
        if let metadata = try loadMetadata(applicationTag: applicationTag) {
            // Never replace an enrolled presence key without re-pairing the device.
            return metadata.keyInfo
        }

        #if targetEnvironment(simulator)
            // Use a software key only on the simulator because its Keychain cannot enforce hardware user presence.
            let softwareKey = P256.Signing.PrivateKey()
            let softwareKeyInfo = UserPresenceKeyInfo(
                publicKeySPKI: softwareKey.publicKey.derRepresentation,
                protection: .softwareTestOnly
            )
            try storeSoftwarePrivateKey(
                softwareKey.rawRepresentation,
                applicationTag: applicationTag
            )
            do {
                try storeMetadata(softwareKeyInfo, applicationTag: applicationTag)
            } catch {
                try? deleteFallbackPrivateKey(applicationTag: applicationTag)
                throw error
            }
            return softwareKeyInfo
        #else
            if secureEnclaveAvailable,
                let keyInfo = try? createSecureEnclaveKey(applicationTag: applicationTag)
            {
                try storeMetadata(keyInfo, applicationTag: applicationTag)
                return keyInfo
            }

            if let context,
                let raw = try? loadFallbackPrivateKey(
                    applicationTag: applicationTag,
                    context: context
                ),
                let existing = try? P256.Signing.PrivateKey(rawRepresentation: raw)
            {
                let keyInfo = UserPresenceKeyInfo(
                    publicKeySPKI: existing.publicKey.derRepresentation,
                    protection: .keychainUserPresence
                )
                try storeMetadata(keyInfo, applicationTag: applicationTag)
                return keyInfo
            }

            let key = P256.Signing.PrivateKey()
            let keyInfo = UserPresenceKeyInfo(
                publicKeySPKI: key.publicKey.derRepresentation,
                protection: .keychainUserPresence
            )
            try storeFallbackPrivateKey(key.rawRepresentation, applicationTag: applicationTag)
            do {
                try storeMetadata(keyInfo, applicationTag: applicationTag)
            } catch {
                try? deleteFallbackPrivateKey(applicationTag: applicationTag)
                throw error
            }
            return keyInfo
        #endif
    }

    static func authorizedSigningMaterial(
        applicationTag: Data,
        context: LAContext
    ) throws -> AuthorizedPresenceSigningMaterial {
        guard let metadata = try loadMetadata(applicationTag: applicationTag) else {
            throw UserPresenceAuthorizationError.keyUnavailable
        }
        switch metadata.protection {
        case .secureEnclaveUserPresence:
            guard
                let key = try loadSecureEnclaveKey(
                    applicationTag: applicationTag,
                    context: context
                )
            else {
                throw UserPresenceAuthorizationError.keyUnavailable
            }
            let keyInfo = try secureEnclaveKeyInfo(key)
            guard keyInfo.publicKeySPKI == metadata.publicKeySPKI else {
                throw UserPresenceAuthorizationError.keyUnavailable
            }
            let box = SecureEnclavePresenceKey(key: key)
            return AuthorizedPresenceSigningMaterial(
                keyInfo: keyInfo,
                sign: { try box.sign($0) }
            )
        case .keychainUserPresence:
            let raw = try loadFallbackPrivateKey(
                applicationTag: applicationTag,
                context: context
            )
            let key: P256.Signing.PrivateKey
            do {
                key = try P256.Signing.PrivateKey(rawRepresentation: raw)
            } catch {
                throw UserPresenceAuthorizationError.keyUnavailable
            }
            guard key.publicKey.derRepresentation == metadata.publicKeySPKI else {
                throw UserPresenceAuthorizationError.keyUnavailable
            }
            let box = KeychainPresenceKey(key: key)
            return AuthorizedPresenceSigningMaterial(
                keyInfo: metadata.keyInfo,
                sign: { try box.sign($0) }
            )
        case .softwareTestOnly:
            throw UserPresenceAuthorizationError.keyUnavailable
        }
    }

    /// Permit unprompted software presence signing only for simulator-created key metadata.
    static func softwareSigningMaterial(
        applicationTag: Data
    ) throws -> AuthorizedPresenceSigningMaterial {
        guard let metadata = try loadMetadata(applicationTag: applicationTag),
            metadata.protection == .softwareTestOnly
        else {
            throw UserPresenceAuthorizationError.keyUnavailable
        }
        let raw = try loadSoftwarePrivateKey(applicationTag: applicationTag)
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(rawRepresentation: raw)
        } catch {
            throw UserPresenceAuthorizationError.keyUnavailable
        }
        guard key.publicKey.derRepresentation == metadata.publicKeySPKI else {
            throw UserPresenceAuthorizationError.keyUnavailable
        }
        let box = KeychainPresenceKey(key: key)
        return AuthorizedPresenceSigningMaterial(
            keyInfo: metadata.keyInfo,
            sign: { try box.sign($0) }
        )
    }

    private static func storeSoftwarePrivateKey(
        _ rawPrivateKey: Data,
        applicationTag: Data
    ) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: privateKeyService,
            kSecAttrAccount: account(applicationTag),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: rawPrivateKey,
        ]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw UserPresenceAuthorizationError.keyUnavailable
        }
    }

    private static func loadSoftwarePrivateKey(applicationTag: Data) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: privateKeyService,
            kSecAttrAccount: account(applicationTag),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else {
            throw UserPresenceAuthorizationError.keyUnavailable
        }
        return data
    }

    private static func createSecureEnclaveKey(applicationTag: Data) throws -> UserPresenceKeyInfo {
        if let existing = try loadSecureEnclaveKey(applicationTag: applicationTag, context: nil) {
            return try secureEnclaveKeyInfo(existing)
        }
        var accessError: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage, .userPresence],
                &accessError
            )
        else {
            throw UserPresenceAuthorizationError.keyUnavailable
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: applicationTag,
                kSecAttrAccessControl: access,
            ],
        ]
        var createError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
            if let raced = try loadSecureEnclaveKey(applicationTag: applicationTag, context: nil) {
                return try secureEnclaveKeyInfo(raced)
            }
            throw UserPresenceAuthorizationError.keyUnavailable
        }
        return try secureEnclaveKeyInfo(key)
    }

    private static func secureEnclaveKeyInfo(_ key: SecKey) throws -> UserPresenceKeyInfo {
        guard let publicKey = SecKeyCopyPublicKey(key),
            let rawPoint = SecKeyCopyExternalRepresentation(publicKey, nil)
        else {
            throw UserPresenceAuthorizationError.keyUnavailable
        }
        return UserPresenceKeyInfo(
            publicKeySPKI: ecKeySPKI(rawPoint: rawPoint as Data),
            protection: .secureEnclaveUserPresence
        )
    }

    private static func loadSecureEnclaveKey(
        applicationTag: Data,
        context: LAContext?
    ) throws -> SecKey? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationTag: applicationTag,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if let context { query[kSecUseAuthenticationContext] = context }
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let result else { throw UserPresenceAuthorizationError.keyUnavailable }
            return (result as! SecKey)
        case errSecItemNotFound:
            return nil
        default:
            throw UserPresenceAuthorizationError.keyUnavailable
        }
    }

    private static func storeFallbackPrivateKey(
        _ rawPrivateKey: Data,
        applicationTag: Data
    ) throws {
        var accessError: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.userPresence],
                &accessError
            )
        else {
            throw UserPresenceAuthorizationError.keyUnavailable
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: privateKeyService,
            kSecAttrAccount: account(applicationTag),
            kSecAttrAccessControl: access,
            kSecValueData: rawPrivateKey,
        ]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw UserPresenceAuthorizationError.keyUnavailable
        }
    }

    private static func loadFallbackPrivateKey(
        applicationTag: Data,
        context: LAContext
    ) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: privateKeyService,
            kSecAttrAccount: account(applicationTag),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else {
            throw UserPresenceAuthorizationError.keyUnavailable
        }
        return data
    }

    private static func deleteFallbackPrivateKey(applicationTag: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: privateKeyService,
            kSecAttrAccount: account(applicationTag),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw UserPresenceAuthorizationError.keyUnavailable
        }
    }

    private static func loadMetadata(applicationTag: Data) throws -> Metadata? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: metadataService,
            kSecAttrAccount: account(applicationTag),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data,
                let metadata = try? JSONDecoder().decode(Metadata.self, from: data)
            else {
                throw UserPresenceAuthorizationError.keyUnavailable
            }
            return metadata
        case errSecItemNotFound:
            return nil
        default:
            throw UserPresenceAuthorizationError.keyUnavailable
        }
    }

    private static func storeMetadata(
        _ keyInfo: UserPresenceKeyInfo,
        applicationTag: Data
    ) throws {
        let data = try JSONEncoder().encode(
            Metadata(publicKeySPKI: keyInfo.publicKeySPKI, protection: keyInfo.protection)
        )
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: metadataService,
            kSecAttrAccount: account(applicationTag),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            if status == errSecDuplicateItem,
                try loadMetadata(applicationTag: applicationTag)?.keyInfo == keyInfo
            {
                return
            }
            throw UserPresenceAuthorizationError.keyUnavailable
        }
    }

    private static func account(_ applicationTag: Data) -> String {
        Base64URL.encode(applicationTag)
    }
}

private final class SecureEnclavePresenceKey: @unchecked Sendable {
    let key: SecKey

    init(key: SecKey) {
        self.key = key
    }

    func sign(_ input: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(
                key,
                .ecdsaSignatureMessageX962SHA256,
                input as CFData,
                &error
            )
        else {
            throw UserPresenceProofError.signingFailed
        }
        return try derECDSAToRaw(der: signature as Data)
    }
}

private final class KeychainPresenceKey: @unchecked Sendable {
    let key: P256.Signing.PrivateKey

    init(key: P256.Signing.PrivateKey) {
        self.key = key
    }

    func sign(_ input: Data) throws -> Data {
        try key.signature(for: input).rawRepresentation
    }
}
