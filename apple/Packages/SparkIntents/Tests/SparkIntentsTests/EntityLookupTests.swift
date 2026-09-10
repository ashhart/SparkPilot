import AppIntents
import Foundation
import Testing

@testable import SparkIntents

/// Nest under the same serialized parent as the other intent suites because they share a process-global service registry.
extension SparkIntentTests {

    /// Siri hands a query the words a person said; without a string query it can only offer a list to tap.
    @Suite(.serialized) struct EntityLookupTests {
        private struct NamedServices: IntentServicing {
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
            func knownTargets() async throws -> [IntentTargetSnapshot] {
                [
                    IntentTargetSnapshot(id: "studio", displayName: "Studio Spark"),
                    IntentTargetSnapshot(id: "loft", displayName: "Loft Spark"),
                    IntentTargetSnapshot(id: "lab", displayName: "Café Lab", kind: .cluster),
                ]
            }
            func knownModels() async throws -> [IntentModelSnapshot] {
                [
                    IntentModelSnapshot(
                        id: "one",
                        modelID: "llama-3",
                        targetID: "studio",
                        displayName: "Llama 3 on Studio Spark",
                        installed: true
                    ),
                    IntentModelSnapshot(
                        id: "two",
                        modelID: "qwen",
                        targetID: "loft",
                        displayName: "Qwen on Loft Spark",
                        installed: true
                    ),
                ]
            }
        }

        @Test func aSpokenSparkNameFindsThatSpark() async throws {
            IntentServices.install(NamedServices())
            defer { IntentServices.install(IntentServices.unavailable) }
            let query = SparkTargetQuery()
            #expect(try await query.entities(matching: "studio").map(\.id) == ["studio"])
            #expect(try await query.entities(matching: "Loft").map(\.id) == ["loft"])
            // Siri transcribes without diacritics as often as with them.
            #expect(try await query.entities(matching: "cafe").map(\.id) == ["lab"])
            #expect(try await query.entities(matching: "Spark").map(\.id) == ["studio", "loft"])
            #expect(try await query.entities(matching: "kitchen").isEmpty)
            #expect(try await query.entities(matching: "   ").isEmpty)
        }

        @Test func aSpokenModelNameFindsThatModel() async throws {
            IntentServices.install(NamedServices())
            defer { IntentServices.install(IntentServices.unavailable) }
            let query = SparkModelQuery()
            #expect(try await query.entities(matching: "llama").map(\.id) == ["one"])
            #expect(try await query.entities(matching: "loft").map(\.id) == ["two"])
            #expect(try await query.entities(matching: "mistral").isEmpty)
        }

        /// A Spark nobody has paired must not resolve into a shortcut.
        @Test func anUnknownNameResolvesToNothingRatherThanEverything() async throws {
            IntentServices.install(IntentServices.unavailable)
            #expect(try await SparkTargetQuery().entities(matching: "studio").isEmpty)
            #expect(try await SparkModelQuery().entities(matching: "llama").isEmpty)
        }
    }

}
