import Foundation
import Observation
import SparkAPI
import SparkSecurity
import SwiftUI

public struct WorkloadOwnershipConfirmation: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case adopt(modelID: String, modelName: String, profileID: String, profileName: String)
        case relinquish
    }

    public let idempotencyKey: UUID
    public let workloadID: String
    public let workloadName: String
    public let action: Action
    public let preview: GeneratedAPI.ModelActionPreview

    public var id: UUID { idempotencyKey }
    public var canApply: Bool { preview.blockers.isEmpty }
}

@MainActor
@Observable
public final class SparkWorkloadOwnershipModel {
    public private(set) var pendingConfirmation: WorkloadOwnershipConfirmation?
    public private(set) var isWorking = false
    public private(set) var operation: SparkAPI.Operation?
    public private(set) var errorMessage: String?

    @ObservationIgnored private let route: URL
    @ObservationIgnored private let runtime: any SparkRuntimeReading
    @ObservationIgnored private let userPresenceAuthorizer: any UserPresenceAuthorizing
    @ObservationIgnored private let presenceEnrollmentProvider: (any DeviceManagementProviding)?
    @ObservationIgnored private var presenceEnrollmentKey: UUID?
    @ObservationIgnored private let operationDelay: @Sendable (Duration) async throws -> Void

    public init(
        route: URL,
        runtime: any SparkRuntimeReading,
        userPresenceAuthorizer: any UserPresenceAuthorizing,
        operationDelay: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.route = route
        self.runtime = runtime
        self.userPresenceAuthorizer = userPresenceAuthorizer
        self.presenceEnrollmentProvider = runtime as? any DeviceManagementProviding
        self.operationDelay = operationDelay
    }

    public func prepareAdoption(
        workloadID: String,
        workloadName: String,
        model: SparkModel,
        profile: SparkModelProfile
    ) async {
        guard !isWorking, model.installState == .installed else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        let key = UUID()
        do {
            let preview = try await runtime.previewWorkloadAdoption(
                route: route,
                workloadID: workloadID,
                request: .init(modelId: model.id, profileId: profile.id),
                idempotencyKey: key
            )
            guard preview.action == .workloadAdopt else {
                throw APIError(
                    .local(message: String(localized: "The Spark returned the wrong review."))
                )
            }
            pendingConfirmation = WorkloadOwnershipConfirmation(
                idempotencyKey: key,
                workloadID: workloadID,
                workloadName: workloadName,
                action: .adopt(
                    modelID: model.id,
                    modelName: model.displayName,
                    profileID: profile.id,
                    profileName: profile.displayName
                ),
                preview: preview
            )
        } catch let error as APIError {
            errorMessage = APIError.message(for: error)
        } catch {
            errorMessage = String(
                localized: "This Spark could not prepare an exact-match adoption review."
            )
        }
    }

