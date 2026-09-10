import Foundation
import SparkCore
import Testing

@testable import SparkDesignSystem

private func designSystemSource(_ name: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let package =
        testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: package.appending(path: "Sources/SparkDesignSystem/\(name).swift"),
        encoding: .utf8
    )
}

/// QA-08: on setup step 1 the primary action was half-covered by the floating tab bar and the secondary one entirely behind it, with nothing to say more was below.
@Test func aPhasesActionsArePinnedClearOfTheFloatingTabBar() {
    #expect(RetailOnboardingChrome.resolve(issue: nil).pinsActions)
}

/// QA-08: a failure screen carries its own retry inside the explanation, so nothing is pinned under it.
@Test func aFailureScreenKeepsItsActionsWithItsExplanation() {
    #expect(!RetailOnboardingChrome.resolve(issue: .localNetworkDenied).pinsActions)
}

/// QA-07: the floating Back/Cancel pill sat straight on top of the scrolling title with no inset or scrim.
@Test func contentScrollingUnderTheToolbarPillGetsAnEdgeEffect() throws {
    #expect(RetailOnboardingChrome.resolve(issue: nil).usesHardTopEdgeEffect)

    let view = try designSystemSource("RetailOnboardingView")
    #expect(view.contains("safeAreaInset(edge: .bottom"))
    #expect(view.contains("RetailOnboardingScrollEdge(chrome: chrome)"))

    let presentation = try designSystemSource("RetailOnboardingPresentation")
    #expect(presentation.contains("scrollEdgeEffectStyle(.hard, for: .top)"))
}
