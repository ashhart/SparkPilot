import SparkAPI
import Testing

@testable import SparkProjects

private let base = """
    import Foundation

    func answer() -> Int {
        41
    }
    """

@Test func edmitsInDifferentPlacesMergeWithoutLosingEither() {
    let mine = base.replacingOccurrences(
        of: "import Foundation",
        with: "import Foundation\nimport OS"
    )
    let theirs = base.replacingOccurrences(of: "    41", with: "    42")
    let merged = ProjectThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)

    #expect(merged.isClean)
    #expect(merged.text.contains("import OS"))
    #expect(merged.text.contains("    42"))
    #expect(!merged.text.contains("    41"))
}

@Test func thesameEditOnBothDevicesIsNotAConflict() {
    let both = base.replacingOccurrences(of: "    41", with: "    42")
    let merged = ProjectThreeWayMerge.merge(base: base, mine: both, theirs: both)
    #expect(merged.isClean)
    #expect(merged.text == both)
}

@Test func aRegionBothDevicesRewroteIsMarkedRatherThanDiscarded() {
    let mine = base.replacingOccurrences(of: "    41", with: "    43")
    let theirs = base.replacingOccurrences(of: "    41", with: "    42")
    let merged = ProjectThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)

    #expect(merged.conflictCount == 1)
    #expect(merged.text.contains("<<<<<<< this device"))
    #expect(merged.text.contains("    43"))
    #expect(merged.text.contains("    42"))
    #expect(merged.text.contains(">>>>>>> the Spark"))
}

@Test func anUntouchedSideKeepsTheOtherSideWhole() {
    let theirs = base + "\n// added on the Spark"
    let merged = ProjectThreeWayMerge.merge(base: base, mine: base, theirs: theirs)
    #expect(merged.isClean)
    #expect(merged.text == theirs)
}

@MainActor
@Test func aConflictOffersAMergeInsteadOfOverwritingTheOtherDevice() async throws {
    let provider = ProjectModelTestTestProvider()
    provider.fileContents = GeneratedAPI.ProjectFileContents(
        path: ProjectModelTestFixtures.fileEntry.path,
        content: base,
        revision: ProjectModelTestFixtures.revision
    )
    provider.saveOutcome = .conflict(
        GeneratedAPI.ProjectFileConflict(
            error: GeneratedAPI.ProjectFileConflictError(
                code: .conflict,
                baseRevision: ProjectModelTestFixtures.revision,
                currentRevision: ProjectModelTestFixtures.newRevision,
                currentContent: base.replacingOccurrences(of: "    41", with: "    42")
            )
        )
    )
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    await model.openFile(ProjectModelTestFixtures.fileEntry)
    model.editorText = base.replacingOccurrences(
        of: "import Foundation",
        with: "import Foundation\nimport OS"
    )
    _ = await model.saveFile()

    let conflict = try #require(model.conflict)
    #expect(conflict.baseContent == base)
    let merged = model.mergeConflictVersions()
    #expect(merged?.isClean == true)
    #expect(model.editorText.contains("import OS"))
    #expect(model.editorText.contains("    42"))
    #expect(!model.editorText.contains("    41"))
}
