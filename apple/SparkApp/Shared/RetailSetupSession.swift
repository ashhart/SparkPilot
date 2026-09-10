import Foundation
import Network
import Observation
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkDesignSystem
import SparkLibrary
import SparkIntents
import SparkSecurity
import SparkTransport
@MainActor
@Observable
final class RetailSetupSession {
    var state = RetailOnboardingState()
    var isAddingSpark = false
    var isChoosingSpark = false
    var machineName = ""
    var customLabel = ""
    var labelSaveFailed = false
    var administratorUsername: String?
    var administratorPassword = ""
    var bootstrapTarget: BootstrapSpark?
    var bootstrapResult: RuntimeBootstrapResult?
    var selectedDiscoveryCandidate: DiscoveredSpark?
    var pairedNode: NodeTrust?
    var pairedRouteURL: URL?

    func send(_ event: RetailOnboardingEvent) {
        do {
            try state.send(event)
        } catch {
            assertionFailure("Invalid retail onboarding transition: \(error)")
        }
    }
}
