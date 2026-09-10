import Foundation
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import IOKit.ps
#endif
import Observation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkSecurity
import SwiftUI
import UniformTypeIdentifiers
@MainActor
@Observable
final class SparkModelLifecycleCoordinator {
    var lifecycle: [String: ModelLifecycleState] = [:]
    var requestedModelID: String?
    var requestedServiceID: String?
    var downloadActivityError: String?
    var lastLoadRequests: [String: ModelOperationRetryRequest] = [:]
    private let route: URL
    private let runtime: any SparkRuntimeReading
    let targetID: String
    let operationStore: any ModelOperationRecoveryStoring
    private let snapshot: SparkDashboardSnapshot
    private let operationDelay: @Sendable (Duration) async throws -> Void
    private var monitorTasks: [String: Task<Void, Never>] = [:]
    var refresh: () async -> Void = {}
    init(
        route: URL,
        targetID: String,
        runtime: any SparkRuntimeReading,
        snapshot: SparkDashboardSnapshot,
        operationStore: any ModelOperationRecoveryStoring,
        operationDelay: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.route = route
        self.targetID = targetID
        self.runtime = runtime
        self.snapshot = snapshot
        self.operationStore = operationStore
        self.operationDelay = operationDelay
    }
    private var models: [SparkModel] { snapshot.models }
    private var errorMessage: String? {
        get { snapshot.errorMessage }
        set { snapshot.errorMessage = newValue }
    }

    func requestModelFocus(_ modelID: String) {
        requestedModelID = modelID
    }

    func requestServiceManagement(serviceID: String) {
        guard serviceID == "open-webui" else { return }
        requestedServiceID = serviceID
    }

    func clearRequestedServiceFocus() {
        requestedServiceID = nil
    }

    var canShowDownloadActivity: Bool { SparkDownloadActivities.available }

    func showDownloadActivity(modelID: String) {
        guard let state = lifecycle[modelID], state.action == .install,
            let operation = state.operation, !operation.state.isTerminal
        else { return }
        downloadActivityError = nil
        do {
            try SparkDownloadActivities.show(targetID: targetID, operation: operation)
        } catch {
            downloadActivityError = String(
                localized:
                    "Lock Screen progress could not start; the download continues on your Spark."
            )
        }
    }

    func requestOperationFocus(_ operationID: SparkOperationID) {
        guard
            let record = try? operationStore.records(for: targetID).first(where: {
                $0.operationID == operationID.rawValue
            })
        else { return }
        requestModelFocus(record.modelID)
    }

    func clearRequestedModelFocus() {
        requestedModelID = nil
    }

    func lifecycleState(for modelID: String) -> ModelLifecycleState? {
        lifecycle[modelID]
    }

    /// Recover durable operations while distinguishing an unknown submission outcome from a terminal failure.
    func recoverPendingOperations(queryRuntime: Bool = true) async {
        let records: [ModelOperationRecoveryRecord]
        do {
            records = try operationStore.records(for: targetID)
        } catch {
            errorMessage = String(
                localized: "Saved operation recovery details could not be read on this device."
            )
            return
        }
        guard !records.isEmpty else { return }
        for record in records { rememberLoadRequest(record) }

        for record in records where record.operationID == nil {
            guard record.retryRequest?.acceptedPreviewDigest != nil else {
                try? operationStore.remove(record)
                lifecycle[record.modelID] = ModelLifecycleState(
                    action: record.action,
                    operation: nil,
                    errorMessage: String(
                        localized: "Review the current Spark state before trying this action again."
                    ),
                    recoveryAction: .refreshPreview
                )
                continue
            }
            lifecycle[record.modelID] = ModelLifecycleState(
                action: record.action,
                operation: nil,
                errorMessage: String(
                    localized: "The app could not confirm whether this action started."
                ),
                recoveryAction: .retryIncompleteOperation
            )
        }

        // Preserve actively polled progress; replacing it with a reconnect notice caused download flicker.
        let operationRecords = records.filter {
            $0.operationID != nil && monitorTasks[$0.storageKey] == nil
        }
        guard !operationRecords.isEmpty else { return }
        guard queryRuntime else {
            for record in operationRecords {
                markStatusRetry(
                    record,
                    message: String(localized: "Reconnect to the Spark to check this operation.")
                )
            }
            return
        }

        var listed: [UUID: SparkAPI.Operation] = [:]
        do {
            var cursor: String?
            var seenCursors = Set<String>()
            let wantedIDs = Set(operationRecords.compactMap(\.operationID))
            var pageCount = 0
            repeat {
                let page = try await runtime.operations(route: route, limit: 200, cursor: cursor)
                pageCount += 1
                for operation in page.items {
                    listed[operation.id] = operation
                }
                if wantedIDs.isSubset(of: Set(listed.keys)) { break }
                cursor = page.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted { break }
            } while cursor != nil && pageCount < 10
        } catch {
            for record in operationRecords {
                markStatusRetry(
                    record,
                    message: SparkDashboardFailurePresentation.lifecycleMessage(for: error)
                )
            }
            return
        }

        for record in operationRecords {
            guard let operationID = record.operationID else { continue }
            do {
                let operation: SparkAPI.Operation
                if let listedOperation = listed[operationID] {
                    operation = listedOperation
                } else {
                    operation = try await runtime.operation(route: route, id: operationID)
                }
                await attach(record, to: operation)
            } catch {
                markStatusRetry(
                    record,
                    message: SparkDashboardFailurePresentation.lifecycleMessage(for: error)
                )
            }
        }
    }

