import Foundation
import SparkBootstrap
import SparkIntents
import SparkLibrary
import SparkSecurity

/// Builds bootstrap services with an embedded release trust root whose equality with packaging keys is checked by validate_contracts.py.
public enum BootstrapComposition {
    @MainActor private static var intentLibrary: SparkLibrary?

    @MainActor public static func refreshWidgetsInBackground() async {
        guard let intentLibrary else { return }
        await SparkWidgetBackgroundRefresh.run(library: intentLibrary)
    }

    /// Info.plist key naming the release manifest for this build's channel.
    public static let manifestURLKey = "SparkReleaseManifestURL"
    /// Read the NVIDIA-created administrator account from Info.plist with the configured DGX OS fallback.
    public static let administratorUsernameKey = "SparkAdministratorUsername"

    public enum CompositionError: Error, Equatable {
        case trustRootMissing
        case trustRootInvalid(String)
    }

    public static func failureDescription(for error: any Error) -> String {
        switch error {
        case is CompositionError:
            String(localized: .releaseTrustRootUnavailable("\(error)"))
        case is DeviceKeyError, is KeychainError:
            isMissingEntitlement(error)
                ? String(localized: .deviceIdentityTemporarilyUnavailable("\(error)"))
                : String(localized: .deviceIdentityUnavailable("\(error)"))
        default:
            String(
                localized:
                    "SparkPilot could not finish starting. Close and reopen the app, then try again."
            )
        }
    }

    /// errSecMissingEntitlement is transient on devices after updates and early launch; a retry, not an unlock, fixes it.
    static func isMissingEntitlement(_ error: any Error) -> Bool {
        let missingEntitlement: OSStatus = -34018
        switch error {
        case DeviceKeyError.keychainLookupFailed(let status),
            DeviceKeyError.keychainAddFailed(let status),
            DeviceKeyError.keychainDeleteFailed(let status):
            return status == missingEntitlement
        case KeychainError.unexpectedStatus(let status):
            return status == missingEntitlement
        default:
            return false
        }
    }

    /// Pass the embedded trust-root bundle explicitly because Bundle.module cannot be a public default argument.
    static var trustRootBundle: Bundle { .module }

    /// The trust root this build verifies releases against.
    public static func trustRoot(bundle: Bundle? = nil) throws -> ReleaseTrustRoot {
        let bundle = bundle ?? trustRootBundle
        guard let url = bundle.url(forResource: "release-keys", withExtension: "json") else {
            throw CompositionError.trustRootMissing
        }
        do {
            return try ReleaseTrustRoot.parse(try Data(contentsOf: url))
        } catch {
            throw CompositionError.trustRootInvalid("\(error)")
        }
    }

    /// Where the signed model catalogue is published; `Info.plist` names it so a build can point elsewhere.
    public static let catalogueURLKey = "SparkCatalogueURL"

    /// Returns a failing catalogue source when the build names no HTTPS location.
    public static func catalogueSource(bundle: Bundle = .main) -> any PublishedCatalogueSource {
        guard
            let raw = (bundle.object(forInfoDictionaryKey: catalogueURLKey) as? String)
                .flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
            !raw.isEmpty
        else {
            return UnconfiguredCatalogueSource()
        }
        guard let url = URL(string: raw) else {
            return UnconfiguredCatalogueSource(misconfigured: "\(catalogueURLKey) is not a URL")
        }
        guard url.scheme?.lowercased() == "https" else {
            return UnconfiguredCatalogueSource(
                misconfigured: "\(catalogueURLKey) must be https, not \(url.scheme ?? raw)"
            )
        }
        return HTTPSCatalogueSource(url: url)
    }

    /// Returns a failing release source when the build has no configured channel.
    public static func releaseSource(bundle: Bundle = .main) -> any ReleaseSource {
        guard
            let raw = (bundle.object(forInfoDictionaryKey: manifestURLKey) as? String)
                .flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
            !raw.isEmpty
        else {
            return UnconfiguredReleaseSource()
        }
        // Distinguish malformed release configuration from an absent release channel.
        guard let url = URL(string: raw) else {
            return UnconfiguredReleaseSource(misconfigured: "\(manifestURLKey) is not a URL")
        }
        guard url.scheme?.lowercased() == "https" else {
            return UnconfiguredReleaseSource(
                misconfigured:
                    "\(manifestURLKey) must be https, not \(url.scheme ?? url.absoluteString)"
            )
        }
        return HTTPSReleaseSource(manifestURL: url)
    }

