import SparkAPI
import SwiftUI

/// Shows runtime-provided categories, sensitivity and exclusions before the owner selects and exports a support bundle.
public struct DiagnosticsExportView: View {
    @Bindable private var model: DiagnosticsExportModel
    @State private var archive: DiagnosticsArchive?

    public init(model: DiagnosticsExportModel) {
        self.model = model
    }

    public var body: some View {
        List {
            if let failure = model.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(model.sections, id: \.id) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                        Text(section.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Always included")
            } footer: {
                Text("These describe the Spark itself and name no person, address or secret.")
            }

            Section {
                ForEach(model.optionalCategories, id: \.id) { category in
                    Toggle(isOn: binding(for: category.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(category.title)
                            Text(category.description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint(
                        String(
                            localized:
                                "Off by default. Adds information that identifies this installation."
                        )
                    )
                }
            } header: {
                Text("Add only if asked")
            } footer: {
                Text("Off unless you turn them on for this export.")
            }

            if !model.neverExported.isEmpty {
                Section("Never included") {
                    ForEach(model.neverExported, id: \.id) { exclusion in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(exclusion.title)
                            Text(exclusion.reason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button {
                    Task { archive = await model.export() }
                } label: {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Text("Export support bundle")
                    }
                }
                .disabled(model.isBusy || model.sections.isEmpty)

                if let archive {
                    ShareLink(item: archive.url) {
                        Label("Share support bundle", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text(
                    """
                    Exporting asks for Face ID, Touch ID, or your passcode, then saves a \
                    readable JSON file on this device. Nothing is uploaded.
                    """
                )
            }
        }
        .navigationTitle("Support bundle")
        .task { await model.load() }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.isSelected(id) },
            set: { model.setSelected(id, $0) }
        )
    }
}
