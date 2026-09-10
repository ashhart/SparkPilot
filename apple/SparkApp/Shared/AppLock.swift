import Foundation
import LocalAuthentication
import Observation
import SwiftUI

public enum AppLockMethod: Sendable, Equatable {
    case faceID
    case touchID
    case opticID
    case devicePasscode

    public var title: String {
        switch self {
        case .faceID: String(localized: "Face ID or device passcode")
        case .touchID: String(localized: "Touch ID or device passcode")
        case .opticID: String(localized: "Optic ID or device passcode")
        case .devicePasscode: String(localized: "device passcode")
        }
    }

    public var unlockTitle: String {
        switch self {
        case .faceID: String(localized: "Unlock with Face ID")
        case .touchID: String(localized: "Unlock with Touch ID")
        case .opticID: String(localized: "Unlock with Optic ID")
        case .devicePasscode: String(localized: "Unlock with passcode")
        }
    }

    public var symbol: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .devicePasscode: "lock.open"
        }
    }
}

public enum AppLockAuthenticationError: Error, Sendable, Equatable {
    case cancelled
    case unavailable
    case failed
}

@MainActor
public protocol AppLockAuthenticating: AnyObject {
    func availableMethod() -> AppLockMethod
    func authenticate(reason: String) async throws
}

@MainActor
public final class SystemAppLockAuthenticator: AppLockAuthenticating {
    public init() {}

    public func availableMethod() -> AppLockMethod {
        let context = LAContext()
        var error: NSError?
        guard
            context.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                error: &error
            )
        else {
            return .devicePasscode
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        case .none: return .devicePasscode
        @unknown default: return .devicePasscode
        }
    }

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        context.localizedFallbackTitle = String(localized: "Use Passcode")

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw AppLockAuthenticationError.unavailable
        }

        do {
            guard
                try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason
                )
            else {
                throw AppLockAuthenticationError.failed
            }
        } catch let error as LAError {
            switch error.code {
            case .appCancel, .systemCancel, .userCancel:
                throw AppLockAuthenticationError.cancelled
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                throw AppLockAuthenticationError.unavailable
            default:
                throw AppLockAuthenticationError.failed
            }
        } catch let error as AppLockAuthenticationError {
            throw error
        } catch {
            throw AppLockAuthenticationError.failed
        }
    }
}

@MainActor
@Observable
public final class AppLockModel {
    public static let enabledKey = "spark.app-lock.enabled.v1"

    public private(set) var isEnabled: Bool
    public private(set) var isLocked: Bool
    public private(set) var isAuthenticating = false
    public private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let authenticator: any AppLockAuthenticating
    private var automaticUnlockPending = true
    private var sceneIsActive = false
    private var backgroundGeneration: UInt64 = 0

    public init(
        defaults: UserDefaults = .standard,
        authenticator: any AppLockAuthenticating = SystemAppLockAuthenticator()
    ) {
        self.defaults = defaults
        self.authenticator = authenticator
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.isLocked = defaults.bool(forKey: Self.enabledKey)
    }

    public var method: AppLockMethod { authenticator.availableMethod() }

    public func unlock() async {
        guard isEnabled, isLocked, !isAuthenticating else { return }
        // Require another button press after biometric cancellation because the authentication sheet itself changes scene activity.
        automaticUnlockPending = false
        let generation = backgroundGeneration
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        do {
            try await authenticator.authenticate(reason: String(localized: "Unlock SparkPilot"))
            guard generation == backgroundGeneration else { return }
            isLocked = false
        } catch AppLockAuthenticationError.cancelled {
            // Retain the opaque lock screen after cancellation until the owner retries.
        } catch AppLockAuthenticationError.unavailable {
            errorMessage =
                String(
                    localized:
                        "Set a device passcode, Face ID, or Touch ID in Settings before using app lock."
                )
        } catch {
            errorMessage = String(
                localized: "SparkPilot could not verify that it is you. Try again."
            )
        }
    }

