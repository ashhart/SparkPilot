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
@MainActor
@Observable
final class SparkDashboardOpenWebUI {
    var openWebUIService: GeneratedAPI.OptionalServiceStatus?
    var openWebUIErrorMessage: String?
    var openWebUIAccessPath: String?
    var isChangingOpenWebUI = false
    var openWebUIOperation: SparkAPI.Operation?
    var openWebUIActionLabel: String?
    var openWebUIPort = "18080"
    var adoptExistingOpenWebUI = false
    var openWebUIAdminEmail = ""
    var openWebUIAdminName = ""
    var openWebUIAdminPassword = ""
    var revealsOpenWebUIAdminPassword = false
    var acceptedOpenWebUIRecipeRevision: String?
    private let route: URL
    private let runtime: any SparkRuntimeReading
    private let targetID: String
    private let snapshot: SparkDashboardSnapshot
    private let authority: SparkDashboardPresenceAuthority
    private let tlsFingerprint: String?
    private let operationDelay: @Sendable (Duration) async throws -> Void
    var refresh: () async -> Void = {}
    init(
        route: URL,
        targetID: String,
        runtime: any SparkRuntimeReading,
        snapshot: SparkDashboardSnapshot,
        authority: SparkDashboardPresenceAuthority,
        tlsFingerprint: String?,
        operationDelay: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.route = route
        self.targetID = targetID
        self.runtime = runtime
        self.snapshot = snapshot
        self.authority = authority
        self.tlsFingerprint = tlsFingerprint
        self.operationDelay = operationDelay
    }
    private var capabilities: SparkCapabilities? { snapshot.capabilities }
    private var capabilitiesChecked: Bool { snapshot.capabilitiesChecked }
    private var identityIssue: SparkDashboardIdentityIssue? { snapshot.identityIssue }

    func postManagedServiceObservation(_ service: GeneratedAPI.OptionalServiceStatus?) {
        let state: SparkManagedServiceObservation.State
        if identityIssue != nil || service?.ownershipVerified != true {
            state = .unknown
        } else if service?.running == true && service?.healthy == true {
            state = .healthy
        } else if service?.running == true && service?.repairAvailable == true {
            state = .unhealthy
        } else if service?.running == true && service?.state == .starting {
            state = .starting
        } else if service?.running != true || service?.installed != true {
            state = .stopped
        } else {
            state = .unhealthy
        }
        NotificationCenter.default.post(
            name: .sparkManagedServiceObservation,
            object: SparkManagedServiceObservation(
                targetID: targetID,
                serviceID: "open-webui",
                state: state,
                observedAt: Date()
            )
        )
    }

    var openWebUIStatus: String { openWebUIStatusValue.text }

    var openWebUIStatusValue: SparkStatusValue {
        guard capabilitiesChecked else { return SparkStatusValue(String(localized: "Checking")) }
        guard openWebUISupported else {
            return SparkStatusValue(String(localized: "Unavailable"))
        }
        guard let service = openWebUIService else {
            return openWebUIErrorMessage == nil
                ? SparkStatusValue(String(localized: "Checking"))
                : SparkStatusValue(String(localized: "Check failed"), tone: .attention)
        }
        if service.updateAvailable {
            return SparkStatusValue(String(localized: "Update available"))
        }
        switch service.state {
        case .notInstalled: return SparkStatusValue(String(localized: "Not installed"))
        case .starting: return SparkStatusValue(String(localized: "Starting"))
        case .healthy: return SparkStatusValue(String(localized: "Healthy"))
        case .stopped: return SparkStatusValue(String(localized: "Stopped"))
        case .failed:
            return SparkStatusValue(String(localized: "Needs attention"), tone: .attention)
        case .recovering: return SparkStatusValue(String(localized: "Recovering"))
        }
    }

    var openWebUIDetail: String {
        guard capabilitiesChecked else {
            return String(localized: "Checking verified service support")
        }
        guard openWebUISupported
        else {
            return String(
                localized: "No verified Open WebUI installer is available on this runtime"
            )
        }
        guard let service = openWebUIService else {
            return openWebUIErrorMessage
                ?? String(localized: "Checking the verified Open WebUI service")
        }
        if service.adopted == true {
            return String(
                localized: "Your existing Open WebUI, accounts and model connections are unchanged."
            )
        }
        if service.healthy, !service.inferenceGateway.healthy {
            return String(localized: .versionGatewayNeedsAttention(service.availableVersion))
        }
        return String(
            localized: .versionAndSignedRecipe(
                version: service.availableVersion,
                revision: service.availableRevision
            )
        )
    }

