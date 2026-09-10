import SwiftUI
import SparkCore

/// Summarize node connection, active model, unified memory and primary actions on the home card (§41.5).
public struct SparkNodeCard: View {
    public let state: NodeCardState

    public init(state: NodeCardState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.name)
                        .font(.title2.weight(.semibold))
                    Label(
                        state.presentation.secondary,
                        systemImage: state.connectivitySymbol
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                StatusLabel(badge: state.badge, text: state.presentation.title)
            }

            if let pressure = state.pressurePresentation {
                MemoryPressureBanner(presentation: pressure)
            }

            if let model = state.activeModel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName).font(.headline)
                    Text(model.performanceSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView(
                    String(localized: "No Model Loaded"),
                    systemImage: "square.stack.3d.up",
                    description: Text("Choose a model when you are ready to start inference.")
                )
            }

            Gauge(
                value: Double(state.usedMemoryBytes),
                in: 0...Double(max(state.totalMemoryBytes, 1))
            ) {
                Text("Unified Memory")
            } currentValueLabel: {
                Text(state.formattedMemory)
            }

            HStack {
                Button("Open Chat") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canChat)
                Button("Manage") {}
                    .buttonStyle(.bordered)
            }
        }
        .padding(22)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}

/// Compact status badge with colour-independent cues (symbol + text).
public struct StatusLabel: View {
    public let badge: NodeStatusBadge
    public let text: String

    public init(badge: NodeStatusBadge, text: String) {
        self.badge = badge
        self.text = text
    }

    public var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel(text)
    }

    private var symbol: String {
        switch badge {
        case .ready: return "checkmark.circle.fill"
        case .probing: return "arrow.triangle.2.circlepath"
        case .degraded: return "exclamationmark.triangle.fill"
        case .offline: return "wifi.slash"
        case .blocked: return "lock.fill"
        case .needsUpdate: return "arrow.down.circle.fill"
        }
    }

    private var tint: Color {
        switch badge {
        case .ready: return .green
        case .probing, .degraded: return .orange
        case .offline: return .gray
        case .blocked: return .red
        case .needsUpdate: return .purple
        }
    }
}

/// Home dashboard: the node list with empty/recovery states (§41.5, §62.1).
public struct HomeDashboardView: View {
    public let cards: [NodeCardState]
    public let emptyState: DashboardEmptyState?
    public let onLookAgain: () -> Void

    public init(
        cards: [NodeCardState],
        emptyState: DashboardEmptyState?,
        onLookAgain: @escaping () -> Void = {}
    ) {
        self.cards = cards
        self.emptyState = emptyState
        self.onLookAgain = onLookAgain
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if cards.isEmpty, let emptyState {
                    ContentUnavailableView {
                        Label(emptyState.title, systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text(emptyState.message)
                    } actions: {
                        if let label = emptyState.actionLabel {
                            Button(label, action: onLookAgain)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.top, 80)
                } else {
                    ForEach(cards, id: \.nodeID.rawValue) { card in
                        SparkNodeCard(state: card)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Home")
    }
}
