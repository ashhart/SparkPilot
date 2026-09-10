import Foundation
import Observation
import SparkAPI
import SparkSecurity
import SwiftUI

public protocol ProviderCredentialManaging: Sendable {
    func providerCredentials(route: URL) async throws -> [GeneratedAPI.ProviderCredential]
    func addProviderCredential(
        route: URL,
        request: GeneratedAPI.AddProviderCredentialRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.ProviderCredential
    func revokeProviderCredential(
        route: URL,
        credentialID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws
}

extension SparkAPIClient: ProviderCredentialManaging {}

@MainActor
@Observable
public final class ProviderCredentialModel {
    public private(set) var credentials: [GeneratedAPI.ProviderCredential] = []
    public private(set) var localDeviceRole: String?
    public private(set) var isLoading = false
    public private(set) var isChanging = false
    public private(set) var errorMessage: String?

    public let route: URL
    public let targetID: String

    @ObservationIgnored private let runtime: any ProviderCredentialManaging
    @ObservationIgnored private let userPresenceAuthorizer: any UserPresenceAuthorizing
    @ObservationIgnored private var selectedByProvider: [String: String] = [:]

    public init(
        route: URL,
        targetID: String,
        runtime: any ProviderCredentialManaging,
        localDeviceRole: String?,
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer()
    ) {
        self.route = route
        self.targetID = targetID
        self.runtime = runtime
        self.localDeviceRole = localDeviceRole
        self.userPresenceAuthorizer = userPresenceAuthorizer
    }

    public var canManage: Bool {
        localDeviceRole == "owner" || localDeviceRole == "administrator"
    }

    public func updateLocalDeviceRole(_ role: String?) {
        localDeviceRole = role
        if !canManage {
            credentials = []
            selectedByProvider = [:]
        }
    }

    public func load() async {
        guard canManage, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            credentials = try await runtime.providerCredentials(route: route)
            reconcileSelections()
        } catch {
            errorMessage = Self.ownerMessage(for: error, action: .list)
        }
    }

    @discardableResult
    public func addHuggingFaceCredential(displayName: String, token: String) async -> Bool {
        guard canManage, !isChanging else { return false }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !secret.isEmpty else {
            errorMessage = String(localized: "Enter a name and a Hugging Face access token.")
            return false
        }
        isChanging = true
        errorMessage = nil
        defer { isChanging = false }
        do {
            let presence = try await userPresenceAuthorizer.authorize(
                localizedReason: String(localized: "Add Hugging Face access to this Spark")
            )
            let added = try await runtime.addProviderCredential(
                route: route,
                request: GeneratedAPI.AddProviderCredentialRequest(
                    provider: "huggingface",
                    displayName: name,
                    secret: secret
                ),
                idempotencyKey: UUID(),
                userPresence: presence
            )
            credentials.removeAll { $0.id == added.id }
            credentials.append(added)
            sortCredentials()
            selectedByProvider[added.provider] = added.id
            return true
        } catch {
            errorMessage = Self.ownerMessage(for: error, action: .add)
            return false
        }
    }

    public func revokeCredential(_ credentialID: String) async {
        guard canManage, !isChanging,
            let credential = credentials.first(where: { $0.id == credentialID })
        else { return }
        isChanging = true
        errorMessage = nil
        defer { isChanging = false }
        do {
            let presence = try await userPresenceAuthorizer.authorize(
                localizedReason: String(localized: "Remove Hugging Face access from this Spark")
            )
            try await runtime.revokeProviderCredential(
                route: route,
                credentialID: credentialID,
                idempotencyKey: UUID(),
                userPresence: presence
            )
            credentials.removeAll { $0.id == credentialID }
            if selectedByProvider[credential.provider] == credentialID {
                selectedByProvider[credential.provider] = nil
            }
            reconcileSelections()
        } catch {
            errorMessage = Self.ownerMessage(for: error, action: .revoke)
        }
    }

    public func credentials(for provider: String) -> [GeneratedAPI.ProviderCredential] {
        credentials.filter { $0.provider == provider }
    }

    public func selectedCredentialID(for provider: String) -> String? {
        selectedByProvider[provider]
    }

    public func selectCredential(_ credentialID: String?, for provider: String) {
        guard let credentialID else {
            selectedByProvider[provider] = nil
            return
        }
        guard credentials.contains(where: { $0.id == credentialID && $0.provider == provider })
        else { return }
        selectedByProvider[provider] = credentialID
    }

    private func reconcileSelections() {
        let providers = Set(credentials.map(\.provider)).union(selectedByProvider.keys)
        for provider in providers {
            let available = credentials(for: provider)
            if let selected = selectedByProvider[provider],
                available.contains(where: { $0.id == selected })
            {
                continue
            }
            selectedByProvider[provider] = available.count == 1 ? available[0].id : nil
        }
    }

    private func sortCredentials() {
        credentials.sort {
            if $0.provider == $1.provider {
                if $0.displayName == $1.displayName { return $0.id < $1.id }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
            return $0.provider < $1.provider
        }
    }

    private enum Action {
        case list
        case add
        case revoke
    }

    private static func ownerMessage(for error: any Error, action: Action) -> String {
        switch error as? UserPresenceAuthorizationError {
        case .declined:
            return String(localized: "The change was cancelled. No token was sent to the Spark.")
        case .unavailable, .keyUnavailable:
            return String(
                localized: "Set up Face ID, Touch ID, or a device passcode, then try again."
            )
        case nil:
            break
        }
        if let api = error as? APIError {
            switch api.code {
            case "ROLE_FORBIDDEN", "POLICY_FORBIDDEN":
                return String(
                    localized: "Only an owner or administrator can manage model-provider access."
                )
            case "USER_PRESENCE_REQUIRED", "USER_PRESENCE_EXPIRED",
                "USER_PRESENCE_INVALID", "USER_PRESENCE_NOT_REGISTERED":
                return String(
                    localized: "Confirm again with Face ID, Touch ID, or your device passcode."
                )
            case "CREDENTIAL_INVALID":
                return String(
                    localized: "The Spark rejected this credential. Check the token and try again."
                )
            default:
                break
            }
        }
        return switch action {
        case .list:
            String(localized: "The Spark could not list its saved Hugging Face access. Try again.")
        case .add: String(localized: "The Spark did not save this Hugging Face token. Try again.")
        case .revoke:
            String(localized: "The Spark did not remove this Hugging Face access. Try again.")
        }
    }
}

public struct ProviderCredentialManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var model: ProviderCredentialModel
    @State private var displayName = String(localized: "Private models")
    @State private var token = ""
    @State private var revealsToken = false
    @State private var pendingRevocation: GeneratedAPI.ProviderCredential?

    public init(model: ProviderCredentialModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Form {
                if model.canManage {
                    savedCredentials
                    addCredential
                } else {
                    ContentUnavailableView(
                        "Administrator access required",
                        systemImage: "lock",
                        description: Text(
                            "Ask this Spark's owner or an administrator to add Hugging Face access."
                        )
                    )
                }
                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Hugging Face access")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            .alert(
                "Remove this Hugging Face access?",
                isPresented: Binding(
                    get: { pendingRevocation != nil },
                    set: { if !$0 { pendingRevocation = nil } }
                ),
                presenting: pendingRevocation
            ) { credential in
                Button(.removeResource(credential.displayName), role: .destructive) {
                    pendingRevocation = nil
                    Task { await model.revokeCredential(credential.id) }
                }
                Button("Cancel", role: .cancel) { pendingRevocation = nil }
            } message: { _ in
                Text("Gated downloads using it will need another saved token.")
            }
        }
    }

