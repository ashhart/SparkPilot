import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

@Test func recoveryCandidateUsesOnlyCurrentInstalledSignedSafeEvidence() async throws {
    let clusterID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let resolver = SignedManagedClusterRecoveryCandidateResolver(
        runtimeResolver: { target in
            let compatible = target == second
            return (
                SparkAPIClient(
                    transport: ExternalClusterTestManagedRecoveryEvidenceTransport(
                        target: target,
                        clusterID: clusterID,
                        installState: compatible ? "installed" : "unverified",
                        safeProfile: compatible
                    ),
                    signer: ExternalClusterTestManagedRequestSigner()
                ),
                externalClusterTestExternalTrust(target.nodeID.rawValue.uuidString, role: .owner)
            )
        }
    )

    let candidate = try await resolver.resolve(
        spec: ManagedClusterRecoverySpec(
            launchID: UUID(uuidString: "00000000-0000-4000-8000-000000000098")!,
            clusterID: clusterID,
            recipeID: "verified-recipe",
            profileID: "safe-profile"
        ),
        targets: [first, second]
    )

    #expect(candidate?.targetID == second.id)
    #expect(candidate?.recipeRevision == "signed-r7")
}

@Test func recoveryCandidateRefusesWhenNoMemberHasCompatibleSignedEvidence() async throws {
    let clusterID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
    let targets = [
        externalClusterTestExternalTarget(1, name: "Spark One"),
        externalClusterTestExternalTarget(2, name: "Spark Two"),
    ]
    let resolver = SignedManagedClusterRecoveryCandidateResolver(
        runtimeResolver: { target in
            (
                SparkAPIClient(
                    transport: ExternalClusterTestManagedRecoveryEvidenceTransport(
                        target: target,
                        clusterID: clusterID,
                        installState: "installed",
                        safeProfile: false
                    ),
                    signer: ExternalClusterTestManagedRequestSigner()
                ),
                externalClusterTestExternalTrust(target.nodeID.rawValue.uuidString, role: .owner)
            )
        }
    )

    let candidate = try await resolver.resolve(
        spec: ManagedClusterRecoverySpec(
            launchID: UUID(uuidString: "00000000-0000-4000-8000-000000000098")!,
            clusterID: clusterID,
            recipeID: "verified-recipe",
            profileID: "safe-profile"
        ),
        targets: targets
    )

    #expect(candidate == nil)
}
