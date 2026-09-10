import SparkAPI
import Testing
@testable import SparkProjects

@MainActor
struct ProjectDeletionTests {
    @Test func onlyTheConfirmedSparkAndADeleteGrantMayRemoveAProject() async {
        let provider = ProjectModelTestTestProvider()
        let model = ProjectsModel(provider: provider)
        await model.load()
        var project = ProjectModelTestFixtures.project
        project.capabilities.removeAll { $0 == .delete }
        provider.collection = .init(items: [project], canCreate: true)
        await model.refreshProjects()
        #expect(!model.canDeleteProject(project))
        #expect(await !model.deleteProject(project, targetID: "node:1"))
        project.capabilities.append(.delete)
        provider.collection = .init(items: [project], canCreate: true)
        await model.refreshProjects()
        #expect(model.canDeleteProject(project))
        #expect(await !model.deleteProject(project, targetID: "node:other"))
        #expect(provider.deletedProjects.isEmpty)
        await model.openProject(project)
        provider.deleteFailure = ProjectModelTestProjectTestError.unavailable
        #expect(await !model.deleteProject(project, targetID: "node:1"))
        #expect(model.projects.count == 1)
        #expect(model.selectedProject?.id == project.id)
        #expect(model.warning != nil)
        provider.deleteFailure = nil
        #expect(await model.deleteProject(project, targetID: "node:1"))
        #expect(model.projects.isEmpty)
        #expect(model.selectedProject == nil)
        #expect(model.files.isEmpty)
        #expect(model.deletingProjectID == nil)
        #expect(provider.deletedProjects == ["node:1::" + project.id])
    }
}
