/// Model SparkPilot guidance around NVIDIA-owned first boot and the subsequent signed runtime install.
public enum RetailOnboardingPhase: String, CaseIterable, Sendable, Hashable {
    case connectToSpark
    case joiningSetupNetwork
    case sparkConnected
    case nvidiaSetup
    case reconnecting
    case rediscovering
    case finishingSparkSetup
    /// The Spark restarts after NVIDIA first boot; nothing is attempted over SSH until it answers again.
    case sparkRestarting
    case runtimeInstall
    case securing
    case starterModel
    case ready
}

/// Express recoverable onboarding failures without exposing SSH or network implementation jargon.
public enum RetailOnboardingIssue: String, Sendable, Hashable, CaseIterable {
    case localNetworkDenied
    case setupHotspotUnavailable
    case setupNetworkJoinDenied
    case nvidiaSetupInterrupted
    case homeNetworkUnavailable
    case sparkNotFoundAfterSetup
    case nvidiaFinalizationFailed
    /// The restart wait ran out before the Spark answered over SSH again.
    case sparkNotBackAfterRestart
    case runtimeInstallFailed
    case pairingFailed
    /// Retry authenticated identity verification from ready without minting an unverified library card.
    case identityUnavailable
    /// Report local signing-key access failure without implying completed installation or pairing failed.
    case deviceKeyUnavailable

    public var recoveryPhase: RetailOnboardingPhase {
        switch self {
        case .localNetworkDenied:
            return .connectToSpark
        case .setupHotspotUnavailable, .setupNetworkJoinDenied:
            return .connectToSpark
        case .nvidiaSetupInterrupted:
            return .nvidiaSetup
        case .homeNetworkUnavailable:
            return .reconnecting
        case .sparkNotFoundAfterSetup:
            return .rediscovering
        case .nvidiaFinalizationFailed:
            return .finishingSparkSetup
        case .sparkNotBackAfterRestart:
            return .sparkRestarting
        case .runtimeInstallFailed:
            return .runtimeInstall
        case .pairingFailed:
            return .securing
        case .identityUnavailable, .deviceKeyUnavailable:
            return .ready
        }
    }
}

public enum RetailOnboardingEvent: Sendable, Equatable {
    case setupNetworkSubmitted
    case setupNetworkJoined
    case connectionCelebrationFinished
    case setupHotspotDisappeared
    case retrySparkWiFi
    case homeNetworkAvailable
    case sparkDiscovered
    case nvidiaSetupCompleted
    /// The Spark answered over SSH after its first-boot restart.
    case sparkRestarted
    case runtimeInstalled
    /// Return to the signed runtime step to replace an expired first-owner invitation.
    case runtimeReinstallRequested
    case pairingCompleted
    case starterModelCompleted
    case starterModelSkipped
    case failed(RetailOnboardingIssue)
    case retry
    case back
}

public enum RetailOnboardingTransitionError: Error, Sendable, Equatable {
    case invalid(event: RetailOnboardingEvent, phase: RetailOnboardingPhase)
    case retryWithoutIssue
}

/// Keep onboarding transitions pure and free of Wi-Fi, administrator or pairing credentials.
public struct RetailOnboardingState: Sendable, Equatable {
    public private(set) var phase: RetailOnboardingPhase
    public private(set) var issue: RetailOnboardingIssue?
    public private(set) var completedPhases: Set<RetailOnboardingPhase>

    public init(
        phase: RetailOnboardingPhase = .connectToSpark,
        issue: RetailOnboardingIssue? = nil,
        completedPhases: Set<RetailOnboardingPhase> = []
    ) {
        self.phase = phase
        self.issue = issue
        self.completedPhases = completedPhases
    }

    public mutating func send(_ event: RetailOnboardingEvent) throws {
        if case .failed(let newIssue) = event {
            issue = newIssue
            return
        }

        if event == .retry {
            guard let issue else {
                throw RetailOnboardingTransitionError.retryWithoutIssue
            }
            self.issue = nil
            phase = issue.recoveryPhase
            return
        }

        if event == .back {
            guard issue == nil, let previousPhase else {
                throw RetailOnboardingTransitionError.invalid(event: event, phase: phase)
            }
            phase = previousPhase
            return
        }

        guard issue == nil else {
            throw RetailOnboardingTransitionError.invalid(event: event, phase: phase)
        }

        let next: RetailOnboardingPhase
        switch (phase, event) {
        case (.connectToSpark, .setupNetworkSubmitted):
            next = .joiningSetupNetwork
        case (.joiningSetupNetwork, .setupNetworkJoined):
            next = .sparkConnected
        case (.sparkConnected, .connectionCelebrationFinished):
            next = .nvidiaSetup
        case (.nvidiaSetup, .setupHotspotDisappeared):
            next = .reconnecting
        case (.reconnecting, .retrySparkWiFi):
            next = .nvidiaSetup
        case (.reconnecting, .homeNetworkAvailable):
            next = .rediscovering
        case (.rediscovering, .sparkDiscovered):
            next = .finishingSparkSetup
        case (.finishingSparkSetup, .nvidiaSetupCompleted):
            next = .sparkRestarting
        case (.sparkRestarting, .sparkRestarted):
            next = .runtimeInstall
        case (.runtimeInstall, .runtimeInstalled):
            next = .securing
        case (.securing, .runtimeReinstallRequested):
            next = .runtimeInstall
        case (.securing, .pairingCompleted):
            next = .starterModel
        case (.starterModel, .starterModelCompleted),
            (.starterModel, .starterModelSkipped):
            next = .ready
        default:
            throw RetailOnboardingTransitionError.invalid(event: event, phase: phase)
        }

        completedPhases.insert(phase)
        phase = next
    }

    public var canGoBack: Bool {
        issue == nil && previousPhase != nil
    }

    /// Allow back only before network handoff or irreversible claims; later phases expose explicit recovery actions.
    private var previousPhase: RetailOnboardingPhase? {
        switch phase {
        case .sparkConnected:
            return .connectToSpark
        case .nvidiaSetup:
            return .connectToSpark
        case .connectToSpark, .joiningSetupNetwork, .reconnecting, .rediscovering,
            .finishingSparkSetup, .sparkRestarting, .runtimeInstall, .securing, .starterModel,
            .ready:
            return nil
        }
    }
}
