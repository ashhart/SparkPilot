import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import SwiftUI

public protocol SparkHostnameControlling: Sendable {
    func setSparkHostname(
        route: URL,
        hostname: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation

    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation
}

extension SparkAPIClient: SparkHostnameControlling {}

@MainActor
@Observable
public final class SparkIdentitySettingsModel {
    public private(set) var displayName: String
    public private(set) var hostname: String
    public var draftLabel: String
    public var draftHostname: String
    public private(set) var isPresentingEditor = false
    public private(set) var pendingHostname: String?
    public private(set) var optimisticHostname: String?
    public private(set) var isChangingHostname = false
    public private(set) var labelMessage: String?
    public private(set) var hostnameMessage: String?
    public private(set) var errorMessage: String?
    public private(set) var canChangeHostname: Bool

    public let route: URL
    public let entryID: String
    public let nodeID: SparkNodeID

    @ObservationIgnored
    private let library: SparkLibrary
    @ObservationIgnored
    private let runtime: (any SparkHostnameControlling)?
    @ObservationIgnored
    private let userPresenceAuthorizer: any UserPresenceAuthorizing
    @ObservationIgnored
    private let operationDelay: @Sendable (Duration) async throws -> Void
    @ObservationIgnored
    private var hostnameIdempotencyKey: UUID?
    @ObservationIgnored
    private var presenceEnrollmentKey: UUID?
    @ObservationIgnored
    private let presenceEnrollmentProvider: (any DeviceManagementProviding)?

    public init(
        route: URL,
        entryID: String,
        nodeID: SparkNodeID,
        displayName: String,
        hostname: String?,
        library: SparkLibrary,
        runtime: (any SparkHostnameControlling)?,
        canChangeHostname: Bool,
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer(),
        operationDelay: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        let normalizedHostname = Self.normalizedHostname(hostname ?? "")
        self.route = route
        self.entryID = entryID
        self.nodeID = nodeID
        self.displayName = displayName
        self.hostname = normalizedHostname
        self.draftLabel = displayName
        self.draftHostname = normalizedHostname
        self.library = library
        self.runtime = runtime
        self.canChangeHostname = canChangeHostname
        self.userPresenceAuthorizer = userPresenceAuthorizer
        self.operationDelay = operationDelay
        self.presenceEnrollmentProvider = runtime as? any DeviceManagementProviding
    }

    public var hostnameForDisplay: String {
        let presentedHostname = optimisticHostname ?? hostname
        return presentedHostname.isEmpty
            ? String(localized: "Not reported") : "\(presentedHostname).local"
    }

    public var labelValidationMessage: String? {
        let trimmed = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 120 {
            return String(localized: "Use no more than 120 characters.")
        }
        return nil
    }

    public var hostnameValidationMessage: String? {
        Self.hostnameValidationMessage(for: Self.normalizedHostname(draftHostname))
    }

    public func presentEditor() {
        draftLabel = displayName
        draftHostname = hostname
        labelMessage = nil
        hostnameMessage = nil
        errorMessage = nil
        isPresentingEditor = true
    }

    public func dismissEditor() {
        guard !isChangingHostname else { return }
        pendingHostname = nil
        isPresentingEditor = false
    }

    public func setCanChangeHostname(_ allowed: Bool) {
        canChangeHostname = allowed
    }

    public func saveLabel() {
        guard labelValidationMessage == nil else { return }
        let trimmed = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard library.setCustomLabel(trimmed, for: entryID),
            let saved = library.entry(id: entryID)
        else {
            errorMessage = String(localized: "The name could not be saved on this device.")
            return
        }
        displayName = saved.displayName
        draftLabel = saved.displayName
        labelMessage =
            trimmed.isEmpty
            ? String(localized: "Using the name reported by the Spark.")
            : String(localized: "Name saved.")
        errorMessage = nil
    }

    public func requestHostnameChange() {
        let normalized = Self.normalizedHostname(draftHostname)
        draftHostname = normalized
        guard canChangeHostname else {
            errorMessage = String(localized: "Only the owner device can change the Spark hostname.")
            return
        }
        guard runtime != nil else {
            errorMessage = String(localized: "Connect to this Spark before changing its hostname.")
            return
        }
        guard let validation = Self.hostnameValidationMessage(for: normalized) else {
            if normalized == hostname {
                hostnameMessage = String(localized: .hostnameAlreadySet(normalized))
                return
            }
            pendingHostname = normalized
            errorMessage = nil
            return
        }
        errorMessage = validation
    }

