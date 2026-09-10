import SparkDesignSystem
import SparkDiscovery
import SwiftUI

/// Keep code pairing focused on installed Sparks; show SSH candidates only in existing-Spark setup.
@MainActor
struct AddSparkDiscoveryResults: View {
    let model: RetailOnboardingModel

    private var groups: AddSparkResultGroups {
        AddSparkResultGroups.resolve(
            nodes: model.localDiscovery.nodes,
            bootstrap: model.bootstrapDiscovery.candidates
        )
    }

    var showsSetupCandidates = false

    var body: some View {
        let groups = groups
        if showsSetupCandidates {
            ForEach(groups.possibleSparks) { bootstrapRow($0) }
            if !groups.otherDevices.isEmpty {
                DisclosureGroup(String(localized: "Other nearby devices")) {
                    Text("Only choose a device if you know it is your Spark.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(groups.otherDevices) { bootstrapRow($0) }
                }
            }
        } else {
            switch AddSparkDiscoveryState.resolve(
                permission: model.localDiscovery.permissionState,
                nodeCount: groups.runtime.count + groups.clusters.count
            ) {
            case .permissionDenied:
                LocalNetworkDeniedRow()
            case .searching:
                Label("No Sparks found yet", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            case .found:
                ForEach(groups.runtime + groups.clusters) { spark in
                    row(spark, action: String(localized: "Use pairing code")) {
                        model.chooseNearbySpark(spark)
                    }
                }
            }
        }
    }

    private func bootstrapRow(_ spark: BootstrapSpark) -> some View {
        Button {
            model.chooseBootstrapSpark(spark)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer").frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: spark.displayName).foregroundStyle(.primary)
                    Text("Check existing setup").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(
        _ spark: DiscoveredSpark,
        action: String,
        choose: @escaping () -> Void
    ) -> some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                SparkProductMark(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: spark.displayName)
                        .foregroundStyle(.primary)
                    Text(verbatim: action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
