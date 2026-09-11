import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

@MainActor
@Test func candidateListIncludesOnlyOwnerPairedStandaloneSparks() {
    let library = SparkLibrary(store: MemoryLibraryStore())
    library.reconcile(externalClusterTestExternalLibraryTarget(1, name: "Spark One"))
    library.reconcile(externalClusterTestExternalLibraryTarget(2, name: "Spark Two"))
    library.reconcile(externalClusterTestExternalLibraryTarget(3, name: "Admin Spark"))
    let ownerIDs = Set([externalClusterTestExternalNode(1), externalClusterTestExternalNode(2)])

    let targets = ExternalClusterTargetList.pairedStandaloneTargets(in: library) { rawNodeID in
        guard let uuid = UUID(uuidString: rawNodeID) else { return nil }
        let nodeID = SparkNodeID(rawValue: uuid)
        return externalClusterTestExternalTrust(
            rawNodeID,
            role: ownerIDs.contains(nodeID) ? .owner : .administrator
        )
    }

    #expect(targets.map(\.displayName) == ["Spark One", "Spark Two"])
}

@Test func productionProviderReadsSignedIdentityFabricAndImportPreviewAPIs() async throws {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let targets = [first, second]
    let provider = SignedExternalClusterPreviewProvider(
        runtimeResolver: { target in
            let peer = target.id == first.id ? second : first
            return ExternalClusterRuntimeConnection(
                api: SparkAPIClient(
                    transport: ExternalClusterTestExternalAPITransport(target: target, peer: peer),
                    signer: ExternalClusterTestExternalRequestSigner()
                ),
                expectedAuthorityFingerprint: "authority"
            )
        },
        now: { ISO8601DateFormatter().date(from: "2026-08-31T09:05:00Z")! }
    )

    let evidence = try await provider.review(name: "Studio cluster", targets: targets)

    #expect(evidence.fabricByNodeID.count == 2)
    #expect(evidence.preview.configurationOwner == .externallyConfigured)
    #expect(evidence.preview.registrationAvailable == false)
}

@MainActor
@Test func completeEvidenceOffersOnlyDeviceLocalRegistration() async {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let provider = ExternalClusterTestExternalPreviewProvider(
        result: .success(
            ExternalClusterEvidence(
                preview: externalClusterTestExternalPreview(first: first, second: second),
                fabricByNodeID: [
                    first.nodeID: externalClusterTestExternalFabric(peer: second.nodeID),
                    second.nodeID: externalClusterTestExternalFabric(peer: first.nodeID),
                ],
                localRegistrationEligible: true
            )
        )
    )
    let model = ExternalClusterPreviewModel(targets: [first, second], provider: provider)
    model.toggle(first.id)
    model.toggle(second.id)
    await model.review()

    let presentation = model.presentation
    #expect(presentation?.evidenceComplete == true)
    #expect(presentation?.availableControls == [.registration])
    #expect(presentation?.memberRows.allSatisfy(\.identityAuthenticated) == true)
    #expect(presentation?.linkRows.count == 1)
    #expect(presentation?.fabricRows.count == 2)
    #expect(presentation?.fabricRows.allSatisfy { $0.speedLabel == "200 GbE" } == true)
    #expect(presentation?.preservedItems.contains("vLLM") == true)
}

@MainActor
@Test func incompleteIdentityAndReciprocalProofBecomeNamedBlockers() async {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let provider = ExternalClusterTestExternalPreviewProvider(
        result: .success(
            ExternalClusterEvidence(
                preview: externalClusterTestExternalPreview(
                    first: first,
                    second: second,
                    complete: false
                ),
                fabricByNodeID: [
                    first.nodeID: externalClusterTestExternalFabric(peer: second.nodeID),
                    second.nodeID: externalClusterTestExternalFabric(
                        peer: first.nodeID,
                        link: .carrier
                    ),
                ]
            )
        )
    )
    let model = ExternalClusterPreviewModel(targets: [first, second], provider: provider)
    model.toggle(first.id)
    model.toggle(second.id)
    await model.review()

    let presentation = model.presentation
    #expect(presentation?.evidenceComplete == false)
    #expect(
        presentation?.blockerRows.map(\.title) == [
            "Spark Two identity is not authenticated",
            "Spark Two has no reciprocal fabric proof",
        ]
    )
    #expect(presentation?.availableControls.isEmpty == true)
}

