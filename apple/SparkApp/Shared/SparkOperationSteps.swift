import SwiftUI

public struct SparkOperationStep: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// Where an install or launch has got to, step by step: done, in progress, still to come.
struct SparkOperationSteps: View {
    let steps: [SparkOperationStep]
    let current: String?

    private var currentIndex: Int {
        guard let id = SparkDashboardOwnerPresentation.stepID(forStage: current),
            let index = steps.firstIndex(where: { $0.id == id })
        else { return current == nil ? 0 : steps.count - 1 }
        return index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(spacing: 8) {
                    Group {
                        if index < currentIndex {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if index == currentIndex {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.quaternary)
                        }
                    }
                    .frame(width: 16)
                    Text(step.label)
                        .font(.caption)
                        .foregroundStyle(index <= currentIndex ? .primary : .secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(
                    index < currentIndex
                        ? String(localized: "Done")
                        : index == currentIndex
                            ? String(localized: "In progress") : String(localized: "Not started")
                )
            }
        }
        .padding(.vertical, 2)
    }
}
