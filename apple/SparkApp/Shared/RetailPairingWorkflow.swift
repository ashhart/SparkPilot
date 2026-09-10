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
final class RetailPairingWorkflow {
    var pairingDeviceTarget: DiscoveredSpark?
    var pairingDeviceError: String?
    var isPairingDevice = false
    var isBatchPairingDevice = false
    var batchRecipientRequestPayload: String?
    var batchPairingProgress: BatchPairingProgress?
    var batchPairingError: String?
    var batchPairingCoordinator: BatchAdditionalDevicePairingCoordinator?
    var pairingFailureDetail: String?
    var isPairing = false
    var pairingNeedsRuntimeReinstall = false
    private let connection: RetailSetupConnection
    private let session: RetailSetupSession
    private let pairingService: (any FirstOwnerPairingServicing)?
    private let additionalDevicePairingService: (any AdditionalDevicePairingServicing)?
    private let pairingJoinCodeRedeemer: any PairingJoinCodeRedeeming
    private let localDiscovery: SparkDiscoveryService
    private let library: SparkLibrary
    private let now: @Sendable () -> Date
    var cancelProbe: () -> Void = {}
    var completePairedSetup: (URL, NodeTrust) -> Void = { _, _ in }
    init(
        connection: RetailSetupConnection,
        session: RetailSetupSession,
        pairingService: (any FirstOwnerPairingServicing)?,
        additionalDevicePairingService: (any AdditionalDevicePairingServicing)?,
        pairingJoinCodeRedeemer: any PairingJoinCodeRedeeming,
        localDiscovery: SparkDiscoveryService,
        library: SparkLibrary,
        now: @escaping @Sendable () -> Date
    ) {
        self.connection = connection
        self.session = session
        self.pairingService = pairingService
        self.additionalDevicePairingService = additionalDevicePairingService
        self.pairingJoinCodeRedeemer = pairingJoinCodeRedeemer
        self.localDiscovery = localDiscovery
        self.library = library
        self.now = now
    }
    private var state: RetailOnboardingState {
        get { session.state }
        set { session.state = newValue }
    }
    private var isAddingSpark: Bool {
        get { session.isAddingSpark }
        set { session.isAddingSpark = newValue }
    }
    private var isChoosingSpark: Bool {
        get { session.isChoosingSpark }
        set { session.isChoosingSpark = newValue }
    }
    private var machineName: String {
        get { session.machineName }
        set { session.machineName = newValue }
    }
    private var administratorUsername: String? {
        get { session.administratorUsername }
        set { session.administratorUsername = newValue }
    }
    private var administratorPassword: String {
        get { session.administratorPassword }
        set { session.administratorPassword = newValue }
    }
    private var bootstrapTarget: BootstrapSpark? {
        get { session.bootstrapTarget }
        set { session.bootstrapTarget = newValue }
    }
    private var bootstrapResult: RuntimeBootstrapResult? {
        get { session.bootstrapResult }
        set { session.bootstrapResult = newValue }
    }
    private var selectedDiscoveryCandidate: DiscoveredSpark? {
        get { session.selectedDiscoveryCandidate }
        set { session.selectedDiscoveryCandidate = newValue }
    }
    private var pairedNode: NodeTrust? {
        get { session.pairedNode }
        set { session.pairedNode = newValue }
    }
    private var pairedRouteURL: URL? {
        get { session.pairedRouteURL }
        set { session.pairedRouteURL = newValue }
    }
    private func send(_ event: RetailOnboardingEvent) { session.send(event) }

    /// Leave additional-device pairing without changing the Spark or local library.
    func cancelPairingDevice() {
        guard !isPairingDevice else { return }
        pairingDeviceTarget = nil
        pairingDeviceError = nil
        selectedDiscoveryCandidate = nil
        isChoosingSpark = false
    }

    /// Create a recipient-bound handoff containing only this device's public identity.
    func beginBatchPairingDevice() {
        guard !isPairingDevice, let additionalDevicePairingService else {
            batchPairingError = String(localized: "Pairing is not available in this build.")
            return
        }
        do {
            let identity = try additionalDevicePairingService.recipientIdentity()
            let request = BatchPairingRecipientRequest(recipient: identity, createdAt: now())
            let coordinator = BatchAdditionalDevicePairingCoordinator(identity: identity) {
                package,
                route in
                try await additionalDevicePairingService.claim(package, route: route)
            }
            batchRecipientRequestPayload = try request.payload(now: now())
            batchPairingCoordinator = coordinator
            batchPairingProgress = nil
            batchPairingError = nil
            isBatchPairingDevice = true
            isChoosingSpark = false
            localDiscovery.stop()
        } catch {
            batchPairingError = String(
                localized: "This device could not prepare its secure pairing identity."
            )
        }
    }

