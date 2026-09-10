import Foundation
import SparkAPI
import SparkLibrary

/// Asks a Spark to ready its development image and coding agent ahead of the first workspace, and remembers the answer.
@MainActor
final class SparkDevelopmentPreparer {
    typealias Perform =
        @MainActor (SparkLibrary, String) async throws -> GeneratedAPI.DevelopmentPreparation?

    static let shared = SparkDevelopmentPreparer()

    /// How long one answer stands before the same Spark is asked again without being forced.
    static let repeatInterval: TimeInterval = 600

    private(set) var statuses: [String: GeneratedAPI.DevelopmentPreparation] = [:]
    private var askedAt: [String: Date] = [:]
    private let now: () -> Date
    private let perform: Perform

    init(now: @escaping () -> Date = Date.init, perform: Perform? = nil) {
        self.now = now
        self.perform = perform ?? Self.askSpark
    }

    /// Every paired Spark at once; one that cannot answer is left for the workspace to explain later.
    func prepareAll(library: SparkLibrary) async {
        guard SparkEngineeringMode.isEnabled() else { return }
        let ids = library.entries.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { _ = await self.prepare(library: library, targetID: id) }
            }
        }
    }

    /// The Spark's answer, or nil when it has no signed route, lacks the capability or could not be reached.
    @discardableResult
    func prepare(library: SparkLibrary, targetID: String, force: Bool = false) async
        -> GeneratedAPI.DevelopmentPreparation?
    {
        if !force, let asked = askedAt[targetID],
            now().timeIntervalSince(asked) < Self.repeatInterval
        {
            return statuses[targetID]
        }
        askedAt[targetID] = now()
        do {
            guard let status = try await perform(library, targetID) else { return nil }
            statuses[targetID] = status
            return status
        } catch {
            askedAt[targetID] = nil
            return nil
        }
    }

    private static let askSpark: Perform = { library, targetID in
        let connection = try SparkSignedProjectConnection.make(library: library, targetID: targetID)
        let capabilities = try await connection.api.capabilities(route: connection.route)
        guard capabilities.isEnabled("development_prepare") else { return nil }
        return try await connection.api.prepareDevelopment(route: connection.route)
    }
}
