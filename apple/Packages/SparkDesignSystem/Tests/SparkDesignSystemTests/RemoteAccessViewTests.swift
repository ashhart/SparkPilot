import Foundation
import SparkDesignSystem
import Testing

@Test func remotePresentationNamesTheTrustBoundary() {
    let overlay = RemoteAccessPresentationResolver.resolve(
        RemoteAccessCardState(enabled: true, mode: .privateOverlay, health: .healthy)
    )
    #expect(overlay.showsDisable)
    #expect(overlay.showsHostname)
    #expect(overlay.detail.localizedCaseInsensitiveContains("overlay"))
    #expect(overlay.detail.localizedCaseInsensitiveContains("device signature"))
    #expect(overlay.disableTitle == "Stop Using Private Route")

    let off = RemoteAccessPresentationResolver.resolve(
        RemoteAccessCardState(enabled: false, mode: .disabled, health: .disabled)
    )
    #expect(!off.showsDisable)
    #expect(!off.showsHostname)
}

/// Unhealthy remote states tell the owner local use continues.
@Test func unhealthyStatesExplainLocalFallback() {
    for mode in [RemoteAccessModeValue.privateOverlay] {
        for health in [RemoteAccessHealthValue.degraded, .failed] {
            let presentation = RemoteAccessPresentationResolver.resolve(
                RemoteAccessCardState(
                    enabled: true,
                    mode: mode,
                    health: health,
                    hostname: "a7f2.spark.example"
                )
            )
            #expect(presentation.showsDisable)
            #expect(
                presentation.detail.localizedCaseInsensitiveContains("locally"),
                "\(health) copy must mention local use"
            )
        }
    }
}

/// Explain the remote route before enabling it.
@Test func setupExplainsPrivateRemoteAccessInPlainLanguage() {
    let overlay = RemoteAccessPresentationResolver.modeExplanation(.privateOverlay)
    let off = RemoteAccessPresentationResolver.modeExplanation(.disabled)

    #expect(overlay.localizedCaseInsensitiveContains("overlay"))
    #expect(overlay.localizedCaseInsensitiveContains("relay"))
    #expect(overlay.localizedCaseInsensitiveContains("pins"))
    #expect(off.localizedCaseInsensitiveContains("local"))

    for text in [overlay, off] {
        #expect(!text.localizedCaseInsensitiveContains("tunnel"))
        #expect(!text.localizedCaseInsensitiveContains("ingress"))
        #expect(!text.localizedCaseInsensitiveContains("JWT"))
    }
}
