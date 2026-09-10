import Foundation
import SparkAPI
import Testing
@testable import SparkProjects

enum ProjectModelTestFixtures {
    static let revision = String(repeating: "a", count: 64)
    static let newRevision = String(repeating: "b", count: 64)
    static let reviewDigest = String(repeating: "c", count: 64)

    static let project = GeneratedAPI.Project(
        id: "10000000-0000-4000-8000-000000000001",
        name: "Private Assistant",
        state: .ready,
        repositoryUrl: nil,
        defaultBranch: "main",
        capabilities: [.read, .write, .terminal, .preview, .agentRun, .review],
        createdAt: "2026-09-01T12:00:00Z",
        updatedAt: "2026-09-01T12:00:00Z"
    )
    static var secondProject: GeneratedAPI.Project {
        var value = project
        value.id = "10000000-0000-4000-8000-000000000099"
        value.name = "Second Project"
        return value
    }
    static let fileEntry = GeneratedAPI.ProjectFileEntry(
        path: "Sources/App.swift",
        revision: revision,
        sizeBytes: 42
    )
    static let fileContents = GeneratedAPI.ProjectFileContents(
        path: fileEntry.path,
        content: "let answer = 42\n",
        revision: revision
    )
    static let changedFile = GeneratedAPI.ProjectChangedFile(
        path: "Sources/App.swift",
        changeType: .modified,
        additions: 1,
        deletions: 1,
        hunks: [
            GeneratedAPI.ProjectDiffHunk(
                oldStart: 1,
                oldLines: 1,
                newStart: 1,
                newLines: 1,
                header: "@@ -1 +1 @@",
                lines: [
                    GeneratedAPI.ProjectDiffLine(kind: .deletion, content: "let answer = 41"),
                    GeneratedAPI.ProjectDiffLine(kind: .addition, content: "let answer = 42"),
                ]
            )
        ]
    )
    static let reviewChange = GeneratedAPI.ProjectChange(
        id: "30000000-0000-4000-8000-000000000003",
        projectId: project.id,
        status: .review,
        task: "Correct the answer",
        baseCommit: String(repeating: "d", count: 40),
        headCommit: String(repeating: "e", count: 40),
        protectedHeadCommit: String(repeating: "d", count: 40),
        reviewDigest: reviewDigest,
        branch: "agent/correct-answer",
        changedFiles: [changedFile],
        testEvidence: [
            GeneratedAPI.ProjectTestEvidence(
                command: "swift test",
                status: .passed,
                exitCode: 0,
                outputDigest: String(repeating: "1", count: 64)
            )
        ],
        toolEvidence: [
            GeneratedAPI.ProjectToolEvidence(sequence: 1, tool: .writeFile, outcome: .ok)
        ],
        evidenceComplete: true,
        createdAt: "2026-09-01T12:00:00Z",
        updatedAt: "2026-09-01T12:01:00Z"
    )
    static var secondReviewChange: GeneratedAPI.ProjectChange {
        var value = reviewChange
        value.id = "30000000-0000-4000-8000-000000000099"
        value.projectId = secondProject.id
        value.reviewDigest = String(repeating: "f", count: 64)
        value.task = "Second task"
        return value
    }
}
