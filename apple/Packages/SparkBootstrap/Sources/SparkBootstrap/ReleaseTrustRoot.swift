import CryptoKit
import Foundation

/// Restrict schema-1 direct online-key trust to dev/lab because production channels require authenticated offline-root delegation.
public struct ReleaseTrustRoot: Sendable, Equatable {
    public let schema: Int
    public let keys: [TrustedReleaseKey]
    let rootKeys: [TrustedReleaseKey]
    let delegationDocument: JSONValue?
    let minimumDelegationVersion: Int64?

    public static let currentSchema = 1

    /// Keep release-manifest and model-catalogue signing purposes separate.
    public static let manifestPurpose = "release-manifest"
    public static let packagePurpose = "release-package"
    public static let cataloguePurpose = "model-catalogue"
    public static let purposes: Set<String> = [
        manifestPurpose, packagePurpose, cataloguePurpose, "release-delegation",
    ]

    /// Channels a schema 1 root may vouch for.
    public static let directTrustChannels: Set<String> = ["dev", "lab"]
}

public struct TrustedReleaseKey: Sendable, Equatable {
    public let keyID: String
    public let algorithm: String
    /// Hex-encoded Ed25519 public key, 32 bytes.
    public let publicKey: String
    public let channels: [String]
    public let purposes: [String]
    public let notBefore: Date
    public let notAfter: Date
    public let revokedAt: Date?
    public let comment: String?
}

/// A manifest whose signature verified, and the key that vouched for it.
public struct VerifiedReleaseManifest: Sendable, Equatable {
    public let manifest: ReleaseManifest
    public let keyID: String
}

public enum ReleaseTrustError: Error, Equatable, Sendable {
    case notJSON(String)
    case unsupportedSchema(Int)
    case empty
    case duplicateKeyID(String)
    case invalidKey(keyID: String, reason: String)
    case unknownKeyID(String)
    case revokedKey(String)
    case keyNotValid(keyID: String, at: Date)
    case channelNotAuthorised(keyID: String, channel: String)
    case purposeNotAuthorised(keyID: String, purposes: [String], needed: String)
    case delegationRequired(String)
    case invalidDelegation(String)
    case signatureInvalid(String)
    case manifest(ReleaseManifestError)
}

extension ReleaseTrustRoot {
    public static func parse(_ data: Data) throws -> ReleaseTrustRoot {
        guard let members = (try? JSONValue.parse(data))?.objectValue else {
            throw ReleaseTrustError.notJSON("trust root is not a JSON object")
        }
        guard let schema = members["schema"]?.integerValue else {
            throw ReleaseTrustError.notJSON("trust root has no schema")
        }
        guard [1, 2].contains(schema) else {
            throw ReleaseTrustError.unsupportedSchema(Int(schema))
        }
        guard let rawKeys = members["keys"]?.arrayValue, !rawKeys.isEmpty else {
            throw ReleaseTrustError.empty
        }

        var keys: [TrustedReleaseKey] = []
        var seen: Set<String> = []
        for raw in rawKeys {
            let key = try TrustedReleaseKey(json: raw)
            // Reject duplicate key IDs that could ambiguously widen scope or bypass revocation.
            guard seen.insert(key.keyID).inserted else {
                throw ReleaseTrustError.duplicateKeyID(key.keyID)
            }
            keys.append(key)
        }
        let allowed: Set<String> =
            schema == 1
            ? ["schema", "keys"]
            : ["schema", "keys", "root_keys", "minimum_delegation_version", "delegation"]
        guard Set(members.keys).isSubset(of: allowed) else {
            throw ReleaseTrustError.invalidDelegation("unknown trust field")
        }
        let rootKeys = try (members["root_keys"]?.arrayValue ?? []).map(
            TrustedReleaseKey.init(json:)
        )
        let root = ReleaseTrustRoot(
            schema: Int(schema),
            keys: keys,
            rootKeys: rootKeys,
            delegationDocument: members["delegation"],
            minimumDelegationVersion: members["minimum_delegation_version"]?.integerValue
        )
        try root.validateDelegation(keysDocument: members["keys"])
        return root
    }

    /// Validate signature and key policy at the supplied time with distinct refusal reasons.
    public func verify(
        manifest data: Data,
        at moment: Date
    ) throws -> VerifiedReleaseManifest {
        let manifest: ReleaseManifest
        do {
            manifest = try ReleaseManifest.parse(data)
        } catch let error as ReleaseManifestError {
            throw ReleaseTrustError.manifest(error)
        }

        guard let signature = manifest.signature else {
            throw ReleaseTrustError.manifest(.missingSignature)
        }
        guard let key = keys.first(where: { $0.keyID == signature.keyID }) else {
            throw ReleaseTrustError.unknownKeyID(signature.keyID)
        }
        try key.assertUsable(
            at: moment,
            channel: manifest.channel,
            purpose: ReleaseTrustRoot.manifestPurpose,
            needed: "sign release manifests"
        )

        try authorizeChannel(manifest.channel, at: moment)
        let signatureBytes: Data
        let canonical: Data
        do {
            signatureBytes = try manifest.signatureBytes()
            canonical = try manifest.canonicalBytes()
        } catch let error as ReleaseManifestError {
            throw ReleaseTrustError.manifest(error)
        }

        guard try key.verifyingKey().isValidSignature(signatureBytes, for: canonical) else {
            throw ReleaseTrustError.signatureInvalid(key.keyID)
        }
        return VerifiedReleaseManifest(manifest: manifest, keyID: key.keyID)
    }

