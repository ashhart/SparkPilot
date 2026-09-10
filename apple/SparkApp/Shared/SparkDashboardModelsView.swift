import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

struct SparkDashboardModelsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsServices = false
    let model: SparkDashboardModel
    let library: SparkLibrary?
    let providerCredentialModel: ProviderCredentialModel?
    let showProviderCredentials: () -> Void
    /// Present when the dashboard has power controls; a mismatch recovery routes there.
    var restartSpark: (() -> Void)? = nil
    @Binding var confirmingOpenWebUIRemoval: Bool
    @Binding var confirmingOpenWebUIRepair: Bool
    @Binding var showingCatalogueImporter: Bool
    @Binding var catalogueFileError: String?

    var body: some View {
        ScrollViewReader { proxy in
            SparkDashboardPage(refresh: { await model.refresh() }) {
                SparkDashboardModelCatalogue(
                    model: model,
                    providerCredentialModel: providerCredentialModel,
                    showProviderCredentials: showProviderCredentials,
                    restartSpark: restartSpark
                )
                if let library, model.canScheduleWarmup {
                    SparkContextTip(.warmup)
                    NavigationLink {
                        SparkWarmupView(library: library, targetID: model.targetID)
                    } label: {
                        Label("Scheduled warm-up", systemImage: "clock.badge.checkmark")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(
                                .quaternary.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                    }
                }
                DisclosureGroup(String(localized: "Configure services"), isExpanded: $showsServices)
                {
                    SparkDashboardOptionalServices(
                        model: model,
                        confirmingOpenWebUIRemoval: $confirmingOpenWebUIRemoval,
                        confirmingOpenWebUIRepair: $confirmingOpenWebUIRepair,
                        showingCatalogueImporter: $showingCatalogueImporter,
                        catalogueFileError: $catalogueFileError
                    )
                }
                SparkDashboardOperationRecovery(
                    model: model,
                    providerCredentialModel: providerCredentialModel,
                    restartSpark: restartSpark
                )
                SparkDashboardWorkloads(
                    inventory: model.workloadInventory,
                    errorMessage: model.workloadErrorMessage,
                    installedModels: model.models.filter { $0.installState == .installed },
                    ownership: model.workloadOwnership
                )

            }
            .task(id: model.requestedModelID) {
                guard let modelID = model.requestedModelID else { return }
                await Task.yield()
                scrollToModel(modelID, proxy: proxy)
            }
            .task(id: model.requestedServiceID) {
                guard model.requestedServiceID == "open-webui" else { return }
                showsServices = true
                await Task.yield()
                proxy.scrollTo("service-open-webui", anchor: .top)
                model.clearRequestedServiceFocus()
            }
        }
        .navigationTitle("Models and services")
    }
    private func scrollToModel(_ modelID: String, proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(modelRowID(modelID), anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(modelRowID(modelID), anchor: .center)
            }
        }
        model.clearRequestedModelFocus()
    }
    private func modelRowID(_ modelID: String) -> String {
        "model-\(modelID)"
    }
}