    @ViewBuilder
    private var savedCredentials: some View {
        Section {
            if model.isLoading, model.credentials.isEmpty {
                ProgressView(String(localized: "Loading access"))
            } else if model.credentials.isEmpty {
                Text("No Hugging Face access is saved.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.credentials, id: \.id) { credential in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(credential.displayName)
                            Text("Hugging Face token")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            pendingRevocation = credential
                        }
                        .disabled(model.isChanging)
                    }
                }
            }
        } header: {
            Text("Saved on this Spark")
        } footer: {
            Text("Tokens stay on this Spark. SparkPilot never displays them again.")
        }
    }

    private var addCredential: some View {
        Section {
            TextField("Name", text: $displayName)
                .textContentType(.nickname)
            HStack {
                Group {
                    if revealsToken {
                        TextField("Hugging Face token", text: $token)
                            #if os(iOS)
                                .textInputAutocapitalization(.never)
                            #endif
                    } else {
                        SecureField("Hugging Face token", text: $token)
                            #if os(iOS)
                                .textInputAutocapitalization(.never)
                            #endif
                    }
                }
                .autocorrectionDisabled()
                .privacySensitive()
                Button {
                    revealsToken.toggle()
                } label: {
                    Image(systemName: revealsToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    revealsToken ? String(localized: "Hide token") : String(localized: "Show token")
                )
            }
            Button("Save on this Spark") {
                let submittedToken = token
                token = ""
                revealsToken = false
                Task {
                    _ = await model.addHuggingFaceCredential(
                        displayName: displayName,
                        token: submittedToken
                    )
                }
            }
            .disabled(
                model.isChanging
                    || displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                    || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        } header: {
            Text("Add access")
        } footer: {
            Text("Use a read-only Hugging Face token for gated model downloads.")
        }
    }
}
