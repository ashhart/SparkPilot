import SparkBootstrap
import SparkDesignSystem
import SwiftUI

/// Shows install changes for a clear preflight or conflict recovery without a force-install action.
struct ExistingSparkPreflightView: View {
    let report: ExistingSparkPreflightPresentation
    let sparkName: String
    let isChecking: Bool
    let onContinue: () -> Void
    let onCheckAgain: () -> Void
    let onCancel: () -> Void

    var body: some View {
        List {
            if !report.conflicts.isEmpty {
                Section {
                    ForEach(report.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(conflict.summary)
                                .font(.subheadline.weight(.semibold))
                            Text(conflict.recovery)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            Text(.conflictAndRecovery(conflict.summary, conflict.recovery))
                        )
                    }
                } header: {
                    Label("Not safe to install yet", systemImage: "exclamationmark.triangle.fill")
                } footer: {
                    Text(
                        .nothingChangedOn(sparkName)
                    )
                }
            }

            if report.checkFailed {
                Section {
                    Text(
                        .didNotAnswerCheck(sparkName)
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } header: {
                    Label("Could not check this Spark", systemImage: "questionmark.circle")
                }
            }

            if !report.found.isEmpty {
                Section("Already on this Spark") {
                    ForEach(report.found, id: \.self) { fact in
                        Text(fact)
                    }
                }
            }

            if !report.notEstablished.isEmpty {
                Section {
                    ForEach(report.notEstablished, id: \.self) { gap in
                        Text(gap)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Could not be checked")
                } footer: {
                    // Explicitly label unavailable inventory so missing evidence does not imply an empty Spark.
                    Text(
                        String(
                            localized:
                                "This account could not read these. They are unknown, not empty."
                        )
                    )
                }
            }

            Section {
                ForEach(report.willAdd, id: \.self) { addition in
                    Label(addition, systemImage: "plus.circle")
                        .labelStyle(.titleAndIcon)
                }
            } header: {
                Text("What installing adds")
            } footer: {
                if let assurance = report.workloadAssurance {
                    Text(assurance)
                }
            }
        }
        .navigationTitle(Text(.checkResource(sparkName)))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                if let title = report.continueTitle {
                    Button(title, action: onContinue)
                        .disabled(isChecking)
                } else {
                    Button("Check Again", action: onCheckAgain)
                        .disabled(isChecking)
                }
            }
        }
    }
}
