import Foundation
import Testing

@testable import SparkProjects

private func target(_ name: String, _ status: ProjectTargetStatus) -> ProjectTarget {
    ProjectTarget(id: "node:\(name)", name: name, status: status)
}

/// QA-14: the picker listed three Sparks alphabetically, chose the offline one, and landed the owner on "This Spark is offline."
@Test func theProjectsPickerOpensOnASparkThatAnswers() {
    let alphabetical = [
        target("Loft Spark", .offline),
        target("Example Spark", .unavailable),
        target("Studio Spark", .available),
    ]

    #expect(ProjectTargetSelection.preferred(alphabetical) == "node:Studio Spark")
}

/// QA-14: with nothing available, the least broken one wins rather than the first letter of the alphabet.
@Test func theLeastBrokenSparkWinsWhenNoneIsAvailable() {
    #expect(
        ProjectTargetSelection.preferred([
            target("Alpha", .identityMismatch),
            target("Beta", .offline),
            target("Gamma", .connecting),
        ]) == "node:Gamma"
    )
    #expect(
        ProjectTargetSelection.preferred([
            target("Alpha", .unavailable),
            target("Beta", .runtimeUpdateRequired),
        ]) == "node:Beta"
    )
}

/// QA-14: equal standing keeps the order the list already had, so the choice does not jump about between loads.
@Test func equallyUsableSparksKeepTheirListedOrder() {
    #expect(
        ProjectTargetSelection.preferred([
            target("Alpha", .available),
            target("Beta", .available),
        ]) == "node:Alpha"
    )
    #expect(ProjectTargetSelection.preferred([]) == nil)
}

/// QA-14: the menu showed no connection state at all, so there was nothing to steer by.
@Test func everyUnusableStateIsNamedInThePicker() {
    let states: [ProjectTargetStatus] = [
        .connecting, .offline, .identityMismatch, .runtimeUpdateRequired, .runtimeUnsupported,
        .unavailable,
    ]

    for state in states {
        let named = ProjectAvailabilityPresentation.shortState(for: state)
        #expect(named != nil, "\(state) has no name for the picker")
        #expect(named?.isEmpty == false)
    }
    #expect(ProjectAvailabilityPresentation.shortState(for: .available) == nil)
}
