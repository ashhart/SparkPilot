import Foundation
import SparkCore
import SparkDesignSystem
import Testing

@testable import SparkAppComposition

/// Tests presentation accessibility contracts; physical rotor, contrast and Dynamic Type checks are tracked in tests/accessibility/coverage.json.
@MainActor
struct AccessibilityContractTests {
    // MARK: - Charts have accessible summaries

    @Test func aSparklineSummarisesWhatItsShapeShows() {
        let summary = String(
            localized: SparkTrendAccessibility.summary([12, 4, 31, 18])
        )
        #expect(summary.contains("Latest 18"), "\(summary)")
        #expect(summary.contains("lowest 4"), "\(summary)")
        #expect(summary.contains("highest 31"), "\(summary)")
        #expect(summary.contains("4 locally saved samples"), "\(summary)")
    }

    @Test func anEmptySparklineSaysSoRatherThanInventingNumbers() {
        let summary = String(localized: SparkTrendAccessibility.summary([]))
        #expect(summary.contains("0"), "\(summary)")
        #expect(!summary.contains("Latest"), "a summary was produced for no data")
    }

    // MARK: - Animated connection lines have static semantic descriptions

    @Test func theConnectionPulseCarriesNoMeaningOfItsOwn() {
        // Suppress decorative animation under Reduced Motion.
        #expect(
            !FleetMotion.shouldAnimateConnectionPulse(tone: .positive, reduceMotion: true)
        )
        #expect(
            FleetMotion.shouldAnimateConnectionPulse(tone: .positive, reduceMotion: false)
        )
        // Keep progress visible because it represents work in flight.
        #expect(FleetMotion.shouldShowCheckProgress(isChecking: true, reduceMotion: true))

        // Whatever the motion, the state is stated.
        let described = String(localized: LocalizedStringResource.connectionStatic("Ready"))
        #expect(described.contains("Ready"), "\(described)")
    }

    // MARK: - Focus order follows visual order

    @Test func focusOrderMatchesTheOrderTheCardIsDrawnIn() {
        #expect(FleetFocusOrder.follows(visualOrder: FleetFocusOrder.card))
        #expect(
            !FleetFocusOrder.follows(visualOrder: [.actions, .name, .connection, .activity]),
            "an order that puts actions first was accepted"
        )
        #expect(
            Set(FleetFocusOrder.card) == Set(FleetFocusOrder.Element.allCases),
            "an element of the card is missing from the declared focus order"
        )
    }

    /// The card applies these priorities, so VoiceOver reads name, connection, activity, then actions.
    @Test func focusPrioritiesDescendAlongTheDrawnOrder() {
        let priorities = FleetFocusOrder.card.map(FleetFocusOrder.priority(for:))
        #expect(
            priorities == priorities.sorted(by: >),
            "a later element would read before an earlier one"
        )
        #expect(Set(priorities).count == priorities.count, "two elements share a priority")
        #expect(priorities.allSatisfy { $0 > 0 }, "an element would fall back to layout order")
    }

    // MARK: - Confirmation buttons name the resource and action

    @Test func everyConsequentialConfirmationNamesItsResourceAndAction() {
        let resource = "Compact 8B"
        let cases: [(String, LocalizedStringResource)] = [
            ("Download", .downloadResource(resource)),
            ("Stop", .stopResource(resource)),
            ("Remove", .removeResource(resource)),
            ("Revoke", .revokeResource(resource)),
            ("Check", .checkResource(resource)),
        ]
        for (action, copy) in cases {
            let rendered = String(localized: copy)
            #expect(rendered.contains(action), "\(rendered) does not name the action")
            #expect(rendered.contains(resource), "\(rendered) does not name the resource")
        }
    }

    @Test func aDestructiveConfirmationSaysWhatWillHappen() {
        let rendered = String(localized: LocalizedStringResource.runningModelWillStop("Compact 8B"))
        #expect(rendered.contains("Compact 8B"))
        #expect(rendered.contains("will stop"), "\(rendered)")
    }

    // MARK: - Dynamic Type

    @Test func aHeaderStacksBeforeItsTextIsTruncated() {
        // Switch accessibility-size headers away from competing for a single line.
        #expect(OperationPresentation.prefersStackedHeader(usesAccessibilityTextSize: true))
        #expect(!OperationPresentation.prefersStackedHeader(usesAccessibilityTextSize: false))
    }
}

// MARK: - Presentation state is never recovered from rendered copy

/// Verifies that status colour derives from state rather than comparing localised display strings.
@MainActor
struct StatusTonePresentationTests {
    @Test func aStatusThatNeedsAttentionSaysSoInItsToneNotOnlyItsWords() {
        let attention = SparkStatusValue("Needs attention", tone: .attention)
        let calm = SparkStatusValue("Healthy")
        #expect(attention.tone == .attention)
        #expect(calm.tone == .normal)

        // Derive semantic tone independently of translated text.
        let translated = SparkStatusValue("Erfordert Aufmerksamkeit", tone: .attention)
        #expect(translated.tone == .attention)
        #expect(translated.tone == attention.tone)
    }

    @Test func everyToneIsReachableSoNoStateIsLeftWithoutOne() {
        #expect(SparkStatusTone.allCases.count == 2)
        #expect(Set(SparkStatusTone.allCases) == [.normal, .attention])
    }
}

// MARK: - A review blocker names the member it is about

/// Name the affected Spark in multi-member confirmation failures (§51.1).
@MainActor
struct ClusterReviewCopyTests {
    @Test func everyMemberBlockerNamesItsMember() {
        let member = "Studio Spark"
        let blockers: [LocalizedStringResource] = [
            .memberNotAuthenticated(member),
            .memberAnotherAuthority(member),
            .memberNoReciprocalProof(member),
            .memberIdentityMismatch(member),
            .memberDifferentAuthority(member),
            .memberAlreadyClustered(member),
            .pairedRouteUnavailable(member),
        ]
        for blocker in blockers {
            let rendered = String(localized: blocker)
            #expect(rendered.contains(member), "\(rendered) does not name its member")
        }
        // Distinct states must have distinguishable text labels.
        #expect(Set(blockers.map { String(localized: $0) }).count == blockers.count)
    }

    @Test func registrationSaysNoSparkWasChanged() {
        let rendered = String(localized: LocalizedStringResource.clusterAddedWithoutChange("Lab"))
        #expect(rendered.contains("Lab"))
        #expect(
            rendered.contains("without changing"),
            "the message must say the registration is device-local: \(rendered)"
        )
    }
}

/// §51.1: a confirmation names the resource it acts on, not just the verb.
@Test func removalAndForgetConfirmationsNameTheirResource() {
    #expect(
        String(localized: .removeFromThisDevice("Desk Spark"))
            == "Remove Desk Spark from this device"
    )
    #expect(String(localized: .forgetNetworkNamed("Studio Wi-Fi")) == "Forget Studio Wi-Fi")
    #expect(String(localized: .deleteChatNamed("Trip notes")) == "Delete Trip notes")
}

/// §51.1: reachability is stated in words, never by colour alone.
@Test func clusterMembersSayWhetherTheyAreReachable() {
    #expect(ClusterMemberCopy.reachability(true) == "Reachable")
    #expect(ClusterMemberCopy.reachability(false) == "Not reachable")
}
