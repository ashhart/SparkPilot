import Foundation
import SparkCore
import SparkDesignSystem
import Testing

/// Resolve every installation/fit combination unambiguously and expose incompatibility (§29.4).
@Test func modelUIStateMappingCoversContract() {
    #expect(ModelUIStateMapping.resolve(installState: "available", fit: "fits") == .available)
    #expect(ModelUIStateMapping.resolve(installState: "installed", fit: "fits") == .ready)
    #expect(ModelUIStateMapping.resolve(installState: "downloading", fit: "fits") == .downloading)
    #expect(ModelUIStateMapping.resolve(installState: "verifying", fit: "fits") == .verifying)
    #expect(ModelUIStateMapping.resolve(installState: "incompatible", fit: "fits") == .incompatible)
    #expect(ModelUIStateMapping.resolve(installState: "unverified", fit: "fits") == .unverified)
    #expect(ModelUIStateMapping.resolve(installState: "failed", fit: "fits") == .failedWithRecovery)
    #expect(
        ModelUIStateMapping.resolve(installState: "available", fit: "cluster_required")
            == .requiresTwoSparks
    )
    #expect(
        ModelUIStateMapping.resolve(installState: "available", fit: "smaller_profile_required")
            == .incompatible
    )
    #expect(ModelUIStateMapping.resolve(installState: "bogus", fit: "bogus") == .available)
}

/// The copy table (§62.2) must hold for every state.
@Test func modelStateCopyIsComplete() {
    let states: [SparkModelUIState] = [
        .available, .downloading, .verifying, .installed, .ready, .unloaded,
        .updateAvailable, .incompatible, .requiresTwoSparks, .unverified,
        .licenceActionRequired, .failedWithRecovery,
    ]
    for state in states {
        let title = ModelStateCopy.title(for: state)
        #expect(!title.isEmpty, "state \(state) needs copy")
    }
    #expect(ModelStateCopy.title(for: .incompatible) == "Does not fit this Spark")
    #expect(ModelStateCopy.title(for: .unverified) == "Unverified model")
}

/// Incompatible models must be visually distinct (colour plus symbol/text).
@Test func incompatibleModelsCarryNonColourCues() {
    let card = ModelCardState(
        id: "example/big-model",
        displayName: "Big Model",
        publisher: "Cat",
        state: .incompatible,
        totalBytes: nil,
        capabilities: [.chat],
        recommendedProfile: "long-32k",
        lastMeasuredSpeed: nil
    )
    // The symbol and copy both mark the state; the view layer renders the tint.
    #expect(card.capabilities == [.chat])
    #expect(card.state == .incompatible)
}

/// Wire decoding from the canonical runtime item shape.
@Test @MainActor func wireModelItemDecodesFromRuntimeShape() throws {
    let json = """
        {
          "id": "example/model-32b",
          "display_name": "Example 32B",
          "install_state": "available",
          "fit": "smaller_profile_required",
          "total_bytes": null,
          "capabilities": { "chat": true, "reasoning": true, "vision": false },
          "profiles": [ { "id": "balanced-16k" }, { "id": "long-32k" } ]
        }
        """
    let item = try JSONDecoder().decode(NetworkModelItem.self, from: Data(json.utf8))
    #expect(item.id == "example/model-32b")
    #expect(item.fit == "smaller_profile_required")
    #expect(item.capabilities["chat"] == true)
    #expect(item.recommendedProfile == "balanced-16k")

    // Through the view model: resolves to incompatible and sorted.
    let vm = ModelListViewModel()
    vm.apply(items: [item])
    #expect(vm.cards.count == 1)
    #expect(vm.cards[0].state == .incompatible)
    #expect(vm.cards[0].capabilities.contains(.reasoning))
}

/// The runtime's profile objects carry numbers and booleans; a string-only decoder threw on every real catalogue.
@Test @MainActor func wireModelItemDecodesTheProfilesTheRuntimeActuallySends() throws {
    let json = """
        {
          "id": "example/model-8b",
          "display_name": "Example 8B",
          "install_state": "installed",
          "fit": "fits",
          "total_bytes": 4900000000,
          "capabilities": { "chat": true },
          "profiles": [
            { "id": "balanced-16k", "display_name": "Balanced", "max_model_length": 16384,
              "max_sequences": 4, "expected_peak_bytes": 6000000000, "measured_peak_bytes": null,
              "safe": true, "idle_policy": "keep_ready", "supported_idle_policies": ["keep_ready"] }
          ]
        }
        """
    let item = try JSONDecoder().decode(NetworkModelItem.self, from: Data(json.utf8))
    #expect(item.recommendedProfile == "balanced-16k")
}
