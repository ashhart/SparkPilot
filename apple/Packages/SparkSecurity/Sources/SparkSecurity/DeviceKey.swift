import CryptoKit
import Foundation
import Security

/// Transmit device request signatures as 64-byte P-256 ECDSA r||s under SPARK2 (§15.2/§37.2).
public protocol DeviceSigning {
    var publicKeySPKI: Data { get }
    func sign(_ data: Data) throws -> Data
}

/// Load the existing Secure Enclave device key before creating one so paired identity survives relaunch.
public struct SecureEnclaveSigner: DeviceSigning, @unchecked Sendable {
    private let key: SecKey
    private let spki: Data

    /// What a lookup could establish about this device's enclave key.
    public enum Existing {
        /// A key is there. It is the identity any grant is bound to.
        case found(SecureEnclaveSigner)
        /// Permit key creation or fallback only after lookup proves absence.
        case absent
    }

    /// Validate and retain SPKI during throwing initialization so publicKeySPKI cannot later return an empty identity.
    init(existing key: SecKey) throws {
        self.key = key
        self.spki = try Self.exportSPKI(key)
    }

    private static func exportSPKI(_ key: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key),
            let raw = SecKeyCopyExternalRepresentation(publicKey, nil)
        else {
            throw DeviceKeyError.publicKeyExportFailed
        }
        // Wrap the raw EC point 04||X||Y in SubjectPublicKeyInfo for wire transport.
        return ecKeySPKI(rawPoint: raw as Data)
    }

    /// Distinguish absent Secure Enclave keys from inaccessible keys before permitting creation or fallback.
    public static func existingKey(applicationTag: Data) throws -> Existing {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationTag: applicationTag,
            kSecReturnRef: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let item else { throw DeviceKeyError.keychainLookupFailed(status) }
            // `SecKey` is a CFType; this is the documented way back.
            return .found(try SecureEnclaveSigner(existing: item as! SecKey))
        case errSecItemNotFound:
            return .absent
        default:
            throw DeviceKeyError.keychainLookupFailed(status)
        }
    }

    /// Create this device's enclave key. Only called once absence is proven.
    public static func create(applicationTag: Data) throws -> SecureEnclaveSigner {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: applicationTag,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw DeviceKeyError.createFailed(error?.takeRetainedValue())
        }
        return try SecureEnclaveSigner(existing: key)
    }

    /// Load or create, failing closed on anything that is not proven absence.
    public init(applicationTag: Data) throws {
        switch try Self.existingKey(applicationTag: applicationTag) {
        case .found(let signer):
            self = signer
        case .absent:
            self = try Self.create(applicationTag: applicationTag)
        }
    }

    /// Remove the key. Used when a device is unpaired deliberately.
    public static func destroy(applicationTag: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationTag: applicationTag,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceKeyError.keychainDeleteFailed(status)
        }
    }

    public var publicKeySPKI: Data { spki }

    public func sign(_ data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(
                key,
                .ecdsaSignatureMessageX962SHA256,
                data as CFData,
                &error
            )
        else {
            throw DeviceKeyError.signFailed(error?.takeRetainedValue())
        }
        return try derECDSAToRaw(der: signature as Data)
    }
}

/// Load or create the software P-256 key under stable Keychain service/account coordinates without iCloud synchronization.
public struct SoftwareSigner: DeviceSigning, @unchecked Sendable {
    private let key: P256.Signing.PrivateKey

    /// Use key application tags for kSecClassKey and service/account coordinates for generic-password items.
    public static let service = "app.spark.device-key"

    /// Inject storage to verify stable software-key reuse without touching the live Keychain.
    public init(applicationTag: Data, store: any SecureStore = KeychainStore()) throws {
        let account = String(decoding: applicationTag, as: UTF8.self)
        self.key = try Self.loadOrCreate(account: account, store: store)
    }

    /// Create keys atomically only when absent and reread after collisions without overwriting or unbounded retries.
    private static func loadOrCreate(
        account: String,
        store: any SecureStore
    ) throws -> P256.Signing.PrivateKey {
        if let stored = try store.data(service: service, account: account) {
            return try P256.Signing.PrivateKey(derRepresentation: stored)
        }
        let candidate = P256.Signing.PrivateKey()
        do {
            try store.add(candidate.derRepresentation, service: service, account: account)
            return candidate
        } catch KeychainError.alreadyExists {
            // Reuse the concurrent writer's key so grants retain the established identity.
            guard let stored = try store.data(service: service, account: account) else {
                throw DeviceKeyError.keychainRaceUnresolved
            }
            return try P256.Signing.PrivateKey(derRepresentation: stored)
        }
    }

