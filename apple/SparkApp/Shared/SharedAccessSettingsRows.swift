import Foundation
import SparkAPI
import SwiftUI

/// The Shared access rows in the opened Spark's settings: the owner's screen, or a guest's own record.
struct SharedAccessSettingsRows: View {
    let model: RetailOnboardingModel

    var body: some View {
        if let shared = model.sharedAccessModel, let trust = model.dashboardTrust {
            NavigationLink {
                SharedAccessRootView(
                    model: shared,
                    trust: trust,
                    availableModels: model.dashboardModel?.models.map(\.id) ?? []
                )
            } label: {
                Label("Shared access", systemImage: "person.2.badge.key")
            }
            .accessibilityIdentifier("settings.shared.access")
        }
        if let guest = model.guestExperienceModel, model.sharedAccessModel == nil {
            NavigationLink {
                GuestAccessView(
                    model: guest,
                    nodeName: model.identitySettingsModel?.displayName
                        ?? String(localized: "this Spark")
                )
            } label: {
                Label("Your access", systemImage: "person.crop.circle.badge.checkmark")
            }
            .accessibilityIdentifier("settings.guest.access")
        }
    }
}
