import Foundation
import Observation
import CoreImage.CIFilterBuiltins
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkSecurity
import SwiftUI

public protocol SparkSettingsManaging: NetworkHandoffIdentityCheckerMaking {
    func identity(route: URL) async throws -> SparkIdentity
    func capabilities(route: URL) async throws -> SparkCapabilities
    func sparkSettings(route: URL) async throws -> GeneratedAPI.SparkSettingsSnapshot
    func wifiNetworks(route: URL) async throws -> GeneratedAPI.WifiNetworksSnapshot
    func storageBreakdown(route: URL) async throws -> GeneratedAPI.StorageBreakdown
    func models(route: URL) async throws -> ModelCatalogue
    func telemetry(route: URL) async throws -> TelemetrySnapshot
    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation
    func connectWifi(
        route: URL,
        request: GeneratedAPI.ConnectWifiRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func forgetWifi(
        route: URL,
        request: GeneratedAPI.ForgetWifiRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func configureLanIpv4(
        route: URL,
        request: GeneratedAPI.ConfigureLanIpv4Request,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func confirmNetworkChange(
        route: URL,
        configurationID: UUID,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func rollbackNetworkChange(
        route: URL,
        configurationID: UUID,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func configureDirectEthernet(
        route: URL,
        enabled: Bool,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func configureTravelAccessPoint(
        route: URL,
        request: GeneratedAPI.ConfigureTravelAccessPointRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func configureBluetooth(
        route: URL,
        request: GeneratedAPI.ConfigureBluetoothRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func setPowerProfile(
        route: URL,
        modeID: Int,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func installSoftwareUpdates(
        route: URL,
        request: GeneratedAPI.InstallSoftwareUpdatesRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func checkSoftwareUpdates(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func configureSystemTime(
        route: URL,
        request: GeneratedAPI.ConfigureSystemTimeRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func updateMemoryGuard(
        route: URL,
        request: GeneratedAPI.MemoryGuardSettings,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func updateModelIdlePolicy(
        route: URL,
        request: GeneratedAPI.ModelIdlePolicySettings,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func updateTelemetryConsent(
        route: URL,
        request: GeneratedAPI.TelemetryConsentSettings,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func cleanStorage(
        route: URL,
        request: GeneratedAPI.StorageCleanupRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
}

extension SparkAPIClient: SparkSettingsManaging {}

public struct PendingSparkNetworkChange: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case findingNewRoute
        case readyToKeep
    }

    public let configurationID: UUID
    public let label: String
    public let phase: Phase
    public let verifiedRoute: URL?

    public var canKeep: Bool {
        phase == .readyToKeep && verifiedRoute != nil
    }
}

/// Pairs a numbered install or update step with the job's start time for elapsed-progress display.
public struct RuntimeUpgradeStage: Equatable, Sendable {
    public let title: String
    public let step: Int
    public let total: Int
    public let startedAt: Date

    public init(title: String, step: Int, total: Int, startedAt: Date) {
        self.title = title
        self.step = max(1, step)
        self.total = max(1, total)
        self.startedAt = startedAt
    }

    public var fraction: Double {
        min(1, Double(step) / Double(total))
    }

    public var label: String {
        String(localized: .stepOfTotal(step, total))
    }

    // Sequence the bundled-release check, fixed SSH installation commands and runtime readiness wait.
    public static let sshTotal = 16

    public static func sshPreparing(startedAt: Date) -> Self {
        Self(
            title: String(localized: "Checking the signed runtime package"),
            step: 1,
            total: sshTotal,
            startedAt: startedAt
        )
    }

    public static func ssh(_ command: BootstrapCommand, startedAt: Date) -> Self {
        Self(
            title: command.summary,
            step: sshStep(for: command),
            total: sshTotal,
            startedAt: startedAt
        )
    }

    public static func sshWaitingForRuntime(startedAt: Date) -> Self {
        Self(
            title: String(localized: "Waiting for Spark Runtime to come online"),
            step: sshTotal,
            total: sshTotal,
            startedAt: startedAt
        )
    }

    /// The installer's command order (`RuntimeBootstrapInstaller.applyRelease`).
    static func sshStep(for command: BootstrapCommand) -> Int {
        switch command {
        case .surveyHost: 2
        case .prepareWorkDirectory: 3
        case .receiveFile(let file):
            switch file {
            case .package: 4
            case .signature: 5
            case .publicKey: 6
            case .manifest: 7
            }
        case .verifyDigest: 8
        case .verifyDetachedSignature: 9
        case .verifyAgainstInstalledTrustRoot: 10
        case .installPackage: 11
        case .installRecommendedTools: 12
        case .enablePrivilegedHelper: 13
        case .enableRuntime: 14
        case .bootstrapOwner, .cleanUp: 15
        }
    }

    // The signed update through paired approval.
    public enum SignedStep: Int, CaseIterable, Sendable {
        case verifying = 1
        case approving
        case sending
        case scheduling
        case restarting

        var title: String {
            switch self {
            case .verifying: String(localized: "Checking the signed runtime package")
            case .approving: String(localized: "Waiting for your approval")
            case .sending: String(localized: "Sending the release to the Spark")
            case .scheduling: String(localized: "The Spark is scheduling the update")
            case .restarting: String(localized: "The Spark is restarting Spark Runtime")
            }
        }
    }

    public static func signed(_ step: SignedStep, startedAt: Date) -> Self {
        Self(
            title: step.title,
            step: step.rawValue,
            total: SignedStep.allCases.count,
            startedAt: startedAt
        )
    }

    /// Uses operation stage names returned by the runtime during polling.
    public static func signed(operationStage: String?, startedAt: Date) -> Self? {
        switch operationStage {
        case "runtime_update_scheduling": signed(.scheduling, startedAt: startedAt)
        case "runtime_update_restarting": signed(.restarting, startedAt: startedAt)
        default: nil
        }
    }
}

struct RuntimeUpgradeProgressView: View {
    let stage: RuntimeUpgradeStage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: stage.fraction) {
                Text(stage.title)
            } currentValueLabel: {
                HStack {
                    Text(stage.label)
                    Spacer()
                    Text(stage.startedAt, style: .timer)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(
                "This takes a few minutes. Keep SparkPilot open; the Spark restarts its runtime near the end and SparkPilot reconnects on its own."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: .sentencePair(stage.label, stage.title)))
    }
}

enum SparkSettingsProgressPresentation {
    static func globalMutationLabel(
        activeMutation: String?,
        runtimeUpgradeProgress: String?
    ) -> String? {
        runtimeUpgradeProgress == nil ? activeMutation : nil
    }
}

enum NetworkHandoffError: Error, Equatable {
    case identityMismatch
    case timedOut
}

struct CachedSparkSettings: Codable, Sendable {
    let settings: GeneratedAPI.SparkSettingsSnapshot
    let wifi: GeneratedAPI.WifiNetworksSnapshot?
    let storage: GeneratedAPI.StorageBreakdown?
}

actor DeviceLocalSparkSettingsCache {
    static let shared = DeviceLocalSparkSettingsCache()

    func load(route: URL) -> CachedSparkSettings? {
        guard let data = UserDefaults.standard.data(forKey: key(route)) else { return nil }
        return try? JSONDecoder().decode(CachedSparkSettings.self, from: data)
    }

    func save(_ snapshot: CachedSparkSettings, route: URL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key(route))
    }

    func key(_ route: URL) -> String {
        let encoded = Data(route.absoluteString.utf8).base64EncodedString()
        return "spark.settings.v1." + encoded
    }
}
