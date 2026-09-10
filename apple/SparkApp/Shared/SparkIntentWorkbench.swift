import Foundation
import Observation
import SparkIntents
import UniformTypeIdentifiers

@MainActor @Observable
final class SparkIntentWorkbench {
    let action: SparkAppleAction
    var targetID = ""
    var modelID = ""
    var input = ""
    private(set) var targets: [IntentTargetSnapshot] = []
    private(set) var models: [IntentModelSnapshot] = []
    private(set) var file: SparkFileAnalysisInput?
    private(set) var isLoading = false
    private(set) var isRunning = false
    private(set) var result: String?
    private(set) var operationID: String?
    private(set) var pendingAnalysis = false
    private(set) var truncated = false
    private(set) var error: String?
    @ObservationIgnored private let service: any IntentServicing
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(action: SparkAppleAction, service: any IntentServicing = IntentServices.shared) {
        self.action = action
        self.service = service
        if action == .analyseFile {
            input = String(localized: "Summarise this document accurately and concisely.")
        }
    }

    var availableModels: [IntentModelSnapshot] {
        models.filter { $0.targetID == targetID && $0.installed && $0.canLoad }
    }

    var canRun: Bool {
        !isLoading && !isRunning
            && targets.contains {
                $0.id == targetID && $0.allowedActions.contains(action.permission)
            }
            && (!action.requiresText
                || !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (action != .loadModel || availableModels.contains { $0.id == modelID })
            && (action != .analyseFile || file != nil)
    }

    func load() async {
        guard !isLoading, !isRunning else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let loaded = try await service.knownTargets()
            try Task.checkCancellation()
            targets = loaded
            if !targets.contains(where: { $0.id == targetID }) {
                targetID = targets.count == 1 ? targets[0].id : ""
            }
            if action == .loadModel {
                models = try await service.knownModels()
            }
        } catch is CancellationError {
        } catch {
            self.error = Self.describe(error)
        }
    }

    func selectFile(_ url: URL) {
        guard !isRunning else { return }
        file = nil
        error = nil
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: SparkFileAnalysisInput.maxBytes + 1) ?? Data()
            file = try SparkFileAnalysisInput.extract(
                data: data,
                contentType: UTType(filenameExtension: url.pathExtension),
                suggestedName: url.lastPathComponent
            )
        } catch {
            self.error = Self.describe(error)
        }
    }

    func start(confirmed: Bool = false) {
        guard canRun else { return }
        guard !action.changesModel || confirmed else {
            error = String(localized: "Review the model change before running this action.")
            return
        }
        let id = UUID()
        generation = id
        let target = targetID
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = availableModels.first { $0.id == modelID }
        let selectedFile = file
        result = nil
        operationID = nil
        pendingAnalysis = false
        truncated = false
        error = nil
        isRunning = true
        work = Task {
            defer {
                if generation == id {
                    isRunning = false
                    work = nil
                }
            }
            do {
                let output: String
                switch action {
                case .ask: output = try await service.ask(text, targetID: target)
                case .status: output = try await service.status(targetID: target).spokenSummary
                case .summarise, .rewrite, .draftReply, .draftEmail:
                    let kind: TextTransformKind =
                        action == .draftEmail
                        ? .draftEmail
                        : action == .summarise
                            ? .summarise : action == .rewrite ? .rewrite : .draftReply
                    output = try await service.transform(text, kind: kind, targetID: target)
                case .loadModel:
                    guard let selectedModel else { throw SparkIntentError.permissionDenied }
                    output = try await service.loadModel(selectedModel.modelID, targetID: target)
                case .unloadModel: output = try await service.unloadActiveModel(targetID: target)
                case .analyseFile, .getAnalysis:
                    let handoff: SparkAnalysisHandoff
                    if action == .analyseFile {
                        guard let selectedFile else { throw SparkIntentError.fileHasNoText }
                        handoff = try await service.analyseFile(
                            selectedFile,
                            instruction: text,
                            targetID: target
                        )
                    } else {
                        guard UUID(uuidString: text) != nil else {
                            throw SparkIntentError.analysisJobUnknown(jobID: text)
                        }
                        handoff = try await service.analysisResult(jobID: text, targetID: target)
                    }
                    guard generation == id, !Task.isCancelled else { return }
                    switch handoff {
                    case .finished(let text, let cutShort):
                        output = text
                        truncated = cutShort
                    case .running(let jobID):
                        output = jobID
                        operationID = jobID
                        pendingAnalysis = true
                    }
                }
                guard generation == id, !Task.isCancelled else { return }
                result = output
                if action.changesModel { operationID = output }
            } catch {
                guard generation == id, !Task.isCancelled else { return }
                self.error = Self.describe(error)
            }
        }
    }

    func cancel() {
        generation = UUID()
        work?.cancel()
        work = nil
        isRunning = false
    }

    private static func describe(_ error: any Error) -> String {
        (error as? SparkIntentError)?.displayMessage
            ?? String(
                localized:
                    "This action could not finish. Check your Spark connection and try again."
            )
    }
}
