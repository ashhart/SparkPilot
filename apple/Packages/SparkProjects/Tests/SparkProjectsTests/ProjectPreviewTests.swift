import Foundation
import SparkAPI
import Testing

@testable import SparkProjects

@MainActor
private func openedModel() async -> (ProjectsModel, ProjectModelTestTestProvider) {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    return (model, provider)
}

/// PLAN 42.10 and 54.6: the preview reaches the project's dev server through the signed proxy.
@MainActor
@Test func aPreviewIsReadThroughTheProxyAndSaysWhereItCameFrom() async {
    let (model, provider) = await openedModel()
    model.previewPort = "5173"
    model.previewPath = "app/index.html"

    await model.loadPreview()

    #expect(provider.previewRequests == ["5173/app/index.html"])
    #expect(model.previewState == .loaded)
    #expect(model.previewBody.contains("Hello from the project"))
    #expect(model.previewOrigin == "localhost:5173/app/index.html")
}

/// Nothing is sent for a port that is not a port; the owner is told which field is wrong.
@MainActor
@Test func aPortThatIsNotAPortNeverLeavesTheDevice() async {
    let (model, provider) = await openedModel()

    for value in ["", "http", "0", "65536", "-1"] {
        model.previewPort = value
        await model.loadPreview()
        #expect(model.previewState == .failed("Enter the port your project serves on."))
    }
    #expect(provider.previewRequests.isEmpty)
}

/// A refusal from the Spark is shown as the Spark's own words, not a status code.
@MainActor
@Test func aRefusedPreviewShowsTheSparksReason() async {
    let (model, provider) = await openedModel()
    provider.previewFailure = APIError(.reported, statusCode: 404, code: "PROJECT_NOT_FOUND")

    await model.loadPreview()

    guard case .failed(let message) = model.previewState else {
        Issue.record("a refused preview must fail")
        return
    }
    #expect(!message.contains("PROJECT_NOT_FOUND"))
    #expect(!message.isEmpty)
    #expect(model.previewBody.isEmpty)
    #expect(model.previewOrigin == nil)
}

/// Leaving the pane drops what was read rather than keeping another project's page around.
@MainActor
@Test func leavingThePaneClearsWhatWasRead() async {
    let (model, _) = await openedModel()
    await model.loadPreview()
    #expect(model.previewState == .loaded)

    model.clearPreview()

    #expect(model.previewState == .idle)
    #expect(model.previewBody.isEmpty)
    #expect(model.previewOrigin == nil)
}

/// An empty path is the service's own root rather than a request for nothing.
@MainActor
@Test func anEmptyPathAsksForTheServiceRoot() async {
    let (model, provider) = await openedModel()
    model.previewPort = "3000"
    model.previewPath = ""

    await model.loadPreview()

    #expect(provider.previewRequests == ["3000/"])
    #expect(model.previewOrigin == "localhost:3000/")
}

/// The Spark decides who may preview: a project granted without project.preview shows no pane action.
@MainActor
@Test func aProjectTheSparkDoesNotLetThisDevicePreviewSendsNothing() async {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    var readable = ProjectModelTestFixtures.project
    readable.capabilities = [.read, .write, .terminal]
    await model.openProject(readable)
    model.previewPort = "5173"

    await model.loadPreview()

    #expect(model.canPreview == false)
    #expect(provider.previewRequests.isEmpty)
}