    public func cancelHostnameChange() {
        pendingHostname = nil
    }

    public func confirmHostnameChange() async {
        guard let requested = pendingHostname,
            let runtime,
            !isChangingHostname
        else { return }
        pendingHostname = nil
        isChangingHostname = true
        hostnameMessage = nil
        errorMessage = nil
        defer { isChangingHostname = false }

        let idempotencyKey = hostnameIdempotencyKey ?? UUID()
        hostnameIdempotencyKey = idempotencyKey
        do {
            let presence = try await userPresenceAuthorizer.authorize(
                localizedReason: String(localized: "Confirm changing this Spark's hostname.")
            )
            optimisticHostname = requested
            var operation = try await submit(
                hostname: requested,
                idempotencyKey: idempotencyKey,
                userPresence: presence,
                runtime: runtime
            )
            operation = try await waitForCompletion(operation, runtime: runtime)
            guard operation.state == .succeeded else {
                throw APIError(
                    .local(message: String(localized: "The Spark did not change its hostname.")),
                    code: operation.errorCode ?? "HOSTNAME_CHANGE_FAILED"
                )
            }
            hostnameIdempotencyKey = nil
            _ = library.recordHostname(requested, for: entryID, nodeID: nodeID)
            hostname = requested
            draftHostname = requested
            optimisticHostname = nil
            hostnameMessage = String(localized: .hostnameChangedTo(requested))
        } catch {
            optimisticHostname = nil
            if Self.isDefinitiveRejection(error) {
                hostnameIdempotencyKey = nil
            }
            errorMessage = Self.describe(error)
        }
    }

    private func submit(
        hostname: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning,
        runtime: any SparkHostnameControlling
    ) async throws -> SparkAPI.Operation {
        do {
            return try await runtime.setSparkHostname(
                route: route,
                hostname: hostname,
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
            localizedReason: String(localized: "Confirm changing this Spark's hostname.")
        )
        return try await runtime.setSparkHostname(
            route: route,
            hostname: hostname,
            idempotencyKey: idempotencyKey,
            userPresence: retryPresence
        )
    }

    private func waitForCompletion(
        _ submitted: SparkAPI.Operation,
        runtime: any SparkHostnameControlling
    ) async throws -> SparkAPI.Operation {
        var operation = submitted
        for _ in 0..<60 {
            switch operation.state {
            case .succeeded, .failed, .cancelled:
                return operation
            default:
                try await operationDelay(.milliseconds(250))
                operation = try await runtime.operation(route: route, id: operation.id)
            }
        }
        throw APIError(
            .local(message: String(localized: "The hostname change is still running.")),
            code: "HOSTNAME_CHANGE_TIMEOUT"
        )
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

    private static func normalizedHostname(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".local.") {
            value.removeLast(7)
        } else if value.hasSuffix(".local") {
            value.removeLast(6)
        }
        return value
    }

    private static func hostnameValidationMessage(for hostname: String) -> String? {
        guard !hostname.isEmpty else { return String(localized: "Enter a hostname.") }
        guard hostname.utf8.count <= 63 else {
            return String(localized: "Use no more than 63 letters, numbers, or hyphens.")
        }
        guard hostname.first?.isLetter == true || hostname.first?.isNumber == true,
            hostname.last?.isLetter == true || hostname.last?.isNumber == true,
            hostname.unicodeScalars.allSatisfy({ scalar in
                scalar.isASCII
                    && (CharacterSet.lowercaseLetters.contains(scalar)
                        || CharacterSet.decimalDigits.contains(scalar) || scalar.value == 45)
            })
        else {
            return
                String(
                    localized:
                        "Use lowercase letters, numbers, or hyphens. Start and end with a letter or number."
                )
        }
        return nil
    }

    private static func isDefinitiveRejection(_ error: any Error) -> Bool {
        guard let status = (error as? APIError)?.statusCode else { return false }
        return (400...499).contains(status)
    }

    private static func describe(_ error: any Error) -> String {
        if error is UserPresenceAuthorizationError {
            return String(
                localized: "Nothing changed. This Apple device could not confirm you are present."
            )
        }
        if let api = error as? APIError {
            if api.code == "INVALID_HOSTNAME" {
                return String(
                    localized:
                        "That hostname is not valid. Use lowercase letters, numbers, or hyphens."
                )
            }
            if api.statusCode == 401 || api.statusCode == 403 {
                return String(localized: "Only the owner device can change the Spark hostname.")
            }
            if api.code == "HOSTNAME_CHANGE_TIMEOUT" {
                return String(
                    localized: "The Spark is still changing its hostname. Refresh in a moment."
                )
            }
        }
        return String(
            localized: "The hostname was not changed. Check the connection and try again."
        )
    }
}

public struct SparkIdentitySettingsCard: View {
    @Bindable private var model: SparkIdentitySettingsModel

