import SparkLibrary
import SwiftUI

/// A presentation preference, never a substitute for the Spark's project permissions.
public enum SparkEngineeringMode {
    public static let preferenceKey = "spark.engineeringMode.enabled"
    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: preferenceKey)
    }
}

struct SparkEngineeringModeToggle: View {
    /// When known, every paired Spark is asked to ready its coding tools the moment the mode turns on.
    var library: SparkLibrary? = nil
    @AppStorage(SparkEngineeringMode.preferenceKey) private var enabled = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Engineering Mode", systemImage: "terminal")
                    .labelStyle(.titleAndIcon)
                Text("Develop on your Spark with workspaces, coding agents and terminals.")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Engineering Mode", isOn: $enabled)
                .labelsHidden()
                .accessibilityLabel("Engineering Mode")
                .accessibilityIdentifier("spark.engineeringMode.toggle")
        }
        .onChange(of: enabled) { _, isOn in
            guard isOn, let library else { return }
            Task { await SparkDevelopmentPreparer.shared.prepareAll(library: library) }
        }
    }
}

struct SparkEngineeringModeRequiredView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Engineering Mode is off", systemImage: "terminal")
        } description: {
            Text(
                "Enable Engineering Mode in Settings to open development workspaces; your saved files remain on the Spark."
            )
        }
    }
}