    /// Verify a detached signature over arbitrary bytes — the `.deb` itself.
    public func verifyDetached(
        keyID: String,
        payload: Data,
        signature: Data,
        at moment: Date,
        channel: String
    ) throws {
        guard let key = keys.first(where: { $0.keyID == keyID }) else {
            throw ReleaseTrustError.unknownKeyID(keyID)
        }
        try key.assertUsable(
            at: moment,
            channel: channel,
            purpose: ReleaseTrustRoot.packagePurpose,
            needed: "sign release packages"
        )
        try authorizeChannel(channel, at: moment)
        guard signature.count == 64,
            try key.verifyingKey().isValidSignature(signature, for: payload)
        else {
            throw ReleaseTrustError.signatureInvalid(keyID)
        }
    }
}

extension TrustedReleaseKey {
    init(json: JSONValue) throws {
        guard let members = json.objectValue else {
            throw ReleaseTrustError.notJSON("key is not an object")
        }
        let allowed: Set<String> = [
            "key_id", "algorithm", "public_key", "channels", "purposes",
            "not_before", "not_after", "revoked_at", "comment",
        ]
        guard Set(members.keys).isSubset(of: allowed) else {
            throw ReleaseTrustError.invalidDelegation("unknown key field")
        }
        let keyID = members["key_id"]?.stringValue ?? ""
        func invalid(_ reason: String) -> ReleaseTrustError {
            .invalidKey(keyID: keyID, reason: reason)
        }
        guard !keyID.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw invalid("key_id is empty")
        }
        guard let algorithm = members["algorithm"]?.stringValue,
            algorithm == ReleaseManifest.signatureAlgorithm
        else {
            throw invalid("algorithm is not \(ReleaseManifest.signatureAlgorithm)")
        }
        guard let publicKey = members["public_key"]?.stringValue,
            publicKey.count == 64,
            Data(hex: publicKey) != nil
        else {
            throw invalid("public_key is not 32 hex-encoded bytes")
        }
        let channels = (members["channels"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard !channels.isEmpty, channels.count == members["channels"]?.arrayValue?.count else {
            throw invalid("invalid channel scope")
        }
        let purposes = (members["purposes"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard !purposes.isEmpty, purposes.count == members["purposes"]?.arrayValue?.count else {
            throw invalid("invalid purpose scope")
        }
        if let unknown = purposes.first(where: { !ReleaseTrustRoot.purposes.contains($0) }) {
            throw invalid("unknown purpose \(unknown)")
        }

        guard let rawNotBefore = members["not_before"]?.stringValue,
            let notBefore = RFC3339.date(from: rawNotBefore)
        else {
            throw invalid("not_before is not RFC 3339")
        }
        guard let rawNotAfter = members["not_after"]?.stringValue,
            let notAfter = RFC3339.date(from: rawNotAfter)
        else {
            throw invalid("not_after is not RFC 3339")
        }
        guard notAfter > notBefore else {
            throw invalid("validity window ends before it starts")
        }

        // Fail closed on malformed revocation timestamps.
        var revokedAt: Date?
        if let value = members["revoked_at"], value != .null {
            guard let raw = value.stringValue else { throw invalid("revoked_at is not RFC 3339") }
            guard let parsed = RFC3339.date(from: raw) else {
                throw invalid("revoked_at is not RFC 3339")
            }
            revokedAt = parsed
        }

        self.init(
            keyID: keyID,
            algorithm: algorithm,
            publicKey: publicKey,
            channels: channels,
            purposes: purposes,
            notBefore: notBefore,
            notAfter: notAfter,
            revokedAt: revokedAt,
            comment: members["comment"]?.stringValue
        )
    }

    func verifyingKey() throws -> Curve25519.Signing.PublicKey {
        guard let bytes = Data(hex: publicKey) else {
            throw ReleaseTrustError.invalidKey(keyID: keyID, reason: "public_key is not hex")
        }
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
        } catch {
            throw ReleaseTrustError.invalidKey(
                keyID: keyID,
                reason: "public_key is not a valid Ed25519 point"
            )
        }
    }

    func assertUsable(at moment: Date, channel: String, purpose: String, needed: String) throws {
        if revokedAt != nil {
            throw ReleaseTrustError.revokedKey(keyID)
        }
        guard moment >= notBefore, moment < notAfter else {
            throw ReleaseTrustError.keyNotValid(keyID: keyID, at: moment)
        }
        guard channels.contains(channel) else {
            throw ReleaseTrustError.channelNotAuthorised(keyID: keyID, channel: channel)
        }
        guard purposes.contains(purpose) else {
            throw ReleaseTrustError.purposeNotAuthorised(
                keyID: keyID,
                purposes: purposes,
                needed: needed
            )
        }
    }
}

extension Data {
    /// Decode lowercase or uppercase hex. Returns nil on anything else.
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    /// Lowercase hex, matching the runtime's fingerprint format.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
