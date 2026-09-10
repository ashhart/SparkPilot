import Foundation
import SparkDesignSystem
import Testing

/// Offer approval actions only during review and keep terminal states read-only (§42.6).
@Test func reviewOffersApprovalTerminalStatesDoNot() {
    let review = ChangeSummaryState(
        id: "c1",
        task: "add parsing",
        status: .review,
        filesChanged: 3,
        insertions: 44,
        deletions: 7,
        testPassed: true,
        branch: "agent-1"
    )
    #expect(ChangePresentationResolver.resolve(review).actions == .approveAndReject)

    for terminal in [ChangeStatus.merged, .rejected, .approved, .failed] {
        let state = ChangeSummaryState(
            id: "c1",
            task: "t",
            status: terminal,
            filesChanged: 0,
            insertions: 0,
            deletions: 0,
            testPassed: nil,
            branch: "agent-1"
        )
        #expect(ChangePresentationResolver.resolve(state).actions == .none)
    }
}

/// Summarize pluralised file changes and the agent's own test result.
@Test func summaryLineIsConcreteAndPluralised() {
    let one = ChangeSummaryState(
        id: "c1",
        task: "t",
        status: .review,
        filesChanged: 1,
        insertions: 3,
        deletions: 1,
        testPassed: false,
        branch: "agent-1"
    )
    let presentation = ChangePresentationResolver.resolve(one)
    // Assert source defaults in package tests and singular grammar in built-product catalogue tests.
    let summary = String(localized: presentation.summaryLine)
    #expect(summary.contains("1 file"), "\(summary)")
    #expect(summary.contains("+3"), "\(summary)")
    #expect(summary.contains("−1"), "\(summary)")
    #expect(summary.contains("tests failed"), "\(summary)")
}

/// Reject copy is explicit that the audit trail is preserved.
@Test func rejectCopyPromisesAuditPreservation() {
    let state = ChangeSummaryState(
        id: "c1",
        task: "t",
        status: .review,
        filesChanged: 0,
        insertions: 0,
        deletions: 0,
        testPassed: nil,
        branch: "agent-1"
    )
    #expect(
        String(localized: ChangePresentationResolver.resolve(state).suggestedRejectCopy)
            .localizedCaseInsensitiveContains("audit")
    )
}

/// Preserve runtime-produced diff order and hunk positions when parsing.
@Test func diffParserHandlesUnifiedText() {
    let diff = """
        @@ -1,3 +1,5 @@
         # project
        -old line
        +new line one
        +new line two
         context stays
        \\ No newline at end of file
        """
    let lines = DiffParser.parse(unifiedDiff: diff)
    #expect(lines.count == 6)
    #expect(lines[0].prefix == .position)
    #expect(lines[0].text.hasPrefix("@@"))
    #expect(lines[1].prefix == .context)
    #expect(lines[2].prefix == .deletion)
    #expect(lines[2].text == "old line")
    #expect(lines[3].prefix == .addition)
    #expect(lines[4].prefix == .addition)
}

/// A hostile or enormous diff is bounded so the UI cannot be blown up.
@Test func diffParserBoundsOutput() {
    let big = (0..<5000).map { "+\u{62}line\($0)" }.joined(separator: "\n")
    let lines = DiffParser.parse(unifiedDiff: big)
    #expect(lines.count <= 1000)
    #expect(lines.allSatisfy { $0.prefix == .addition })
}