    var openWebUISupported: Bool {
        capabilities?.isEnabled("optional_service_recipes") == true
            && capabilities?.isEnabled("open_webui_service") == true
    }

    var supportsOpenWebUIPorts: Bool { capabilities?.isEnabled("open_webui_ports") == true }

    var selectedOpenWebUIPort: Int? {
        guard let port = Int(openWebUIPort), (1024...65535).contains(port),
            ![7443, 7444, 18081].contains(port), !(18100...18199).contains(port),
            port != route.port, port != (route.port ?? 7443) + 1
        else { return nil }
        return port
    }

    var canInstallOpenWebUI: Bool {
        openWebUIInstallBlocker == nil
    }

    /// Explains the first unmet Open WebUI installation prerequisite in form order.
    var openWebUIInstallBlocker: String? {
        if supportsOpenWebUIPorts && selectedOpenWebUIPort == nil {
            return String(
                localized:
                    "Choose an available port between 1024 and 65535; SparkPilot's own ports are reserved."
            )
        }
        if supportsOpenWebUIPorts && adoptExistingOpenWebUI {
            guard let service = openWebUIService, !service.installed else {
                return String(localized: "Open WebUI is already connected or unavailable.")
            }
            return acceptedOpenWebUIRecipeRevision == service.availableRevision
                ? nil : String(localized: "Accept the connection review to continue.")
        }
        return SparkDashboardOwnerPresentation.openWebUIInstallBlocker(
            offered: openWebUIService != nil,
            installed: openWebUIService?.installed ?? false,
            availableRevision: openWebUIService?.availableRevision,
            email: openWebUIAdminEmail,
            name: openWebUIAdminName,
            password: openWebUIAdminPassword,
            acceptedRevision: acceptedOpenWebUIRecipeRevision
        )
    }

    func acceptOpenWebUIRecipe(_ accepted: Bool) {
        acceptedOpenWebUIRecipeRevision = accepted ? openWebUIService?.availableRevision : nil
    }

    func installOpenWebUI() async {
        guard canInstallOpenWebUI, let revision = acceptedOpenWebUIRecipeRevision else { return }
        let adopting = supportsOpenWebUIPorts && adoptExistingOpenWebUI
        let request = GeneratedAPI.InstallOpenWebUIRequest(
            adminEmail: adopting
                ? nil : SparkDashboardOwnerPresentation.openWebUIAdminEmail(openWebUIAdminEmail),
            adminName: adopting ? nil : openWebUIAdminName,
            adminPassword: adopting ? nil : openWebUIAdminPassword,
            acceptedRecipeRevision: revision,
            port: supportsOpenWebUIPorts ? selectedOpenWebUIPort : nil,
            adoptExisting: supportsOpenWebUIPorts ? adoptExistingOpenWebUI : nil
        )
        defer {
            openWebUIAdminPassword = ""
            revealsOpenWebUIAdminPassword = false
        }
        let succeeded = await performOpenWebUIMutation(
            label: adopting
                ? String(localized: "Connecting Open WebUI")
                : String(localized: "Installing Open WebUI"),
            reason: adopting
                ? String(
                    localized:
                        "Connect the existing Open WebUI without changing its data or settings."
                ) : String(localized: "Confirm installing Open WebUI on this Spark.")
        ) { presence in
            try await self.runtime.installOpenWebUI(
                route: self.route,
                request: request,
                idempotencyKey: UUID(),
                userPresence: presence
            )
        }
        if succeeded {
            openWebUIAdminEmail = ""
            openWebUIAdminName = ""
            acceptedOpenWebUIRecipeRevision = nil
        }
    }

    func updateOpenWebUI() async {
        guard openWebUIService?.installed == true else { return }
        _ = await performOpenWebUIMutation(
            label: String(localized: "Updating Open WebUI"),
            reason: String(localized: "Confirm updating Open WebUI on this Spark.")
        ) { presence in
            try await self.runtime.updateOpenWebUI(
                route: self.route,
                idempotencyKey: UUID(),
                userPresence: presence
            )
        }
    }

