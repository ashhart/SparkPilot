import SwiftUI

/// Local, dismissible guidance beside the feature it explains; no usage tracking.
struct SparkContextTip: View {
    enum Kind: String, CaseIterable {
        case launchPreset, shortcuts, warmup

        var dismissalKey: String { "spark.tip.\(rawValue).dismissed" }

        var title: String {
            switch self {
            case .launchPreset: String(localized: "Your preset is remembered")
            case .shortcuts: String(localized: "Ask with Siri")
            case .warmup: String(localized: "Get ready before you return")
            }
        }

        var message: String {
            switch self {
            case .launchPreset:
                String(
                    localized:
                        "Launch model starts it with your saved preset. Change preset only when you want different settings."
                )
            case .shortcuts:
                String(
                    localized:
                        "Try saying “Ask SparkPilot a question”. Your paired Spark must be connected and its model ready."
                )
            case .warmup:
                String(
                    localized:
                        "Schedule your model to load before you need it. Your Spark must stay powered on; it skips the warm-up if it is busy."
                )
            }
        }
    }

    private let kind: Kind
    @AppStorage private var dismissed: Bool

    init(_ kind: Kind) {
        self.kind = kind
        _dismissed = AppStorage(wrappedValue: false, kind.dismissalKey)
    }

    var body: some View {
        if !dismissed {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.title).font(.subheadline.weight(.semibold))
                Text(kind.message).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Got it") { dismissed = true }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("spark.tip.\(kind.rawValue).dismiss")
            }
        }
    }
}
