import Foundation
import Testing
@testable import SparkCore

@Test func operationStateRawValues() {
    #expect(SparkOperationState.succeeded.rawValue == "succeeded")
    #expect(SparkOperationState.waitingForApproval.rawValue == "waiting_for_approval")
}

@Test func identifiersAreHashableAndDecodable() throws {
    let node = SparkNodeID(rawValue: UUID(uuidString: "7a836150-16e1-46b5-8ac0-32b2a5f2f820")!)
    let data = try JSONEncoder().encode(node)
    let decoded = try JSONDecoder().decode(SparkNodeID.self, from: data)
    #expect(decoded == node)
}

@Test func roleAndTransportKinds() {
    #expect(SparkDeviceRole.developer.rawValue == "developer")
    #expect(SparkTransportKind.directEthernet.rawValue == "directEthernet")
    #expect(SparkInferenceState.unloaded.rawValue == "unloaded")
}

@Test func cachedInferencePreservesUnavailableQueueDepth() throws {
    let snapshot = ActiveInferenceSnapshot(
        state: .ready,
        modelIdentity: nil,
        profileID: "balanced",
        activeRequests: 2,
        queueDepth: nil,
        tokensPerSecond: 42.5,
        timeToFirstTokenMilliseconds: 210
    )

    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(ActiveInferenceSnapshot.self, from: encoded)
    #expect(decoded.queueDepth == nil)
}

@Test func errorEnvelopeMapping() {
    let e = SparkError.notPaired(requestID: "req-1")
    #expect(e.code == "DEVICE_NOT_PAIRED")
}

@Test func retailOnboardingFollowsSupportedFactoryFlow() throws {
    var state = RetailOnboardingState()
    let events: [RetailOnboardingEvent] = [
        .setupNetworkSubmitted,
        .setupNetworkJoined,
        .connectionCelebrationFinished,
        .setupHotspotDisappeared,
        .homeNetworkAvailable,
        .sparkDiscovered,
        .nvidiaSetupCompleted,
        .sparkRestarted,
        .runtimeInstalled,
        .pairingCompleted,
        .starterModelSkipped,
    ]

    for event in events {
        try state.send(event)
    }

    #expect(state.phase == .ready)
    #expect(state.issue == nil)
    #expect(state.completedPhases.contains(.nvidiaSetup))
    #expect(state.completedPhases.contains(.finishingSparkSetup))
    #expect(state.completedPhases.contains(.sparkRestarting))
    #expect(state.completedPhases.contains(.securing))
}

@Test func retailOnboardingFinishesNVIDIASetupAfterRediscovery() throws {
    var state = RetailOnboardingState(phase: .rediscovering)

    try state.send(.sparkDiscovered)
    #expect(state.phase == .finishingSparkSetup)

    try state.send(.nvidiaSetupCompleted)
    #expect(state.phase == .sparkRestarting, "the Spark restarts before anything is installed")

    try state.send(.sparkRestarted)
    #expect(state.phase == .runtimeInstall)
}

@Test func nothingIsInstalledUntilTheSparkAnswersAfterItsRestart() {
    var state = RetailOnboardingState(phase: .sparkRestarting)

    #expect(throws: RetailOnboardingTransitionError.self) {
        try state.send(.runtimeInstalled)
    }
    #expect(state.phase == .sparkRestarting)
}

@Test func aFailedWiFiHandoffReturnsToNVIDIASetup() throws {
    var state = RetailOnboardingState(phase: .reconnecting)

    try state.send(.retrySparkWiFi)

    #expect(state.phase == .nvidiaSetup)
}

@Test func retailOnboardingRetriesAtTheCorrectRecoveryStage() throws {
    var state = RetailOnboardingState(phase: .rediscovering)
    try state.send(.failed(.sparkNotFoundAfterSetup))

    #expect(state.issue == .sparkNotFoundAfterSetup)

    try state.send(.retry)
    #expect(state.phase == .rediscovering)
    #expect(state.issue == nil)
}

@Test func anExpiredPairingCanReturnToTheSignedRuntimeInstall() throws {
    var state = RetailOnboardingState(phase: .securing)
    try state.send(.failed(.pairingFailed))
    try state.send(.retry)
    try state.send(.runtimeReinstallRequested)

    #expect(state.phase == .runtimeInstall)
    #expect(state.issue == nil)
}

@Test func retailOnboardingRejectsOutOfOrderEvents() {
    var state = RetailOnboardingState()

    #expect(throws: RetailOnboardingTransitionError.self) {
        try state.send(.sparkDiscovered)
    }
}

@Test func retailOnboardingCanReturnFromProvisioningToConnection() throws {
    var state = RetailOnboardingState(phase: .nvidiaSetup)

    #expect(state.canGoBack)
    try state.send(.back)

    #expect(state.phase == .connectToSpark)
    #expect(state.issue == nil)
}

@Test func retailOnboardingShowsConnectionBeforeProvisioning() throws {
    var state = RetailOnboardingState(phase: .connectToSpark)

    try state.send(.setupNetworkSubmitted)
    try state.send(.setupNetworkJoined)
    #expect(state.phase == .sparkConnected)

    try state.send(.connectionCelebrationFinished)
    #expect(state.phase == .nvidiaSetup)
}

@Test func connectedConfirmationHasABackRouteToNetworkSelection() throws {
    var state = RetailOnboardingState()
    try state.send(.setupNetworkSubmitted)
    try state.send(.setupNetworkJoined)

    #expect(state.phase == .sparkConnected)
    #expect(state.canGoBack, "the connected confirmation must not trap the owner")

    try state.send(.back)
    #expect(state.phase == .connectToSpark)
}

@Test func backIsRefusedOncePairingIsUnderWayOrDone() throws {
    // Prevent back navigation while a claim completion could arrive in an incompatible phase.
    var securing = RetailOnboardingState(phase: .securing)
    #expect(!securing.canGoBack)
    #expect(throws: RetailOnboardingTransitionError.self) {
        try securing.send(.back)
    }

    // Prevent back navigation from repeating installation after a single-use ownership claim.
    var starterModel = RetailOnboardingState(phase: .starterModel)
    #expect(!starterModel.canGoBack)
    #expect(throws: RetailOnboardingTransitionError.self) {
        try starterModel.send(.back)
    }
}

@Test func backIsRefusedAfterTheSetupHotspotIsGivenUp() throws {
    for phase in [RetailOnboardingPhase.reconnecting, .rediscovering, .runtimeInstall] {
        var state = RetailOnboardingState(phase: phase)
        #expect(!state.canGoBack, "\(phase) has no reachable earlier screen")
        #expect(throws: RetailOnboardingTransitionError.self) {
            try state.send(.back)
        }
    }
}

@Test func everyPhaseWithoutBackStillHasARecoveryRoute() throws {
    // Provide a retry path for every phase that disables back navigation.
    let recoverable: [RetailOnboardingPhase: RetailOnboardingIssue] = [
        .reconnecting: .homeNetworkUnavailable,
        .rediscovering: .sparkNotFoundAfterSetup,
        .runtimeInstall: .runtimeInstallFailed,
        .securing: .pairingFailed,
        .finishingSparkSetup: .nvidiaFinalizationFailed,
        .sparkRestarting: .sparkNotBackAfterRestart,
    ]

    for (phase, issue) in recoverable {
        var state = RetailOnboardingState(phase: phase)
        #expect(!state.canGoBack)
        try state.send(.failed(issue))
        try state.send(.retry)
        #expect(state.phase == phase)
        #expect(state.issue == nil)
    }
}
