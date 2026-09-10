import Foundation
import SparkIntents
import Testing
@testable import SparkAppComposition

@MainActor
struct SparkIntentWorkbenchTests {
    @Test func inspectingActionsDoesNotRunThemAndMultipleSparksRequireAChoice() async throws {
        let service = WorkbenchService(twoTargets: true)
        let model = SparkIntentWorkbench(action: .ask, service: service)
        await model.load()
        model.input = "A question"
        #expect(model.targetID.isEmpty)
        #expect(!model.canRun)
        model.start()
        #expect(await service.calls.isEmpty)
        model.targetID = "second"
        model.start()
        await finish(model)
        #expect(await service.calls == ["ask:second:A question"])
        #expect(model.result == "Answer: A question")
    }

    @Test func observerCanCheckStatusButCannotRunInference() async {
        let service = WorkbenchService(observer: true)
        let ask = SparkIntentWorkbench(action: .ask, service: service)
        await ask.load()
        ask.input = "A question"
        ask.start()
        #expect(!ask.canRun)
        #expect(await service.calls.isEmpty)
        let status = SparkIntentWorkbench(action: .status, service: service)
        await status.load()
        #expect(status.canRun)
        status.start()
        await finish(status)
        #expect(await service.calls == ["status:first"])
        #expect(status.result?.contains("Test Spark") == true)
    }

    @Test func modelChangesRequireReviewAndCannotUseAModelFromAnotherSpark() async {
        let service = WorkbenchService(twoTargets: true)
        let model = SparkIntentWorkbench(action: .loadModel, service: service)
        await model.load()
        model.targetID = "second"
        model.modelID = "first-model"
        #expect(!model.canRun)
        model.start(confirmed: true)
        #expect(await service.calls.isEmpty)
        model.targetID = "first"
        model.start()
        #expect(model.error != nil)
        #expect(await service.calls.isEmpty)
        model.start(confirmed: true)
        await finish(model)
        #expect(await service.calls == ["load:first:installed-model"])
        #expect(model.operationID == "operation-id")
    }

    @Test func cancellingDiscardsLateResultsAndDoesNotCancelOtherActions() async throws {
        let service = WorkbenchService()
        let model = SparkIntentWorkbench(action: .ask, service: service)
        await model.load()
        model.input = "slow"
        model.start()
        for _ in 0..<100 {
            if await !service.calls.isEmpty { break }
            await Task.yield()
        }
        model.cancel()
        model.input = "new"
        model.start()
        await finish(model)
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.result == "Answer: new")
        #expect(!model.isRunning)
    }

    @Test func malformedJobIDsNeverReachTheServiceAndPendingJobsKeepTheirIdentity() async {
        let service = WorkbenchService()
        let model = SparkIntentWorkbench(action: .getAnalysis, service: service)
        await model.load()
        model.input = "../../not-a-job"
        model.start()
        await finish(model)
        #expect(model.error != nil)
        #expect(await service.calls.isEmpty)
        let jobID = UUID().uuidString
        model.input = jobID
        model.start()
        await finish(model)
        #expect(model.pendingAnalysis)
        #expect(model.operationID == jobID)
        #expect(model.result == jobID)
    }

    @Test func selectedFilesAreBoundedAndAnInvalidReplacementClearsThePreviousFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.txt")
        try Data("Only this selected text".utf8).write(to: selected)
        let model = SparkIntentWorkbench(action: .analyseFile, service: WorkbenchService())
        model.selectFile(selected)
        #expect(model.file?.text == "Only this selected text")
        #expect(model.file?.sourceName == "selected.txt")
        try Data(repeating: 65, count: SparkFileAnalysisInput.maxBytes + 1).write(to: selected)
        model.selectFile(selected)
        #expect(model.file == nil)
        #expect(model.error != nil)
    }

    @Test(arguments: [SparkAppleAction.summarise, .rewrite, .draftReply, .draftEmail])
    func textTransformsOnlyReturnText(_ action: SparkAppleAction) async {
        let service = WorkbenchService()
        let model = SparkIntentWorkbench(action: action, service: service)
        await model.load()
        model.input = "Supplied text"
        model.start()
        await finish(model)
        #expect(model.result == "Draft result")
        #expect(await service.calls == ["transform:first:Supplied text"])
        #expect(model.operationID == nil)
    }

    private func finish(_ model: SparkIntentWorkbench) async {
        for _ in 0..<100 {
            if !model.isRunning { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!model.isRunning)
    }
}

private actor WorkbenchService: IntentServicing {
    var calls: [String] = []
    let twoTargets: Bool
    let observer: Bool
    init(twoTargets: Bool = false, observer: Bool = false) {
        self.twoTargets = twoTargets
        self.observer = observer
    }
    func knownTargets() -> [IntentTargetSnapshot] {
        let permissions: Set<IntentTargetAction> =
            observer ? [.readStatus] : [.readStatus, .runInference, .operateModels]
        return (twoTargets ? ["first", "second"] : ["first"]).map {
            IntentTargetSnapshot(id: $0, displayName: $0, allowedActions: permissions)
        }
    }
    func knownModels() -> [IntentModelSnapshot] {
        [
            .init(
                id: "first-model",
                modelID: "installed-model",
                targetID: "first",
                displayName: "Installed model",
                installed: true
            )
        ]
    }
    func ask(_ question: String, targetID: String?) async -> String {
        calls.append("ask:\(targetID ?? ""):\(question)")
        if question == "slow" { try? await Task.sleep(for: .milliseconds(50)) }
        return "Answer: " + question
    }
    func status(targetID: String?) -> SparkStatusSnapshot {
        calls.append("status:\(targetID ?? "")")
        return .init(nodeName: "Test Spark", reachability: .readyLocalNetwork)
    }
    func transform(_ text: String, kind: TextTransformKind, targetID: String?) -> String {
        calls.append("transform:\(targetID ?? ""):\(text)")
        return "Draft result"
    }
    func loadModel(_ modelID: String, targetID: String) -> String {
        calls.append("load:\(targetID):\(modelID)")
        return "operation-id"
    }
    func unloadActiveModel(targetID: String?) -> String {
        calls.append("unload:\(targetID ?? "")")
        return "operation-id"
    }
    func analyseFile(_ input: SparkFileAnalysisInput, instruction: String, targetID: String?)
        -> SparkAnalysisHandoff
    {
        calls.append("file:\(targetID ?? "")")
        return .finished(text: input.text, truncated: false)
    }
    func analysisResult(jobID: String, targetID: String?) -> SparkAnalysisHandoff {
        calls.append("analysis:\(targetID ?? "")")
        return .running(jobID: jobID)
    }
}