    func retryStatus(
        modelID: String,
        progress: @escaping @MainActor (SparkAPI.Operation) -> Void = { _ in }
    ) async {
        guard let record = recoveryRecord(for: modelID), let operationID = record.operationID else {
            return
        }
        do {
            let operation = try await runtime.operation(route: route, id: operationID)
            await attach(record, to: operation, progress: progress)
        } catch {
            markStatusRetry(
                record,
                message: SparkDashboardFailurePresentation.lifecycleMessage(for: error)
            )
        }
    }

    var unlistedModelIDsNeedingRecovery: [String] {
        let listedModelIDs = Set(models.map(\.id))
        return lifecycle.compactMap { modelID, state in
            state.recoveryAction == nil || listedModelIDs.contains(modelID) ? nil : modelID
        }.sorted()
    }

    func retryIncompleteOperation(modelID: String) async {
        guard let record = recoveryRecord(for: modelID), record.operationID == nil else { return }
        rememberLoadRequest(record)
        guard record.retryRequest?.acceptedPreviewDigest != nil else {
            try? operationStore.remove(record)
            lifecycle[modelID] = ModelLifecycleState(
                action: record.action,
                operation: nil,
                errorMessage: String(
                    localized: "Review the current Spark state before trying this action again."
                ),
                recoveryAction: .refreshPreview
            )
            return
        }
        if record.action == .load {
            guard let request = record.retryRequest, request.profileID != nil else {
                lifecycle[modelID] = ModelLifecycleState(
                    action: .load,
                    operation: nil,
                    errorMessage: String(
                        localized: "The saved load request is incomplete. Start the model again."
                    )
                )
                try? operationStore.remove(record)
                return
            }
        }
        let fallback =
            record.action == .unload
            ? ModelOperationRetryRequest(force: false) : ModelOperationRetryRequest()
        let request = record.retryRequest ?? fallback
        await perform(action: record.action, modelID: modelID, retryRequest: request) {
            key,
            savedRequest in
            try await SparkModelMutationSubmitter(route: self.route, runtime: self.runtime).submit(
                action: record.action,
                modelID: modelID,
                request: savedRequest,
                idempotencyKey: key
            )
        }
    }

