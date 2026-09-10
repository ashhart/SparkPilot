import Foundation
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import IOKit.ps
#endif
import Observation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkSecurity
import SwiftUI
import UniformTypeIdentifiers
struct SparkModelMutationSubmitter {
    let route: URL
    let runtime: any SparkRuntimeReading

    func submit(
        action: ModelLifecycleAction,
        modelID: String,
        request: ModelOperationRetryRequest,
        idempotencyKey key: UUID,
        userPresence: String? = nil
    ) async throws -> SparkAPI.Operation {
        switch action {
        case .install:
            return try await self.runtime.installModel(
                route: self.route,
                modelID: modelID,
                request: GeneratedAPI.InstallModelRequest(
                    recipeRevision: request.recipeRevision,
                    providerCredentialId: request.providerCredentialID,
                    acceptedPreviewDigest: try SparkDashboardFailurePresentation.acceptedDigest(
                        request
                    )
                ),
                idempotencyKey: key
            )
        case .load:
            guard let profileID = request.profileID else {
                throw PendingRuntimeError.unconfigured
            }
            let target = SparkDashboardFailurePresentation.loadTarget(request)
            return try await self.runtime.loadModel(
                route: self.route,
                request: GeneratedAPI.LoadModelRequest(
                    modelId: modelID,
                    profileId: profileID,
                    replaceActive: request.replaceActive,
                    acceptedPreviewDigest: try SparkDashboardFailurePresentation.acceptedDigest(
                        request
                    ),
                    target: target
                ),
                idempotencyKey: key
            )
        case .unload:
            return try await self.runtime.unloadModel(
                route: self.route,
                request: GeneratedAPI.StopModelRequest(
                    force: request.force,
                    acceptedPreviewDigest: try SparkDashboardFailurePresentation.acceptedDigest(
                        request
                    )
                ),
                idempotencyKey: key
            )
        case .remove:
            return try await self.runtime.removeModel(
                route: self.route,
                modelID: modelID,
                request: GeneratedAPI.RemoveModelRequest(
                    acceptedPreviewDigest: try SparkDashboardFailurePresentation.acceptedDigest(
                        request
                    )
                ),
                idempotencyKey: key,
                userPresence: userPresence
            )
        }
    }
}
