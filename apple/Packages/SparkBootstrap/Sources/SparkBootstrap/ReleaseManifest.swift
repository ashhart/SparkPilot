import Foundation
import SparkSecurity

/// Validate the authoritative release-manifest schema before signature verification, including its artifacts array.
public struct ReleaseManifest: Sendable, Equatable {
    public let version: String
    public let channel: String
    public let releasedAt: String
    public let minimumDGXOS: String
    public let maximumDGXOS: String?
    public let apiVersion: Int64?
    public let artifacts: [ReleaseArtifact]
    public let signature: ManifestSignature?

    /// Derive signing bytes from the received document rather than re-encoding a decoded model.
    private let document: JSONValue

    public static let channels: Set<String> = ["dev", "lab", "beta", "stable"]
    public static let architecture = "aarch64"
    public static let signatureAlgorithm = "ed25519"
}

public struct ReleaseArtifact: Sendable, Equatable {
    public let name: String
    public let architecture: String
    public let url: URL
    public let size: Int64
    public let sha256: String
    public let signatureURL: URL
}

public struct ManifestSignature: Sendable, Equatable {
    public let keyID: String
    public let algorithm: String
    /// base64url, no padding, 64 raw bytes.
    public let value: String
}

public enum ReleaseManifestError: Error, Equatable, Sendable {
    case notJSON(String)
    case missingField(String)
    case unexpectedField(String)
    case invalidVersion(String)
    case invalidReleasedAt(String)
    case invalidAPIVersion(Int64)
    case unsupportedChannel(String)
    case noArtifacts
    case invalidArtifact(name: String, reason: String)
    case missingSignature
    case unsupportedAlgorithm(String)
    case malformedSignature
    case artifactNotFound(String)
    case ambiguousArtifact(Int)
    case canonicalisation(CanonicalJSONError)
}

extension ReleaseManifest {
    /// Parse and validate. No signature is checked here.
    public static func parse(_ data: Data) throws -> ReleaseManifest {
        let document: JSONValue
        do {
            document = try JSONValue.parse(data)
        } catch {
            throw ReleaseManifestError.notJSON("\(error)")
        }
        guard let members = document.objectValue else {
            throw ReleaseManifestError.notJSON("manifest is not a JSON object")
        }

        // Reject unknown manifest members so signature verification cannot silently omit signed fields.
        let known: Set<String> = [
            "version", "channel", "released_at", "minimum_dgx_os", "maximum_dgx_os",
            "api_version", "artifacts", "signature",
        ]
        for key in members.keys where !known.contains(key) {
            throw ReleaseManifestError.unexpectedField(key)
        }

        func requiredString(_ key: String) throws -> String {
            guard let value = members[key]?.stringValue else {
                throw ReleaseManifestError.missingField(key)
            }
            return value
        }

        let version = try requiredString("version")
        guard isReleaseVersion(version) else {
            throw ReleaseManifestError.invalidVersion(version)
        }

        let channel = try requiredString("channel")
        guard channels.contains(channel) else {
            throw ReleaseManifestError.unsupportedChannel(channel)
        }

        let releasedAt = try requiredString("released_at")
        guard RFC3339.date(from: releasedAt) != nil else {
            throw ReleaseManifestError.invalidReleasedAt(releasedAt)
        }

        let minimumDGXOS = try requiredString("minimum_dgx_os")
        guard !minimumDGXOS.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ReleaseManifestError.missingField("minimum_dgx_os")
        }

        let maximumDGXOS = members["maximum_dgx_os"]?.stringValue
        let apiVersion = members["api_version"]?.integerValue
        if let apiVersion, apiVersion < 1 {
            throw ReleaseManifestError.invalidAPIVersion(apiVersion)
        }

        guard let rawArtifacts = members["artifacts"]?.arrayValue else {
            throw ReleaseManifestError.missingField("artifacts")
        }
        guard !rawArtifacts.isEmpty else { throw ReleaseManifestError.noArtifacts }
        let artifacts = try rawArtifacts.map(ReleaseArtifact.init(json:))

        var signature: ManifestSignature?
        if let raw = members["signature"] {
            signature = try ManifestSignature(json: raw)
        }