    func perform(
        action: ModelLifecycleAction,
        modelID: String,
        retryRequest: ModelOperationRetryRequest,
        idempotencyKey: UUID? = nil,
        progress: @escaping @MainActor (SparkAPI.Operation) -> Void = { _ in },
        submit: (UUID, ModelOperationRetryRequest) async throws -> SparkAPI.Operation
    ) async {
        guard lifecycle[modelID]?.isRunning != true else { return }

        let record: ModelOperationRecoveryRecord
        do {
            let saved = try operationStore.records(for: targetID)
            if let otherAction = saved.first(where: { $0.modelID == modelID && $0.action != action }
            ) {
                restorePresentation(for: otherAction)
                return
            }
            if let existing = saved.first(where: { $0.modelID == modelID && $0.action == action }) {
                if let idempotencyKey, idempotencyKey != existing.idempotencyKey {
                    restorePresentation(for: existing)
                    return
                }
                if existing.operationID != nil {
                    await retryStatus(modelID: modelID, progress: progress)
                    return
                }
                record = existing
            } else {
                record = ModelOperationRecoveryRecord(
                    targetID: targetID,
                    modelID: modelID,
                    action: action,
                    idempotencyKey: idempotencyKey ?? UUID(),
                    retryRequest: retryRequest
                )
                try operationStore.save(record)
            }
        } catch {
            lifecycle[modelID] = ModelLifecycleState(
                action: action,
                operation: nil,
                errorMessage: String(
                    localized: "This device could not save recovery details, so no change was sent."
                )
            )
            return
        }

        rememberLoadRequest(record)
        lifecycle[modelID] = ModelLifecycleState(
            action: action,
            operation: nil,
            errorMessage: nil
        )
        do {
            let savedRequest = record.retryRequest ?? retryRequest
            let operation = try await submit(record.idempotencyKey, savedRequest)
            var attachedRecord = record
            attachedRecord.operationID = operation.id
            let operationIDWasPersisted: Bool
            do {
                try operationStore.save(attachedRecord)
                operationIDWasPersisted = true
            } catch {
                operationIDWasPersisted = false
            }
            await monitor(
                attachedRecord,
                from: operation,
                operationIDWasPersisted: operationIDWasPersisted,
                progress: progress
            )
        } catch is CancellationError {
            markIncompleteRetry(
                record,
                message: String(
                    localized:
                        "The app stopped before it could confirm whether this action started."
                )
            )
        } catch {
            if SparkDashboardFailurePresentation.isPreviewInvalidation(error) {
                try? operationStore.remove(record)
                lifecycle[modelID] = ModelLifecycleState(
                    action: action,
                    operation: nil,
                    errorMessage: String(
                        localized: "The Spark changed since this review. Review the action again."
                    ),
                    recoveryAction: .refreshPreview
                )
            } else if SparkDashboardFailurePresentation.isDefiniteRejection(error) {
                try? operationStore.remove(record)
                lifecycle[modelID] = ModelLifecycleState(
                    action: action,
                    operation: nil,
                    errorMessage: SparkDashboardFailurePresentation.lifecycleMessage(for: error)
                )
            } else {
                markIncompleteRetry(
                    record,
                    message: SparkDashboardFailurePresentation.lifecycleMessage(for: error)
                )
            }
        }
    }

    private func attach(
        _ record: ModelOperationRecoveryRecord,
        to operation: SparkAPI.Operation,
        progress: @escaping @MainActor (SparkAPI.Operation) -> Void = { _ in }
    ) async {
        lifecycle[record.modelID] = ModelLifecycleState(
            action: record.action,
            operation: operation,
            errorMessage: SparkDashboardFailurePresentation.ownerOperationError(operation),
            errorTitle: SparkDashboardFailurePresentation.ownerOperationErrorTitle(operation),
            technicalErrorCode: operation.errorCode
        )
        if operation.state.isTerminal {
            progress(operation)
            await finish(record, operation: operation)
        } else {
            startMonitoring(record, from: operation, progress: progress)
        }
    }

