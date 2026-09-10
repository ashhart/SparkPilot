import SparkDiscovery
#if os(iOS)
    import UIKit
#endif
import SwiftUI

/// What the Sparks Nearby section shows, so §12.2's recovery is a tested decision not a view detail.
enum AddSparkDiscoveryState: Equatable {
    case permissionDenied
    case searching
    case found

    static func resolve(
        permission: LocalNetworkPermissionState,
        nodeCount: Int
    ) -> AddSparkDiscoveryState {
        if permission == .denied { return .permissionDenied }
        return nodeCount == 0 ? .searching : .found
    }
}

/// Explain a refused local-network permission and offer the only action that fixes it (§12.2).
struct LocalNetworkDeniedRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local network access is off", systemImage: "lock")
                .font(.headline)
            Text(
                "SparkPilot finds a Spark on your own network. Allow Local Network access for SparkPilot in Settings, then come back."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            #endif
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