    func pairSeveralSparks(payload: String) async {
        guard !isPairingDevice, let batchPairingCoordinator else { return }
        isPairingDevice = true
        batchPairingError = nil
        defer { isPairingDevice = false }
        do {
            let result = try await batchPairingCoordinator.accept(payload: payload)
            batchPairingProgress = result.progress
            reconcileBatchGrants(result)
            if result.failedCount > 0 {
                batchPairingError = String(
                    localized: "Some Sparks could not be paired. Retry only the failed Sparks."
                )
            }
        } catch {
            batchPairingError = RetailOnboardingFailurePresentation.describe(
                batchPairingError: error
            )
        }
    }

    func retryBatchPairing(nodeID: String) async {
        guard !isPairingDevice, let coordinator = batchPairingCoordinator,
            let batchID = batchPairingProgress?.batchID
        else { return }
        isPairingDevice = true
        defer { isPairingDevice = false }
        do {
            let result = try await coordinator.retry(batchID: batchID, nodeID: nodeID)
            batchPairingProgress = result.progress
            reconcileBatchGrants(result)
            batchPairingError = result.failedCount == 0 ? nil : batchPairingError
        } catch {
            batchPairingError = RetailOnboardingFailurePresentation.describe(
                batchPairingError: error
            )
        }
    }

    func cancelBatchPairingDevice() {
        guard !isPairingDevice else { return }
        isBatchPairingDevice = false
        batchRecipientRequestPayload = nil
        batchPairingProgress = nil
        batchPairingError = nil
        batchPairingCoordinator = nil
    }

    func reconcileBatchGrants(_ result: BatchPairingRunResult) {
        for (nodeID, trust) in result.grants {
            guard let target = result.progress.targets.first(where: { $0.id == nodeID }),
                let route = target.target.package.localHintURL,
                let uuid = UUID(uuidString: trust.nodeID)
            else { continue }
            let authenticated = AuthenticatedTarget(
                nodeID: SparkNodeID(rawValue: uuid),
                clusterID: nil,
                name: trust.nodeName,
                role: .standalone,
                authorityFingerprint: trust.authorityFingerprint,
                displayName: trust.nodeName,
                routes: [
                    CachedRoute(
                        baseURL: route,
                        kind: .localWiFi,
                        peerFingerprint: trust.tlsFingerprint,
                        lastSuccess: now()
                    )
                ],
                reachedAt: now()
            )
            _ = SparkIntentEntityReconciler.reconcile(authenticated, into: library)
        }
    }

