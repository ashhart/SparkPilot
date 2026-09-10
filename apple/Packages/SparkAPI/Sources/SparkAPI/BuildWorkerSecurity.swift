import CryptoKit
import Foundation
import SparkSecurity

public struct BuildWorkerTrust: Sendable, Equatable {
    public let authorityPublicKey: String
    public let authorityFingerprint: String
    public let workerID: UUID
    public let allowedProjectIDs: Set<String>

    public init(
        authorityPublicKey: String,
        authorityFingerprint: String,
        workerID: UUID,
        allowedProjectIDs: Set<String>
    ) {
        self.authorityPublicKey = authorityPublicKey
        self.authorityFingerprint = authorityFingerprint
        self.workerID = workerID
        self.allowedProjectIDs = allowedProjectIDs
    }
}

public enum BuildRecipeVerificationError: Error, Equatable, Sendable {
    case malformedAuthority
    case authorityMismatch
    case signatureInvalid
    case recipeDigestMismatch
    case protocolUnsupported
    case workerMismatch
    case projectNotAllowed
    case mutableCommit
    case sourceDigestInvalid
    case ticketBindingMismatch
    case ticketLimitInvalid
    case identifierInvalid
    case leaseInvalid
    case expired
    case invalidTime
}

public enum BuildRecipeVerifier {
    public static func verify(
        _ claim: GeneratedAPI.BuildClaim,
        trust: BuildWorkerTrust,
        now: Date = Date()
    ) throws -> GeneratedAPI.BuildRecipePayload {
        let recipe = claim.recipe
        guard recipe.authorityPublicKey == trust.authorityPublicKey,
            recipe.authorityFingerprint == trust.authorityFingerprint
        else { throw BuildRecipeVerificationError.authorityMismatch }
        guard let publicKeyBytes = Data(hex: recipe.authorityPublicKey),
            publicKeyBytes.count == 32,
            SHA256Digest.hex(publicKeyBytes) == recipe.authorityFingerprint,
            let signature = Base64URL.decode(recipe.signature), signature.count == 64
        else { throw BuildRecipeVerificationError.malformedAuthority }
        let payloadBytes = try CanonicalBuildJSON.encode(recipe.payload)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
        guard publicKey.isValidSignature(signature, for: payloadBytes) else {
            throw BuildRecipeVerificationError.signatureInvalid
        }
        guard SHA256Digest.hex(try CanonicalBuildJSON.encode(recipe)) == claim.recipeSha256 else {
            throw BuildRecipeVerificationError.recipeDigestMismatch
        }
        let payload = recipe.payload
        guard payload.`protocol` == "SPARK-BUILD-1" else {
            throw BuildRecipeVerificationError.protocolUnsupported
        }
        guard payload.claimGeneration > 0 else {
            throw BuildRecipeVerificationError.ticketBindingMismatch
        }
        guard payload.workerId.caseInsensitiveCompare(trust.workerID.uuidString) == .orderedSame
        else {
            throw BuildRecipeVerificationError.workerMismatch
        }
        guard trust.allowedProjectIDs.contains(payload.projectId.lowercased()) else {
            throw BuildRecipeVerificationError.projectNotAllowed
        }
        guard UUID(uuidString: payload.buildId) != nil,
            UUID(uuidString: payload.projectId) != nil,
            UUID(uuidString: payload.sourceTicket.ticketId) != nil,
            UUID(uuidString: payload.artifactTicket.ticketId) != nil
        else { throw BuildRecipeVerificationError.identifierInvalid }
        guard payload.commit.isLowercaseHex(count: 40) else {
            throw BuildRecipeVerificationError.mutableCommit
        }
        guard payload.sourceSha256.isLowercaseHex(count: 64) else {
            throw BuildRecipeVerificationError.sourceDigestInvalid
        }
        guard payload.sourceTicket.commit == payload.commit,
            payload.sourceTicket.sourceSha256 == payload.sourceSha256,
            payload.sourceTicket.expiresAt == payload.expiresAt,
            payload.artifactTicket.expiresAt == payload.expiresAt,
            payload.artifactTicket.uploadPathTemplate
                == "/api/v1/builds/\(payload.buildId)/artifacts/{artifactId}"
        else { throw BuildRecipeVerificationError.ticketBindingMismatch }
        guard (1...(2 * 1024 * 1024 * 1024)).contains(payload.sourceTicket.maxBytes),
            payload.artifactTicket.maxFileBytes == 8 * 1024 * 1024,
            payload.artifactTicket.maxTotalBytes == 32 * 1024 * 1024,
            payload.artifactTicket.maxFiles == 16,
            (60...1_800).contains(payload.timeoutSeconds)
        else { throw BuildRecipeVerificationError.ticketLimitInvalid }
        guard let issued = parseDate(payload.issuedAt),
            let expires = parseDate(payload.expiresAt),
            issued < expires,
            issued <= now.addingTimeInterval(5 * 60),
            expires.timeIntervalSince(issued) <= 40 * 60
        else { throw BuildRecipeVerificationError.invalidTime }
        guard now < expires else { throw BuildRecipeVerificationError.expired }
        guard let leaseExpires = parseDate(claim.lease.expiresAt),
            now < leaseExpires,
            leaseExpires <= expires,
            (5...60).contains(claim.lease.heartbeatSeconds),
            Base64URL.decode(claim.lease.claimToken)?.count == 32,
            Base64URL.decode(claim.lease.artifactToken)?.count == 32
        else { throw BuildRecipeVerificationError.leaseInvalid }
        return payload
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public struct BuildEvidenceSigner: Sendable {
    private let key: any SendableDeviceSigning

    public init(key: any SendableDeviceSigning) {
        self.key = key
    }

    public func sign(
        _ evidence: GeneratedAPI.BuildResultEvidence
    ) throws -> GeneratedAPI.SignedBuildResult {
        let signature = try key.sign(CanonicalBuildJSON.encode(evidence))
        return GeneratedAPI.SignedBuildResult(
            evidence: evidence,
            workerSignature: Base64URL.encode(signature)
        )
    }
}

enum CanonicalBuildJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

extension Data {
    fileprivate init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
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
}

extension String {
    fileprivate func isLowercaseHex(count: Int) -> Bool {
        self.count == count
            && utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}
