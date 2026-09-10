import Foundation
import Observation
import SparkAPI
import SparkSecurity

/// Inject support-bundle API behavior so owner controls can be tested without hardware.
public protocol DiagnosticsExporting: Sendable {
    func diagnosticsCatalogue(route: URL) async throws -> GeneratedAPI.DiagnosticsCatalogue
    func exportDiagnostics(
        route: URL,
        includeOptional: [String],
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.DiagnosticsBundle
}

/// Reuse the shipping client's support-bundle routes through protocol conformance.
extension SparkAPIClient: DiagnosticsExporting {
    public func exportDiagnostics(
        route: URL,
        includeOptional: [String],
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.DiagnosticsBundle {
        try await exportDiagnostics(
            route: route,
            request: GeneratedAPI.DiagnosticsExportRequest(includeOptional: includeOptional),
            userPresence: userPresence
        )
    }
}

/// A support archive written on this device, ready for the system exporter.
public struct DiagnosticsArchive: Sendable, Equatable {
    public let url: URL
    /// Retain each file's sensitivity classification for review before sharing.
    public let manifest: GeneratedAPI.DiagnosticsManifest
}

/// Builds export controls from runtime-provided categories and refuses category IDs the Spark does not offer.
@MainActor
@Observable
public final class DiagnosticsExportModel {
    public private(set) var sections: [GeneratedAPI.DiagnosticsSection] = []
    public private(set) var optionalCategories: [GeneratedAPI.DiagnosticsSection] = []
    public private(set) var neverExported: [GeneratedAPI.DiagnosticsExclusion] = []
    /// Ticked optional categories, in the order the runtime lists them.
    public private(set) var selectedCategories: [String] = []
    public private(set) var isBusy = false
    public private(set) var failure: String?

    /// The exact pinned route this model was built for.
    public let route: URL
    @ObservationIgnored private let service: any DiagnosticsExporting
    @ObservationIgnored private let userPresenceAuthorizer: any UserPresenceAuthorizing
    @ObservationIgnored private let writer: DiagnosticsArchiveWriter

    public init(
        route: URL,
        service: any DiagnosticsExporting,
        userPresenceAuthorizer: any UserPresenceAuthorizing,
        writer: DiagnosticsArchiveWriter = DiagnosticsArchiveWriter()
    ) {
        self.route = route
        self.service = service
        self.userPresenceAuthorizer = userPresenceAuthorizer
        self.writer = writer
    }

    public func load() async {
        failure = nil
        do {
            let catalogue = try await service.diagnosticsCatalogue(route: route)
            sections = catalogue.sections
            optionalCategories = catalogue.optionalCategories
            neverExported = catalogue.neverExported
            // Optional categories start disabled regardless of the runtime's suggested defaults.
            selectedCategories = []
        } catch {
            failure = describe(error)
        }
    }

    public func isSelected(_ id: String) -> Bool {
        selectedCategories.contains(id)
    }

    public func setSelected(_ id: String, _ selected: Bool) {
        guard optionalCategories.contains(where: { $0.id == id }) else { return }
        var next = Set(selectedCategories)
        if selected { next.insert(id) } else { next.remove(id) }
        selectedCategories = optionalCategories.map(\.id).filter(next.contains)
    }

    /// Proves owner presence before requesting a bundle, then writes it for the system exporter.
    public func export() async -> DiagnosticsArchive? {
        guard !isBusy else { return nil }
        isBusy = true
        failure = nil
        defer { isBusy = false }

        do {
            let presence = try await userPresenceAuthorizer.authorize(
                localizedReason: String(localized: "Export a support bundle from this Spark")
            )
            let bundle = try await service.exportDiagnostics(
                route: route,
                includeOptional: selectedCategories,
                userPresence: presence
            )
            let url = try writer.write(bundle)
            return DiagnosticsArchive(url: url, manifest: bundle.manifest)
        } catch {
            failure = describe(error)
            return nil
        }
    }

    /// Displays only the documented stable error code, keeping runtime operator prose out of app copy.
    private func describe(_ error: Error) -> String {
        if let error = error as? APIError {
            return error.code ?? "REQUEST_FAILED"
        }
        if let error = error as? DiagnosticsArchiveError {
            return error.code
        }
        return "EXPORT_FAILED"
    }
}
