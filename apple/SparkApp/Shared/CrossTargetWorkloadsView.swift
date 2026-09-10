import SparkCore
import SwiftUI

public enum WorkloadLayoutPreference: Sendable, Equatable {
    case automatic
    case matrix
    case stacked
}

enum WorkloadLayoutPlan {
    static func usesStackedLayout(
        preference: WorkloadLayoutPreference,
        width: CGFloat,
        hasCompactHorizontalSize: Bool,
        usesAccessibilityTextSize: Bool
    ) -> Bool {
        if usesAccessibilityTextSize { return true }
        switch preference {
        case .matrix:
            return false
        case .stacked:
            return true
        case .automatic:
            return hasCompactHorizontalSize || width < WorkloadLayoutMetrics.compactThreshold
        }
    }
}

enum WorkloadActionPresentation {
    static func targetDetailsAccessibilityLabel(targetName: String) -> String {
        String(localized: .showWorkloadDetailsFor(targetName))
    }

    static func placementDetailsAccessibilityLabel(
        modelName: String,
        targetName: String,
        state: WorkloadDisplayState
    ) -> String {
        String(
            localized: .showPlacementDetails(
                model: modelName,
                target: targetName,
                state: state.label
            )
        )
    }
}

/// Render supplied workload snapshots without fetching, caching or mutating Spark state.
public struct CrossTargetWorkloadsView: View {
    @Bindable private var model: WorkloadComparisonModel
    private let layoutPreference: WorkloadLayoutPreference
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        model: WorkloadComparisonModel,
        layoutPreference: WorkloadLayoutPreference = .automatic
    ) {
        self.model = model
        self.layoutPreference = layoutPreference
    }

    public var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Divider()
                content(compact: usesCompactLayout(width: geometry.size.width))
            }
        }
        .navigationTitle("Workloads")
        .sheet(
            isPresented: Binding(
                get: { model.isDetailPresented },
                set: { if !$0 { model.closeDetail() } }
            )
        ) {
            if let target = model.selectedTarget {
                NavigationStack {
                    WorkloadTargetDetailView(
                        target: target,
                        rows: model.snapshot.rows,
                        selectedRowID: model.selectedRowID,
                        onClose: model.closeDetail
                    )
                }
                .frame(minWidth: 520, minHeight: 620)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Workloads")
                    .font(.largeTitle.bold())
                Text("Compare each signed model across your Sparks and clusters.")
                    .foregroundStyle(.secondary)
                Text(summaryLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(summaryAccessibilityLabel)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    workloadSearch
                    workloadFilter
                }
                VStack(alignment: .leading, spacing: 10) {
                    workloadSearch
                    workloadFilter
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var workloadSearch: some View {
        Label {
            TextField("Search models", text: $model.searchText)
                .textFieldStyle(.plain)
        } icon: {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var workloadFilter: some View {
        Picker("Filter workloads", selection: $model.filter) {
            ForEach(WorkloadFilter.allCases) { filter in
                Text(filter.label).tag(filter)
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private func content(compact: Bool) -> some View {
        if model.snapshot.targets.isEmpty {
            ContentUnavailableView(
                "No Sparks in your library",
                systemImage: "square.stack.3d.up.slash",
                description: Text("Add a Spark before comparing workloads.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else if model.snapshot.rows.isEmpty {
            ContentUnavailableView(
                "No workload evidence",
                systemImage: "shippingbox",
                description: Text("Your targets have not reported a signed model recipe yet.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else if model.visibleRows.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if compact {
            stackedContent
        } else {
            matrixContent
        }
    }

    private var matrixContent: some View {
        ScrollView(.vertical) {
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    matrixHeader
                    ForEach(model.visibleRows) { row in
                        matrixRow(row)
                    }
                }
                .padding(24)
                .frame(
                    width: WorkloadLayoutMetrics.matrixWidth(
                        targetCount: model.snapshot.targets.count
                    ),
                    alignment: .leading
                )
            }
        }
    }

    private var matrixHeader: some View {
        HStack(alignment: .top, spacing: WorkloadLayoutMetrics.columnSpacing) {
            Text("Model and recipe")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(
                    width: WorkloadLayoutMetrics.rowHeaderWidth,
                    alignment: .bottomLeading
                )
            ForEach(model.snapshot.targets) { target in
                Button {
                    model.select(rowID: nil, targetID: target.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(target.name, systemImage: targetSymbol(target.kind))
                            .font(.headline)
                        Text(target.kind.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(target.memberSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(target.evidenceLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(
                        width: WorkloadLayoutMetrics.targetColumnWidth,
                        alignment: .bottomLeading
                    )
                    .frame(minHeight: 104, alignment: .bottomLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    WorkloadActionPresentation.targetDetailsAccessibilityLabel(
                        targetName: target.name
                    )
                )
                .accessibilityValue(target.accessibilitySummary)
                .accessibilityHint("Opens target details.")
            }
        }
    }

    private func matrixRow(_ row: WorkloadRowPresentation) -> some View {
        HStack(alignment: .top, spacing: WorkloadLayoutMetrics.columnSpacing) {
            VStack(alignment: .leading, spacing: 5) {
                Text(row.name)
                    .font(.headline)
                Text(row.versionLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(width: WorkloadLayoutMetrics.rowHeaderWidth, alignment: .leading)
            ForEach(model.snapshot.targets) { target in
                if let cell = row.cell(for: target.id) {
                    workloadCell(cell, row: row, target: target)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func workloadCell(
        _ cell: WorkloadCellPresentation,
        row: WorkloadRowPresentation,
        target: WorkloadTargetColumn
    ) -> some View {
        Button {
            model.select(rowID: row.id, targetID: target.id)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                WorkloadStateBadge(state: cell.state)
                if cell.evidence != .current {
                    Text(cell.evidence.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(
                width: WorkloadLayoutMetrics.targetColumnWidth,
                alignment: .leading
            )
            .frame(minHeight: 76, alignment: .leading)
            .background(
                backgroundColor(cell.state),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            WorkloadActionPresentation.placementDetailsAccessibilityLabel(
                modelName: row.name,
                targetName: target.name,
                state: cell.state
            )
        )
        .accessibilityValue(cell.accessibilitySummary)
        .accessibilityHint("Opens target and member details.")
    }

    private var stackedContent: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 16) {
                ForEach(model.visibleRows) { row in
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name)
                                .font(.title3.bold())
                            Text(row.versionLabel)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.snapshot.targets) { target in
                            if let cell = row.cell(for: target.id) {
                                Button {
                                    model.select(rowID: row.id, targetID: target.id)
                                } label: {
                                    ViewThatFits(in: .horizontal) {
                                        HStack(alignment: .center, spacing: 12) {
                                            stackedTargetSummary(target)
                                            Spacer(minLength: 8)
                                            stackedPlacementState(cell)
                                        }
                                        VStack(alignment: .leading, spacing: 10) {
                                            stackedTargetSummary(target)
                                            stackedPlacementState(cell)
                                        }
                                    }
                                    .padding(12)
                                    .background(
                                        backgroundColor(cell.state),
                                        in: RoundedRectangle(cornerRadius: 12)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    WorkloadActionPresentation.placementDetailsAccessibilityLabel(
                                        modelName: row.name,
                                        targetName: target.name,
                                        state: cell.state
                                    )
                                )
                                .accessibilityValue(cell.accessibilitySummary)
                                .accessibilityHint("Opens target and member details.")
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        .quaternary.opacity(0.42),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                }
            }
            .padding(20)
        }
    }

    private func usesCompactLayout(width: CGFloat) -> Bool {
        WorkloadLayoutPlan.usesStackedLayout(
            preference: layoutPreference,
            width: width,
            hasCompactHorizontalSize: horizontalSizeClass == .compact,
            usesAccessibilityTextSize: dynamicTypeSize.isAccessibilitySize
        )
    }

    private func stackedTargetSummary(_ target: WorkloadTargetColumn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(target.name)
                .font(.subheadline.bold())
            Text(target.memberSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stackedPlacementState(_ cell: WorkloadCellPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WorkloadStateBadge(state: cell.state)
            if cell.evidence != .current {
                Text(cell.evidence.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryLabel: String {
        let models = model.snapshot.rows.count
        let targets = model.snapshot.targets.count
        return String(localized: .workloadsAcrossTargets(workloads: models, targets: targets))
    }

    private var summaryAccessibilityLabel: String {
        let attention = model.snapshot.rows.count { row in
            row.cells.contains { $0.state.needsAttention }
        }
        return String(
            localized: .workloadSummaryNeedingAttention(
                summary: summaryLabel,
                attention: attention
            )
        )
    }

    private func backgroundColor(_ state: WorkloadDisplayState) -> Color {
        switch state {
        case .running: .green.opacity(0.13)
        case .installed: .blue.opacity(0.11)
        case .downloading, .planned: .indigo.opacity(0.11)
        case .degraded: .orange.opacity(0.14)
        case .blocked: .red.opacity(0.13)
        case .notPresent, .unknown: .secondary.opacity(0.08)
        }
    }

    private func targetSymbol(_ kind: WorkloadTargetKind) -> String {
        switch kind {
        case .spark: "desktopcomputer"
        case .cluster: "square.3.layers.3d"
        }
    }
}
