import Foundation
import SparkSecurity

/// Run the verified bootstrap sequence with failure-path artifact cleanup and bounded administrator-credential lifetime (§11.3).
public struct RuntimeBootstrapInstaller: Sendable {
    private let trustRoot: ReleaseTrustRoot
    private let source: any ReleaseSource
    private let progress: any BootstrapProgressReporting
    private let now: @Sendable () -> Date

    public init(
        trustRoot: ReleaseTrustRoot,
        source: any ReleaseSource,
        progress: any BootstrapProgressReporting = SilentBootstrapProgress(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.trustRoot = trustRoot
        self.source = source
        self.progress = progress
        self.now = now
    }

    /// Prepare the verified bootstrap release for paired API transfer without SSH credentials.
    public func prepareUpdateBundle(
        artifactName: String? = nil,
        dgxOSVersion: String? = nil
    ) async throws -> RuntimeUpdateBundle {
        let release = try await prepareRelease(
            artifactName: artifactName,
            dgxOSVersion: dgxOSVersion
        )
        return RuntimeUpdateBundle(
            releaseID: RuntimeReleaseIdentity.releaseID(
                manifest: release.manifest,
                artifact: release.artifact
            ),
            manifest: release.manifestData,
            package: release.packageData,
            detachedSignature: release.signature
        )
    }

    /// Verify release metadata without loading package bytes when checking for an available runtime update.
    public func availableUpdateReleaseID(dgxOSVersion: String? = nil) async throws -> String {
        let manifestData = try await source.manifest()
        let verified: VerifiedReleaseManifest
        do {
            verified = try trustRoot.verify(manifest: manifestData, at: now())
        } catch let error as ReleaseTrustError {
            throw RuntimeBootstrapError.trust(error)
        }
        try checkCompatibility(manifest: verified.manifest, dgxOSVersion: dgxOSVersion)
        return RuntimeReleaseIdentity.releaseID(
            manifest: verified.manifest,
            artifact: try verified.manifest.artifact(named: nil)
        )
    }

    /// Offer a read-only report before owner approval while installation always performs its own fresh preflight.
    public func preflight(over session: any BootstrapSSHSession) async throws -> HostPreflight {
        // Supply unused validated parameters only to satisfy the shared command type; the survey itself remains constant.
        let parameters = try BootstrapCommand.Parameters(
            operationID: UUID(),
            artifactName: "unused.deb",
            sha256: String(repeating: "0", count: 64),
            size: 1
        )
        return try await survey(over: session, parameters: parameters)
    }

    private func survey(
        over session: any BootstrapSSHSession,
        parameters: BootstrapCommand.Parameters
    ) async throws -> HostPreflight {
        let result: CommandResult
        do {
            result = try await run(.surveyHost, parameters, over: session, stdin: nil)
        } catch let error as RuntimeBootstrapError {
            // Report survey execution failure separately from an empty host inventory.
            if case .commandFailed = error {
                throw RuntimeBootstrapError.preflightUnavailable(
                    String(localized: "this Spark could not be checked before installing")
                )
            }
            throw error
        }
        let preflight = HostPreflight(survey: HostSurvey.parse(result.outputText))
        guard preflight.survey.isWellFormed else {
            throw RuntimeBootstrapError.preflightUnavailable(
                String(
                    localized:
                        "this Spark did not answer the check this app makes before installing"
                )
            )
        }
        return preflight
    }

    /// Use the already host-confirmed SSH session and send the unstored sudo credential only on command stdin.
    public func install(
        over session: any BootstrapSSHSession,
        administratorPassword: String,
        operationID: UUID = UUID(),
        artifactName: String? = nil,
        dgxOSVersion: String? = nil
    ) async throws -> RuntimeBootstrapResult {
        guard
            let result = try await applyRelease(
                over: session,
                administratorPassword: administratorPassword,
                operationID: operationID,
                artifactName: artifactName,
                dgxOSVersion: dgxOSVersion,
                bootstrapOwner: true
            )
        else {
            throw RuntimeBootstrapError.malformedBootstrapReport(
                "the Spark did not return its first-owner pairing record"
            )
        }
        return result
    }

    /// Repair owned Sparks with the same signed installation sequence while omitting first-owner invitation creation.
    public func upgrade(
        over session: any BootstrapSSHSession,
        administratorPassword: String,
        operationID: UUID = UUID(),
        artifactName: String? = nil,
        dgxOSVersion: String? = nil
    ) async throws {
        _ = try await applyRelease(
            over: session,
            administratorPassword: administratorPassword,
            operationID: operationID,
            artifactName: artifactName,
            dgxOSVersion: dgxOSVersion,
            bootstrapOwner: false
        )
    }

    private func applyRelease(
        over session: any BootstrapSSHSession,
        administratorPassword: String,
        operationID: UUID,
        artifactName: String?,
        dgxOSVersion: String?,
        bootstrapOwner: Bool
    ) async throws -> RuntimeBootstrapResult? {
        let release = try await prepareRelease(
            artifactName: artifactName,
            dgxOSVersion: dgxOSVersion
        )

        let parameters = try BootstrapCommand.Parameters(
            operationID: operationID,
            artifactName: release.artifact.name,
            sha256: release.artifact.sha256,
            size: release.artifact.size
        )

        // Run preflight inside applyRelease so every installation caller must pass it before mutation.
        let preflight = try await survey(over: session, parameters: parameters)
        guard preflight.canInstall else {
            throw RuntimeBootstrapError.preflightBlocked(preflight.conflicts)
        }
        // 11.3.3: the survey is the only place the Spark's DGX OS is known, so it is measured here.
        if dgxOSVersion == nil {
            try checkCompatibility(
                manifest: release.manifest,
                dgxOSVersion: preflight.survey.dgxOSVersion
            )
        }

        let password = Data(administratorPassword.utf8)

        do {
            let result = try await runSequence(
                over: session,
                parameters: parameters,
                manifestData: release.manifestData,
                packageData: release.packageData,
                signature: release.signature,
                trustRoot: trustRoot,
                keyID: release.keyID,
                password: password,
                bootstrapOwner: bootstrapOwner
            )
            // Clean temporary bootstrap files after successful installation.
            _ = try? await run(.cleanUp, parameters, over: session, stdin: nil)
            return result
        } catch {
            // Remove temporary package and key artifacts after installation failure.
            _ = try? await run(.cleanUp, parameters, over: session, stdin: nil)
            throw error
        }
    }

    // MARK: - The sequence

    private func runSequence(
        over session: any BootstrapSSHSession,
        parameters: BootstrapCommand.Parameters,
        manifestData: Data,
        packageData: Data,
        signature: Data,
        trustRoot: ReleaseTrustRoot,
        keyID: String,
        password: Data,
        bootstrapOwner: Bool
    ) async throws -> RuntimeBootstrapResult? {
        // Transfer artifacts into the operation's private staging directory.
        _ = try await run(.prepareWorkDirectory, parameters, over: session, stdin: nil)
        _ = try await run(.receiveFile(.package), parameters, over: session, stdin: packageData)
        _ = try await run(.receiveFile(.signature), parameters, over: session, stdin: signature)
        _ = try await run(
            .receiveFile(.publicKey),
            parameters,
            over: session,
            stdin: Data(try releasePublicKeyPEM(keyID: keyID).utf8)
        )
        _ = try await run(.receiveFile(.manifest), parameters, over: session, stdin: manifestData)

        // Verify both transferred artifact digests and detached signatures.
        _ = try await run(.verifyDigest, parameters, over: session, stdin: nil)
        _ = try await run(.verifyDetachedSignature, parameters, over: session, stdin: nil)

        let reVerification = try await run(
            .verifyAgainstInstalledTrustRoot,
            parameters,
            over: session,
            stdin: password
        )
        let trustRootSource: RuntimeBootstrapResult.TrustRootSource =
            reVerification.outputText.contains("spark-bootstrap-no-installed-trust-root")
            ? .supplied : .installed

        // Install the verified package before enabling its services.
        _ = try await run(.installPackage, parameters, over: session, stdin: password)
        // Best effort: an offline Spark keeps a fully configured runtime.
        _ = try? await run(.installRecommendedTools, parameters, over: session, stdin: password)
        _ = try await run(.enablePrivilegedHelper, parameters, over: session, stdin: password)
        _ = try await run(.enableRuntime, parameters, over: session, stdin: password)

        guard bootstrapOwner else { return nil }

        // Step 8 runs only for a fresh, unowned Spark.
        let bootstrap = try await run(.bootstrapOwner, parameters, over: session, stdin: password)
        return try decodeBootstrapReport(bootstrap.standardOutput, trustRootSource: trustRootSource)
    }

    private func run(
        _ command: BootstrapCommand,
        _ parameters: BootstrapCommand.Parameters,
        over session: any BootstrapSSHSession,
        stdin: Data?
    ) async throws -> CommandResult {
        progress.bootstrapWillRun(command)

        // Send sudo the password plus newline while file-transfer stdin contains only artifact bytes.
        var input = stdin
        if command.requiresElevation, var password = stdin {
            password.append(0x0A)
            input = password
        }

        let result: CommandResult
        do {
            result = try await session.run(command, parameters: parameters, standardInput: input)
        } catch let error as BootstrapSSHError {
            throw RuntimeBootstrapError.ssh(error)
        }

        guard result.succeeded else {
            throw RuntimeBootstrapError.commandFailed(
                command: command,
                exitStatus: result.exitStatus,
                // Trim and bound remote output before errors or logs retain it.
                detail: String(result.errorText.prefix(2000))
            )
        }
        return result
    }

    // MARK: - Local verification

    private struct PreparedRelease {
        let manifestData: Data
        let manifest: ReleaseManifest
        let artifact: ReleaseArtifact
        let packageData: Data
        let signature: Data
        let keyID: String
    }

    private func prepareRelease(
        artifactName: String?,
        dgxOSVersion: String?
    ) async throws -> PreparedRelease {
        let manifestData = try await source.manifest()
        let verified: VerifiedReleaseManifest
        do {
            verified = try trustRoot.verify(manifest: manifestData, at: now())
        } catch let error as ReleaseTrustError {
            throw RuntimeBootstrapError.trust(error)
        }
        let artifact: ReleaseArtifact
        do {
            artifact = try verified.manifest.artifact(named: artifactName)
        } catch let error as ReleaseManifestError {
            throw RuntimeBootstrapError.manifest(error)
        }
        try checkCompatibility(manifest: verified.manifest, dgxOSVersion: dgxOSVersion)

        let packageData = try await source.artifact(artifact)
        try verifyLocally(packageData, against: artifact)
        let signatureData = try await source.detachedSignature(artifact)
        guard let signature = normalisedSignature(signatureData) else {
            throw RuntimeBootstrapError.artifactSignatureInvalid(
                "the detached signature is not 64 bytes"
            )
        }
        do {
            try trustRoot.verifyDetached(
                keyID: verified.keyID,
                payload: packageData,
                signature: signature,
                at: now(),
                channel: verified.manifest.channel
            )
        } catch let error as ReleaseTrustError {
            throw RuntimeBootstrapError.trust(error)
        }
        return PreparedRelease(
            manifestData: manifestData,
            manifest: verified.manifest,
            artifact: artifact,
            packageData: packageData,
            signature: signature,
            keyID: verified.keyID
        )
    }

    private func verifyLocally(_ data: Data, against artifact: ReleaseArtifact) throws {
        guard Int64(data.count) == artifact.size else {
            throw RuntimeBootstrapError.artifactSizeMismatch(
                expected: artifact.size,
                actual: Int64(data.count)
            )
        }
        let digest = SHA256Hex.of(data)
        guard digest == artifact.sha256 else {
            throw RuntimeBootstrapError.artifactDigestMismatch(
                expected: artifact.sha256,
                actual: digest
            )
        }
    }

    /// Accept detached signatures only as 64 raw bytes or their base64url representation.
    private func normalisedSignature(_ data: Data) -> Data? {
        if data.count == 64 { return data }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Base64URL.decode(text), decoded.count == 64 else { return nil }
        return decoded
    }

    private func checkCompatibility(manifest: ReleaseManifest, dgxOSVersion: String?) throws {
        guard let dgxOSVersion, !dgxOSVersion.isEmpty else { return }
        if compareVersions(dgxOSVersion, manifest.minimumDGXOS) < 0 {
            throw RuntimeBootstrapError.incompatible(
                reason: String(
                    localized: .releaseNeedsNewerDGXOS(
                        found: dgxOSVersion,
                        minimum: manifest.minimumDGXOS
                    )
                )
            )
        }
        if let maximum = manifest.maximumDGXOS, compareVersions(dgxOSVersion, maximum) > 0 {
            throw RuntimeBootstrapError.incompatible(
                reason: String(
                    localized: .releaseSupportsOlderDGXOS(found: dgxOSVersion, maximum: maximum)
                )
            )
        }
    }

    /// Compare dotted numeric components with nonnumeric parts as zero so unreadable versions cannot appear newer.
    private func compareVersions(_ left: String, _ right: String) -> Int {
        let leftParts = left.split(separator: ".").map { Int($0) ?? 0 }
        let rightParts = right.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(leftParts.count, rightParts.count) {
            let a = index < leftParts.count ? leftParts[index] : 0
            let b = index < rightParts.count ? rightParts[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    /// Encode the release public key as PEM SubjectPublicKeyInfo for stock OpenSSL verification.
    private func releasePublicKeyPEM(keyID: String) throws -> String {
        guard let key = trustRoot.keys.first(where: { $0.keyID == keyID }),
            let raw = Data(hex: key.publicKey)
        else {
            throw RuntimeBootstrapError.trust(.unknownKeyID(keyID))
        }
        // RFC 8410 section 4: the Ed25519 SubjectPublicKeyInfo prefix.
        let prefix: [UInt8] = [
            0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00,
        ]
        let der = Data(prefix) + raw
        let base64 = der.base64EncodedString()
        var lines = ["-----BEGIN PUBLIC KEY-----"]
        var index = base64.startIndex
        while index < base64.endIndex {
            let end =
                base64.index(index, offsetBy: 64, limitedBy: base64.endIndex)
                ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        lines.append("-----END PUBLIC KEY-----")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - The Spark's answer

    private func decodeBootstrapReport(
        _ data: Data,
        trustRootSource: RuntimeBootstrapResult.TrustRootSource
    ) throws -> RuntimeBootstrapResult {
        guard let members = (try? JSONValue.parse(data))?.objectValue else {
            throw RuntimeBootstrapError.malformedBootstrapReport(
                "the Spark did not return a JSON bootstrap report"
            )
        }
        func required(_ key: String) throws -> String {
            guard let value = members[key]?.stringValue, !value.isEmpty else {
                throw RuntimeBootstrapError.malformedBootstrapReport("missing \(key)")
            }
            return value
        }

        let authorityPublicKey = try required("authority_public_key")
        let authorityFingerprint = try required("authority_fingerprint")
        let tlsFingerprint = try required("tls_fingerprint")

        // Verify the authority key matches the trusted fingerprint before sending pairing requests.
        guard let keyBytes = Data(hex: authorityPublicKey), keyBytes.count == 32 else {
            throw RuntimeBootstrapError.malformedBootstrapReport(
                "authority_public_key is not 32 hex-encoded bytes"
            )
        }
        guard SHA256Hex.of(keyBytes) == authorityFingerprint else {
            throw RuntimeBootstrapError.malformedBootstrapReport(
                "authority_public_key does not hash to authority_fingerprint"
            )
        }
        guard isSHA256Hex(tlsFingerprint) else {
            throw RuntimeBootstrapError.malformedBootstrapReport(
                "tls_fingerprint is not a SHA-256 digest"
            )
        }
        // Reject identical authority and TLS fingerprints because they represent different key material.
        guard tlsFingerprint != authorityFingerprint else {
            throw RuntimeBootstrapError.malformedBootstrapReport(
                "tls_fingerprint and authority_fingerprint are the same value"
            )
        }

        guard let invitation = members["invitation"], invitation.objectValue != nil else {
            throw RuntimeBootstrapError.malformedBootstrapReport("missing invitation")
        }

        return RuntimeBootstrapResult(
            nodeID: try required("node_id"),
            nodeName: members["node_name"]?.stringValue ?? String(localized: "Spark"),
            authorityFingerprint: authorityFingerprint,
            authorityPublicKey: authorityPublicKey,
            tlsFingerprint: tlsFingerprint,
            invitationExpiresAt: try required("expires_at"),
            invitation: invitation,
            trustRootSource: trustRootSource
        )
    }
}
