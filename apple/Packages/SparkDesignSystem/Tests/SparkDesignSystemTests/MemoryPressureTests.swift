import Foundation
import SparkCore
import SparkDesignSystem
import Testing

/// Present pressure recovery in plain language without OOM, PSI or container terminology (§33.5).
@Test func pressureMatrixPresentsRecoveryActions() {
    let normal = MemoryPressurePresentationResolver.resolve(.normal)
    #expect(normal == nil, "normal pressure shows no banner")

    let warning = MemoryPressurePresentationResolver.resolve(.warning)!
    #expect(!warning.title.isEmpty)
    #expect(warning.actions == [.wait])

    let critical = MemoryPressurePresentationResolver.resolve(.critical)!
    #expect(critical.actions.contains(.chooseSmallerModel))
    #expect(critical.actions.contains(.getDiagnostics))

    let emergency = MemoryPressurePresentationResolver.resolve(.emergency)!
    #expect(emergency.actions == [.chooseSmallerModel, .getDiagnostics])
}

/// Render complete recovery instructions instead of labels for controls without handlers.
@Test func recoveryGuidanceReadsAsAdviceNotAButtonCaption() {
    let actions: [MemoryRecoveryAction] = [.wait, .chooseSmallerModel, .getDiagnostics]
    for action in actions {
        let guidance = action.guidance
        #expect(!guidance.isEmpty)
        #expect(guidance.hasSuffix("."), "\(guidance) does not read as a sentence")
        #expect(guidance.split(separator: " ").count >= 4, "\(guidance) reads as a button label")
    }
}

/// Keep memory recovery guidance understandable without runtime terminology.
@Test func recoveryGuidanceAvoidsRuntimeVocabulary() {
    let leaked = ["oom", "psi", "container", "cgroup", "swap", "vllm"]
    for action in [MemoryRecoveryAction.wait, .chooseSmallerModel, .getDiagnostics] {
        let guidance = action.guidance.lowercased()
        for term in leaked {
            #expect(!guidance.contains(term), "\(action.guidance) leaks \"\(term)\"")
        }
    }
}

/// State that emergency recovery requires owner action and does not automatically restart the model (§33.6).
@Test func emergencyCopyExplainsNoAutomaticRestart() {
    let emergency = MemoryPressurePresentationResolver.resolve(.emergency)!
    #expect(
        emergency.message.localizedCaseInsensitiveContains("not restart on its own")
            || emergency.message.localizedCaseInsensitiveContains("will not restart"),
        "emergency copy must state there is no automatic restart"
    )
}

/// Copy stays plain: no kernel, OOM, PSI, or container jargon.
@Test func pressureCopyKeepsPlainLanguage() {
    for level in MemoryPressureLevel.allCases {
        guard let p = MemoryPressurePresentationResolver.resolve(level) else { continue }
        for text in [p.title, p.message] {
            #expect(!text.localizedCaseInsensitiveContains("OOM"))
            #expect(!text.localizedCaseInsensitiveContains("PSI"))
            #expect(!text.localizedCaseInsensitiveContains("kernel"))
            #expect(!text.localizedCaseInsensitiveContains("container"))
            #expect(!text.localizedCaseInsensitiveContains("vLLM"))
        }
    }
}

/// The card hides the banner unless pressure is known and not normal.
@Test func cardPressurePresentationFollowsLevel() {
    func card(_ level: MemoryPressureLevel?) -> NodeCardState {
        NodeCardState(
            nodeID: SparkNodeID(rawValue: UUID()),
            name: "n",
            connection: .connectedDirect,
            activeModel: nil,
            usedMemoryBytes: 0,
            totalMemoryBytes: 137_438_953_472,
            memoryPressure: level
        )
    }

    #expect(card(nil).pressurePresentation == nil)
    #expect(card(.normal).pressurePresentation == nil)
    #expect(card(.warning).pressurePresentation != nil)
    #expect(
        card(.emergency).pressurePresentation?.actions == [.chooseSmallerModel, .getDiagnostics]
    )
}

/// The API's four contract values all map onto levels.
@Test func pressureLevelMatchesContractValues() {
    #expect(MemoryPressureLevel(rawValue: "normal") == .normal)
    #expect(MemoryPressureLevel(rawValue: "warning") == .warning)
    #expect(MemoryPressureLevel(rawValue: "critical") == .critical)
    #expect(MemoryPressureLevel(rawValue: "emergency") == .emergency)
    #expect(
        MemoryPressureLevel(rawValue: "draining") == nil,
        "server-internal states never reach the API"
    )
}
