import SparkAPI
import SwiftUI

/// Show an unload whose memory did not come back, with the two things the owner can do about it.
struct SparkDashboardUnloadNotice: View {
    let evidence: ActiveInferenceUnloadEvidence
    let checkAgain: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Memory was not reclaimed after unloading", systemImage: "memorychip")
                .font(.subheadline.weight(.semibold))
            Text(Self.detail(for: evidence))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Check Again", action: checkAgain)
                    .buttonStyle(.borderedProminent)
                Button("Restart from Settings", action: openSettings)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .orange.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

extension SparkDashboardUnloadNotice {
    static func detail(for evidence: ActiveInferenceUnloadEvidence) -> String {
        let free = ByteCountFormatter.string(
            fromByteCount: evidence.availableBytes,
            countStyle: .memory
        )
        let short = ByteCountFormatter.string(
            fromByteCount: evidence.shortfallBytes,
            countStyle: .memory
        )
        return String(
            localized: .unreclaimedMemory(model: evidence.modelID, short: short, free: free)
        )
    }
}
