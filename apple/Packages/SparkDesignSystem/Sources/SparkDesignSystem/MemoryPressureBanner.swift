import SwiftUI

/// Pair memory-pressure guidance with symbol and text so recovery does not depend on colour (§33.5).
public struct MemoryPressureBanner: View {
    public let presentation: MemoryPressurePresentation
    private let stopModel: (() -> Void)?
    private let openModels: (() -> Void)?

    /// Handlers turn the guidance into one-tap actions; without them the banner stays advisory.
    public init(
        presentation: MemoryPressurePresentation,
        stopModel: (() -> Void)? = nil,
        openModels: (() -> Void)? = nil
    ) {
        self.presentation = presentation
        self.stopModel = stopModel
        self.openModels = openModels
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(presentation.title, systemImage: "memorychip")
                .font(.subheadline.weight(.semibold))

            Text(presentation.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !presentation.actions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(presentation.actions, id: \.self) { action in
                        Label(action.guidance, systemImage: "arrow.turn.down.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            if stopModel != nil || openModels != nil {
                HStack(spacing: 10) {
                    if let stopModel {
                        Button(String(localized: "Stop the running model"), action: stopModel)
                            .buttonStyle(.borderedProminent)
                    }
                    if let openModels {
                        Button(String(localized: "Open Models"), action: openModels)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 2)
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