    private func startMonitoring(
        _ record: ModelOperationRecoveryRecord,
        from operation: SparkAPI.Operation,
        progress: @escaping @MainActor (SparkAPI.Operation) -> Void = { _ in }
    ) {
        guard monitorTasks[record.storageKey] == nil else { return }
        monitorTasks[record.storageKey] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.monitor(
                record,
                from: operation,
                operationIDWasPersisted: true,
                progress: progress
            )
            self.monitorTasks[record.storageKey] = nil
        }
    }

    private func monitor(
        _ record: ModelOperationRecoveryRecord,
        from initialOperation: SparkAPI.Operation,
        operationIDWasPersisted: Bool,
        progress: @MainActor (SparkAPI.Operation) -> Void = { _ in }
    ) async {
        var operation = initialOperation
        lifecycle[record.modelID] = ModelLifecycleState(
            action: record.action,
            operation: operation,
            errorMessage: nil
        )
        progress(operation)
        if record.action == .install {
            await SparkDownloadActivities.update(targetID: targetID, operation: operation)
        }
        do {
            while !operation.state.isTerminal {
                try Task.checkCancellation()
                try await operationDelay(.seconds(1))
                let refreshed = try await runtime.operation(route: route, id: operation.id)
                operation = refreshed
                progress(operation)
                if record.action == .install {
                    await SparkDownloadActivities.update(targetID: targetID, operation: operation)
                }
                lifecycle[record.modelID] = ModelLifecycleState(
                    action: record.action,
                    operation: operation,
                    errorMessage: SparkDashboardFailurePresentation.ownerOperationError(operation),
                    errorTitle: SparkDashboardFailurePresentation.ownerOperationErrorTitle(
                        operation
                    ),
                    technicalErrorCode: operation.errorCode
                )
            }
            await finish(record, operation: operation)
        } catch is CancellationError {
            markPollingRecovery(
                record,
                operationIDWasPersisted: operationIDWasPersisted,
                message: String(
                    localized:
                        "Operation monitoring stopped. Check the Spark for its current status."
                )
            )
        } catch {
            markPollingRecovery(
                record,
                operationIDWasPersisted: operationIDWasPersisted,
                message: SparkDashboardFailurePresentation.lifecycleMessage(for: error)
            )
        }
    }

    private func finish(
        _ record: ModelOperationRecoveryRecord,
        operation: SparkAPI.Operation
    ) async {
        if record.action == .install {
            await SparkDownloadActivities.update(targetID: targetID, operation: operation)
        }
        rememberLoadRequest(record)
        do {
            try operationStore.remove(record)
        } catch {
            errorMessage =
                String(
                    localized:
                        "The action finished, but its local recovery record could not be cleared."
                )
        }
        if operation.state == .failed || operation.state == .cancelled {
            lifecycle[record.modelID] = ModelLifecycleState(
                action: record.action,
                operation: operation,
                errorMessage: SparkDashboardFailurePresentation.ownerOperationError(operation)
                    ?? String(localized: "The Spark could not complete this action."),
                errorTitle: SparkDashboardFailurePresentation.ownerOperationErrorTitle(operation),
                technicalErrorCode: operation.errorCode,
                recoveryAction: SparkDashboardFailurePresentation.terminalRecoveryAction(
                    for: operation
                )
            )
        } else {
            lifecycle[record.modelID] = ModelLifecycleState(
                action: record.action,
                operation: operation,
                errorMessage: nil
            )
            await refresh()
        }
    }

    func recoveryRecord(for modelID: String) -> ModelOperationRecoveryRecord? {
        try? operationStore.records(for: targetID).first { $0.modelID == modelID }
    }

    private func rememberLoadRequest(_ record: ModelOperationRecoveryRecord) {
        guard record.action == .load, let request = record.retryRequest else { return }
        // Preserve the semantic load request for a fresh review after its stale preview or terminal receipt is removed.
        lastLoadRequests[record.modelID] = request
    }

    func restorePresentation(for record: ModelOperationRecoveryRecord) {
        if record.operationID == nil {
            markIncompleteRetry(
                record,
                message: String(
                    localized: "Finish recovering the earlier action before starting another one."
                )
            )
        } else {
            markStatusRetry(
                record,
                message: String(localized: "Check the earlier action before starting another one.")
            )
        }
    }

    private func markIncompleteRetry(
        _ record: ModelOperationRecoveryRecord,
        message: String
    ) {
        lifecycle[record.modelID] = ModelLifecycleState(
            action: record.action,
            operation: nil,
            errorMessage: message,
            recoveryAction: .retryIncompleteOperation
        )
    }

    private func markStatusRetry(
        _ record: ModelOperationRecoveryRecord,
        message: String
    ) {
        lifecycle[record.modelID] = ModelLifecycleState(
            action: record.action,
            operation: lifecycle[record.modelID]?.operation,
            errorMessage: message,
            recoveryAction: .retryStatus
        )
    }

    private func markPollingRecovery(
        _ record: ModelOperationRecoveryRecord,
        operationIDWasPersisted: Bool,
        message: String
    ) {
        if operationIDWasPersisted {
            markStatusRetry(record, message: message)
        } else {
            var keyOnlyRecord = record
            keyOnlyRecord.operationID = nil
            markIncompleteRetry(keyOnlyRecord, message: message)
        }
    }

    func stopMonitoring() {
        for task in monitorTasks.values {
            task.cancel()
        }
        monitorTasks.removeAll()
    }

}
