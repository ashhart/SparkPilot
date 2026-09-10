import Foundation
import SparkSecurity

/// Carry authority key, authority fingerprint and separate TLS pin over confirmed SSH for first-owner pairing.
public struct RuntimeBootstrapResult: Sendable, Equatable {
    public let nodeID: String
    public let nodeName: String
    /// SHA-256 of the Ed25519 owner-authority public key, lowercase hex.
    public let authorityFingerprint: String
    /// The Ed25519 owner-authority public key itself, lowercase hex.
    public let authorityPublicKey: String
    /// SHA-256 of the local API's leaf certificate in DER form. The pin.
    public let tlsFingerprint: String
    public let invitationExpiresAt: String
    /// Preserve the signed invitation in the claim endpoint's expected shape.
    public let invitation: JSONValue
    /// Record whether on-Spark verification used an installed trust root or the installer-supplied key.
    public let trustRootSource: TrustRootSource

    public init(
        nodeID: String,
        nodeName: String,
        authorityFingerprint: String,
        authorityPublicKey: String,
        tlsFingerprint: String,
        invitationExpiresAt: String,
        invitation: JSONValue,
        trustRootSource: TrustRootSource
    ) {
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.authorityFingerprint = authorityFingerprint
        self.authorityPublicKey = authorityPublicKey
        self.tlsFingerprint = tlsFingerprint
        self.invitationExpiresAt = invitationExpiresAt
        self.invitation = invitation
        self.trustRootSource = trustRootSource
    }

    public enum TrustRootSource: String, Sendable, Equatable {
        /// Verify against the trust root retained from the Spark's previous installation.
        case installed
        /// On first install, Apple-side embedded trust establishes authenticity and the Spark check verifies transfer integrity.
        case supplied
    }
}

public enum RuntimeBootstrapError: Error, Sendable, Equatable {
    case manifest(ReleaseManifestError)
    case trust(ReleaseTrustError)
    case ssh(BootstrapSSHError)
    case artifactUnavailable(String)
    /// A downloaded artifact did not match the signed manifest.
    case artifactDigestMismatch(expected: String, actual: String)
    case artifactSizeMismatch(expected: Int64, actual: Int64)
    /// The detached signature was missing or did not verify. Never skipped.
    case artifactSignatureInvalid(String)
    case commandFailed(command: BootstrapCommand, exitStatus: Int32, detail: String)
    case malformedBootstrapReport(String)
    case incompatible(reason: String)
    /// Report all read-only preflight conflicts so the owner can resolve them together (§10.2).
    case preflightBlocked([PreflightConflict])
    /// Treat an unreadable survey as a blocking observation failure rather than an empty machine.
    case preflightUnavailable(String)
}

/// Allow signed staging only after manifest, digest, size and detached-signature verification.
public struct RuntimeUpdateBundle: Sendable, Equatable {
    public let releaseID: String
    public let manifest: Data
    public let package: Data
    public let detachedSignature: Data

    public init(
        releaseID: String,
        manifest: Data,
        package: Data,
        detachedSignature: Data
    ) {
        self.releaseID = releaseID
        self.manifest = manifest
        self.package = package
        self.detachedSignature = detachedSignature
    }
}

/// Separate release fetching from the mandatory signed-artifact verification performed by the installer.
public protocol ReleaseSource: Sendable {
    func manifest() async throws -> Data
    func artifact(_ artifact: ReleaseArtifact) async throws -> Data
    func detachedSignature(_ artifact: ReleaseArtifact) async throws -> Data
}

/// Progress, for the onboarding UI. Never carries a password.
public protocol BootstrapProgressReporting: Sendable {
    func bootstrapWillRun(_ command: BootstrapCommand)
}

public struct SilentBootstrapProgress: BootstrapProgressReporting {
    public init() {}
    public func bootstrapWillRun(_ command: BootstrapCommand) {}
}

public struct ClosureBootstrapProgress: BootstrapProgressReporting {
    private let handler: @Sendable (BootstrapCommand) -> Void

    public init(handler: @escaping @Sendable (BootstrapCommand) -> Void) {
        self.handler = handler
    }

    public func bootstrapWillRun(_ command: BootstrapCommand) {
        handler(command)
    }
}