    public func prepareRelinquish(workloadID: String, workloadName: String) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        let key = UUID()
        do {
            let preview = try await runtime.previewWorkloadRelinquish(
                route: route,
                workloadID: workloadID,
                idempotencyKey: key
            )
            guard preview.action == .workloadRelinquish else {
                throw APIError(
                    .local(message: String(localized: "The Spark returned the wrong review."))
                )
            }
            pendingConfirmation = WorkloadOwnershipConfirmation(
                idempotencyKey: key,
                workloadID: workloadID,
                workloadName: workloadName,
                action: .relinquish,
                preview: preview
            )
        } catch let error as APIError {
            errorMessage = APIError.message(for: error)
        } catch {
            errorMessage = String(localized: "This Spark could not prepare the relinquish review.")
        }
    }

    public func cancel() {
        guard !isWorking else { return }
        pendingConfirmation = nil
        errorMessage = nil
    }

    @discardableResult
    public func apply() async -> Bool {
        guard let confirmation = pendingConfirmation, confirmation.canApply, !isWorking else {
            return false
        }
        isWorking = true
        errorMessage = nil
        operation = nil
        defer {
            isWorking = false
            operation = nil
        }
        do {
            switch confirmation.action {
            case .adopt(let modelID, _, let profileID, _):
                var submitted = try await submitWithPresence(
                    reason: String(
                        localized: "Confirm managing this exact external model workload."
                    )
                ) { presence in
                    try await self.runtime.adoptWorkload(
                        route: self.route,
                        workloadID: confirmation.workloadID,
                        request: .init(
                            modelId: modelID,
                            profileId: profileID,
                            acceptedPreviewDigest: confirmation.preview.previewDigest
                        ),
                        idempotencyKey: confirmation.idempotencyKey,
                        userPresence: presence
                    )
                }
                operation = submitted
                while !Self.isTerminal(submitted) {
                    try await operationDelay(.seconds(1))
                    submitted = try await runtime.operation(route: route, id: submitted.id)
                    operation = submitted
                }
                guard submitted.state == .succeeded else {
                    throw APIError(
                        .local(
                            message: String(
                                localized:
                                    "The workload stayed externally managed because adoption did not complete."
                            )
                        ),
                        code: submitted.errorCode
                    )
                }
            case .relinquish:
                let response = try await submitWithPresence(
                    reason: String(
                        localized:
                            "Confirm removing SparkPilot ownership without stopping the workload."
                    )
                ) { presence in
                    try await self.runtime.relinquishWorkload(
                        route: self.route,
                        workloadID: confirmation.workloadID,
                        request: .init(
                            acceptedPreviewDigest: confirmation.preview.previewDigest
                        ),
                        idempotencyKey: confirmation.idempotencyKey,
                        userPresence: presence
                    )
                }
                guard !response.containerChanged else {
                    throw APIError(
                        .local(
                            message: String(
                                localized: "The Spark returned an unsafe relinquish result."
                            )
                        )
                    )
                }
            }
            pendingConfirmation = nil
            return true
        } catch is UserPresenceAuthorizationError {
            errorMessage =
                String(
                    localized:
                        "Nothing changed because this Apple device could not confirm you are present."
                )
        } catch let error as APIError {
            if Self.previewInvalid(error) {
                pendingConfirmation = nil
                errorMessage = String(
                    localized: "The workload changed after review. Review its current state again."
                )
            } else {
                errorMessage = APIError.message(for: error)
            }
        } catch {
            errorMessage =
                String(
                    localized:
                        "SparkPilot could not confirm the ownership change. Try again to check the same request."
                )
        }
        return false
    }

    private func submitWithPresence<T: Sendable>(
        reason: String,
        submit: @escaping (any UserPresenceProofSigning) async throws -> T
    ) async throws -> T {
        let presence = try await userPresenceAuthorizer.authorize(localizedReason: reason)
        do {
            return try await submit(presence)
        } catch {
            guard (error as? APIError)?.code == "USER_PRESENCE_NOT_REGISTERED" else {
                throw error
            }
            try await enrollPresenceKey()
            let retry = try await userPresenceAuthorizer.authorize(localizedReason: reason)
            return try await submit(retry)
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
        let key = presenceEnrollmentKey ?? UUID()
        presenceEnrollmentKey = key
        do {
            _ = try await presenceEnrollmentProvider.enrollPresenceKey(
                route: route,
                idempotencyKey: key,
                userPresence: presence
            )
            presenceEnrollmentKey = nil
        } catch {
            if let status = (error as? APIError)?.statusCode, (400...499).contains(status) {
                presenceEnrollmentKey = nil
            }
            throw error
        }
    }

    private static func isTerminal(_ operation: SparkAPI.Operation) -> Bool {
        switch operation.state {
        case .succeeded, .failed, .cancelled: true
        default: false
        }
    }

    private static func previewInvalid(_ error: APIError) -> Bool {
        ["PREVIEW_STALE", "PREVIEW_EXPIRED", "PREVIEW_NOT_FOUND", "PREVIEW_ALREADY_ACCEPTED"]
            .contains(error.code)
    }
}

public struct WorkloadOwnershipConfirmationView: View {
    public let confirmation: WorkloadOwnershipConfirmation
    public let isWorking: Bool
    public let operation: SparkAPI.Operation?
    public let errorMessage: String?
    public let cancel: () -> Void
    public let apply: () -> Void

    public var body: some View {
        NavigationStack {
            Form {
                Section("Review") {
                    Text(title).font(.headline)
                    Text(summary).foregroundStyle(.secondary)
                }
                if !confirmation.preview.blockers.isEmpty {
                    Section("Cannot continue") {
                        ForEach(confirmation.preview.blockers, id: \.code) { blocker in
                            Label(blocker.ownerExplanation, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            if let recovery = blocker.recoveryAction { Text(recovery) }
                        }
                    }
                }
                if !confirmation.preview.warnings.isEmpty {
                    Section("What this means") {
                        ForEach(confirmation.preview.warnings, id: \.code) { warning in
                            Text(warning.ownerExplanation)
                        }
                    }
                }
                if let operation {
                    Section("Progress") {
                        ProgressView(value: operation.progress)
                        Text(
                            operation.stage?.replacingOccurrences(of: "_", with: " ")
                                ?? String(localized: "Working")
                        )
                    }
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle") }
                }
            }
            .navigationTitle("Workload ownership")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(applyTitle, action: apply)
                        .disabled(!confirmation.canApply || isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private var title: String {
        switch confirmation.action {
        case .adopt: String(localized: "Let SparkPilot manage this workload?")
        case .relinquish: String(localized: "Stop managing this workload?")
        }
    }

    private var summary: String {
        switch confirmation.action {
        case .adopt(_, let modelName, _, let profileName):
            String(
                localized: .workloadVerifiedAgainst(
                    workload: confirmation.workloadName,
                    model: modelName,
                    profile: profileName
                )
            )
        case .relinquish:
            String(
                localized:
                    "SparkPilot will remove only its ownership record. The original container and files stay in place."
            )
        }
    }

    private var applyTitle: String {
        switch confirmation.action {
        case .adopt: String(localized: "Adopt")
        case .relinquish: String(localized: "Relinquish")
        }
    }
}
