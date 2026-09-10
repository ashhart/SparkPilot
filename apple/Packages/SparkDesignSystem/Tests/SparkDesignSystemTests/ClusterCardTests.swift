import Foundation
import SparkDesignSystem
import Testing

/// §35.5: placement vocabulary stays plain and complete.
@Test func placementVocabularyMatchesTheSpec() {
    let vocabulary = ClusterPresentationResolver.placementVocabulary
    #expect(vocabulary.contains("Uses both Sparks"))
    #expect(vocabulary.contains("Requires both Sparks"))
    #expect(vocabulary.count == 4)
}

/// Keep single-Spark availability visible when distributed cluster service is degraded (§35.7).
@Test func clusterStatesExplainConsequences() {
    let ready = ClusterPresentationResolver.resolve(
        ClusterCardState(name: "Studio pair", state: .ready, members: [])
    )
    #expect(ready.title == "Studio pair")
    #expect(ready.detail.localizedCaseInsensitiveContains("both Sparks"))

    let degraded = ClusterPresentationResolver.resolve(
        ClusterCardState(name: nil, state: .degraded, members: [])
    )
    #expect(degraded.detail.localizedCaseInsensitiveContains("Single-Spark"))

    let failed = ClusterPresentationResolver.resolve(
        ClusterCardState(name: nil, state: .failed, members: [])
    )
    #expect(failed.detail.localizedCaseInsensitiveContains("cable"))

    for state in ClusterStateValue.allCases {
        let presentation = ClusterPresentationResolver.resolve(
            ClusterCardState(name: nil, state: state, members: [])
        )
        #expect(!presentation.title.isEmpty)
        #expect(!presentation.symbol.isEmpty)
    }
}

/// Member rows expose role in product language, not topology jargon.
@Test func memberRolesUseProductLanguage() {
    let state = ClusterCardState(
        name: "pair",
        state: .ready,
        members: [
            ClusterMemberValue(id: "a", name: "Spark A", role: "leader", reachable: true),
            ClusterMemberValue(id: "b", name: "Spark B", role: "worker", reachable: false),
        ]
    )
    #expect(state.reachableMembers == 1)
    #expect(state.members[0].role == "leader")
    #expect(!state.members[1].reachable)
}