    /// An ephemeral signer for contexts with no Keychain at all.
    public init() {
        self.key = P256.Signing.PrivateKey()
    }

    /// Remove the stored key. Used when a device is unpaired deliberately.
    public static func destroy(
        applicationTag: Data,
        store: any SecureStore = KeychainStore()
    ) throws {
        try store.delete(service: service, account: String(decoding: applicationTag, as: UTF8.self))
    }

    public var publicKeySPKI: Data {
        key.publicKey.derRepresentation
    }

    public func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).rawRepresentation
    }
}

/// Secure Enclave first, software fallback (§15.2).
public enum DeviceKeyFactory {
    /// Matches the server's kSecAttrApplicationTag conventions.
    public static let defaultApplicationTag = "app.spark.device-key".data(using: .utf8)!

    /// Return SendableDeviceSigning for both hardware and software signers so actor handoff never requires an unsigned fallback.
    public static func makeSigner(
        applicationTag: Data = defaultApplicationTag,
        store: any SecureStore = KeychainStore()
    ) throws -> any SendableDeviceSigning {
        guard SecureEnclave.isAvailable else {
            // Proven unsupported: there is no enclave on this device.
            return try SoftwareSigner(applicationTag: applicationTag, store: store)
        }

        // Propagate existing-key lookup errors instead of creating a different software identity.
        switch try SecureEnclaveSigner.existingKey(applicationTag: applicationTag) {
        case .found(let signer):
            return signer
        case .absent:
            break
        }

        // Allow creation fallback only after proving no Secure Enclave key exists.
        do {
            return try SecureEnclaveSigner.create(applicationTag: applicationTag)
        } catch {
            return try SoftwareSigner(applicationTag: applicationTag, store: store)
        }
    }

    /// Clear both hardware and software device-key stores when forgetting this identity.
    public static func destroy(
        applicationTag: Data = defaultApplicationTag,
        store: any SecureStore = KeychainStore()
    ) throws {
        try? SecureEnclaveSigner.destroy(applicationTag: applicationTag)
        try SoftwareSigner.destroy(applicationTag: applicationTag, store: store)
    }
}

/// Keep cross-isolation signing conformances beside both concrete signer types.
public protocol SendableDeviceSigning: DeviceSigning, Sendable {}

extension SoftwareSigner: SendableDeviceSigning {}
extension SecureEnclaveSigner: SendableDeviceSigning {}

public enum DeviceKeyError: Error {
    case createFailed(CFError?)
    /// Fail inconsistent absent/collision/absent storage results instead of overwriting possible identity material.
    case keychainRaceUnresolved
    case signFailed(CFError?)
    case keychainAddFailed(OSStatus)
    case keychainLookupFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case malformedSignature
    /// Fail key construction when public-key export cannot produce valid SPKI.
    case publicKeyExportFailed
}

// MARK: - SPKI / DER helpers

/// Wrap a raw EC point (04||X||Y) into a SubjectPublicKeyInfo DER blob.
func ecKeySPKI(rawPoint: Data) -> Data {
    // id-ecPublicKey 1.2.840.10045.2.1, P-256 OID 1.2.840.10045.3.1.7
    let oidECPublicKey: [UInt8] = [0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]
    let oidP256: [UInt8] = [0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]
    let algorithm =
        Data([0x30, UInt8(oidECPublicKey.count + oidP256.count)])
        + Data(oidECPublicKey + oidP256)
    let bitStringContent = Data([0x00]) + rawPoint
    let bitString = Data([0x03, UInt8(bitStringContent.count)]) + bitStringContent
    let spki = algorithm + bitString
    return Data([0x30, UInt8(spki.count)]) + spki
}

/// Convert ASN.1 ECDSA integer pairs into the required 64-byte raw r||s wire form.
func derECDSAToRaw(der: Data) throws -> Data {
    do {
        return try P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation
    } catch {
        throw DeviceKeyError.malformedSignature
    }
}
