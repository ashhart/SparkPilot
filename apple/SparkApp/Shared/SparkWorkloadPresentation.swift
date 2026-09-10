import Foundation
import SparkAPI

/// Separates managed and external workloads structurally, deriving actions only from signed capability and explicit management origin.
public enum SparkWorkloadPresentation {
    /// One observed workload, already reduced to the words the owner reads.
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        /// Use a safe fallback when the runtime's container name cannot be displayed.
        public let title: String
        /// Labels ownership on every row rather than relying on section position.
        public let ownership: String
        /// What this workload was recognised as, and its lifecycle state.
        public let detail: String
        /// Keeps accepted image references in technical details and omits values this build cannot display.
        public let imageReference: String?
        /// Show published host endpoints for service recognition.
        public let endpoints: [String]
        /// Lists aliases from the external engine's credential-free model endpoint, with an empty list meaning not established.
        public let servedModels: [String]
        /// The verified local API port, when the model-list probe succeeded.
        public let apiSummary: String?
        /// Offer workload controls only when runtime lifecycle ownership permits them.
        public let isManagedBySparkPilot: Bool
        /// Restrict external adoption to the supported exact-match engine type.
        public let canReviewAdoption: Bool
        /// Allow relinquishment only for explicit externally adopted workloads, never runtime-created containers.
        public let canRelinquish: Bool

