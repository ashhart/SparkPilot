import AppIntents
import Foundation
import Testing

@testable import SparkIntents

/// Nest under the same serialized parent as the other intent suites because they share a process-global service registry.
extension SparkIntentTests {

    /// Cover what Shortcuts and Siri show before an intent runs, and what they do when a required choice is missing.
    @Suite(.serialized) struct IntentPresentationTests {
        /// Only one paired Spark, so nothing needs choosing.
        private struct OneSparkServices: IntentServicing {
            func status(targetID: String?) async throws -> SparkStatusSnapshot {
                SparkStatusSnapshot(nodeName: "Studio", reachability: .readyLocalNetwork)
            }
            func ask(_ question: String, targetID: String?) async throws -> String { "answered" }
            func transform(_ text: String, kind: TextTransformKind, targetID: String?) async throws
                -> String
            { "transformed" }
            func loadModel(_ modelID: String, targetID: String) async throws -> String {
                "operation"
            }
            func unloadActiveModel(targetID: String?) async throws -> String { "operation" }
            func analyseFile(
                _ input: SparkFileAnalysisInput,
                instruction: String,
                targetID: String?
            ) async throws -> SparkAnalysisHandoff { .finished(text: "analysed", truncated: false) }
            func analysisResult(jobID: String, targetID: String?) async throws
                -> SparkAnalysisHandoff
            {
                .finished(text: "analysed", truncated: false)
            }
            func knownTargets() async throws -> [IntentTargetSnapshot] { [] }
            func knownModels() async throws -> [IntentModelSnapshot] { [] }
        }

        /// Several paired Sparks and no target given: the service cannot pick one.
        private struct AmbiguousTargetServices: IntentServicing {
            func status(targetID: String?) async throws -> SparkStatusSnapshot {
                throw SparkIntentError.targetRequired
            }
            func ask(_ question: String, targetID: String?) async throws -> String {
                throw SparkIntentError.targetRequired
            }
            func transform(_ text: String, kind: TextTransformKind, targetID: String?) async throws
                -> String
            { throw SparkIntentError.targetRequired }
            func loadModel(_ modelID: String, targetID: String) async throws -> String {
                throw SparkIntentError.targetRequired
            }
            func unloadActiveModel(targetID: String?) async throws -> String {
                throw SparkIntentError.targetRequired
            }
            func analyseFile(
                _ input: SparkFileAnalysisInput,
                instruction: String,
                targetID: String?
            ) async throws -> SparkAnalysisHandoff { throw SparkIntentError.targetRequired }
            func analysisResult(jobID: String, targetID: String?) async throws
                -> SparkAnalysisHandoff
            {
                throw SparkIntentError.targetRequired
            }
            func knownTargets() async throws -> [IntentTargetSnapshot] { [] }
            func knownModels() async throws -> [IntentModelSnapshot] { [] }
        }

        @Test func everyShippingIntentSummarisesItsParametersForShortcuts() throws {
            let sources = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/SparkIntents")
            var checked = 0
            for name in ["SparkIntents.swift", "AnalysisIntents.swift"] {
                let source = try String(contentsOf: sources.appending(path: name), encoding: .utf8)
                for declaration in source.components(separatedBy: "public struct ").dropFirst()
                where declaration.contains(": AppIntent {") {
                    let intent = declaration.prefix(while: { $0 != ":" })
                        .trimmingCharacters(in: .whitespaces)
                    #expect(
                        declaration.contains("static var parameterSummary"),
                        "\(intent) shows Shortcuts a bare title with no summary"
                    )
                    checked += 1
                }
            }
            #expect(checked == 10, "the shipping intent count changed; the summary check drifted")
        }

        @Test func intentsAnswerInTheBackgroundAndStayDiscoverable() {
            #expect(AskSparkIntent.openAppWhenRun == false)
            #expect(CheckSparkStatusIntent.openAppWhenRun == false)
            #expect(SummarizeWithSparkIntent.openAppWhenRun == false)
            #expect(RewriteWithSparkIntent.openAppWhenRun == false)
            #expect(DraftReplyWithSparkIntent.openAppWhenRun == false)
            #expect(DraftEmailWithSparkIntent.openAppWhenRun == false)
            #expect(LoadSparkModelIntent.openAppWhenRun == false)
            #expect(UnloadActiveModelIntent.openAppWhenRun == false)
            #expect(AnalyseFileWithSparkIntent.openAppWhenRun == false)
            #expect(GetSparkAnalysisIntent.openAppWhenRun == false)

            #expect(AskSparkIntent.isDiscoverable)
            #expect(CheckSparkStatusIntent.isDiscoverable)
            #expect(SummarizeWithSparkIntent.isDiscoverable)
            #expect(RewriteWithSparkIntent.isDiscoverable)
            #expect(DraftReplyWithSparkIntent.isDiscoverable)
            #expect(DraftEmailWithSparkIntent.isDiscoverable)
            #expect(LoadSparkModelIntent.isDiscoverable)
            #expect(UnloadActiveModelIntent.isDiscoverable)
            #expect(AnalyseFileWithSparkIntent.isDiscoverable)
            #expect(GetSparkAnalysisIntent.isDiscoverable)
        }

        @Test func severalSparksMakeSiriAskWhichOneRatherThanFail() async {
            IntentServices.install(AmbiguousTargetServices())
            defer { IntentServices.install(IntentServices.unavailable) }
            await #expect(throws: AppIntentError.self) {
                _ = try await AskSparkIntent(question: "How is the fleet?").perform()
            }
            await #expect(throws: AppIntentError.self) {
                _ = try await CheckSparkStatusIntent().perform()
            }
            await #expect(throws: AppIntentError.self) {
                _ = try await SummarizeWithSparkIntent(text: "Some text").perform()
            }
            await #expect(throws: AppIntentError.self) {
                _ = try await RewriteWithSparkIntent(text: "Some text").perform()
            }
            await #expect(throws: AppIntentError.self) {
                _ = try await DraftReplyWithSparkIntent(text: "Some text").perform()
            }
            await #expect(throws: AppIntentError.self) {
                _ = try await DraftEmailWithSparkIntent(text: "A brief").perform()
            }
            await #expect(throws: AppIntentError.self) {
                _ = try await UnloadActiveModelIntent().perform()
            }
        }

        @Test func loadingWithoutAChosenModelAsksForOneRatherThanFail() async {
            IntentServices.install(OneSparkServices())
            defer { IntentServices.install(IntentServices.unavailable) }
            await #expect(throws: AppIntentError.self) {
                _ = try await LoadSparkModelIntent(model: nil).perform()
            }
        }

        /// A named-but-missing model is a real refusal, not a missing choice.
        @Test func anUninstalledModelStillRefusesWithOwnerCopy() async {
            IntentServices.install(OneSparkServices())
            defer { IntentServices.install(IntentServices.unavailable) }
            await #expect(throws: SparkIntentError.modelNotInstalled(modelID: "Llama on Studio")) {
                _ = try await LoadSparkModelIntent(
                    model: SparkModelEntity(
                        id: "entity",
                        modelID: "llama",
                        targetID: "studio",
                        displayName: "Llama on Studio",
                        installed: false
                    )
                ).perform()
            }
        }
    }

}