    public func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled, !isAuthenticating else { return }
        automaticUnlockPending = false
        let generation = backgroundGeneration
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        do {
            let reason =
                enabled
                ? String(localized: "Turn on app lock") : String(localized: "Turn off app lock")
            try await authenticator.authenticate(reason: reason)
            guard generation == backgroundGeneration else { return }
            isEnabled = enabled
            isLocked = false
            defaults.set(enabled, forKey: Self.enabledKey)
        } catch AppLockAuthenticationError.cancelled {
            // Keep the existing setting.
        } catch AppLockAuthenticationError.unavailable {
            errorMessage =
                String(
                    localized:
                        "Set a device passcode, Face ID, or Touch ID in Settings before using app lock."
                )
        } catch {
            errorMessage = String(
                localized:
                    "SparkPilot could not verify that it is you. The setting was not changed."
            )
        }
    }

    func unlockAutomatically() async {
        guard sceneIsActive, automaticUnlockPending else { return }
        await unlock()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        sceneIsActive = phase == .active
        switch phase {
        case .active: break
        case .inactive:
            appBecameInactive()
        case .background:
            // Allow automatic reprompting only after a real background visit, excluding biometric sheet transitions.
            automaticUnlockPending = true
            backgroundGeneration &+= 1
            appBecameInactive()
        @unknown default:
            appBecameInactive()
        }
    }

    public func appBecameInactive() {
        guard isEnabled else { return }
        isLocked = true
    }
}

public struct AppLockGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var model: AppLockModel
    private let content: Content

    public init(model: AppLockModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    public var body: some View {
        ZStack {
            content
                .environment(\.sparkPersonalAppLock, model)
                .allowsHitTesting(!model.isLocked)
                .accessibilityHidden(model.isLocked)

            if model.isLocked {
                lockScreen
                    .zIndex(1)
            }
        }
        .task {
            model.scenePhaseChanged(scenePhase)
            await model.unlockAutomatically()
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
            if phase == .active {
                Task { await model.unlockAutomatically() }
            }
        }
    }

    private var lockScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("SparkPilot is locked")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text("Unlock to manage your DGX Sparks.")
                    // Choose foreground contrast against the fixed black backdrop independently of system colour scheme.
                    .foregroundStyle(.white.opacity(0.75))

                Button {
                    Task { await model.unlock() }
                } label: {
                    Label(model.method.unlockTitle, systemImage: model.method.symbol)
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isAuthenticating)

                if model.isAuthenticating {
                    ProgressView()
                        .tint(.white)
                }
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
    }
}

public struct AppLockSettingsView: View {
    @Bindable private var model: AppLockModel

    public init(model: AppLockModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section("App lock") {
                LabeledContent("Status", value: model.isEnabled ? "On" : "Off")
                LabeledContent("Unlock with", value: model.method.title)

                Button(
                    model.isEnabled
                        ? String(localized: "Turn off app lock")
                        : String(localized: "Turn on app lock")
                ) {
                    Task { await model.setEnabled(!model.isEnabled) }
                }
                .disabled(model.isAuthenticating)

                if model.isAuthenticating {
                    HStack {
                        ProgressView()
                        Text("Waiting for confirmation")
                    }
                }
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text(
                    String(
                        localized:
                            "When app lock is on, SparkPilot locks when you switch apps or interrupt it, such as by opening Control Centre. It uses the security already set up on this device and does not store a separate PIN."
                    )
                )
            }
        }
        .navigationTitle("App lock")
    }
}

/// Authenticate intent entry points separately because they bypass the scene lock gate.
@MainActor
public enum SparkIntentAppLock {
    public static func authenticate() async throws {
        try await authenticate(defaults: .standard, authenticator: SystemAppLockAuthenticator())
    }

    static func authenticate(
        defaults: UserDefaults,
        authenticator: any AppLockAuthenticating
    ) async throws {
        guard defaults.bool(forKey: AppLockModel.enabledKey) else { return }
        try await authenticator.authenticate(reason: String(localized: "Unlock SparkPilot"))
    }

    /// Changing the model on a shared Spark needs a fresh presence proof even with app lock off.
    public static func authenticateModelChange() async throws {
        try await authenticateModelChange(authenticator: SystemAppLockAuthenticator())
    }

    static func authenticateModelChange(authenticator: any AppLockAuthenticating) async throws {
        try await authenticator.authenticate(
            reason: String(localized: "Confirm changing the model on your Spark")
        )
    }
}