@Test func providerRejectsMixedAuthoritiesBeforeReadingClusterEvidence() async {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let provider = SignedExternalClusterPreviewProvider(
        runtimeResolver: { target in
            ExternalClusterRuntimeConnection(
                api: SparkAPIClient(
                    transport: ExternalClusterTestExternalAPITransport(
                        target: target,
                        peer: target == first ? second : first
                    ),
                    signer: ExternalClusterTestExternalRequestSigner()
                ),
                expectedAuthorityFingerprint: target == first ? "authority" : "other-authority"
            )
        }
    )

    await #expect(throws: ExternalClusterPreviewError.authorityMismatch("Spark Two")) {
        try await provider.review(name: "Unsafe", targets: [first, second])
    }
}

@Test func providerRejectsCarrierAndAddressEvidenceWithoutPerMemberPeerProof() async {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let provider = SignedExternalClusterPreviewProvider(
        runtimeResolver: { target in
            ExternalClusterRuntimeConnection(
                api: SparkAPIClient(
                    transport: ExternalClusterTestExternalAPITransport(
                        target: target,
                        peer: target == first ? second : first,
                        fabricProof: .candidate
                    ),
                    signer: ExternalClusterTestExternalRequestSigner()
                ),
                expectedAuthorityFingerprint: "authority"
            )
        },
        now: { ISO8601DateFormatter().date(from: "2026-08-31T09:05:00Z")! }
    )

    await #expect(throws: ExternalClusterPreviewError.signedEvidenceMismatch) {
        try await provider.review(name: "Spoofed", targets: [first, second])
    }
}

@Test func unreachableMemberIsNamedInsteadOfBeingTreatedAsAbsent() async {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let provider = SignedExternalClusterPreviewProvider(
        runtimeResolver: { target in
            ExternalClusterRuntimeConnection(
                api: SparkAPIClient(
                    transport: ExternalClusterTestExternalAPITransport(
                        target: target,
                        peer: target == first ? second : first,
                        unreachable: target == second
                    ),
                    signer: ExternalClusterTestExternalRequestSigner()
                ),
                expectedAuthorityFingerprint: "authority"
            )
        }
    )

    await #expect(
        throws: ExternalClusterPreviewError.pairedRouteUnavailable("Spark Two")
    ) {
        try await provider.review(name: "Partial", targets: [first, second])
    }
}

@MainActor
@Test func reviewedClusterRegistersLocallyAndRemovalRestoresStandaloneCards() async throws {
    let library = SparkLibrary(store: MemoryLibraryStore())
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    for target in [first, second] {
        library.reconcile(
            AuthenticatedTarget(
                nodeID: target.nodeID,
                clusterID: nil,
                name: target.displayName,
                role: .standalone,
                authorityFingerprint: "authority",
                displayName: target.route.host ?? target.displayName,
                routes: [CachedRoute(baseURL: target.route, kind: .localWiFi)],
                reachedAt: ISO8601DateFormatter().date(from: "2026-08-31T09:05:00Z")!
            )
        )
    }
    let provider = ExternalClusterTestExternalPreviewProvider(
        result: .success(
            ExternalClusterEvidence(
                preview: externalClusterTestExternalPreview(first: first, second: second),
                fabricByNodeID: [
                    first.nodeID: externalClusterTestExternalFabric(peer: second.nodeID),
                    second.nodeID: externalClusterTestExternalFabric(peer: first.nodeID),
                ],
                authorityFingerprint: "authority",
                verifiedAt: ISO8601DateFormatter().date(from: "2026-08-31T09:05:00Z")!,
                localRegistrationEligible: true
            )
        )
    )
    let model = ExternalClusterPreviewModel(
        targets: [first, second],
        name: "Studio cluster",
        library: library,
        trustLookup: { rawNodeID in externalClusterTestExternalTrust(rawNodeID, role: .owner) },
        provider: provider
    )
    model.toggle(first.id)
    model.toggle(second.id)
    await model.review()

    #expect(model.canRegister)
    model.register()
    let cluster = try #require(library.externalClusterEntries.first)
    #expect(library.entries.count == 1)
    #expect(cluster.members.count == 2)
    #expect(
        cluster.externalClusterRegistration?.topologyIsStale(
            at: ISO8601DateFormatter().date(from: "2026-08-31T09:09:00Z")!
        ) == false
    )

    await model.refreshRegistration(cluster.id)
    #expect(model.actionMessage == "Studio cluster topology was verified again.")

    model.removeRegistration(cluster.id)
    #expect(library.externalClusterEntries.isEmpty)
    #expect(
        Set(library.entries.compactMap(\.standaloneNodeID)) == Set([first.nodeID, second.nodeID])
    )
}

