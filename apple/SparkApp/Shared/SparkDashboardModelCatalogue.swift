import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

struct SparkDashboardModelCatalogue: View {
    let model: SparkDashboardModel
    let providerCredentialModel: ProviderCredentialModel?
    let showProviderCredentials: () -> Void
    var restartSpark: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Available models")
                    .font(.title2.bold())
                SparkTooltipButton(
                    title: String(localized: "Available models"),
                    message:
                        String(
                            localized:
                                "Models are read from the Spark. Saved model details stay read-only until the Spark reconnects."
                        )
                )
                Spacer()
            }

            Text(
                "Recipes tested on a DGX Spark and signed by SparkPilot. Press Download and the model runs with the settings that were tested."
            )
            .font(.callout).foregroundStyle(.secondary)
            if model.catalogueRefreshSupported {
                HStack(spacing: 10) {
                    Image(systemName: "globe").foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(model.publishedCatalogueStatusLine)
                        .font(.caption)
                        .foregroundStyle(
                            model.publishedCatalogueIsNewer ? Color.accentColor : .secondary
                        )
                    Spacer()
                    if model.isCheckingPublishedCatalogue {
                        ProgressView().controlSize(.small)
                    } else if model.publishedCatalogueIsNewer {
                        Button("Get new recipes") {
                            Task { await model.preparePublishedCatalogueRefresh() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.isPreparingCatalogueRefresh || model.isRefreshingCatalogue)
                    }
                }
                .task { await model.checkPublishedCatalogue() }
            }

            if let error = model.profileReenableErrorMessage,
                model.pendingProfileReenable == nil
            {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if model.isRefreshing, model.models.isEmpty, model.cachedPlacements.isEmpty {
                SparkSkeletonList(
                    rowCount: 2,
                    accessibilityLabel: String(localized: "Loading available models")
                )
            } else if !model.cachedPlacements.isEmpty {
                ForEach(model.cachedPlacements) { placement in
                    cachedModelCard(placement)
                }
            } else if model.models.isEmpty {
                ContentUnavailableView(
                    "No models reported",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Refresh after the Spark Runtime is healthy.")
                )
            } else {
                ForEach(model.models) { item in
                    SparkDashboardModelCard(
                        item: item,
                        model: model,
                        providerCredentialModel: providerCredentialModel,
                        showProviderCredentials: showProviderCredentials,
                        restartSpark: restartSpark
                    )
                }
            }
        }

    }
    private func cachedModelCard(_ placement: ModelPlacementSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(placement.displayName)
                    .font(.headline)
                Text(cachedPlacementLabel(placement.state))
                    .font(.subheadline)
                Text("Saved model evidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                .placementEvidence(
                    name: placement.displayName,
                    state: cachedPlacementLabel(placement.state)
                )
            )
        )
    }
    private func cachedPlacementLabel(_ state: ModelPlacementState) -> String {
        switch state {
        case .available: String(localized: "Available")
        case .downloading: String(localized: "Downloading when last seen")
        case .installed: String(localized: "Installed")
        case .starting: String(localized: "Starting when last seen")
        case .running: String(localized: "Running when last seen")
        case .stopping: String(localized: "Stopping when last seen")
        case .failed: String(localized: "Needs attention")
        case .incompatible: String(localized: "Not compatible")
        case .unknown: String(localized: "Status unavailable")
        }
    }
}
