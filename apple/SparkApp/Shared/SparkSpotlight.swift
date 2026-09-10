import Foundation
import Observation
import SparkIntents
import SparkLibrary
import SwiftUI

public protocol SparkSpotlightIndexing: Sendable {
    func replace(_ records: [SparkSpotlightIndexer.Record]) async throws
    func removeAll() async throws
}

extension SparkSpotlightIndexer: SparkSpotlightIndexing {}

enum SparkSpotlightRecordBuilder {
    static func records(
        entries: [LibraryEntry],
        modelSnapshot: CrossTargetModelLibrarySnapshot
    ) -> [SparkSpotlightIndexer.Record] {
        let targets = entries.compactMap { entry -> SparkSpotlightIndexer.Record? in
            guard entry.issue == nil else { return nil }
            let title = approvedTargetTitle(entry)
            switch entry.kind {
            case .standalone:
                return SparkSpotlightIndexer.nodeRecord(id: entry.id, name: title)
            case .cluster:
                return SparkSpotlightIndexer.clusterRecord(id: entry.id, name: title)
            }
        }
        let models: [SparkSpotlightIndexer.Record] = modelSnapshot.models.compactMap { model in
            guard model.verification == .verified else { return nil }
            return SparkSpotlightIndexer.modelRecord(id: model.id, name: model.displayName)
        }
        return (targets + models).sorted {
            if $0.domain.rawValue != $1.domain.rawValue {
                return $0.domain.rawValue < $1.domain.rawValue
            }
            return $0.id < $1.id
        }
    }

    private static func approvedTargetTitle(_ entry: LibraryEntry) -> String {
        let label = entry.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label, !label.isEmpty { return label }
        return entry.kind == .cluster
            ? String(localized: "DGX Spark cluster") : String(localized: "DGX Spark")
    }
}

@MainActor
@Observable
public final class SparkSpotlightModel {
    public private(set) var isEnabled: Bool
    public private(set) var isSyncing = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let indexer: any SparkSpotlightIndexing
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let enabledKey: String
    @ObservationIgnored private var entries: [LibraryEntry] = []
    @ObservationIgnored private var modelSnapshot: CrossTargetModelLibrarySnapshot = .empty
    @ObservationIgnored private var revision = 0

    public init(
        indexer: any SparkSpotlightIndexing = SparkSpotlightIndexer(),
        defaults: UserDefaults = .standard,
        enabledKey: String = "sparkpilot.spotlight.enabled"
    ) {
        self.indexer = indexer
        self.defaults = defaults
        self.enabledKey = enabledKey
        self.isEnabled = defaults.object(forKey: enabledKey) as? Bool ?? false
    }

    public func prepare() async {
        revision += 1
        await synchronize()
    }

    public func observe(
        entries: [LibraryEntry],
        modelSnapshot: CrossTargetModelLibrarySnapshot
    ) async {
        self.entries = entries
        self.modelSnapshot = modelSnapshot
        revision += 1
        guard isEnabled else { return }
        await synchronize()
    }

    public func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        defaults.set(enabled, forKey: enabledKey)
        revision += 1
        await synchronize()
    }

    private func synchronize() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        while true {
            let syncingRevision = revision
            do {
                if isEnabled {
                    try await indexer.replace(
                        SparkSpotlightRecordBuilder.records(
                            entries: entries,
                            modelSnapshot: modelSnapshot
                        )
                    )
                } else {
                    try await indexer.removeAll()
                }
                errorMessage = nil
            } catch {
                errorMessage =
                    isEnabled
                    ? String(localized: "Spotlight could not update its SparkPilot results.")
                    : String(
                        localized:
                            "Spotlight is off, but its previous SparkPilot results could not be removed."
                    )
            }
            guard syncingRevision != revision else { return }
        }
    }
}

public struct SparkSpotlightSettingsView: View {
    @Bindable private var model: SparkSpotlightModel
    @State private var isChanging = false

    public init(model: SparkSpotlightModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "Show Sparks and models in Spotlight"),
                    isOn: Binding(
                        get: { model.isEnabled },
                        set: { enabled in
                            isChanging = true
                            Task {
                                await model.setEnabled(enabled)
                                isChanging = false
                            }
                        }
                    )
                )
                .disabled(isChanging || model.isSyncing)
            } footer: {
                Text(
                    """
                    This local index contains owner labels and verified model names. \
                    Prompts, answers, hostnames, network addresses, diagnostics, and \
                    secrets stay out.
                    """
                )
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Spotlight")
    }
}
