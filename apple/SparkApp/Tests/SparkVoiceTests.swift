import CryptoKit
import Foundation
import SparkAPI
import SparkCore
import SparkBootstrap
import SparkSecurity
import Testing
@testable import SparkAppComposition

private struct VoiceTestStreamer: SparkChatStreaming {
    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        AsyncThrowingStream {
            $0.yield(
                .chunk(
                    id: "voice-test",
                    model: target.modelID,
                    delta: "Spoken answer",
                    reasoning: "Private working",
                    finishReason: "stop"
                )
            )
            $0.yield(.done)
            $0.finish()
        }
    }
}

@MainActor
struct SparkVoiceTests {
    private func model() -> SparkChatModel {
        SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [
                    SparkChatTarget(
                        id: "test",
                        displayName: "Test Spark",
                        nodeID: SparkNodeID(rawValue: UUID()),
                        route: URL(string: "https://fixture.invalid")!,
                        tlsFingerprint: "test",
                        authorityFingerprint: "test",
                        modelID: "test-model",
                        modelName: "Test model"
                    )
                ],
                pairedTargetCount: 1
            ),
            streamer: VoiceTestStreamer()
        )
    }

    /// A chat whose only Spark is reached over `connection`, under the owner's §39.2 policy.
    private func policyModel(
        connection: TargetConnectionState,
        choice: SparkExecutionPolicyModel.Choice,
        asksBeforeRemote: Bool = true
    ) -> SparkChatModel {
        let defaults = UserDefaults(suiteName: "voice-policy-\(UUID().uuidString)")!
        let policy = SparkExecutionPolicyModel(defaults: defaults)
        policy.choice = choice
        policy.asksBeforeRemoteExecution = asksBeforeRemote
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [
                    SparkChatTarget(
                        id: "test",
                        displayName: "Test Spark",
                        nodeID: SparkNodeID(rawValue: UUID()),
                        route: URL(string: "https://fixture.invalid")!,
                        tlsFingerprint: "test",
                        authorityFingerprint: "test",
                        modelID: "test-model",
                        modelName: "Test model",
                        connection: connection
                    )
                ],
                pairedTargetCount: 1
            ),
            streamer: VoiceTestStreamer()
        )
        model.executionPolicy = policy
        return model
    }

    private func voiceTarget(_ chat: SparkChatModel) -> SparkVoiceTarget {
        SparkVoiceTarget(chat.catalogue.targets[0])
    }

    @Test func onDeviceOnlyRefusesASpokenTurnAndSaysWhy() async {
        let model = policyModel(connection: .connectedWiFi, choice: .onDeviceOnly)
        #expect(model.sendVoiceMessage("A spoken question") == nil)
        #expect(model.executionPolicyRefusal?.contains("on this device only") == true)
        #expect(model.messages.isEmpty)
        #expect(model.generationState == .ready)
    }

    @Test func aRemoteRouteHoldsTheSpokenTurnUntilTheOwnerConfirmsIt() async throws {
        let model = policyModel(connection: .connectedRemote, choice: .anyPairedTarget)
        model.draft = "An unfinished typed line"
        #expect(model.sendVoiceMessage("A spoken question") == nil)
        #expect(model.pendingRemoteExecution?.contains("remote connection") == true)
        #expect(model.messages.isEmpty)
        let generation = try #require(model.confirmRemoteExecution())
        await generation.value
        #expect(model.messages.first?.content == "A spoken question")
        #expect(model.messages.last?.content == "Spoken answer")
        #expect(model.draft == "An unfinished typed line")
        #expect(model.pendingRemoteExecution == nil)
    }

    @Test func cancellingTheRemoteQuestionDropsTheSpokenTurn() async {
        let model = policyModel(connection: .connectedRemote, choice: .anyPairedTarget)
        model.draft = "typed"
        #expect(model.sendVoiceMessage("A spoken question") == nil)
        model.cancelRemoteExecution()
        #expect(model.pendingVoicePrompt == nil)
        #expect(model.pendingRemoteExecution == nil)
        model.pendingRemoteExecution = "stale"
        await model.confirmRemoteExecution()?.value
        let sent = model.messages.filter { $0.role == .user }.map(\.content)
        #expect(sent == ["typed"], "the draft, never the dropped turn")
    }

    @Test func aRemoteRouteWithTheQuestionTurnedOffLetsASpokenTurnThrough() async throws {
        let model = policyModel(
            connection: .connectedRemote,
            choice: .anyPairedTarget,
            asksBeforeRemote: false
        )
        let generation = try #require(model.sendVoiceMessage("A spoken question"))
        await generation.value
        #expect(model.messages.last?.content == "Spoken answer")
    }

    @Test func theVoiceSheetSaysAConfirmationIsNeededOnThePhone() async {
        let model = policyModel(connection: .connectedRemote, choice: .anyPairedTarget)
        let voice = SparkVoiceSession(
            chat: model,
            dictationOnly: false,
            conversation: true,
            initialTarget: voiceTarget(model)
        )
        voice.receive("A spoken question")
        #expect(voice.phase == .failed)
        #expect(voice.error?.contains("Confirm it in the chat on your phone") == true)
        #expect(model.pendingRemoteExecution != nil)
        #expect(model.messages.isEmpty)
        voice.stop()
    }

    @Test func theVoiceSheetRepeatsThePolicysOwnRefusal() async {
        let model = policyModel(connection: .connectedWiFi, choice: .onDeviceOnly)
        let voice = SparkVoiceSession(chat: model, dictationOnly: false, conversation: true)
        await voice.prepare()
        #expect(voice.targets.isEmpty, "on this device only hides every Spark")
        #expect(voice.voiceUnavailable == .onDeviceOnlyPolicy)
        #expect(voice.error == SparkVoiceAvailabilityCopy.message(for: .onDeviceOnlyPolicy))
        #expect(!voice.permits(voiceTarget(model)))
        voice.stop()
    }

    @Test func aSurfaceFilterStillAppliesUnderAPermissivePolicy() async {
        let model = policyModel(connection: .connectedWiFi, choice: .sparkOnly)
        let voice = SparkVoiceSession(chat: model, dictationOnly: false, conversation: true)
        #expect(voice.permits(voiceTarget(model)))
        voice.voiceTargetFilter = { _ in false }
        #expect(!voice.permits(voiceTarget(model)))
        await voice.prepare()
        #expect(voice.voiceUnavailable == .sparkUnreachable)
        voice.stop()
    }

    @Test func voiceTurnPreservesTypedDraftAndUsesTheChatStream() async throws {
        let model = model()
        model.draft = "Keep this unfinished typed message"
        let generation = try #require(model.sendVoiceMessage("  A spoken question  "))
        await generation.value
        #expect(model.draft == "Keep this unfinished typed message")
        #expect(model.messages.first?.content == "A spoken question")
        #expect(model.messages.last?.content == "Spoken answer")
        #expect(model.messages.last?.reasoning == "Private working")
        #expect(SparkVoiceSession.spokenText(model.messages.last!.content) == "Spoken answer")
    }

    @Test func voiceTurnCannotInterruptAnExistingGenerationOrSendBlankSpeech() async throws {
        let model = model()
        #expect(model.sendVoiceMessage(" \n ") == nil)
        let first = try #require(model.sendVoiceMessage("First question"))
        #expect(model.sendVoiceMessage("Second question") == nil)
        await first.value
        #expect(model.messages.filter { $0.role == .user }.count == 1)
    }

    @Test func closingAnUnusedVoiceSheetDoesNotCancelATextRequest() async throws {
        let model = model()
        model.draft = "A text question"
        let generation = try #require(model.send())
        let voice = SparkVoiceSession(chat: model, dictationOnly: false)
        voice.stop()
        #expect(model.generationState == .streaming)
        await generation.value
        #expect(model.generationState == .ready)
    }

    @Test func speechRemovesMarkdownAndKeepsCodeInTheTranscript() {
        let text = SparkVoiceSession.spokenText(
            "# A heading\n\nA **clear** [answer](https://example.invalid).\n\n```sh\nrm -rf example\n```"
        )
        #expect(text.contains("A heading"))
        #expect(text.contains("A clear answer."))
        #expect(!text.contains("**"))
        #expect(!text.contains("rm -rf"))
        #expect(!text.contains("https://"))
    }

    @Test func readingWithoutAVoicePackDoesNotSendAMessageOrCancelATextReply() async throws {
        let model = model()
        model.draft = "My unfinished message"
        let generation = try #require(model.sendVoiceMessage("A question"))
        let session = SparkVoiceSession(chat: model, dictationOnly: false)
        session.readAloud("An older answer")
        #expect(session.phase == .needsDownload)
        #expect(model.generationState == .streaming)
        #expect(model.draft == "My unfinished message")
        await generation.value
        #expect(model.messages.filter { $0.role == .user }.count == 1)
        #expect(model.messages.last?.content == "Spoken answer")
    }

    @Test func initialInstallCarriesTheSignedRuntimeWithKokoroSupport() async throws {
        let source = try #require(BootstrapComposition.bundledReleaseSource())
        let root = try BootstrapComposition.trustRoot()
        let verified = try root.verify(manifest: await source.manifest(), at: Date())
        #expect(verified.manifest.version == "0.1.13")
        let available = try await RuntimeBootstrapInstaller(
            trustRoot: root,
            source: source
        ).availableUpdateReleaseID()
        #expect(available == "dev-0.1.13-0qa20260908.1")
        #expect(
            SparkSettingsFailurePresentation.release(
                available,
                differsFromInstalledVersion: "0.1.13"
            )
        )
        #expect(
            !SparkSettingsFailurePresentation.release(
                available,
                differsFromInstalledVersion: "0.1.13-0qa20260908.1"
            )
        )
        #expect(
            SparkSettingsFailurePresentation.release(
                available,
                differsFromInstalledVersion: "0.1.12"
            )
        )
        let artifact = try #require(verified.manifest.artifacts.first)
        #expect(artifact.name == "spark-runtime_0.1.13-0qa20260908.1_arm64.deb")
        let data = try await source.artifact(artifact)
        let encoded = String(decoding: try await source.detachedSignature(artifact), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let signature = try #require(Base64URL.decode(encoded))
        try root.verifyDetached(
            keyID: verified.keyID,
            payload: data,
            signature: signature,
            at: Date(),
            channel: verified.manifest.channel
        )
        #expect(data.count == artifact.size)
        #expect(SHA256Digest.hex(data) == artifact.sha256)
    }

    @Test func speechKeepsNaturalSentencesAndBoundsLongReplies() {
        let text = "Hello! I’m happy you’re here. Take a breath and make yourself comfortable."
        let chunks = SparkVoiceSession.speechChunks(text)
        #expect(chunks.count == 1)
        #expect(chunks[0].contains("Take a breath"))
        let long = SparkVoiceSession.speechChunks(
            String(repeating: "A longer sentence. ", count: 1_000)
        )
        #expect(long.count > 1)
        #expect(long.allSatisfy { $0.utf8.count <= 6_000 })
    }
}
