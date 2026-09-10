import SparkDesignSystem
import SwiftUI

/// The pill that stands in for a keyboard while the car moves: a symbol, one line, one voice button.
struct SparkDrivingTypingNotice: View {
    let restriction: SparkTypingRestriction
    var startVoice: (() -> Void)?

    var body: some View {
        switch restriction {
        case .none:
            EmptyView()
        case .parkedHint:
            Label(SparkDrivingCopy.parkedTitle, systemImage: "parkingsign.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SparkSpacing.regular)
                .accessibilityIdentifier("spark.driving.parked")
        case .paused:
            HStack(spacing: SparkSpacing.compact) {
                Image(systemName: "car.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: SparkSpacing.tiny) {
                    Text(SparkDrivingCopy.movingTitle).font(.body.weight(.semibold))
                    Text(SparkDrivingCopy.movingDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let startVoice {
                    Button(action: startVoice) {
                        Image(systemName: "waveform")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .frame(width: 38, height: 38)
                            .background(Color.white, in: Circle())
                            .frame(
                                width: SparkLayout.minimumTouchTarget,
                                height: SparkLayout.minimumTouchTarget
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Talk to your Spark")
                }
            }
            .padding(SparkSpacing.compact)
            .frame(minHeight: SparkLayout.minimumTouchTarget)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("spark.driving.paused")
        }
    }
}

/// Read the car's decision from the bridge, so a view never asks the reducer directly.
struct SparkTypingRestrictionKey: EnvironmentKey {
    static let defaultValue: SparkTypingRestriction = .none
}

extension EnvironmentValues {
    var sparkTypingRestriction: SparkTypingRestriction {
        get { self[SparkTypingRestrictionKey.self] }
        set { self[SparkTypingRestrictionKey.self] = newValue }
    }
}

/// Publish the live restriction into the environment beneath one view.
public struct SparkDrivingEnvironment: ViewModifier {
    @State private var bridge = SparkCarPlayBridge.shared

    public init() {}

    public func body(content: Content) -> some View {
        content.environment(\.sparkTypingRestriction, bridge.typingRestriction)
    }
}

extension View {
    public func sparkDrivingEnvironment() -> some View { modifier(SparkDrivingEnvironment()) }
}