    /// Provides an embedded signed release so first installation can run without internet access.
    static func bundledReleaseSource(bundle: Bundle? = nil) -> BundledReleaseSource? {
        let bundle = bundle ?? trustRootBundle
        let resourceURL: (String, String?) -> URL? = { name, extensionName in
            bundle.url(
                forResource: name,
                withExtension: extensionName,
                subdirectory: "RuntimeRelease"
            ) ?? bundle.url(forResource: name, withExtension: extensionName)
        }
        let packagesIn: (String?) -> [URL] = { subdirectory in
            let raw =
                bundle.urls(forResourcesWithExtension: "deb", subdirectory: subdirectory) ?? []
            let encoded =
                bundle.urls(forResourcesWithExtension: "b64", subdirectory: subdirectory) ?? []
            return raw + encoded.filter { $0.lastPathComponent.hasSuffix(".deb.b64") }
        }
        let nestedPackages = packagesIn("RuntimeRelease")
        let packages =
            nestedPackages.isEmpty
            ? packagesIn(nil)
            : nestedPackages
        // Find the release manifest by filename shape because its version and channel vary between releases.
        let nestedManifests =
            bundle.urls(forResourcesWithExtension: "json", subdirectory: "RuntimeRelease") ?? []
        let candidates: [URL]
        if nestedManifests.isEmpty {
            candidates = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        } else {
            candidates = nestedManifests
        }
        let manifests = candidates.filter { $0.lastPathComponent.hasPrefix("spark-runtime-") }
        guard
            manifests.count == 1,
            let manifest = manifests.first,
            packages.count == 1,
            let package = packages.first
        else { return nil }
        let packageName =
            package.pathExtension == "b64"
            ? package.deletingPathExtension().lastPathComponent : package.lastPathComponent
        guard let signature = resourceURL(packageName, "sig") else { return nil }
        return BundledReleaseSource(
            manifestURL: manifest,
            packageURL: package,
            signatureURL: signature
        )
    }

    public static func administratorUsername(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: administratorUsernameKey) as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "nvidia"
    }

    /// Install intent dependencies before scene tasks because Siri and Shortcuts may launch without a scene.
    @MainActor
    public static func prepareIntentServices(
        refreshShortcutParameters: @escaping @Sendable () -> Void = {}
    ) {
        guard intentLibrary == nil else { return }
        let library = SparkLibrary.appLibrary()
        library.load()
        intentLibrary = library
        SparkWidgetPublisher().publish(library: library, appLock: AppLockModel(), forceReload: true)
        IntentServices.install(
            SparkAppIntentService(library: library),
            refreshShortcutParameters: refreshShortcutParameters
        )
    }

    /// The installer the app ships with.
    public static func installer(
        hostKeyPolicy: HostKeyPolicy,
        bundle: Bundle = .main
    ) throws -> any RuntimeBootstrapInstalling {
        SSHRuntimeBootstrapInstaller(
            trustRoot: try trustRoot(),
            source: bundledReleaseSource() ?? releaseSource(bundle: bundle),
            hostKeyPolicy: hostKeyPolicy,
            username: administratorUsername(bundle: bundle)
        )
    }

    /// Assembles all onboarding dependencies or throws if the embedded release trust root cannot be read.
    @MainActor
    public static func onboardingModel(
        hostKeyCoordinator: HostKeyConfirmationCoordinator,
        deviceName: String,
        platform: String,
        onReady: @escaping @MainActor () -> Void = {}
    ) throws -> RetailOnboardingModel {
        prepareIntentServices()
        guard let intentLibrary else {
            preconditionFailure("Intent service preparation must create the app library.")
        }
        let hostKeyStore = KeychainHostKeyStore()
        let policy = HostKeyPolicy(
            store: hostKeyStore,
            confirmer: hostKeyCoordinator.confirmer
        )
        let presenceAuthorizer = SystemUserPresenceAuthorizer()
        let model = RetailOnboardingModel(
            runtimeInstaller: try installer(hostKeyPolicy: policy),
            hostKeyStore: hostKeyStore,
            pairingService: try pairingService(
                deviceName: deviceName,
                platform: platform,
                userPresenceAuthorizer: presenceAuthorizer
            ),
            additionalDevicePairingService: try additionalDevicePairingService(
                deviceName: deviceName,
                platform: platform,
                userPresenceAuthorizer: presenceAuthorizer
            ),
            library: intentLibrary,
            onReady: onReady
        )
        return model
    }

    /// The pairing service the app ships with.
    public static func pairingService(
        deviceName: String,
        platform: String,
        defaults: UserDefaults = .standard,
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer()
    ) throws -> any FirstOwnerPairingServicing {
        let signer = try DeviceKeyFactory.makeSigner()
        let deviceID = DeviceIdentityStore.loadOrCreateDeviceID(defaults: defaults)
        return SparkFirstOwnerPairingService(
            pairing: FirstOwnerPairing(
                signer: signer,
                deviceID: deviceID,
                deviceName: deviceName,
                platform: platform,
                userPresenceAuthorizer: userPresenceAuthorizer
            )
        )
    }

    /// Pair an Apple device through an invitation from an existing owner.
    public static func additionalDevicePairingService(
        deviceName: String,
        platform: String,
        defaults: UserDefaults = .standard,
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer()
    ) throws -> any AdditionalDevicePairingServicing {
        let signer = try DeviceKeyFactory.makeSigner()
        let deviceID = DeviceIdentityStore.loadOrCreateDeviceID(defaults: defaults)
        let identity = try BatchPairingParticipantIdentity(
            deviceID: deviceID,
            displayName: deviceName,
            platform: platform,
            publicKeySPKI: signer.publicKeySPKI
        )
        return SparkAdditionalDevicePairingService(
            pairing: FirstOwnerPairing(
                signer: signer,
                deviceID: deviceID,
                deviceName: deviceName,
                platform: platform,
                userPresenceAuthorizer: userPresenceAuthorizer
            ),
            identity: identity
        )
    }
}
