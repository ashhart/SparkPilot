import Foundation
import SparkCore
import SparkLibrary
import SwiftUI

extension FleetPresentationBuilder {
    /// The connection row plus the path in use, so a card says "Over Tailscale" and names the host it is reached by.
    static func connectionPresentation(
        state: TargetConnectionState,
        isChecking: Bool,
        route: PreferredRouteSummary?
    ) -> FleetConnectionPresentation {
        let base = connectionPresentation(state: state, isChecking: isChecking)
        let connected: Set<TargetConnectionState> = [
            .connectedWiFi, .connectedDirect, .connectedRemote, .delayed,
        ]
        guard connected.contains(state), let route else { return base }
        let path = SparkConnectionPath.resolve(kind: route.kind, host: route.host)
        return FleetConnectionPresentation(
            label: base.label,
            symbol: base.symbol,
            tone: base.tone,
            isChecking: base.isChecking,
            pathLabel: path.label,
            pathHost: path.host,
            pathSymbol: path.symbol,
            pathAccessibilityLabel: path.accessibilityLabel
        )
    }
}

/// The path row under a fleet card's connection state.
struct FleetConnectionPathRow: View {
    let connection: FleetConnectionPresentation

    var body: some View {
        if let pathLabel = connection.pathLabel {
            HStack(spacing: 6) {
                Image(systemName: connection.pathSymbol)
                    .accessibilityHidden(true)
                Text(pathLabel)
                if let host = connection.pathHost {
                    Text(host)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(connection.pathAccessibilityLabel ?? pathLabel)
        }
    }
}
