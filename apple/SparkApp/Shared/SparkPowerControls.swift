import Observation
import SparkAPI
import SparkSecurity
import SwiftUI

public protocol SparkPowerControlling: Sendable {
    func rebootSpark(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation

    func shutdownSpark(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
}

extension SparkAPIClient: SparkPowerControlling {}

public enum SparkPowerAction: String, Sendable, Hashable, Identifiable {
    case reboot
    case shutdown

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .reboot: String(localized: "Reboot Spark")
        case .shutdown: String(localized: "Shut Down Spark")
        }
    }

    var confirmationTitle: String {
        switch self {
        case .reboot: String(localized: "Reboot This Spark?")
        case .shutdown: String(localized: "Shut Down This Spark?")
        }
    }

    var confirmationMessage: String {
        switch self {
        case .reboot:
            String(
                localized:
                    "Your Spark will go offline for a few minutes while it restarts. The app will reconnect when it is ready."
            )
        case .shutdown:
            String(
                localized:
                    "Your Spark will turn off. You will need to press its physical power button to use it again."
            )
        }
    }

    var authorizationReason: String {
        switch self {
        case .reboot: String(localized: "Confirm rebooting this Spark.")
        case .shutdown: String(localized: "Confirm shutting down this Spark.")
        }
    }

    var acceptedMessage: String {
        switch self {
        case .reboot: String(localized: "Reboot requested. Reconnecting can take a few minutes.")
        case .shutdown:
            String(
                localized:
                    "Shutdown requested. Press the Spark’s physical power button to turn it back on."
            )
        }
    }
}

@MainActor
@Observable
public final class SparkPowerControlModel {
    public private(set) var pendingAction: SparkPowerAction?
    public private(set) var isSubmitting = false
    public private(set) var acceptedAction: SparkPowerAction?
    public private(set) var successMessage: String?
    public private(set) var errorMessage: String?
    public private(set) var lastOperation: SparkAPI.Operation?

    public let route: URL

    @ObservationIgnored
    private let runtime: any SparkPowerControlling
    @ObservationIgnored
    private let presenceEnrollmentProvider: (any DeviceManagementProviding)?
    @ObservationIgnored
    private let userPresenceAuthorizer: any UserPresenceAuthorizing
    @ObservationIgnored
    private var actionKeys: [SparkPowerAction: UUID] = [:]
    @ObservationIgnored
    private var presenceEnrollmentKey: UUID?

    public init(
        route: URL,
        runtime: any SparkPowerControlling,
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer()
    ) {
        self.route = route
        self.runtime = runtime
        self.presenceEnrollmentProvider = runtime as? any DeviceManagementProviding
        self.userPresenceAuthorizer = userPresenceAuthorizer
    }

    public func request(_ action: SparkPowerAction) {
        guard !isSubmitting else { return }
        pendingAction = action
        errorMessage = nil
    }

    public func cancelConfirmation() {
        pendingAction = nil
    }

    public func confirm() async {
        guard let action = pendingAction, !isSubmitting else { return }
        pendingAction = nil
        isSubmitting = true
        errorMessage = nil
        successMessage = nil
        defer { isSubmitting = false }

        let idempotencyKey = actionKeys[action] ?? UUID()
        actionKeys[action] = idempotencyKey
        do {
            let presence = try await userPresenceAuthorizer.authorize(
                localizedReason: action.authorizationReason
            )
            let operation = try await submit(
                action,
                idempotencyKey: idempotencyKey,
                userPresence: presence
            )
            lastOperation = operation
            actionKeys[action] = nil
            acceptedAction = action
            successMessage = action.acceptedMessage
        } catch {
            if Self.isDefinitiveRejection(error) {
                actionKeys[action] = nil
            }
            errorMessage = Self.describe(error, action: action)
        }
    }

    private func submit(
        _ action: SparkPowerAction,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        do {
            return try await call(
                action,
                idempotencyKey: idempotencyKey,
                userPresence: userPresence
            )
        } catch {
            guard (error as? APIError)?.code == "USER_PRESENCE_NOT_REGISTERED" else {
                throw error
            }
        }

        try await enrollPresenceKey()
        let retryPresence = try await userPresenceAuthorizer.authorize(
            localizedReason: action.authorizationReason
        )
        return try await call(
            action,
            idempotencyKey: idempotencyKey,
            userPresence: retryPresence
        )
    }

    private func call(
        _ action: SparkPowerAction,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        switch action {
        case .reboot:
            try await runtime.rebootSpark(
                route: route,
                idempotencyKey: idempotencyKey,
                userPresence: userPresence
            )
        case .shutdown:
            try await runtime.shutdownSpark(
                route: route,
                idempotencyKey: idempotencyKey,
                userPresence: userPresence
            )
        }
    }

