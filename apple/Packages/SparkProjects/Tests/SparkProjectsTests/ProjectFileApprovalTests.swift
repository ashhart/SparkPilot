import Foundation
import SparkAPI
import Testing
@testable import SparkProjects

@MainActor
@Test func revisionConflictPreservesBothVersionsUntilAnExplicitSave() async {
    let provider = ProjectModelTestTestProvider()
    provider.saveOutcome = .conflict(
        GeneratedAPI.ProjectFileConflict(
            error: GeneratedAPI.ProjectFileConflictError(
                code: .conflict,
                baseRevision: ProjectModelTestFixtures.revision,
                currentRevision: ProjectModelTestFixtures.newRevision,
                currentContent: "let answer = 43\n"
            )
        )
    )
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    await model.openFile(ProjectModelTestFixtures.fileEntry)
    model.editorText = "let answer = 42\n"

    #expect(!(await model.saveFile()))
    #expect(model.conflict?.localContent == "let answer = 42\n")
    #expect(model.conflict?.remoteContent == "let answer = 43\n")

    model.replaceRemoteWithLocalVersion()
    #expect(model.editorText == "let answer = 42\n")
    #expect(model.editorRevision == ProjectModelTestFixtures.newRevision)
    #expect(model.conflict == nil)
    #expect(provider.saveRequests == 1, "choosing a version must not write it")

    provider.saveOutcome = .saved(
        GeneratedAPI.ProjectFileSave(
            path: ProjectModelTestFixtures.fileEntry.path,
            revision: ProjectModelTestFixtures.newRevision
        )
    )
    #expect(await model.saveFile())
    #expect(model.editorRevision == ProjectModelTestFixtures.newRevision)
    #expect(provider.saveRequests == 2)
}

@MainActor
@Test func approvalSendsTheExactReviewedDigestAndRejectsFailedEvidence() async {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)

    #expect(model.canApprove(ProjectModelTestFixtures.reviewChange))
    #expect(await model.approve(ProjectModelTestFixtures.reviewChange, comment: "Reviewed on iPad"))
    #expect(provider.approvedDigests == [ProjectModelTestFixtures.reviewDigest])

    var failed = ProjectModelTestFixtures.reviewChange
    failed.testEvidence = [
        GeneratedAPI.ProjectTestEvidence(
            command: "swift test",
            status: .failed,
            exitCode: 1,
            outputDigest: String(repeating: "2", count: 64)
        )
    ]
    #expect(!model.canApprove(failed))
}

@MainActor
@Test func staleDecisionResponsesCannotCrossProjectBoundaries() async {
    let provider = ProjectModelTestTestProvider()
    provider.collection = ProjectCollection(
        items: [ProjectModelTestFixtures.project, ProjectModelTestFixtures.secondProject],
        canCreate: true
    )
    provider.changesByProject = [
        ProjectModelTestFixtures.project.id: [ProjectModelTestFixtures.reviewChange],
        ProjectModelTestFixtures.secondProject.id: [ProjectModelTestFixtures.secondReviewChange],
    ]
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)

    provider.delaysApproval = true
    let approval = Task { await model.approve(ProjectModelTestFixtures.reviewChange, comment: nil) }
    for _ in 0..<20 where provider.approvalContinuation == nil { await Task.yield() }
    await model.openProject(ProjectModelTestFixtures.secondProject)
    provider.resumeApproval()

    #expect(!(await approval.value))
    #expect(model.changes == [ProjectModelTestFixtures.secondReviewChange])

    await model.openProject(ProjectModelTestFixtures.project)
    provider.delaysRequestChanges = true
    let request = Task {
        await model.requestChanges(ProjectModelTestFixtures.reviewChange, comment: "Please revise")
    }
    for _ in 0..<20 where provider.requestChangesContinuation == nil { await Task.yield() }
    await model.openProject(ProjectModelTestFixtures.secondProject)
    provider.resumeRequestChanges()

    #expect(!(await request.value))
    #expect(model.changes == [ProjectModelTestFixtures.secondReviewChange])
}

@MainActor
@Test func requestingChangesRequiresACommentAndKeepsTheReviewedDigest() async {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)

    #expect(!(await model.requestChanges(ProjectModelTestFixtures.reviewChange, comment: "  ")))
    #expect(
        await model.requestChanges(
            ProjectModelTestFixtures.reviewChange,
            comment: "Cover the failure path"
        )
    )
    #expect(provider.requestedComments == ["Cover the failure path"])
}

@Test func incompleteOrMalformedEvidenceCannotBeApproved() {
    var incomplete = ProjectModelTestFixtures.reviewChange
    incomplete.evidenceComplete = false
    #expect(!ProjectReviewGate.canApprove(incomplete))

    var malformed = ProjectModelTestFixtures.reviewChange
    malformed.reviewDigest = "not-a-digest"
    #expect(!ProjectReviewGate.canApprove(malformed))

    var noTests = ProjectModelTestFixtures.reviewChange
    noTests.testEvidence = []
    #expect(!ProjectReviewGate.canApprove(noTests))

    var nonZeroExit = ProjectModelTestFixtures.reviewChange
    nonZeroExit.testEvidence[0].exitCode = 1
    #expect(!ProjectReviewGate.canApprove(nonZeroExit))

    var brokenSequence = ProjectModelTestFixtures.reviewChange
    brokenSequence.toolEvidence[0].sequence = 2
    #expect(!ProjectReviewGate.canApprove(brokenSequence))

    var movedProtectedHead = ProjectModelTestFixtures.reviewChange
    movedProtectedHead.protectedHeadCommit = String(repeating: "f", count: 40)
    #expect(!ProjectReviewGate.canApprove(movedProtectedHead))
}
