import SwiftUI
import SparkCore

/// Make model fit and incompatibility prominent without relying on colour (§41.7).
public struct ModelCardView: View {
    public let state: ModelCardState

    public init(state: ModelCardState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.displayName).font(.headline)
                    Text(state.provenance).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                stateDescription
            }

            HStack(spacing: 8) {
                ForEach(state.capabilities, id: \.self) { capability in
                    Text(capability.label)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }

            HStack {
                if let profile = state.recommendedProfile {
                    Label(.recommendedProfile(profile), systemImage: "slider.horizontal.3")
                }
                if let bytes = state.totalBytes {
                    Text(size(bytes))
                }
                Spacer()
                if let speed = state.lastMeasuredSpeed {
                    Text(speed).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var stateDescription: some View {
        Label(ModelStateCopy.title(for: state.state), systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private var symbol: String {
        switch state.state {
        case .ready, .installed: return "checkmark.circle.fill"
        case .available: return "arrow.down.circle"
        case .downloading, .verifying: return "arrow.triangle.2.circlepath"
        case .unloaded: return "moon.zzz"
        case .updateAvailable: return "arrow.down.circle.fill"
        case .incompatible, .requiresTwoSparks: return "exclamationmark.triangle.fill"
        case .unverified: return "questionmark.circle"
        case .licenceActionRequired: return "key.fill"
        case .failedWithRecovery: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch state.state {
        case .ready, .installed: return .green
        case .available: return .blue
        case .downloading, .verifying, .unloaded: return .orange
        case .updateAvailable: return .purple
        case .incompatible, .requiresTwoSparks, .failedWithRecovery: return .red
        case .unverified: return .gray
        case .licenceActionRequired: return .yellow
        }
    }

    private var accessibilitySummary: String {
        var parts = [state.displayName, state.provenance, ModelStateCopy.title(for: state.state)]
        if let profile = state.recommendedProfile {
            parts.append(String(localized: .recommendedProfileSpoken(profile)))
        }
        return parts.joined(separator: ", ")
    }

    private func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// The models library screen: rows + empty/incompatible states.
public struct ModelLibraryView: View {
    public let cards: [ModelCardState]

    public init(cards: [ModelCardState]) {
        self.cards = cards
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if cards.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Models"),
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("The catalogue is empty on this Spark.")
                    )
                    .padding(.top, 80)
                } else {
                    ForEach(cards, id: \.id) { card in
                        ModelCardView(state: card)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Models")
    }
}
