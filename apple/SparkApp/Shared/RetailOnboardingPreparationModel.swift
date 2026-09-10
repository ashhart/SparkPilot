import Combine
import SparkDesignSystem

@MainActor
public final class RetailOnboardingPreparationModel: ObservableObject {
    static let pendingRuntime: [RetailPreparationItem] = [
        RetailPreparationItem(
            id: "runtime-package",
            title: String(localized: "Signed Spark Runtime"),
            detail: String(localized: "Waiting to install"),
            status: .pending
        ),
        RetailPreparationItem(
            id: "privileged-helper",
            title: String(localized: "Privileged helper"),
            detail: String(localized: "Waiting for the verified runtime"),
            status: .pending
        ),
        RetailPreparationItem(
            id: "spark-runtime",
            title: String(localized: "Spark service"),
            detail: String(localized: "Waiting to start"),
            status: .pending
        ),
        RetailPreparationItem(
            id: "local-pairing",
            title: String(localized: "Private owner pairing"),
            detail: String(localized: "Waiting for the Spark service"),
            status: .pending
        ),
    ]

    static let pendingAI: [RetailPreparationItem] = [
        RetailPreparationItem(
            id: "runtime-health",
            title: String(localized: "Spark connection"),
            detail: String(localized: "Waiting for the local health check"),
            status: .pending
        ),
        RetailPreparationItem(
            id: "vllm",
            title: String(localized: "Running models"),
            detail: String(localized: "Waiting for the runtime controls check"),
            status: .pending
        ),
        RetailPreparationItem(
            id: "catalogue",
            title: String(localized: "Models you can download"),
            detail: String(localized: "Waiting for the Spark catalogue"),
            status: .pending
        ),
        RetailPreparationItem(
            id: "open-webui",
            title: String(localized: "Open WebUI"),
            detail: String(localized: "Waiting for the verified optional-service check"),
            status: .unavailable
        ),
        RetailPreparationItem(
            id: "nemotron",
            title: "Nemotron Lightning",
            detail: String(localized: "Not in this Spark's signed model catalogue"),
            status: .unavailable
        ),
    ]

    @Published public internal(set) var runtime = pendingRuntime
    @Published public internal(set) var ai = pendingAI
    @Published public internal(set) var isInstallingRuntime = false
    @Published public internal(set) var isCheckingAIServices = false

    public internal(set) var firstModelID: String?

    public init() {}

    func reset() {
        runtime = Self.pendingRuntime
        ai = Self.pendingAI
        firstModelID = nil
        isInstallingRuntime = false
        isCheckingAIServices = false
    }
}