@Test func externalClusterJourneyIsReachableOnPhonePadAndMac() {
    #expect(AppleNavigationPlan.sidebarSections.contains(.clusters))
    #expect(AppleNavigationPlan.phoneMoreSections.contains(.clusters))
    #if os(macOS)
        #expect(MacSidebarItem.allCases.contains(.clusters))
    #endif
}

private func externalClusterFabricPresentation(
    proof: GeneratedAPI.FabricPortStatusPeerProof = .authenticatedNode,
    owner: GeneratedAPI.FabricStatusConfigurationOwner = .externallyConfigured
) -> ExternalClusterPreviewPresentation {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    return ExternalClusterPreviewPresentation(
        evidence: ExternalClusterEvidence(
            preview: externalClusterTestExternalPreview(first: first, second: second),
            fabricByNodeID: [
                first.nodeID: externalClusterTestExternalFabric(
                    peer: second.nodeID,
                    proof: proof,
                    owner: owner
                )
            ],
            localRegistrationEligible: true
        ),
        targets: [first, second]
    )
}

@MainActor
@Test func aCarrierWithoutAnAuthenticatedPeerSaysCheckingTheOtherEnd() {
    let presentation = externalClusterFabricPresentation(proof: .candidate)
    #expect(!presentation.fabricRows.isEmpty)
    #expect(presentation.fabricRows.allSatisfy { $0.peerLabel == "Checking the other end" })
}

@MainActor
@Test func theFabricRowNamesWhoOwnsTheFabric() {
    let managed = externalClusterFabricPresentation(owner: .sparkRuntimeManaged)
    #expect(managed.fabricRows.allSatisfy { $0.ownershipLabel == "Managed by SparkPilot" })
    let external = externalClusterFabricPresentation(owner: .externallyConfigured)
    #expect(
        external.fabricRows.allSatisfy { $0.ownershipLabel == "Configured outside SparkPilot" }
    )
}

// MARK: - Telling identically named Sparks apart

private func clusterSubtitleTestTarget(
    name: String,
    hostname: String?
) -> ExternalClusterTarget {
    ExternalClusterTarget(
        libraryEntryID: "\(name):\(hostname ?? "none")",
        nodeID: SparkNodeID(rawValue: UUID()),
        displayName: name,
        route: URL(string: "https://example.invalid:7443")!,
        hostname: hostname
    )
}

@Test func twoSparksSharingOneNameAreStillTellableApartByHost() {
    let first = clusterSubtitleTestTarget(name: "Spark", hostname: "spark-a8bf")
    let second = clusterSubtitleTestTarget(name: "Spark", hostname: "spark-c410")
    #expect(ExternalClusterTargetSubtitle.text(for: first) == "spark-a8bf.local")
    #expect(ExternalClusterTargetSubtitle.text(for: second) == "spark-c410.local")
    #expect(
        ExternalClusterTargetSubtitle.text(for: first)
            != ExternalClusterTargetSubtitle.text(for: second)
    )
}

@Test func anAlreadySuffixedHostIsNotSuffixedTwice() {
    let target = clusterSubtitleTestTarget(name: "Spark", hostname: "spark-a8bf.local")
    #expect(ExternalClusterTargetSubtitle.text(for: target) == "spark-a8bf.local")
}

@Test func aSparkWithNoUsefulHostKeepsTheDescriptiveSubtitle() {
    for hostname in [nil, "", "   "] as [String?] {
        let target = clusterSubtitleTestTarget(name: "Spark", hostname: hostname)
        #expect(ExternalClusterTargetSubtitle.text(for: target) == "Paired standalone Spark")
    }
}

@Test func aHostThatOnlyRepeatsTheNameIsNotShownTwice() {
    let target = clusterSubtitleTestTarget(name: "spark-a8bf", hostname: "SPARK-A8BF")
    #expect(ExternalClusterTargetSubtitle.text(for: target) == "Paired standalone Spark")
}

@Test func qualifiedHostsAndIPAddressesAreNotRewrittenAsLocalNames() {
    for hostname in ["spark.example.ts.net", "192.0.2.10", "2001:db8::1"] {
        let target = clusterSubtitleTestTarget(name: "Spark", hostname: hostname)
        #expect(ExternalClusterTargetSubtitle.text(for: target) == hostname)
    }
}