    private func enrollPresenceKey() async throws {
        guard let presenceEnrollmentProvider else {
            throw APIError(
                .local(message: String(localized: "Presence-key enrollment is unavailable.")),
                code: "USER_PRESENCE_ENROLLMENT_UNAVAILABLE"
            )
        }
        let presence = try await userPresenceAuthorizer.authorize(
            localizedReason: String(
                localized: "Confirm upgrading protected actions for this Apple device."
            )
        )
        let idempotencyKey = presenceEnrollmentKey ?? UUID()
        presenceEnrollmentKey = idempotencyKey
        do {
            _ = try await presenceEnrollmentProvider.enrollPresenceKey(
                route: route,
                idempotencyKey: idempotencyKey,
                userPresence: presence
            )
            presenceEnrollmentKey = nil
        } catch {
            if Self.isDefinitiveRejection(error) {
                presenceEnrollmentKey = nil
            }
            throw error
        }
    }

    private static func isDefinitiveRejection(_ error: any Error) -> Bool {
        guard let status = (error as? APIError)?.statusCode else { return false }
        return (400...499).contains(status)
    }

    private static func describe(_ error: any Error, action: SparkPowerAction) -> String {
        if error is UserPresenceAuthorizationError {
            return String(
                localized: "Nothing changed. This Apple device could not confirm you are present."
            )
        }
        if let api = error as? APIError {
            switch api.code {
            case "USER_PRESENCE_REQUIRED", "USER_PRESENCE_INVALID", "USER_PRESENCE_EXPIRED",
                "USER_PRESENCE_NOT_REGISTERED", "USER_PRESENCE_SIGNER_UNAVAILABLE",
                "USER_PRESENCE_ENROLLMENT_UNAVAILABLE":
                return String(
                    localized:
                        "Nothing changed. This Apple device could not confirm you are present."
                )
            default:
                break
            }
            if api.statusCode == 401 || api.statusCode == 403 {
                return String(
                    localized: "Only the owner device can use this Spark’s power controls."
                )
            }
        }
        // Keep separate complete sentences so translators can inflect each action for its object.
        return action == .reboot
            ? String(
                localized:
                    "The Spark did not accept the request to reboot. Check the connection and try again."
            )
            : String(
                localized:
                    "The Spark did not accept the request to shut down. Check the connection and try again."
            )
    }
}

public struct SparkPowerControlsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable private var model: SparkPowerControlModel

    public init(model: SparkPowerControlModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Power")
                .font(.title2.bold())

            controls

            if model.isSubmitting {
                ProgressView(String(localized: "Sending securely…"))
            }
            // Indicate request acceptance rather than completion because this view does not poll the operation to a terminal state.
            if let successMessage = model.successMessage {
                Label(successMessage, systemImage: "paperplane.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .modifier(SparkPowerConfirmation(model: model))
    }

    @ViewBuilder
    private var controls: some View {
        if horizontalSizeClass == .compact {
            VStack(spacing: 12) {
                rebootButton
                shutdownButton
            }
        } else {
            HStack(spacing: 12) {
                rebootButton
                shutdownButton
            }
        }
    }

    private var rebootButton: some View {
        let copy = SparkPowerControlsPresentation.action(.reboot)
        return powerButton(
            title: copy.title,
            subtitle: copy.subtitle,
            symbol: "arrow.clockwise",
            action: .reboot,
            tint: .orange
        )
    }

    private var shutdownButton: some View {
        let copy = SparkPowerControlsPresentation.action(.shutdown)
        return powerButton(
            title: copy.title,
            subtitle: copy.subtitle,
            symbol: "power",
            action: .shutdown,
            tint: .red
        )
    }

    private func powerButton(
        title: String,
        subtitle: String,
        symbol: String,
        action: SparkPowerAction,
        tint: Color
    ) -> some View {
        Button {
            model.request(action)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: Circle())
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(model.isSubmitting)
        .accessibilityLabel(title)
        .accessibilityHint(action.confirmationMessage)
        .accessibilityIdentifier("spark.dashboard.power.\(action.rawValue)")
    }
}

/// Provides distinct power-action labels so colour is not required to distinguish the buttons.
enum SparkPowerControlsPresentation {
    struct Action: Equatable {
        let title: String
        let subtitle: String
    }

    static func action(_ action: SparkPowerAction) -> Action {
        switch action {
        case .reboot:
            Action(
                title: String(localized: "Reboot"),
                subtitle: String(localized: "Restart this Spark")
            )
        case .shutdown:
            Action(
                title: String(localized: "Shut Down"),
                subtitle: String(localized: "Turn this Spark off")
            )
        }
    }
}

/// The confirmation every power action goes through, shared by the Power card and the updates page.
public struct SparkPowerConfirmation: ViewModifier {
    @Bindable private var model: SparkPowerControlModel

    public init(model: SparkPowerControlModel) {
        self.model = model
    }

    public func body(content: Content) -> some View {
        content.alert(
            model.pendingAction?.confirmationTitle ?? String(localized: "Confirm Power Action"),
            isPresented: Binding(
                get: { model.pendingAction != nil },
                set: { if !$0 { model.cancelConfirmation() } }
            )
        ) {
            if let action = model.pendingAction {
                Button(action.title, role: .destructive) {
                    Task { await model.confirm() }
                }
            }
            Button("Cancel", role: .cancel) {
                model.cancelConfirmation()
            }
        } message: {
            if let action = model.pendingAction {
                Text(action.confirmationMessage)
            }
        }
    }
}
