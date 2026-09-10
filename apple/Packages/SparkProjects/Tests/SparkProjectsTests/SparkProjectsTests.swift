import Foundation
import SparkAPI
import Testing
@testable import SparkProjects

@MainActor
@Test func loadPublishesProjectsAndServerGrantedCapabilities() async {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)

    await model.load()

    #expect(model.projects == [ProjectModelTestFixtures.project])
    #expect(model.projectState == .loaded)
    #expect(model.canCreateProject)
    #expect(!model.isShowingCachedProjects)
}

@MainActor
@Test func failedRefreshKeepsTheLastGoodProjectCache() async {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    provider.projectFailure = ProjectModelTestProjectTestError.unavailable

    await model.refreshProjects()

    #expect(model.projects == [ProjectModelTestFixtures.project])
    #expect(model.projectState == .loaded)
    #expect(model.isShowingCachedProjects)
    #expect(model.warning?.contains("Cached") == true)
}

@MainActor
@Test func initialTargetProbePublishesLoadingInsteadOfAFalseEmptyState() async {
    let provider = ProjectModelTestTestProvider()
    provider.delaysTargets = true
    let model = ProjectsModel(provider: provider)

    let load = Task { await model.load() }
    for _ in 0..<20 where provider.targetContinuation == nil { await Task.yield() }

    #expect(model.projectState == .loading)
    provider.resumeTargets()
    await load.value
    #expect(model.projectState == .loaded)
}

@MainActor
@Test func reloadRefreshesTheOpenProjectAfterLibraryChanges() async {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    #expect(provider.fileListRequests == 1)
    #expect(provider.changeListRequests == 1)

    await model.load()

    #expect(provider.fileListRequests == 2)
    #expect(provider.changeListRequests == 2)
}

@MainActor
@Test func unavailableTargetsKeepCacheReadOnlyAndIdentityMismatchPurgesIt() async {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    await model.openFile(ProjectModelTestFixtures.fileEntry)

    provider.targetValues = [
        ProjectTarget(id: "node:1", name: "Desk Spark", status: .offline)
    ]
    await model.load()

    #expect(model.projects == [ProjectModelTestFixtures.project])
    #expect(model.isShowingCachedProjects)
    #expect(!model.canEditFile)
    #expect(!model.canRunAgent)
    #expect(!model.canReviewChanges)
    #expect(!model.canUseTerminal)

    provider.targetValues = [
        ProjectTarget(id: "node:1", name: "Desk Spark", status: .identityMismatch)
    ]
    await model.load()

    #expect(model.projects.isEmpty)
    #expect(model.selectedProject == nil)
    #expect(!model.isShowingCachedProjects)
    #expect(model.warning?.contains("identity") == true)
}

@MainActor
@Test func lateRefreshFromAnotherSparkCannotReplaceTheSelectedSpark() async {
    let provider = ProjectModelTestTestProvider()
    var secondProject = ProjectModelTestFixtures.project
    secondProject.id = "10000000-0000-4000-8000-000000000099"
    secondProject.name = "Second Spark Project"
    provider.targetValues = [
        ProjectTarget(id: "node:1", name: "First", isOnline: true, projectsAvailable: true),
        ProjectTarget(id: "node:2", name: "Second", isOnline: true, projectsAvailable: true),
    ]
    provider.collectionsByTarget = [
        "node:1": ProjectCollection(items: [ProjectModelTestFixtures.project], canCreate: true),
        "node:2": ProjectCollection(items: [secondProject], canCreate: false),
    ]
    let model = ProjectsModel(provider: provider)
    await model.load()
    provider.delayedProjectTargets = ["node:1"]

    let staleRefresh = Task { await model.refreshProjects() }
    for _ in 0..<20 where provider.projectContinuations["node:1"] == nil {
        await Task.yield()
    }
    await model.selectTarget("node:2")
    provider.resumeProjects(targetID: "node:1")
    await staleRefresh.value

    #expect(model.selectedTargetID == "node:2")
    #expect(model.projects == [secondProject])
    #expect(!model.canCreateProject)
}