    var canRepairOpenWebUI: Bool {
        identityIssue == nil && !isChangingOpenWebUI
            && openWebUIService?.ownershipVerified == true
            && openWebUIService?.repairAvailable == true
    }

    func repairOpenWebUI() async {
        guard canRepairOpenWebUI else { return }
        _ = await performOpenWebUIMutation(
            label: String(localized: "Repairing Open WebUI"),
            reason: String(localized: "Confirm repairing the managed Open WebUI service.")
        ) { presence in
            try await self.runtime.repairOpenWebUI(
                route: self.route,
                idempotencyKey: UUID(),
                userPresence: presence
            )
        }
    }

    func removeOpenWebUI(eraseData: Bool) async {
        guard openWebUIService?.installed == true else { return }
        _ = await performOpenWebUIMutation(
            label: String(localized: "Removing Open WebUI"),
            reason: eraseData
                ? String(
                    localized: "Confirm removing Open WebUI and its local data from this Spark."
                )
                : String(localized: "Confirm removing Open WebUI while keeping its local data.")
        ) { presence in
            try await self.runtime.removeOpenWebUI(
                route: self.route,
                request: .init(eraseData: eraseData),
                idempotencyKey: UUID(),
                userPresence: presence
            )
        }
    }

    func requestOpenWebUIAccess() async {
        guard openWebUIService?.healthy == true else { return }
        openWebUIErrorMessage = nil
        do {
            let access = try await runtime.openWebUIAccess(
                route: route,
                idempotencyKey: UUID()
            )
            _ = try PinnedOpenWebUIRoute(baseRoute: route, accessPath: access.accessPath)
            guard tlsFingerprint != nil else {
                throw PinnedOpenWebUIRoute.Error.missingFingerprint
            }
            openWebUIAccessPath = access.accessPath
        } catch {
            openWebUIAccessPath = nil
            openWebUIErrorMessage =
                String(
                    localized:
                        "Open WebUI could not be opened through this Spark's trusted connection."
                )
        }
    }

    func dismissOpenWebUI() {
        openWebUIAccessPath = nil
    }

    private func performOpenWebUIMutation(
        label: String,
        reason: String,
        submit: @escaping (any UserPresenceProofSigning) async throws -> SparkAPI.Operation
    ) async -> Bool {
        guard !isChangingOpenWebUI else { return false }
        isChangingOpenWebUI = true
        openWebUIActionLabel = label
        openWebUIOperation = nil
        openWebUIErrorMessage = nil
        defer {
            isChangingOpenWebUI = false
            openWebUIActionLabel = nil
            openWebUIOperation = nil
        }
        do {
            var operation = try await authority.submitPresenceAuthorized(
                reason: reason,
                submit: submit
            )
            openWebUIOperation = operation
            // Bound polling so an unsettled operation cannot leave Apply disabled indefinitely.
            var pollsRemaining = 300
            while !operation.state.isTerminal {
                guard pollsRemaining > 0 else {
                    throw APIError(
                        .local(
                            message: String(
                                localized:
                                    "The Spark is still working on this. Refresh in a moment."
                            )
                        ),
                        code: "OPERATION_STILL_RUNNING"
                    )
                }
                pollsRemaining -= 1
                try await operationDelay(.seconds(1))
                operation = try await runtime.operation(route: route, id: operation.id)
                openWebUIOperation = operation
            }
            guard operation.state == .succeeded else {
                throw APIError(
                    .local(
                        message: String(
                            localized: "The Spark could not complete this Open WebUI action."
                        )
                    ),
                    code: operation.errorCode
                )
            }
            do {
                let status = try await runtime.openWebUIStatus(route: route)
                openWebUIService = status
                postManagedServiceObservation(status)
            } catch {
                openWebUIService = nil
                postManagedServiceObservation(nil)
                openWebUIErrorMessage =
                    String(
                        localized:
                            "The action finished, but Open WebUI status could not be checked."
                    )
            }
            return true
        } catch is UserPresenceAuthorizationError {
            openWebUIErrorMessage =
                String(
                    localized:
                        "Nothing changed because this Apple device could not confirm you are present."
                )
            return false
        } catch let api as APIError {
            openWebUIErrorMessage = APIError.message(for: api)
            return false
        } catch {
            openWebUIErrorMessage = String(
                localized: "The Spark could not complete this Open WebUI action."
            )
            return false
        }
    }

}
