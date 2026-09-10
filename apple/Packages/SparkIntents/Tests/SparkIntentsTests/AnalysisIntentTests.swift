import AppIntents
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import SparkIntents

/// Nest intent suites under one serialized parent because they share a process-global service registry.
extension SparkIntentTests {

    @Suite(.serialized)
    struct SparkAnalysisIntentTests {
        private final class FakeAnalysisServices: IntentServicing, @unchecked Sendable {
            var handoff: SparkAnalysisHandoff = .finished(text: "Three risks.", truncated: false)
            var resultHandoff: SparkAnalysisHandoff = .finished(
                text: "Three risks.",
                truncated: false
            )
            var capturedInput: SparkFileAnalysisInput?
            var capturedInstruction: String?
            var capturedTargetID: String?
            var capturedJobID: String?
            var failure: SparkIntentError?

            func status(targetID: String?) async throws -> SparkStatusSnapshot {
                throw SparkIntentError.noPairedSpark
            }
            func ask(_ question: String, targetID: String?) async throws -> String {
                throw SparkIntentError.noPairedSpark
            }
            func transform(_ text: String, kind: TextTransformKind, targetID: String?) async throws
                -> String
            {
                throw SparkIntentError.noPairedSpark
            }
            func loadModel(_ modelID: String, targetID: String) async throws -> String {
                throw SparkIntentError.noPairedSpark
            }
            func unloadActiveModel(targetID: String?) async throws -> String {
                throw SparkIntentError.noPairedSpark
            }
            func knownTargets() async throws -> [IntentTargetSnapshot] { [] }
            func knownModels() async throws -> [IntentModelSnapshot] { [] }

            func analyseFile(
                _ input: SparkFileAnalysisInput,
                instruction: String,
                targetID: String?
            ) async throws -> SparkAnalysisHandoff {
                if let failure { throw failure }
                capturedInput = input
                capturedInstruction = instruction
                capturedTargetID = targetID
                return handoff
            }

            func analysisResult(
                jobID: String,
                targetID: String?
            ) async throws -> SparkAnalysisHandoff {
                if let failure { throw failure }
                capturedJobID = jobID
                capturedTargetID = targetID
                return resultHandoff
            }
        }

        private func install(_ services: FakeAnalysisServices) {
            IntentServices.install(services)
        }

        // MARK: - §40.5 file handling

        /// Reject unsupported analysis types before upload with actionable guidance (§40.5).
        @Test func onlyTextTypesAreAccepted() throws {
            let text = try SparkFileAnalysisInput.extract(
                data: Data("Risk one. Risk two.".utf8),
                contentType: .plainText,
                suggestedName: "board-notes.txt"
            )
            #expect(text.text == "Risk one. Risk two.")
            #expect(text.sourceName == "board-notes.txt")

            // Source code and structured text are still text.
            #expect(
                throws: Never.self,
                performing: {
                    try SparkFileAnalysisInput.extract(
                        data: Data("{\"a\":1}".utf8),
                        contentType: .json,
                        suggestedName: "payload.json"
                    )
                }
            )

