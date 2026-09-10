import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

extension SparkAPIClient {
    public func models(route base: URL) async throws -> ModelCatalogue {
        try await get(base.appendingPathComponent("api/v1/models"))
    }

    public func catalogueStatus(
        route base: URL
    ) async throws -> GeneratedAPI.CatalogueStatus {
        try await get(endpoint(base, "api", "v1", "catalogue"))
    }

    public func previewCatalogueRefresh(
        route base: URL,
        request: GeneratedAPI.CatalogueRefreshPreviewRequest,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.ModelActionPreview {
        try await post(
            endpoint(base, "api", "v1", "catalogue", "refresh", "preview"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    public func refreshCatalogue(
        route base: URL,
        request: GeneratedAPI.CatalogueRefreshRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "catalogue", "refresh"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func previewReenableModelProfile(
        route base: URL,
        modelID: String,
        profileID: String,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.ModelActionPreview {
        try await post(
            endpoint(
                base,
                "api",
                "v1",
                "models",
                modelID,
                "profiles",
                profileID,
                "re-enable",
                "preview"
            ),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey
        )
    }

    public func reenableModelProfile(
        route base: URL,
        modelID: String,
        profileID: String,
        request: GeneratedAPI.ReenableModelProfileRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(
                base,
                "api",
                "v1",
                "models",
                modelID,
                "profiles",
                profileID,
                "re-enable"
            ),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func activeInference(route base: URL) async throws -> ActiveInference {
        try await get(base.appendingPathComponent("api/v1/inference/active"))
    }

    /// Build the digest-bound confirmation for a model installation.
    public func previewInstallModel(
        route base: URL,
        modelID: String,
        request: GeneratedAPI.InstallModelPreviewRequest = .init(),
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        // Allow publisher file resolution more time than the default request budget for large repositories.
        try await post(
            endpoint(base, "api", "v1", "models", modelID, "install", "preview"),
            body: request,
            idempotencyKey: idempotencyKey,
            timeoutInterval: Self.applianceReadTimeout
        )
    }

    /// `POST /api/v1/models/{modelId}/install` using the generated contract body.
    public func installModel(
        route base: URL,
        modelID: String,
        request: GeneratedAPI.InstallModelRequest,
        idempotencyKey: UUID
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "models", modelID, "install"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    public func providerCredentials(
        route base: URL
    ) async throws -> [GeneratedAPI.ProviderCredential] {
        let response: GeneratedAPI.ProviderCredentialList = try await get(
            endpoint(base, "api", "v1", "credentials")
        )
        return response.items
    }

    public func addProviderCredential(
        route base: URL,
        request: GeneratedAPI.AddProviderCredentialRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.ProviderCredential {
        try await post(
            endpoint(base, "api", "v1", "credentials"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func revokeProviderCredential(
        route base: URL,
        credentialID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws {
        try await deleteNoContent(
            endpoint(base, "api", "v1", "credentials", credentialID),
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    /// Build the digest-bound confirmation for a load or replacement.
    public func previewLoadModel(
        route base: URL,
        request: GeneratedAPI.LoadModelPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        try await post(
            endpoint(base, "api", "v1", "inference", "load", "preview"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    /// `POST /api/v1/inference/load` using the generated contract body.
    public func loadModel(
        route base: URL,
        request: GeneratedAPI.LoadModelRequest,
        idempotencyKey: UUID
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "inference", "load"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    /// Build the digest-bound confirmation for stopping inference.
    public func previewUnloadModel(
        route base: URL,
        request: GeneratedAPI.StopModelPreviewRequest = .init(),
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        try await post(
            endpoint(base, "api", "v1", "inference", "unload", "preview"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    /// `POST /api/v1/inference/unload` using the generated contract body.
    public func unloadModel(
        route base: URL,
        request: GeneratedAPI.StopModelRequest,
        idempotencyKey: UUID
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "inference", "unload"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    /// Build the digest-bound confirmation for logical model removal.
    public func previewRemoveModel(
        route base: URL,
        modelID: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        try await post(
            endpoint(base, "api", "v1", "models", modelID, "remove", "preview"),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey
        )
    }

    /// `DELETE /api/v1/models/{modelId}`.
    public func removeModel(
        route base: URL,
        modelID: String,
        request: GeneratedAPI.RemoveModelRequest,
        idempotencyKey: UUID,
        userPresence: String? = nil
    ) async throws -> Operation {
        try await delete(
            endpoint(base, "api", "v1", "models", modelID),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }
}
