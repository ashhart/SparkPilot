import CoreSpotlight
import Foundation

/// Index only approved product metadata, excluding conversation bodies by default (§40.8).
public struct SparkSpotlightIndexer: Sendable {
    public enum Domain: String, Sendable {
        public static let identifier = "app.spark.spark-fabric"

        case node
        case cluster
        case model
        case conversation
        case project
        case artefact
    }

    public let domainIdentifier: String
    private let now: @Sendable () -> Date

    public init(domainIdentifier: String = Domain.identifier) {
        self.domainIdentifier = domainIdentifier
        self.now = Date.init
    }

    public init(
        domainIdentifier: String = Domain.identifier,
        now: @escaping @Sendable () -> Date
    ) {
        self.domainIdentifier = domainIdentifier
        self.now = now
    }

    /// Construct index records only through per-domain factories whose parameters enforce approved metadata fields.
    public struct Record: Equatable, Sendable {
        public let domain: Domain
        public let id: String
        public let title: String
        public let description: String?
        public let keywords: [String]

        fileprivate init(
            domain: Domain,
            id: String,
            title: String,
            description: String? = nil,
            keywords: [String] = []
        ) {
            self.domain = domain
            self.id = id
            self.title = title
            self.description = description
            self.keywords = keywords
        }
    }

    /// Build searchable items without accessing the system index.
    public func searchableItem(for record: Record) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = record.title
        attributes.contentDescription = record.description
        attributes.keywords = record.keywords.isEmpty ? nil : record.keywords
        // Include explicit product attribution in addition to the Spotlight domain namespace (§40.8).
        attributes.displayName = record.title
        attributes.domainIdentifier = domainIdentifier
        attributes.contentCreationDate = now()
        return CSSearchableItem(
            uniqueIdentifier: "\(domainIdentifier)/\(record.domain.rawValue)/\(record.id)",
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }

    /// Propagate asynchronous system-index submission failures.
    public func index(_ records: [Record]) async throws {
        let items = records.map(searchableItem)
        try await CSSearchableIndex.default().indexSearchableItems(items)
    }

    /// Remove the donated metadata domain before replacement so deleted targets cannot persist in search.
    public func replace(_ records: [Record]) async throws {
        try await removeAll()
        guard !records.isEmpty else { return }
        try await index(records)
    }

    /// Remove everything this app donated.
    public func removeAll() async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(
            withDomainIdentifiers: [domainIdentifier]
        )
    }

    // MARK: - The approved records (§40.8)

    /// Index only a conversation title and return nil when none exists.
    public static func conversationRecord(id: String, title: String?) -> Record? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        else { return nil }
        return Record(domain: .conversation, id: id, title: title)
    }

    /// A project: §40.8 approves "project names and descriptions".
    public static func projectRecord(id: String, name: String, summary: String? = nil) -> Record {
        Record(domain: .project, id: id, title: name, description: summary)
    }

    /// A model: §40.8 approves "model names".
    public static func modelRecord(id: String, name: String) -> Record {
        Record(domain: .model, id: id, title: name)
    }

    /// A Spark node: §40.8 approves "Spark nodes/clusters".
    public static func nodeRecord(id: String, name: String) -> Record {
        Record(domain: .node, id: id, title: name)
    }

    public static func clusterRecord(id: String, name: String) -> Record {
        Record(domain: .cluster, id: id, title: name)
    }

    /// A generated artefact: §40.8 approves "generated artefact titles".
    public static func artefactRecord(id: String, title: String) -> Record {
        Record(domain: .artefact, id: id, title: title)
    }
}
