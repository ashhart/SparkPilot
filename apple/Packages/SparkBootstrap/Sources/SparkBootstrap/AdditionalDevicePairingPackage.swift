import CryptoKit
import Foundation
import SparkSecurity

/// Carry the full TLS pin and authority public key out of band without passwords, tokens or private keys.
public struct AdditionalDevicePairingPackage: Codable, Equatable, Sendable {
    /// QA-04: minted under the app's own scheme; `PairingLinkScheme` still reads the older `spark://pair/` form.
    public static let route = "pair/"
    public static let schemePrefix = PairingLinkScheme.mint(route)

    public let nodeName: String
    public let tlsFingerprint: String
    public let authorityPublicKey: String
    public let invitation: PairingInvitation
    /// Treat the owner's endpoint as a routing hint whose connection still requires the supplied TLS pin and authority key.
    public let localHint: String?

    public init(
        nodeName: String,
        tlsFingerprint: String,
        authorityPublicKey: String,
        invitation: PairingInvitation,
        localHint: String? = nil
    ) {
        self.nodeName = nodeName
        self.tlsFingerprint = tlsFingerprint
        self.authorityPublicKey = authorityPublicKey
        self.invitation = invitation
        self.localHint = localHint
    }

    public init(qrPayload: String) throws {
        guard let encoded = PairingLinkScheme.body(of: qrPayload, route: Self.route) else {
            throw AdditionalDevicePairingPackageError.notAPairingPackage
        }
        guard let data = Self.base64URLDecode(encoded) else {
            throw AdditionalDevicePairingPackageError.malformedEncoding
        }
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw AdditionalDevicePairingPackageError.malformedPackage
        }
        try validate()
    }

    public func qrPayload() throws -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return Self.schemePrefix + Self.base64URLEncode(data)
    }

    /// Parse fractional RFC 3339 expiry timestamps so valid nanosecond-precision invitations remain usable.
    public func isLocallyPlausible(now: Date = Date()) -> Bool {
        guard let expiry = RFC3339.date(from: invitation.expiresAt) else { return false }
        return expiry > now
    }

    /// Adapt the trusted handoff to the existing challenge and claim engine.
    public func bootstrapResult() throws -> RuntimeBootstrapResult {
        try validate()
        let invitationData = try JSONEncoder().encode(invitation)
        return RuntimeBootstrapResult(
            nodeID: invitation.nodeID,
            nodeName: nodeName,
            authorityFingerprint: invitation.authorityFingerprint,
            authorityPublicKey: authorityPublicKey,
            tlsFingerprint: tlsFingerprint,
            invitationExpiresAt: invitation.expiresAt,
            invitation: try JSONValue.parse(invitationData),
            trustRootSource: .supplied
        )
    }

    /// Verify every target's authority signature before claiming any batch invitation to prevent malformed partial grants.
    public func verifyInvitationSignature() throws {
        let bootstrap = try bootstrapResult()
        guard let authorityBytes = Self.hexData(authorityPublicKey), authorityBytes.count == 32
        else {
            throw AdditionalDevicePairingPackageError.invalidAuthorityPublicKey
        }
        let authority = try Curve25519.Signing.PublicKey(rawRepresentation: authorityBytes)
        try PairingInvitationPayload(json: bootstrap.invitation).verify(under: authority)
    }

    private func validate() throws {
        let trimmedName = nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 120 else {
            throw AdditionalDevicePairingPackageError.invalidNodeName
        }
        guard Self.isHexDigest(tlsFingerprint) else {
            throw AdditionalDevicePairingPackageError.invalidTLSFingerprint
        }
        guard Self.isHexDigest(authorityPublicKey) else {
            throw AdditionalDevicePairingPackageError.invalidAuthorityPublicKey
        }
        let keyBytes = Data(
            stride(from: 0, to: authorityPublicKey.count, by: 2).compactMap { offset in
                let start = authorityPublicKey.index(
                    authorityPublicKey.startIndex,
                    offsetBy: offset
                )
                let end = authorityPublicKey.index(start, offsetBy: 2)
                return UInt8(authorityPublicKey[start..<end], radix: 16)
            }
        )
        let digest = SHA256.hash(data: keyBytes).map { String(format: "%02x", $0) }.joined()
        let expected = invitation.authorityFingerprint
            .lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
        guard digest == expected else {
            throw AdditionalDevicePairingPackageError.authorityKeyMismatch
        }
        guard PairingInvitation.supportedVersions.contains(invitation.version),
            UUID(uuidString: invitation.nodeID) != nil,
            UUID(uuidString: invitation.invitationID) != nil,
            invitation.signature?.isEmpty == false
        else {
            throw AdditionalDevicePairingPackageError.malformedInvitation
        }
        if let localHint {
            guard let url = URL(string: localHint),
                url.scheme?.lowercased() == "https",
                url.user == nil,
                url.password == nil,
                url.host != nil
            else {
                throw AdditionalDevicePairingPackageError.invalidLocalHint
            }
        }
    }

    /// The address hint as a usable route, when it is one.
    public var localHintURL: URL? {
        guard let localHint, let url = URL(string: localHint),
            url.scheme?.lowercased() == "https",
            url.user == nil,
            url.password == nil,
            url.host != nil
        else { return nil }
        return url
    }

    private static func isHexDigest(_ value: String) -> Bool {
        value.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func hexData(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            data.append(byte)
            index = end
        }
        return data
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 =
            value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private enum CodingKeys: String, CodingKey {
        case nodeName = "node_name"
        case tlsFingerprint = "tls_fingerprint"
        case authorityPublicKey = "authority_public_key"
        case invitation
        case localHint = "local_hint"
    }
}

public enum AdditionalDevicePairingPackageError: Error, Equatable, Sendable {
    case notAPairingPackage
    case malformedEncoding
    case malformedPackage
    case invalidNodeName
    case invalidTLSFingerprint
    case invalidAuthorityPublicKey
    case authorityKeyMismatch
    case malformedInvitation
    case invalidLocalHint
}
