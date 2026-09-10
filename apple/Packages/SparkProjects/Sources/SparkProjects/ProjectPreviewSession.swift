import Foundation
import Observation
import SparkAPI

/// PLAN 42.7's preview pane and 54.6's "preview works through authenticated proxy".
@MainActor
@Observable
final class ProjectPreviewSession {
    /// The port the project's own dev server listens on inside its container.
    var port = "3000"
    var path = ""
    private(set) var body = ""
    private(set) var state: ProjectLoadState = .idle
    /// The port and path the shown body actually came from, so the header cannot lie.
    private(set) var loadedFrom: String?
    @ObservationIgnored var contextIsCurrent: (String, String) -> Bool = { _, _ in false }
    private let provider: any ProjectDataProviding
    private var sequence = 0

    init(provider: any ProjectDataProviding) { self.provider = provider }

    /// A port a person typed is only a port when it is one; nothing is sent otherwise.
    var requestedPort: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)),
            (1...65_535).contains(value)
        else { return nil }
        return value
    }

    func load(targetID: String?, projectID: String?, permitted: Bool) async {
        guard permitted, let targetID, let projectID else {
            state = .failed(String(localized: "This device cannot open previews on this Spark."))
            return
        }
        guard let requestedPort else {
            state = .failed(String(localized: "Enter the port your project serves on."))
            return
        }
        sequence += 1
        let attempt = sequence
        let requestedPath = path.trimmingCharacters(in: .whitespaces)
        state = .loading
        do {
            let loaded = try await provider.preview(
                targetID: targetID,
                projectID: projectID,
                port: requestedPort,
                path: requestedPath
            )
            // A late answer from a Spark or project the owner has left never lands.
            guard attempt == sequence, contextIsCurrent(targetID, projectID) else { return }
            body = loaded
            loadedFrom = ProjectPreviewSession.origin(port: requestedPort, path: requestedPath)
            state = loaded.isEmpty ? .empty : .loaded
        } catch {
            guard attempt == sequence, contextIsCurrent(targetID, projectID) else { return }
            body = ""
            loadedFrom = nil
            state = .failed(APIError.message(for: error))
        }
    }

    func clear() {
        sequence += 1
        body = ""
        loadedFrom = nil
        state = .idle
    }

    static func origin(port: Int, path: String) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return "localhost:\(port)/\(trimmed)"
    }
}
