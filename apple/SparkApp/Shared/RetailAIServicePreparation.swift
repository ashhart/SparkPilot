import Foundation
import Network
import Observation
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkDesignSystem
import SparkLibrary
import SparkIntents
import SparkSecurity
import SparkTransport
@MainActor
@Observable
final class RetailAIServicePreparation {

    private let dashboard: RetailDashboardSession
    private let session: RetailSetupSession
    private let runtime: (any SparkRuntimeReading)?
    private let signerProvider: RetailOnboardingModel.SignerProvider
    init(
        dashboard: RetailDashboardSession,
        session: RetailSetupSession,
        runtime: (any SparkRuntimeReading)?,
        signerProvider: @escaping RetailOnboardingModel.SignerProvider
    ) {
        self.dashboard = dashboard
        self.session = session
        self.runtime = runtime
        self.signerProvider = signerProvider
    }
    private var state: RetailOnboardingState {
        get { session.state }
        set { session.state = newValue }
    }
    private var pairedNode: NodeTrust? {
        get { session.pairedNode }
        set { session.pairedNode = newValue }
    }
    private var pairedRouteURL: URL? {
        get { session.pairedRouteURL }
        set { session.pairedRouteURL = newValue }
    }
    private var resolvedRuntime: (any SparkRuntimeReading)? {
        get { dashboard.resolvedRuntime }
        set { dashboard.resolvedRuntime = newValue }
    }

    func checkAIServices(
        preparation: RetailOnboardingPreparationModel? = nil
    ) async {
        guard let preparation, state.phase == .starterModel,
            !preparation.isCheckingAIServices
        else { return }
        guard let route = pairedRouteURL, let trust = pairedNode else {
            preparation.ai = RetailOnboardingPreparationModel.pendingAI.map { item in
                guard item.status != .unavailable else { return item }
                return RetailPreparationItem(
                    id: item.id,
                    title: item.title,
                    detail: String(localized: "Pairing did not provide a trusted local route"),
                    status: .failed
                )
            }
            return
        }

        preparation.isCheckingAIServices = true
        preparation.ai = RetailOnboardingPreparationModel.pendingAI
        preparation.firstModelID = nil
        for id in ["runtime-health", "vllm", "catalogue", "open-webui"] {
            updateAIPreparation(
                preparation: preparation,
                id: id,
                detail: String(localized: "Checking directly on your Spark"),
                status: .working
            )
        }
        defer { preparation.isCheckingAIServices = false }

        do {
            let localRuntime: any SparkRuntimeReading
            if let runtime {
                localRuntime = runtime
            } else {
                localRuntime = try SparkAPIClient.pinned(
                    to: trust.tlsFingerprint,
                    signer: signer(forNode: trust.nodeID)
                )
            }
            resolvedRuntime = localRuntime

            async let loadedHealth = localRuntime.health(route: route)
            async let loadedInference = localRuntime.activeInference(route: route)
            async let loadedCatalogue = localRuntime.models(route: route)
            async let loadedCapabilities = try? localRuntime.capabilities(route: route)
            async let loadedOpenWebUI = try? localRuntime.openWebUIStatus(route: route)
            let result = try await (
                health: loadedHealth,
                inference: loadedInference,
                catalogue: loadedCatalogue,
                capabilities: loadedCapabilities,
                openWebUI: loadedOpenWebUI
            )

            updateAIPreparation(
                preparation: preparation,
                id: "runtime-health",
                detail: result.health.isOK
                    ? String(localized: .healthyWithVersion(result.health.runtimeVersion))
                    : String(localized: "The runtime reported that it needs attention"),
                status: result.health.isOK ? .ready : .failed
            )

            let containerRuntimeAvailable =
                result.capabilities?.isEnabled("container_runtime") == true
            let vLLMIsReady = containerRuntimeAvailable && result.inference.state != .failed
            updateAIPreparation(
                preparation: preparation,
                id: "vllm",
                detail: !containerRuntimeAvailable
                    ? String(
                        localized:
                            "Update the Spark software before running models."
                    )
                    : (vLLMIsReady
                        ? String(
                            localized:
                                "Your Spark can download and run models."
                        )
                        : String(localized: "The model service reported a failure")),
                status: !containerRuntimeAvailable
                    ? .unavailable : (vLLMIsReady ? .ready : .failed)
            )

            preparation.firstModelID = result.catalogue.items.first?.id
            let modelCount = result.catalogue.items.count
            let signedCatalogueAvailable =
                result.capabilities?.isEnabled("signed_catalogue") == true
            updateAIPreparation(
                preparation: preparation,
                id: "catalogue",
                detail: !signedCatalogueAvailable
                    ? String(localized: "This runtime does not expose a verified model catalogue")
                    : (modelCount == 1
                        ? String(localized: "1 signed model is available")
                        : String(localized: .signedModelsAvailable(modelCount))),
                status: signedCatalogueAvailable && modelCount > 0 ? .ready : .unavailable
            )

            let openWebUIAvailable =
                result.capabilities?.isEnabled("optional_service_recipes") == true
                && result.capabilities?.isEnabled("open_webui_service") == true
            let openWebUIPresentation: (detail: String, status: RetailPreparationStatus) =
                if !openWebUIAvailable {
                    (
                        String(
                            localized: "This runtime does not publish a verified Open WebUI recipe"
                        ),
                        .unavailable
                    )
                } else if let service = result.openWebUI {
                    switch service.state {
                    case .healthy:
                        (String(localized: "Installed and healthy"), .ready)
                    case .notInstalled:
                        (
                            String(localized: "Available to install from this Spark after setup"),
                            .unavailable
                        )
                    case .starting, .recovering:
                        (String(localized: "The verified service is still preparing"), .working)
                    case .stopped:
                        (
                            String(localized: "Installed but stopped; manage it after setup"),
                            .unavailable
                        )
                    case .failed:
                        (String(localized: "The installed service needs attention"), .failed)
                    }
                } else {
                    (String(localized: "The verified service status could not be checked"), .failed)
                }
            updateAIPreparation(
                preparation: preparation,
                id: "open-webui",
                detail: openWebUIPresentation.detail,
                status: openWebUIPresentation.status
            )

            if signedCatalogueAvailable
                && result.catalogue.items.contains(where: {
                    $0.id.localizedCaseInsensitiveContains("nemotron")
                        || $0.displayName.localizedCaseInsensitiveContains("nemotron")
                })
            {
                updateAIPreparation(
                    preparation: preparation,
                    id: "nemotron",
                    detail: String(localized: "Available in the signed model catalogue"),
                    status: .ready
                )
            }
        } catch {
            for id in ["runtime-health", "vllm", "catalogue"] {
                updateAIPreparation(
                    preparation: preparation,
                    id: id,
                    detail: String(localized: "The local check could not be completed"),
                    status: .failed
                )
            }
        }
    }

    func updateAIPreparation(
        preparation: RetailOnboardingPreparationModel,
        id: String,
        detail: String,
        status: RetailPreparationStatus
    ) {
        preparation.ai = preparation.ai.map { item in
            guard item.id == id else { return item }
            return RetailPreparationItem(
                id: item.id,
                title: item.title,
                detail: detail,
                status: status
            )
        }
    }

    func signer(forNode nodeID: String) throws -> any RequestSigning {
        guard let identifier = UUID(uuidString: nodeID) else {
            throw RetailSignerError.invalidNodeID
        }
        return try signerProvider(identifier)
    }
}
