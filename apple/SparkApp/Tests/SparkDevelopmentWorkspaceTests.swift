import Foundation
import SparkAPI
import SparkLibrary
import Testing
@testable import SparkAppComposition

@MainActor
struct SparkDevelopmentWorkspaceTests {
    @Test func engineeringModeIsOptInAndPersistsWithoutChangingPermissions() throws {
        let suite = "SparkEngineeringModeTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!SparkEngineeringMode.isEnabled(in: defaults))
        defaults.set(true, forKey: SparkEngineeringMode.preferenceKey)
        #expect(SparkEngineeringMode.isEnabled(in: defaults))
        defaults.set(false, forKey: SparkEngineeringMode.preferenceKey)
        #expect(!SparkEngineeringMode.isEnabled(in: defaults))
    }
    @Test func twoPanesKeepTheirDraftsModelsAndRemoteIdentitiesSeparateAcrossRelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "development-\(UUID()).json"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let library = SparkLibrary(store: MemoryLibraryStore(), now: { Date() })
        let store = SparkDevelopmentWorkspace(library: library, archiveURL: url)
        let first = record("First", target: "spark-a", model: "model-a")
        let second = record("Second", target: "spark-b", model: "model-b")
        store.update(first)
        store.update(second)
        let left = SparkDevelopmentContext(record: first, workspace: store)
        let right = SparkDevelopmentContext(record: second, workspace: store)
        left.draft = "Edit the first project"
        right.draft = "Explain the second project"
        #expect(left.model !== right.model)
        #expect(left.id != right.id)
        let reopened = SparkDevelopmentWorkspace(library: library, archiveURL: url)
        #expect(reopened.record(first.id)?.draft == "Edit the first project")
        #expect(reopened.record(second.id)?.draft == "Explain the second project")
        #expect(reopened.record(first.id)?.selection.modelID == "model-a")
        #expect(reopened.record(second.id)?.targetID == "spark-b")
    }
    @Test func aDamagedArchiveIsNotOverwrittenByANewWorkspace() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "development-\(UUID()).json"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("not a workspace archive".utf8)
        try original.write(to: url)
        let library = SparkLibrary(store: MemoryLibraryStore(), now: { Date() })
        let store = SparkDevelopmentWorkspace(library: library, archiveURL: url)
        #expect(store.storageError != nil)
        store.update(record("New", target: "spark-a", model: "model-a"))
        #expect(try Data(contentsOf: url) == original)
    }
    private func record(_ name: String, target: String, model: String) -> SparkDevelopmentRecord {
        SparkDevelopmentRecord(
            id: UUID(),
            targetID: target,
            projectID: UUID().uuidString,
            projectName: name,
            sparkName: target,
            selection: .init(harness: .ohMyPi, modelID: model, clusterID: nil),
            launchKey: UUID(),
            terminal: nil,
            draft: ""
        )
    }
}
