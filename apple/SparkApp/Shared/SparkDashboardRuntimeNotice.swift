import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

struct SparkDashboardRuntimeNotice: View {
    let notice: SparkDashboardOwnerPresentation.RuntimeUpdateNotice
    let settingsModel: SparkSettingsModel

    var body: some View {
        NavigationLink {
            SparkSettingsView(model: settingsModel, group: .updates)
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .frame(width: 40, height: 40)
                        .background(.orange.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(notice.title)
                            .font(.headline)
                        Text(notice.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Text(notice.actionTitle)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.orange.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Runtime update required. Update Spark")
        .accessibilityHint("Opens the signed runtime update controls for this Spark.")
        .accessibilityIdentifier("spark.dashboard.runtime-update")

    }
}