            for unsupported: UTType in [.png, .jpeg, .pdf, .mp3, .zip] {
                #expect(throws: SparkIntentError.self) {
                    try SparkFileAnalysisInput.extract(
                        data: Data([0x00, 0x01, 0x02]),
                        contentType: unsupported,
                        suggestedName: "thing"
                    )
                }
            }
        }

        /// Validate UTF-8 bytes independently of the file's claimed text type.
        @Test func textTypedBytesMustActuallyDecode() {
            #expect(throws: SparkIntentError.self) {
                try SparkFileAnalysisInput.extract(
                    data: Data([0xFF, 0xFE, 0x00, 0x9C]),
                    contentType: .plainText,
                    suggestedName: "claims-to-be-text.txt"
                )
            }
        }

        @Test func emptyFilesAreRefusedRatherThanSentAsAnEmptyPrompt() {
            #expect(throws: SparkIntentError.self) {
                try SparkFileAnalysisInput.extract(
                    data: Data("   \n\t ".utf8),
                    contentType: .plainText,
                    suggestedName: "blank.txt"
                )
            }
        }

        /// Enforce and name the upload size limit before any document leaves the device (§40.5).
        @Test func oversizeFilesAreRefusedBeforeAnythingLeavesTheDevice() {
            let oversize = Data(
                repeating: UInt8(ascii: "a"),
                count: SparkFileAnalysisInput.maxBytes + 1
            )
            #expect(throws: SparkIntentError.self) {
                try SparkFileAnalysisInput.extract(
                    data: oversize,
                    contentType: .plainText,
                    suggestedName: "huge.txt"
                )
            }
            // Format the upload limit using the reader's locale.
            #expect(
                SparkIntentError.requestTooLarge(limitBytes: SparkFileAnalysisInput.maxBytes)
                    .displayMessage
                    .contains(SparkFileAnalysisInput.maxBytes.formatted())
            )

            // Accept input exactly at the documented byte limit.
            let atLimit = Data(repeating: UInt8(ascii: "a"), count: SparkFileAnalysisInput.maxBytes)
            #expect(
                throws: Never.self,
                performing: {
                    try SparkFileAnalysisInput.extract(
                        data: atLimit,
                        contentType: .plainText,
                        suggestedName: "exact.txt"
                    )
                }
            )
        }

        /// Send only a display label so analysis prompts never expose the owner's directory layout (§40.5).
        @Test func theSourceNameIsALabelAndNeverAPath() throws {
            let input = try SparkFileAnalysisInput.extract(
                data: Data("hello".utf8),
                contentType: .plainText,
                suggestedName: "/Users/example/Private/Clients/acme/contract.txt"
            )
            #expect(input.sourceName == "contract.txt")
            #expect(!input.sourceName.contains("/"))

            let long = String(repeating: "n", count: 400) + ".txt"
            let bounded = try SparkFileAnalysisInput.extract(
                data: Data("hello".utf8),
                contentType: .plainText,
                suggestedName: long
            )
            #expect(bounded.sourceName.utf8.count <= SparkFileAnalysisInput.maxSourceNameBytes)

            // A file with no usable name still analyses; it just has no label.
            let unnamed = try SparkFileAnalysisInput.extract(
                data: Data("hello".utf8),
                contentType: .plainText,
                suggestedName: nil
            )
            #expect(unnamed.sourceName.isEmpty)
        }

        // MARK: - The intents

        @Test func analyseFileIntentRoutesThroughTheServicesSeam() async throws {
            let services = FakeAnalysisServices()
            install(services)
            defer { IntentServices.install(IntentServices.unavailable) }

            let intent = AnalyseFileWithSparkIntent(
                file: IntentFile(
                    data: Data("Risk one. Risk two.".utf8),
                    filename: "board-notes.txt",
                    type: .plainText
                ),
                instruction: "List the risks.",
                target: SparkTargetEntity(id: "node-1", displayName: "Studio Spark")
            )
            let result = try await intent.perform()
            _ = result

            #expect(services.capturedInput?.text == "Risk one. Risk two.")
            #expect(services.capturedInput?.sourceName == "board-notes.txt")
            #expect(services.capturedInstruction == "List the risks.")
            #expect(services.capturedTargetID == "node-1")
        }

        /// Identify durable work that outlives the intent without claiming it finished or was cancelled (§40.3).
        @Test func anUnfinishedAnalysisHandsOffTheJobInsteadOfClaimingAnAnswer() async {
            let services = FakeAnalysisServices()
            services.handoff = .running(jobID: "6f1c9f4e-0000-4000-8000-000000000001")
            install(services)
            defer { IntentServices.install(IntentServices.unavailable) }

            let intent = AnalyseFileWithSparkIntent(
                file: IntentFile(
                    data: Data("A very long document.".utf8),
                    filename: "long.txt",
                    type: .plainText
                ),
                instruction: "Summarise it."
            )
            await #expect(throws: SparkIntentError.self) {
                _ = try await intent.perform()
            }

            let message = SparkIntentError.analysisContinuesOnSpark(
                jobID: "6f1c9f4e-0000-4000-8000-000000000001"
            ).displayMessage
            #expect(message.contains("6f1c9f4e-0000-4000-8000-000000000001"))
            #expect(message.contains("Get Spark Analysis"))
            // It must not promise a screen the app does not have.
            #expect(!message.lowercased().contains("open sparkpilot"))
        }

        @Test func getAnalysisIntentReturnsAFinishedAnswer() async throws {
            let services = FakeAnalysisServices()
            services.resultHandoff = .finished(text: "Two risks, both funding.", truncated: false)
            install(services)
            defer { IntentServices.install(IntentServices.unavailable) }

            let intent = GetSparkAnalysisIntent(jobID: "6f1c9f4e-0000-4000-8000-000000000001")
            _ = try await intent.perform()
            #expect(services.capturedJobID == "6f1c9f4e-0000-4000-8000-000000000001")
        }

        /// Report a running analysis as pending rather than returning an empty answer.
        @Test func getAnalysisIntentRefusesToInventAnAnswerForARunningJob() async {
            let services = FakeAnalysisServices()
            services.resultHandoff = .running(jobID: "6f1c9f4e-0000-4000-8000-000000000001")
            install(services)
            defer { IntentServices.install(IntentServices.unavailable) }

            await #expect(throws: SparkIntentError.self) {
                _ = try await GetSparkAnalysisIntent(
                    jobID: "6f1c9f4e-0000-4000-8000-000000000001"
                ).perform()
            }
        }

        /// Validate and bound job identifiers before inserting them into request paths.
        @Test func jobIdentifiersAreValidatedBeforeTheyBecomeARequest() async {
            let services = FakeAnalysisServices()
            install(services)
            defer { IntentServices.install(IntentServices.unavailable) }

            for bad in [
                "", "  ", "../../operations", String(repeating: "a", count: 500), "not-a-uuid",
            ] {
                await #expect(throws: SparkIntentError.self, "\(bad) must be refused") {
                    _ = try await GetSparkAnalysisIntent(jobID: bad).perform()
                }
            }
            #expect(services.capturedJobID == nil, "nothing malformed reached the service")
        }

        /// Explain missing pairing for every intent instead of crashing or returning no result (§40.9).
        @Test func unavailableServicesExplainPairingForTheAnalysisIntents() async {
            IntentServices.install(IntentServices.unavailable)

            await #expect(throws: SparkIntentError.self) {
                _ = try await AnalyseFileWithSparkIntent(
                    file: IntentFile(data: Data("hello".utf8), filename: "a.txt", type: .plainText),
                    instruction: "Summarise it."
                ).perform()
            }
            await #expect(throws: SparkIntentError.self) {
                _ = try await GetSparkAnalysisIntent(
                    jobID: "6f1c9f4e-0000-4000-8000-000000000001"
                ).perform()
            }
        }

        /// Distinguish truncated analysis results from complete answers.
        @Test func aTruncatedAnalysisSaysSo() {
            #expect(SparkAnalysisHandoff.finished(text: "…", truncated: true).isTruncated)
            #expect(!SparkAnalysisHandoff.finished(text: "…", truncated: false).isTruncated)
            #expect(!SparkAnalysisHandoff.running(jobID: "x").isTruncated)
        }
    }

}
