import SparkCore
import SwiftUI

struct WorkloadStateBadge: View {
    let state: WorkloadDisplayState

    var body: some View {
        Label(state.label, systemImage: state.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var foregroundColor: Color {
        switch state {
        case .running: .green
        case .installed: .blue
        case .downloading, .planned: .indigo
        case .degraded: .orange
        case .blocked: .red
        case .notPresent, .unknown: .secondary
        }
    }
}

struct WorkloadTargetDetailView: View {
    let target: WorkloadTargetColumn
    let rows: [WorkloadRowPresentation]
    let selectedRowID: ModelPlacementIdentity?
    let onClose: () -> Void

    var body: some View {
        Form {
            overview
            models
            performance
            members
            identity
            updates
        }
        .formStyle(.grouped)
        .navigationTitle(target.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onClose)
                    .accessibilityLabel("Close workload details")
            }
        }
    }

    private var overview: some View {
        Section("Overview") {
            detailRow(String(localized: "Target"), target.kind.label)
            detailRow(String(localized: "Connection"), target.connectionLabel)
            detailRow(String(localized: "Evidence"), target.evidenceLabel)
            detailRow(String(localized: "Runtime health"), target.runtimeHealthLabel)
            if !target.blockers.isEmpty {
                ForEach(target.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
            if !target.warnings.isEmpty {
                ForEach(target.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var models: some View {
        Section("Models") {
            ForEach(orderedRows) { row in
                if let cell = row.cell(for: target.id) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name)
                                .fontWeight(row.id == selectedRowID ? .bold : .regular)
                            Text(row.versionLabel)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(cell.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        WorkloadStateBadge(state: cell.state)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        Text(
                            .workloadRowSummary(
                                name: row.name,
                                version: row.versionLabel,
                                summary: cell.accessibilitySummary
                            )
                        )
                    )
                }
            }
        }
    }

    private var performance: some View {
        Section("Performance") {
            detailRow(String(localized: "Unified memory"), target.performance.memoryLabel)
            detailRow(String(localized: "Disk"), target.performance.diskLabel)
            detailRow(String(localized: "Active requests"), target.performance.activeRequestsLabel)
            detailRow(String(localized: "Queue depth"), target.performance.queueDepthLabel)
            detailRow(String(localized: "Throughput"), target.performance.throughputLabel)
            detailRow(String(localized: "First-token latency"), target.performance.latencyLabel)
        }
    }

    @ViewBuilder
    private var members: some View {
        Section("Members") {
            if target.members.isEmpty {
                Text("No member evidence reported")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(target.members) { member in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: member.state.symbolName)
                            .foregroundStyle(memberColor(member.state))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(member.name)
                                .fontWeight(.semibold)
                            Text(.pair(member.role, member.state.label))
                                .font(.caption)
                            Text(member.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(member.accessibilitySummary)
                }
            }
        }
    }

    private var identity: some View {
        Section("Identity") {
            detailRow(
                String(localized: "Logical identity"),
                target.technicalIdentity,
                monospaced: true
            )
            detailRow(String(localized: "Target type"), target.kind.label)
            detailRow(String(localized: "Member count"), String(target.members.count))
        }
    }

    private var updates: some View {
        Section("Updates") {
            detailRow(String(localized: "Runtime version"), target.runtimeVersion, monospaced: true)
            detailRow(String(localized: "Status"), target.updateLabel)
        }
    }

    private var orderedRows: [WorkloadRowPresentation] {
        guard let selectedRowID,
            let selected = rows.first(where: { $0.id == selectedRowID })
        else {
            return rows
        }
        return [selected] + rows.filter { $0.id != selectedRowID }
    }

    private func detailRow(
        _ label: String,
        _ value: String,
        monospaced: Bool = false
    ) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(.pair(label, value)))
    }

    private func memberColor(_ state: WorkloadMemberState) -> Color {
        switch state {
        case .ready: .green
        case .degraded: .orange
        case .unknown: .secondary
        }
    }
}