    public init(model: SparkIdentitySettingsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spark details")
                    .font(.title2.bold())
                Spacer()
                Button("Edit") { model.presentEditor() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Edit Spark name and hostname")
            }
            detailRow(
                title: String(localized: "Name in this app"),
                value: model.displayName,
                help: String(
                    localized: "A private label saved only in SparkPilot on this Apple device."
                )
            )
            detailRow(
                title: String(localized: "Hostname"),
                value: model.hostnameForDisplay,
                help: String(
                    localized:
                        "The Spark's local network name. Changing it updates the Spark itself."
                )
            )
            if model.optimisticHostname != nil {
                Label("Changing hostname", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .sheet(
            isPresented: Binding(
                get: { model.isPresentingEditor },
                set: { if !$0 { model.dismissEditor() } }
            )
        ) {
            SparkIdentitySettingsEditor(model: model)
        }
    }

    private func detailRow(title: String, value: String, help: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 5) {
                Text(title)
                    .foregroundStyle(.secondary)
                SparkTooltipButton(title: title, message: help)
            }
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

private struct SparkIdentitySettingsEditor: View {
    @Bindable var model: SparkIdentitySettingsModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    labelSection
                    hostnameSection
                    if let errorMessage = model.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: 620)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Spark details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.dismissEditor() }
                        .disabled(model.isChangingHostname)
                }
            }
        }
        .alert(
            // Present hostname confirmation only with the actual proposed hostname.
            Text(
                model.pendingHostname.map { LocalizedStringResource.changeHostnameTo($0) }
                    ?? .changeHostnameConfirmation
            ),
            isPresented: Binding(
                get: { model.pendingHostname != nil },
                set: { if !$0 { model.cancelHostnameChange() } }
            )
        ) {
            Button("Change Hostname") {
                Task { await model.confirmHostnameChange() }
            }
            Button("Cancel", role: .cancel) { model.cancelHostnameChange() }
        } message: {
            Text(
                "The Spark may disappear from the network for a moment while the new name takes effect."
            )
        }
    }

    private var labelSection: some View {
        settingsSection(
            title: String(localized: "Name in this app"),
            help:
                String(
                    localized:
                        "This label stays on this Apple device. It does not rename the Spark on your network."
                )
        ) {
            roundedField(String(localized: "Workshop Spark"), text: $model.draftLabel)
            if let message = model.labelValidationMessage {
                validation(message)
            }
            Button("Save app name") { model.saveLabel() }
                .buttonStyle(.borderedProminent)
                .disabled(model.labelValidationMessage != nil)
            if let message = model.labelMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
    }

    private var hostnameSection: some View {
        settingsSection(
            title: String(localized: "Network hostname"),
            help:
                String(
                    localized:
                        "This is the Spark's name on your local network. For example, spark1 becomes spark1.local."
                )
        ) {
            HStack(spacing: 0) {
                #if os(iOS)
                    TextField("spark1", text: $model.draftHostname)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                #else
                    TextField("spark1", text: $model.draftHostname)
                        .textFieldStyle(.plain)
                #endif
                Text(".local")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            }

            if let message = model.hostnameValidationMessage {
                validation(message)
            }
            Button("Change hostname") { model.requestHostnameChange() }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.hostnameValidationMessage != nil || model.isChangingHostname
                        || !model.canChangeHostname
                )
            if model.isChangingHostname {
                ProgressView(String(localized: "Changing hostname"))
            }
            if !model.canChangeHostname {
                Text("Only the owner device can change the hostname.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let message = model.hostnameMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
    }

    private func roundedField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            }
    }

    private func validation(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private func settingsSection<Content: View>(
        title: String,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
            Text(help)
                .font(.callout)
                .foregroundStyle(.secondary)
            content()
        }
        .padding()
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
    }
}
