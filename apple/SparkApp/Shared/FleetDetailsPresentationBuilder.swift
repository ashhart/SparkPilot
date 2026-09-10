import SparkDesignSystem
import Foundation
import Observation
import SparkCore
import SparkLibrary

extension FleetPresentationBuilder {
    // MARK: Details

    /// Keep detailed identities, routes and notice codes in the inspector.
    public static func details(for target: FleetTargetInput) -> FleetDetailsPresentation {
        let snapshot = target.snapshot
        var sections: [FleetDetailSection] = []

        sections.append(
            FleetDetailSection(
                id: "overview",
                title: String(localized: "Overview"),
                rows: [
                    FleetDetailRow(
                        id: "connection",
                        label: String(localized: "Connection"),
                        value: connectionPresentation(
                            state: snapshot.connectionState,
                            isChecking: false
                        ).label
                    ),
                    FleetDetailRow(
                        id: "lastContact",
                        label: String(localized: "Last contact"),
                        value: lastContact(snapshot)
                    ),
                    FleetDetailRow(
                        id: "runtimeVersion",
                        label: String(localized: "Spark Runtime"),
                        value: snapshot.runtime.version ?? FleetFormat.unknown
                    ),
                    FleetDetailRow(
                        id: "updateState",
                        label: String(localized: "Update state"),
                        value: updateStateLabel(snapshot.runtime.updateState)
                    ),
                    FleetDetailRow(
                        id: "memory",
                        label: String(localized: "Unified memory"),
                        value: availableMemory(snapshot)
                    ),
                    FleetDetailRow(
                        id: "disk",
                        label: String(localized: "Free storage"),
                        value: snapshot.disk.map { FleetFormat.gigabytes($0.freeBytes) }
                            ?? FleetFormat.unknown
                    ),
                    FleetDetailRow(
                        id: "installed",
                        label: String(localized: "Installed models"),
                        value: installedModels(snapshot)
                    ),
                    FleetDetailRow(
                        id: "activeModel",
                        label: String(localized: "Active model"),
                        value: activeModel(snapshot)
                    ),
                ]
            )
        )

        let memberRows = snapshot.members.map { member in
            FleetDetailRow(
                id: member.nodeID.rawValue.uuidString.lowercased(),
                label: member.displayName,
                value: String(
                    localized: .memberRoleReachabilityNode(
                        role: memberRoleLabel(member.role),
                        reachability: member.reachable
                            ? String(localized: "Reachable")
                            : String(localized: "Not reachable"),
                        node: member.nodeID.rawValue.uuidString.lowercased()
                    )
                )
            )
        }
        if !memberRows.isEmpty {
            sections.append(
                FleetDetailSection(
                    id: "members",
                    title: String(localized: "Members"),
                    rows: memberRows
                )
            )
        }

        let noticeRows =
            snapshot.blockers.map {
                FleetDetailRow(id: "blocker.\($0.code)", label: $0.message, value: $0.code)
            }
            + snapshot.warnings.map {
                FleetDetailRow(id: "warning.\($0.code)", label: $0.message, value: $0.code)
            }
        if !noticeRows.isEmpty {
            sections.append(
                FleetDetailSection(
                    id: "attention",
                    title: String(localized: "Needs attention"),
                    rows: noticeRows
                )
            )
        }

        let operationRows = snapshot.operations.map { operation in
            FleetDetailRow(
                id: operation.id.rawValue.uuidString.lowercased(),
                label: OperationPresentation.title(kind: operation.kind),
                value: [
                    OperationPresentation.stateLabel(operation.state),
                    operation.stage.map(OperationPresentation.stageLabel),
                    operation.progress.map {
                        $0.formatted(.percent.precision(.fractionLength(0)))
                    },
                    operation.errorCode.map(OperationPresentation.failureText),
                ]
                .compactMap { $0 }
                .joined(separator: " · ")
            )
        }
        if !operationRows.isEmpty {
            sections.append(
                FleetDetailSection(
                    id: "operations",
                    title: String(localized: "Operations"),
                    rows: operationRows
                )
            )
        }

        var identityRows = [
            FleetDetailRow(
                id: "logicalIdentity",
                label: String(localized: "Logical identity"),
                value: snapshot.technicalDetails.logicalIdentity
            )
        ]
        if let route = snapshot.preferredRoute {
            identityRows.append(
                FleetDetailRow(
                    id: "route",
                    label: String(localized: "Preferred route"),
                    value: routeLabel(route)
                )
            )
        }
        sections.append(
            FleetDetailSection(
                id: "identity",
                title: String(localized: "Identity and routes"),
                rows: identityRows
            )
        )

        return FleetDetailsPresentation(
            id: target.id,
            title: snapshot.displayName,
            sections: sections
        )
    }

    static func updateStateLabel(_ state: SparkRuntimeUpdateState) -> String {
        switch state {
        case .current: String(localized: "Up to date")
        case .available: String(localized: "Update available")
        case .required: String(localized: "Update required")
        case .unknown: FleetFormat.unknown
        }
    }

    static func routeLabel(_ route: PreferredRouteSummary) -> String {
        var parts = [transportLabel(route.kind)]
        if let host = route.host {
            parts.append(route.port.map { "\(host):\($0)" } ?? host)
        }
        if let interfaceName = route.interfaceName { parts.append(interfaceName) }
        return parts.joined(separator: " · ")
    }

    static func transportLabel(_ kind: SparkTransportKind) -> String {
        switch kind {
        case .directEthernet: String(localized: "Direct connection")
        case .localWiFi: String(localized: "Local Wi-Fi")
        case .privateOverlay: String(localized: "Private overlay")
        }
    }
}