    /// Resume first-owner setup using Bonjour only for addressing; SSH confirmation and the signed installer establish trust.
    func finishInterruptedFirstOwnerSetup() {
        guard !isPairingDevice, let target = pairingDeviceTarget else { return }

        cancelProbe()
        localDiscovery.stop()
        state = RetailOnboardingState(phase: .runtimeInstall)
        isChoosingSpark = false
        isAddingSpark = true
        pairingDeviceTarget = nil
        pairingDeviceError = nil
        selectedDiscoveryCandidate = target
        bootstrapTarget = BootstrapSpark(
            displayName: target.displayName,
            endpoint: target.endpoint
        )
        machineName = target.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: ".local",
                with: "",
                options: [.caseInsensitive, .anchored]
            )
        administratorUsername = nil
        administratorPassword = ""
        bootstrapResult = nil
        pairingNeedsRuntimeReinstall = false
    }

    /// Trust the owner's pairing QR package; use Bonjour only as an address hint.
    func pairThisDevice(payload: String) async {
        guard !isPairingDevice, additionalDevicePairingService != nil else {
            pairingDeviceError = String(localized: "Pairing is not available in this build.")
            return
        }

        let package: AdditionalDevicePairingPackage
        do {
            package = try AdditionalDevicePairingPackage(qrPayload: payload)
        } catch {
            pairingDeviceError =
                String(
                    localized:
                        "That is not a Spark pairing invitation. Ask the owner to create a new code."
                )
            return
        }
        guard package.isLocallyPlausible(now: now()) else {
            pairingDeviceError = String(
                localized: "That invitation has expired. Ask the owner to create a new one."
            )
            return
        }
        guard let target = pairingDeviceTarget else {
            // A guest joining from a link has no Bonjour discovery, so the signed routes carry the join.
            await joinSharedAccess(package)
            return
        }
        guard discoveryHint(target.shortNodeID, matches: package.invitation.nodeID) else {
            pairingDeviceError =
                String(localized: .invitationWrongSpark(target.displayName))
            return
        }
        guard let route = pairingRoute(target: target, package: package) else {
            pairingDeviceError =
                String(
                    localized:
                        "This Spark did not provide a safe local address. Ask the owner to create a new invitation."
                )
            return
        }

        isPairingDevice = true
        pairingDeviceError = nil
        defer { isPairingDevice = false }
        await claimAdditionalDevice(package, target: target, route: route)
    }

    /// Try the signed local route, then the tailnet route, and say which path failed.
    func joinSharedAccess(_ package: AdditionalDevicePairingPackage) async {
        guard let service = additionalDevicePairingService else {
            pairingDeviceError = String(localized: "Pairing is not available in this build.")
            return
        }
        let routes = SharedAccessJoin.candidateRoutes(for: package)
        guard !routes.isEmpty else {
            pairingDeviceError = SharedAccessJoin.unreachableMessage(tried: routes)
            return
        }
        isPairingDevice = true
        pairingDeviceError = nil
        defer { isPairingDevice = false }
        var lastError: (any Error)?
        for route in routes {
            do {
                let trust = try await service.claim(package, route: route.url)
                guard trust.nodeID.lowercased() == package.invitation.nodeID.lowercased() else {
                    throw AdditionalDevicePairingError.grantForAnotherSpark
                }
                pairedNode = trust
                pairedRouteURL = route.url
                machineName = trust.nodeName
                completePairedSetup(route.url, trust)
                pairingDeviceTarget = nil
                selectedDiscoveryCandidate = nil
                return
            } catch let error as AdditionalDevicePairingError
                where error == .grantForAnotherSpark
            {
                pairingDeviceError = RetailOnboardingFailurePresentation.describe(
                    additionalPairingError: error
                )
                return
            } catch {
                lastError = error
            }
        }
        pairingDeviceError =
            SharedAccessJoin.reachabilityFailure(lastError)
            ? SharedAccessJoin.unreachableMessage(tried: routes)
            : RetailOnboardingFailurePresentation.describe(
                additionalPairingError: lastError
                    ?? AdditionalDevicePairingError.grantForAnotherSpark
            )
    }

    func pairThisDevice(joinCode rawCode: String, trustedFingerprint: String? = nil) async {
        guard !isPairingDevice,
            let target = pairingDeviceTarget,
            additionalDevicePairingService != nil
        else {
            pairingDeviceError = String(localized: "Pairing is not available in this build.")
            return
        }
        let code = rawCode.filter { !$0.isWhitespace }
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            pairingDeviceError = String(
                localized: "Enter the six-digit code shown on your paired Apple device."
            )
            return
        }
        guard let route = joinCodeRoute(target: target) else {
            pairingDeviceError =
                String(
                    localized:
                        "This Spark did not provide a usable local address. Choose it again or enter its IP address."
                )
            return
        }

        isPairingDevice = true
        pairingDeviceError = nil
        defer { isPairingDevice = false }
        do {
            let package: AdditionalDevicePairingPackage
            if let trustedFingerprint {
                guard
                    let fingerprint = HTTPSPairingJoinCodeRedeemer.normalizedFingerprint(
                        trustedFingerprint
                    )
                else {
                    throw PairingJoinCodeError.invalidFingerprint
                }
                package = try await pairingJoinCodeRedeemer.redeem(
                    code: code,
                    route: route,
                    trustedFingerprint: fingerprint
                )
            } else {
                package = try await pairingJoinCodeRedeemer.redeem(code: code, route: route)
            }
            guard discoveryHint(target.shortNodeID, matches: package.invitation.nodeID) else {
                pairingDeviceError =
                    String(localized: .joinCodeWrongSpark(target.displayName))
                return
            }
            await claimAdditionalDevice(package, target: target, route: route)
        } catch {
            pairingDeviceError = RetailOnboardingFailurePresentation.describe(joinCodeError: error)
        }
    }

    func claimAdditionalDevice(
        _ package: AdditionalDevicePairingPackage,
        target: DiscoveredSpark,
        route: URL
    ) async {
        guard let additionalDevicePairingService else {
            pairingDeviceError = String(localized: "Pairing is not available in this build.")
            return
        }
        do {
            let trust = try await additionalDevicePairingService.claim(package, route: route)
            guard trust.nodeID.lowercased() == package.invitation.nodeID.lowercased() else {
                throw AdditionalDevicePairingError.grantForAnotherSpark
            }
            pairedNode = trust
            pairedRouteURL = route
            machineName = trust.nodeName
            completePairedSetup(route, trust)
            pairingDeviceTarget = nil
            selectedDiscoveryCandidate = nil
        } catch {
            pairingDeviceError = RetailOnboardingFailurePresentation.describe(
                additionalPairingError: error
            )
        }
    }

    /// Claim the installer's first-owner invitation when the securing phase begins.
    func pairFirstOwner() async {
        guard state.phase == .securing, !isPairing else { return }
        guard let pairingService, let bootstrapResult else {
            send(.failed(.pairingFailed))
            return
        }
        guard let route = pairedRoute(for: bootstrapResult) else {
            send(.failed(.pairingFailed))
            return
        }

        isPairing = true
        defer {
            isPairing = false
        }

        do {
            let trust = try await pairingService.claim(bootstrapResult, route: route)
            pairedNode = trust
            pairedRouteURL = route
            self.bootstrapResult = nil
            // Erase the in-memory SSH credential immediately after this device becomes trusted.
            administratorPassword = ""
            pairingNeedsRuntimeReinstall = false
            send(.pairingCompleted)
        } catch {
            pairingNeedsRuntimeReinstall =
                RetailOnboardingFailurePresentation.needsRuntimeReinstall(after: error)
            if !RetailOnboardingFailurePresentation.shouldRetainAdministratorPassword(after: error)
            {
                administratorPassword = ""
            }
            pairingFailureDetail = RetailOnboardingFailurePresentation.describe(pairingError: error)
            send(.failed(.pairingFailed))
        }
    }

    /// Use the matched local address with the installer's TLS pin so a wrong endpoint never receives the invitation.
    func pairedRoute(for bootstrap: RuntimeBootstrapResult) -> URL? {
        let host: String
        if let bootstrapTarget {
            host = SSHRuntimeBootstrapInstaller.hostName(for: bootstrapTarget)
        } else {
            let name = normalisedMachineName
            guard !name.isEmpty else { return nil }
            host = "\(name).local"
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = 7443
        return components.url
    }

    func discoveryHint(_ hint: String?, matches nodeID: String) -> Bool {
        guard let hint = hint?.lowercased(), !hint.isEmpty else { return true }
        let compactNodeID = nodeID.lowercased().replacingOccurrences(of: "-", with: "")
        return compactNodeID.hasPrefix(hint.replacingOccurrences(of: "-", with: ""))
    }

    func pairingRoute(
        target: DiscoveredSpark,
        package: AdditionalDevicePairingPackage
    ) -> URL? {
        if case .hostPort(let host, let port) = target.endpoint {
            var components = URLComponents()
            components.scheme = "https"
            components.host = Self.urlHost(host)
            components.port = Int(port.rawValue)
            if let route = components.url { return route }
        }
        // Use the owner's recorded address only as a routing hint; the pairing package's TLS pin establishes trust.
        if let hint = package.localHintURL { return hint }
        for raw in [package.invitation.localEndpoint, package.invitation.remoteEndpoint] {
            guard let raw, let route = URL(string: raw),
                route.scheme?.lowercased() == "https",
                route.user == nil,
                route.password == nil,
                route.host != nil
            else { continue }
            return route
        }
        return nil
    }

    func joinCodeRoute(target: DiscoveredSpark) -> URL? {
        switch target.endpoint {
        case .hostPort(let host, let port):
            var components = URLComponents()
            components.scheme = "https"
            components.host = Self.urlHost(host)
            components.port = Int(port.rawValue)
            return components.url
        case .service(let name, _, _, _):
            let host = name.lowercased().hasSuffix(".local") ? name : "\(name).local"
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.port = 7443
            return components.url
        default:
            return nil
        }
    }

    private static func urlHost(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _): return name
        case .ipv4(let address):
            return "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case .ipv6(let address):
            let text = "\(address)".replacingOccurrences(of: "%", with: "%25")
            return "[\(text)]"
        @unknown default: return "\(host)"
        }
    }

    private var normalisedMachineName: String { connection.normalisedMachineName }
}
