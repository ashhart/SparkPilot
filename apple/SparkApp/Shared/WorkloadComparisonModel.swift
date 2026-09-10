import Foundation
import Observation
import SparkCore

public enum WorkloadFilter: String, CaseIterable, Sendable, Equatable, Identifiable {
    case all
    case active
    case installed
    case attention

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: String(localized: "All")
        case .active: String(localized: "Running")
        case .installed: String(localized: "Installed")
        case .attention: String(localized: "Needs attention")
        }
    }

    fileprivate func includes(_ row: WorkloadRowPresentation) -> Bool {
        switch self {
        case .all:
            true
        case .active:
            row.cells.contains { $0.state == .running }
        case .installed:
            row.cells.contains { $0.state == .installed || $0.state == .running }
        case .attention:
            row.cells.contains { $0.state.needsAttention }
        }
    }
}

@MainActor
@Observable
public final class WorkloadComparisonModel {
    public private(set) var snapshot: WorkloadComparisonSnapshot
    public var searchText = ""
    public var filter: WorkloadFilter = .all
    public private(set) var selectedRowID: ModelPlacementIdentity?
    public private(set) var selectedTargetID: SparkTargetIdentity?
    public var isDetailPresented = false

    public init(snapshot: WorkloadComparisonSnapshot) {
        self.snapshot = snapshot
    }

    public convenience init(
        operationalSnapshots: [TargetOperationalSnapshot],
        generatedAt: Date
    ) {
        self.init(
            snapshot: WorkloadComparisonBuilder.snapshot(
                from: operationalSnapshots,
                generatedAt: generatedAt
            )
        )
    }

    public var visibleRows: [WorkloadRowPresentation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.rows.filter { row in
            filter.includes(row)
                && (query.isEmpty
                    || row.name.localizedCaseInsensitiveContains(query)
                    || row.versionLabel.localizedCaseInsensitiveContains(query))
        }
    }

    public var selectedTarget: WorkloadTargetColumn? {
        guard let selectedTargetID else { return nil }
        return snapshot.targets.first { $0.id == selectedTargetID }
    }

    public var selectedRow: WorkloadRowPresentation? {
        guard let selectedRowID else { return nil }
        return snapshot.rows.first { $0.id == selectedRowID }
    }

    public func select(
        rowID: ModelPlacementIdentity?,
        targetID: SparkTargetIdentity
    ) {
        selectedRowID = rowID
        selectedTargetID = targetID
        isDetailPresented = true
    }

    public func closeDetail() {
        isDetailPresented = false
    }

    public func replaceSnapshot(_ replacement: WorkloadComparisonSnapshot) {
        snapshot = replacement
        if let selectedTargetID,
            !replacement.targets.contains(where: { $0.id == selectedTargetID })
        {
            self.selectedTargetID = nil
            selectedRowID = nil
            isDetailPresented = false
        } else if let selectedRowID,
            !replacement.rows.contains(where: { $0.id == selectedRowID })
        {
            self.selectedRowID = nil
        }
    }
}

public enum WorkloadLayoutMetrics {
    public static let rowHeaderWidth: CGFloat = 220
    public static let targetColumnWidth: CGFloat = 184
    public static let columnSpacing: CGFloat = 12
    public static let compactThreshold: CGFloat = 700

    public static func matrixWidth(targetCount: Int) -> CGFloat {
        let count = max(0, targetCount)
        guard count > 0 else { return rowHeaderWidth }
        return rowHeaderWidth + CGFloat(count) * targetColumnWidth
            + CGFloat(count) * columnSpacing
    }
}