        return ReleaseManifest(
            version: version,
            channel: channel,
            releasedAt: releasedAt,
            minimumDGXOS: minimumDGXOS,
            maximumDGXOS: maximumDGXOS,
            apiVersion: apiVersion,
            artifacts: artifacts,
            signature: signature,
            document: document
        )
    }

    /// The exact bytes the manifest signature covers.
    public func canonicalBytes() throws -> Data {
        do {
            return try document.canonicalBytes(excludingTopLevel: "signature")
        } catch let error as CanonicalJSONError {
            throw ReleaseManifestError.canonicalisation(error)
        }
    }

    /// The 64 raw signature bytes.
    public func signatureBytes() throws -> Data {
        guard let signature else { throw ReleaseManifestError.missingSignature }
        guard signature.algorithm == Self.signatureAlgorithm else {
            throw ReleaseManifestError.unsupportedAlgorithm(signature.algorithm)
        }
        guard let bytes = Base64URL.decode(signature.value), bytes.count == 64 else {
            throw ReleaseManifestError.malformedSignature
        }
        return bytes
    }

    /// Require an artifact name unless the manifest contains exactly one choice.
    public func artifact(named name: String?) throws -> ReleaseArtifact {
        if let name {
            guard let match = artifacts.first(where: { $0.name == name }) else {
                throw ReleaseManifestError.artifactNotFound(name)
            }
            return match
        }
        guard artifacts.count == 1 else {
            throw ReleaseManifestError.ambiguousArtifact(artifacts.count)
        }
        return artifacts[0]
    }

    /// `^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$`, spelled out.
    static func isReleaseVersion(_ version: String) -> Bool {
        let core: Substring
        let suffix: Substring?
        if let index = version.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            core = version[version.startIndex..<index]
            suffix = version[version.index(after: index)...]
        } else {
            core = version[...]
            suffix = nil
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        guard
            parts.allSatisfy({
                !$0.isEmpty && $0.allSatisfy(\.isNumber) && $0.allSatisfy(\.isASCII)
            })
        else { return false }
        guard let suffix else { return true }
        return !suffix.isEmpty
            && suffix.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
            }
    }

}

extension ReleaseArtifact {
    init(json: JSONValue) throws {
        guard let members = json.objectValue else {
            throw ReleaseManifestError.invalidArtifact(name: "?", reason: "not an object")
        }
        let known: Set<String> = ["name", "architecture", "url", "size", "sha256", "signature_url"]
        for key in members.keys where !known.contains(key) {
            throw ReleaseManifestError.unexpectedField("artifacts[].\(key)")
        }

        let name = members["name"]?.stringValue ?? ""
        func invalid(_ reason: String) -> ReleaseManifestError {
            .invalidArtifact(name: name, reason: reason)
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw invalid("name is empty")
        }
        guard members["architecture"]?.stringValue == ReleaseManifest.architecture else {
            throw invalid("architecture is not \(ReleaseManifest.architecture)")
        }
        guard let size = members["size"]?.integerValue, size > 0 else {
            throw invalid("size is missing or zero")
        }
        guard let sha256 = members["sha256"]?.stringValue, isSHA256Hex(sha256) else {
            throw invalid("sha256 is not 64 lowercase hex characters")
        }
        // Require authenticated release transport in addition to digest verification.
        guard let rawURL = members["url"]?.stringValue,
            let url = URL(string: rawURL),
            url.scheme?.lowercased() == "https"
        else {
            throw invalid("url is missing or not https")
        }
        guard let rawSignatureURL = members["signature_url"]?.stringValue,
            let signatureURL = URL(string: rawSignatureURL),
            signatureURL.scheme?.lowercased() == "https"
        else {
            throw invalid("signature_url is missing or not https")
        }

        self.init(
            name: name,
            architecture: ReleaseManifest.architecture,
            url: url,
            size: size,
            sha256: sha256,
            signatureURL: signatureURL
        )
    }
}

extension ManifestSignature {
    init(json: JSONValue) throws {
        guard let members = json.objectValue else {
            throw ReleaseManifestError.missingSignature
        }
        guard let keyID = members["key_id"]?.stringValue,
            !keyID.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw ReleaseManifestError.missingField("signature.key_id")
        }
        guard let algorithm = members["algorithm"]?.stringValue else {
            throw ReleaseManifestError.missingField("signature.algorithm")
        }
        // Reject unsupported signature algorithms instead of bypassing verification.
        guard algorithm == ReleaseManifest.signatureAlgorithm else {
            throw ReleaseManifestError.unsupportedAlgorithm(algorithm)
        }
        guard let value = members["value"]?.stringValue,
            let decoded = Base64URL.decode(value),
            decoded.count == 64
        else {
            throw ReleaseManifestError.malformedSignature
        }
        self.init(keyID: keyID, algorithm: algorithm, value: value)
    }
}

func isSHA256Hex(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains($0) }
}
