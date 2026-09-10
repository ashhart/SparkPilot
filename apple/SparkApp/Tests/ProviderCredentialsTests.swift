import Foundation
import SparkAPI
import SparkSecurity
import Testing
@testable import SparkAppComposition

private final class ProviderCredentialPresenceSession: UserPresenceProofSigning,
    @unchecked Sendable
{
    let keyInfo = UserPresenceKeyInfo(publicKeySPKI: Data([1]), protection: .softwareTestOnly)

    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
        throw UserPresenceProofError.signingFailed
    }
}

private actor ProviderCredentialPresenceAuthorizer: UserPresenceAuthorizing {
    private var calls = 0

    func keyInfo() async throws -> UserPresenceKeyInfo {
        UserPresenceKeyInfo(publicKeySPKI: Data([1]), protection: .softwareTestOnly)
    }

    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
        calls += 1
        return ProviderCredentialPresenceSession()
    }

    func count() -> Int { calls }
}

private actor ProviderCredentialRuntime: ProviderCredentialManaging {
    var items: [GeneratedAPI.ProviderCredential]
    var failure: APIError?
    private(set) var listCalls = 0
    private(set) var addRequests: [GeneratedAPI.AddProviderCredentialRequest] = []
    private(set) var revokedIDs: [String] = []

    init(items: [GeneratedAPI.ProviderCredential] = [], failure: APIError? = nil) {
        self.items = items
        self.failure = failure
    }

    func providerCredentials(route: URL) async throws -> [GeneratedAPI.ProviderCredential] {
        listCalls += 1
        return items
    }

    func addProviderCredential(
        route: URL,
        request: GeneratedAPI.AddProviderCredentialRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.ProviderCredential {
        addRequests.append(request)
        if let failure { throw failure }
        let item = GeneratedAPI.ProviderCredential(
            id: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
            provider: request.provider,
            displayName: request.displayName,
            createdAt: "2026-08-31T12:00:00Z"
        )
        items.append(item)
        return item
    }

    func revokeProviderCredential(
        route: URL,
        credentialID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws {
        revokedIDs.append(credentialID)
        items.removeAll { $0.id == credentialID }
    }

    func counts() -> (Int, Int, Int) {
        (listCalls, addRequests.count, revokedIDs.count)
    }

    func replaceItems(_ replacement: [GeneratedAPI.ProviderCredential]) {
        items = replacement
    }
}

private let providerCredentialFixture = GeneratedAPI.ProviderCredential(
    id: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
    provider: "huggingface",
    displayName: "Private models",
    createdAt: "2026-08-31T12:00:00Z"
)

@MainActor
@Test func providerCredentialManagementIsHiddenFromOrdinaryRoles() async {
    let runtime = ProviderCredentialRuntime(items: [providerCredentialFixture])
    let model = ProviderCredentialModel(
        route: URL(string: "https://spark.local:7443")!,
        targetID: "spark-1",
        runtime: runtime,
        localDeviceRole: "user"
    )

    await model.load()

    #expect(!model.canManage)
    #expect(model.credentials.isEmpty)
    #expect(await runtime.counts().0 == 0)
}

@MainActor
@Test func providerCredentialAddSelectAndRevokeUseFreshPresence() async {
    let runtime = ProviderCredentialRuntime()
    let presence = ProviderCredentialPresenceAuthorizer()
    let model = ProviderCredentialModel(
        route: URL(string: "https://spark.local:7443")!,
        targetID: "spark-1",
        runtime: runtime,
        localDeviceRole: "owner",
        userPresenceAuthorizer: presence
    )

    let added = await model.addHuggingFaceCredential(
        displayName: "Private models",
        token: "hf_private_token"
    )

    #expect(added)
    #expect(model.selectedCredentialID(for: "huggingface") == providerCredentialFixture.id)
    #expect(await presence.count() == 1)
    #expect(await runtime.counts().1 == 1)

    await model.revokeCredential(providerCredentialFixture.id)
    #expect(model.credentials.isEmpty)
    #expect(model.selectedCredentialID(for: "huggingface") == nil)
    #expect(await presence.count() == 2)
    #expect(await runtime.counts().2 == 1)
}

@MainActor
@Test func providerCredentialErrorsNeverEchoTheSubmittedToken() async {
    let runtime = ProviderCredentialRuntime(
        failure: APIError(
            .local(message: "rejected hf_private_token"),
            statusCode: 422,
            code: "CREDENTIAL_INVALID"
        )
    )
    let model = ProviderCredentialModel(
        route: URL(string: "https://spark.local:7443")!,
        targetID: "spark-1",
        runtime: runtime,
        localDeviceRole: "administrator",
        userPresenceAuthorizer: ProviderCredentialPresenceAuthorizer()
    )

    let added = await model.addHuggingFaceCredential(
        displayName: "Private models",
        token: "hf_private_token"
    )

    #expect(!added)
    #expect(model.errorMessage?.contains("hf_private_token") == false)
}

@MainActor
@Test func staleOrWrongProviderSelectionsAreNeverUsed() async {
    let runtime = ProviderCredentialRuntime(items: [providerCredentialFixture])
    let model = ProviderCredentialModel(
        route: URL(string: "https://spark.local:7443")!,
        targetID: "spark-1",
        runtime: runtime,
        localDeviceRole: "owner"
    )

    await model.load()
    #expect(model.selectedCredentialID(for: "huggingface") == providerCredentialFixture.id)

    model.selectCredential(providerCredentialFixture.id, for: "other-provider")
    #expect(model.selectedCredentialID(for: "other-provider") == nil)

    await runtime.replaceItems([])
    await model.load()
    #expect(model.selectedCredentialID(for: "huggingface") == nil)
}