        public var accessibilityLabel: String {
            var parts = [title, ownership, detail]
            if !endpoints.isEmpty {
                parts.append(
                    String(localized: .publishedOn(endpoints.formatted(.list(type: .and))))
                )
            }
            if !servedModels.isEmpty {
                parts.append(
                    String(localized: .servingModels(servedModels.formatted(.list(type: .and))))
                )
            }
            if let apiSummary {
                parts.append(apiSummary)
            }
            return parts.joined(separator: ". ")
        }
    }

    /// A group of rows that share an ownership meaning.
    public struct Section: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        /// Explain the lifecycle ownership rules beside each workload group.
        public let footer: String
        public let rows: [Row]
    }

    static let managedSectionID = "spark-managed"
    static let externalSectionID = "externally-managed"

    /// Group workloads by ownership and omit empty groups.
    public static func sections(
        _ inventory: GeneratedAPI.WorkloadInventory
    ) -> [Section] {
        guard inventory.available else { return [] }
        let managed = inventory.workloads.filter { $0.ownership == .sparkManaged }
        let external = inventory.workloads.filter { $0.ownership != .sparkManaged }
        var sections: [Section] = []
        if !managed.isEmpty {
            sections.append(
                Section(
                    id: managedSectionID,
                    title: String(localized: "Managed by SparkPilot"),
                    footer:
                        String(
                            localized:
                                "SparkPilot can control these from Models. Adopted workloads keep their original container and are labelled here."
                        ),
                    rows: managed.map { row($0, adoptionSupported: inventory.adoptionSupported) }
                )
            )
        }
        if !external.isEmpty {
            sections.append(
                Section(
                    id: externalSectionID,
                    title: String(localized: "Externally managed"),
                    footer: externalFooter(adoptionSupported: inventory.adoptionSupported),
                    rows: external.map {
                        row($0, adoptionSupported: inventory.adoptionSupported)
                    }
                )
            )
        }
        return sections
    }

    /// Explains why externally managed workloads are observed without SparkPilot control actions.
    static func externalFooter(adoptionSupported: Bool) -> String {
        adoptionSupported
            ? String(
                localized:
                    "SparkPilot did not start these and never sends them a start, stop, or remove command unless an administrator accepts an exact signed-recipe adoption review."
            )
            : String(
                localized:
                    "SparkPilot did not start these. It reports them and never sends them a start, stop, or remove command. Taking one over is not available in this build."
            )
    }

    /// Describe an unavailable workload read separately from an observed empty inventory.
    public static func unavailableMessage(
        _ inventory: GeneratedAPI.WorkloadInventory
    ) -> String? {
        guard !inventory.available else { return nil }
        return inventory.unavailableReason.map { reason in
            String(localized: .workloadsUnreadableBecause(reason))
        } ?? String(localized: "Workloads could not be read from this Spark.")
    }

    /// Warns when truncation or unreadable records prevent the list from representing the entire machine.
    public static func truncationNotice(
        _ inventory: GeneratedAPI.WorkloadInventory
    ) -> String? {
        guard inventory.available, inventory.truncated else { return nil }
        return String(localized: "This Spark has more workloads than this list shows.")
    }

    /// Show the empty state only after a successful inventory read found no workloads.
    public static func emptyMessage(
        _ inventory: GeneratedAPI.WorkloadInventory
    ) -> String? {
        guard inventory.available, inventory.workloads.isEmpty else { return nil }
        return String(localized: "No workloads are present on this Spark.")
    }

    static func row(
        _ workload: GeneratedAPI.ObservedWorkload,
        adoptionSupported: Bool
    ) -> Row {
        Row(
            id: workload.workloadId,
            title: workload.name ?? String(localized: "Unnamed workload"),
            ownership: ownershipLabel(workload),
            detail: detail(workload),
            imageReference: workload.imageReference,
            endpoints: workload.publishedPorts.map(endpoint),
            servedModels: workload.servedModels ?? [],
            apiSummary: apiSummary(workload),
            isManagedBySparkPilot: workload.ownership == .sparkManaged,
            canReviewAdoption: adoptionSupported
                && workload.ownership == .externalObserved
                && workload.recognisedEngine == .vllm
                && workload.state == .running,
            canRelinquish: workload.ownership == .sparkManaged
                && workload.managementOrigin == .externalAdoption
        )
    }

    static func apiSummary(_ workload: GeneratedAPI.ObservedWorkload) -> String? {
        guard workload.configurationState == .verified,
            workload.apiProtocol == "openai_compatible",
            let port = workload.apiPort
        else { return nil }
        return String(localized: .openAICompatibleAPIOnPort(String(port)))
    }

    static func ownershipLabel(_ workload: GeneratedAPI.ObservedWorkload) -> String {
        if workload.ownership == .sparkManaged,
            workload.managementOrigin == .externalAdoption
        {
            return String(localized: "Managed by SparkPilot, adopted in place")
        }
        return switch workload.ownership {
        case .sparkManaged: String(localized: "Managed by SparkPilot")
        case .externalObserved: String(localized: "Externally managed")
        // Keep adoptable workloads labeled external until adoption succeeds.
        case .adoptionAvailable: String(localized: "Externally managed, can be taken over")
        case .unknownExternal: String(localized: "Externally managed, not identified")
        }
    }

    /// Joins workload identity and state through display.joined so translators control ordering and separators.
    static func detail(_ workload: GeneratedAPI.ObservedWorkload) -> String {
        String(
            localized: .joined(
                description(engine: workload.recognisedEngine, kind: workload.kind),
                stateLabel(workload.state)
            )
        )
    }

    static func description(
        engine: GeneratedAPI.WorkloadEngine,
        kind: GeneratedAPI.WorkloadKind
    ) -> String {
        switch engine {
        case .vllm: return String(localized: "vLLM inference engine")
        case .sglang: return String(localized: "SGLang inference engine")
        case .ray: return String(localized: "Ray cluster runtime")
        case .openWebui: return String(localized: "Open WebUI")
        case .none: break
        }
        switch kind {
        case .projectContainer: return String(localized: "Project container")
        case .inferenceEngine: return String(localized: "Inference engine")
        case .optionalService: return String(localized: "Optional service")
        case .clusterRuntime: return String(localized: "Cluster runtime")
        // Distinguish an unidentified engine from no engine being present.
        case .unknown: return String(localized: "Not identified")
        }
    }

    static func stateLabel(_ state: GeneratedAPI.WorkloadState) -> String {
        switch state {
        case .created: String(localized: "Created")
        case .running: String(localized: "Running")
        case .paused: String(localized: "Paused")
        case .restarting: String(localized: "Restarting")
        case .removing: String(localized: "Removing")
        case .exited: String(localized: "Stopped")
        case .dead: String(localized: "Failed")
        // Do not infer stopped status from an unfamiliar runtime state.
        case .unknown: String(localized: "State unknown")
        }
    }

    /// Formats reported address, ports and protocol as technical data without translatable prose.
    static func endpoint(_ port: GeneratedAPI.ObservedWorkloadPort) -> String {
        "\(port.hostIp):\(port.hostPort) → \(port.containerPort)/\(port.protocol.rawValue)"
    }
}
