import Foundation
import FoundationModels
import SparkAPI
import Testing
@testable import SparkLanguageModel

// MARK: - Executor identity (§39.4)

@Test func executorConfigurationHashesStableIdentityOnly() {
    let capabilities = SparkModelCapabilities(
        toolCalling: true,
        guidedGeneration: false,
        reasoning: true,
        securityContextID: UUID(),
        revision: "r3"
    )
    let descriptor = SparkLanguageModelDescriptor(
        target: "spark/abc",
        modelID: "llama-8b",
        capabilities: capabilities
    )

    let first = descriptor.executorConfiguration(routingPolicyVersion: 4)
    let second = descriptor.executorConfiguration(routingPolicyVersion: 4)
    #expect(first == second, "same inputs, same identity")

    let bumped = descriptor.executorConfiguration(routingPolicyVersion: 5)
    #expect(first != bumped, "policy version is part of the cache identity")
    #expect(first.target == "spark/abc")
    #expect(first.modelID == "llama-8b")
    #expect(first.capabilityRevision == "r3")
}

@Test func unsupportedCapabilitiesSurfaceActionably() {
    let textOnly = SparkLanguageModelDescriptor(
        target: "spark/abc",
        modelID: "m",
        capabilities: .textOnly(securityContextID: UUID())
    )
    #expect(textOnly.require(.toolCalling) == .toolCalling)
    #expect(textOnly.require(.guidedGeneration) == .guidedGeneration)
    #expect(textOnly.require(.reasoning) == .reasoning)

    let capable = SparkLanguageModelDescriptor(
        target: "spark/abc",
        modelID: "m",
        capabilities: SparkModelCapabilities(
            toolCalling: true,
            guidedGeneration: true,
            reasoning: true,
            securityContextID: UUID(),
            revision: "1"
        )
    )
    #expect(capable.require(.toolCalling) == nil)
    #expect(capable.require(.reasoning) == nil)
}

// MARK: - Transcript mapping (§39.6/§39.7)

@Test func transcriptMapsToChatRoles() throws {
    let instructions = Transcript.Instructions(
        segments: [.text(.init(content: "You are a private assistant."))],
        toolDefinitions: []
    )
    let prompt = Transcript.Prompt(
        segments: [.text(.init(content: "Summarise this document."))]
    )
    let response = Transcript.Response(
        assetIDs: [],
        segments: [.text(.init(content: "Here is the summary."))]
    )
    let transcript = Transcript(entries: [
        .instructions(instructions),
        .prompt(prompt),
        .response(response),
    ])

    let request = try SparkTranscriptMapper.map(
        transcript: transcript,
        generationOptions: GenerationOptions(),
        modelID: "llama-8b"
    )

    #expect(request.model == "llama-8b")
    #expect(request.stream)
    #expect(request.streamOptionsIncludeUsage == true)
    #expect(request.messages.map(\.role) == ["system", "user", "assistant"])
    #expect(request.messages[0].content == "You are a private assistant.")
    #expect(request.messages[1].content == "Summarise this document.")
    #expect(request.messages[2].content == "Here is the summary.")
}

@Test func generationOptionsTranslateOnlySupportedOnes() throws {
    var request = ChatCompletionRequest(model: "m", messages: [])
    try SparkTranscriptMapper.apply(
        generationOptions: GenerationOptions(temperature: 0.7, maximumResponseTokens: 512),
        to: &request
    )
    #expect(request.temperature == 0.7)
    #expect(request.maxTokens == 512)

    // Greedy overrides to deterministic decoding.
    try SparkTranscriptMapper.apply(
        generationOptions: GenerationOptions(sampling: .greedy),
        to: &request
    )
    #expect(request.temperature == 0)

    // Assert that unsupported constrained sampling fails rather than disappearing from the request.
    var loose = ChatCompletionRequest(model: "m", messages: [])
    #expect(throws: SparkInferenceError.self) {
        try SparkTranscriptMapper.apply(
            generationOptions: GenerationOptions(sampling: .random(top: 8)),
            to: &loose
        )
    }
    #expect(loose.temperature == nil, "and nothing was written on the way out")
}

@Test func structuredAndToolContentThrowInsteadOfDropping() {
    let structuredPrompt = Transcript.Prompt(
        segments: [
            .text(.init(content: "before")),
            .structure(.init(source: "image", content: GeneratedContent("data"))),
        ]
    )
    #expect(throws: SparkInferenceError.self) {
        _ = try SparkTranscriptMapper.map(
            transcript: Transcript(entries: [.prompt(structuredPrompt)]),
            generationOptions: GenerationOptions(),
            modelID: "m"
        )
    }

    let toolEntry = Transcript.Entry.toolCalls(
        Transcript.ToolCalls(id: "1", [Transcript.ToolCall]())
    )
    #expect(throws: SparkInferenceError.self) {
        _ = try SparkTranscriptMapper.map(
            transcript: Transcript(entries: [toolEntry]),
            generationOptions: GenerationOptions(),
            modelID: "m"
        )
    }

    // An empty transcript is an error, not an empty request.
    #expect(throws: SparkInferenceError.self) {
        _ = try SparkTranscriptMapper.map(
            transcript: Transcript(),
            generationOptions: GenerationOptions(),
            modelID: "m"
        )
    }
}

// MARK: - Readiness policy (§39.9)

private struct Probes: EngineReadinessProbing, Sendable {
    var active: String?
    var installed: Set<String>

    func activeModelID() async throws -> String? { active }

    func isInstalled(modelID: String) async throws -> Bool {
        installed.contains(modelID)
    }

    func startLoad(modelID: String) async throws {}
}

private struct StaticStream: ChatStreaming, Sendable {
    var events: [ChatStreamEvent]

    func stream(_ request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

@Test func ensureReadyFollowsThePolicyLadder() async throws {
    // Ready → continue without side effects.
    let ready = Probes(active: "llama-8b", installed: ["llama-8b"])
    let client = SparkInferenceClient(
        probes: ready,
        chat: StaticStream(events: [])
    )
    try await client.ensureReady(modelID: "llama-8b", reason: .generationRequest)

    // Installed but idle → durable load proceeds.
    let idle = Probes(active: nil, installed: ["llama-8b"])
    let loading = SparkInferenceClient(
        probes: idle,
        chat: StaticStream(events: [])
    )
    try await loading.ensureReady(modelID: "llama-8b", reason: .explicitUserAction)

    // Another model active → explicit replacement, never silent unload.
    let busy = Probes(active: "qwen-72b", installed: ["llama-8b"])
    let busyClient = SparkInferenceClient(
        probes: busy,
        chat: StaticStream(events: [])
    )
    await #expect(throws: SparkInferenceError.self) {
        try await busyClient.ensureReady(modelID: "llama-8b", reason: .generationRequest)
    }

    // Not installed → actionable error, no download.
    let absent = Probes(active: nil, installed: [])
    let absentClient = SparkInferenceClient(
        probes: absent,
        chat: StaticStream(events: [])
    )
    await #expect(throws: SparkInferenceError.self) {
        try await absentClient.ensureReady(modelID: "llama-8b", reason: .foundationModelsPrewarm)
    }
}

@Test func streamRunsReadinessThenStreams() async throws {
    let events: [ChatStreamEvent] = [
        .chunk(id: "1", model: "llama-8b", delta: "Hello", finishReason: nil),
        .chunk(id: "1", model: "llama-8b", delta: nil, finishReason: "stop"),
        .usage(prompt: 12, completion: 2, total: 14),
        .done,
    ]
    let client = SparkInferenceClient(
        probes: Probes(active: nil, installed: ["llama-8b"]),
        chat: StaticStream(events: events)
    )

    var received: [String] = []
    let stream = try await client.stream(
        modelID: "llama-8b",
        request: ChatCompletionRequest(model: "llama-8b", messages: [])
    )
    for try await event in stream {
        if case .chunk(_, _, let delta, _, _) = event, let delta {
            received.append(delta)
        }
    }
    #expect(received == ["Hello"])
}

// MARK: - Event accumulation + metadata (§39.8)

@Test func accumulatorProducesTypedMetadata() {
    let (accumulator, deltas) = SparkStreamAccumulator.accumulate(
        [
            .chunk(id: "1", model: "llama-8b", delta: "Hel", finishReason: nil),
            .chunk(id: "1", model: "llama-8b", delta: "lo", finishReason: nil),
            .chunk(id: "1", model: "llama-8b", delta: nil, finishReason: "stop"),
            .usage(prompt: 20, completion: 5, total: 25),
            .done,
        ],
        nodeID: "node-1"
    )

    #expect(accumulator.responseText == "Hello")
    #expect(deltas == ["Hel", "lo"])

    let metadata = accumulator.metadata(modelID: "llama-8b", requestID: "req-9")
    #expect(metadata.modelID == "llama-8b")
    #expect(metadata.requestID == "req-9")
    #expect(metadata.nodeID == "node-1")
    #expect(metadata.finishReason == "stop")
    #expect(metadata.promptTokens == 20)
    #expect(metadata.completionTokens == 5)

    let keys = metadata.metadataKeys
    #expect(keys["spark.modelID"] == "llama-8b")
    #expect(keys["spark.requestID"] == "req-9")
    #expect(keys["spark.nodeID"] == "node-1")
    #expect(keys["spark.finishReason"] == "stop")
    #expect(keys["spark.promptTokens"] == "20")
    #expect(keys["spark.completionTokens"] == "5")
    #expect(keys["spark.transport"] == "spark")
    #expect(keys["spark.executionLocation"] == "spark/node-1")
}

// MARK: - Generation options, timing and readiness coverage

@Test func aModelThatIsNotInstalledSaysSoEvenWhenAnotherIsLoaded() async throws {
    // Report a missing requested model before offering to unload a different active model.
    let client = SparkInferenceClient(
        probes: Probes(active: "qwen-72b", installed: ["qwen-72b"]),
        chat: StaticStream(events: [])
    )
    await #expect(throws: SparkInferenceError.modelNotInstalled(modelID: "llama-8b")) {
        try await client.ensureReady(modelID: "llama-8b", reason: .generationRequest)
    }
}

@Test func replacementIsStillReportedWhenTheRequestedModelIsInstalled() async throws {
    // Recognize the case where unloading the active model would make installation possible.
    let client = SparkInferenceClient(
        probes: Probes(active: "qwen-72b", installed: ["qwen-72b", "llama-8b"]),
        chat: StaticStream(events: [])
    )
    await #expect(
        throws: SparkInferenceError.modelReplacementRequired(
            activeModelID: "qwen-72b",
            requestedModelID: "llama-8b"
        )
    ) {
        try await client.ensureReady(modelID: "llama-8b", reason: .generationRequest)
    }
}

@Test func timeToFirstTokenMeasuresTheWaitNotTheGeneration() {
    // Use an event-controlled clock to distinguish request-to-first-token latency from generation duration.
    let clock = SettableClock(nanoseconds: 100_000_000)  // request goes out at 100ms
    var accumulator = SparkStreamAccumulator(nodeID: "node-1", clock: clock.read)

    clock.nanoseconds = 400_000_000  // first token lands 300ms later
    _ = accumulator.consume(.chunk(id: "1", model: "m", delta: "Hi", finishReason: nil))
    clock.nanoseconds = 1_400_000_000  // and it generates for another second
    _ = accumulator.consume(.done)
    accumulator.recordUsage(prompt: 10, completion: 100)

    let metadata = accumulator.metadata(modelID: "m")
    #expect(
        metadata.timeToFirstTokenMilliseconds == 300,
        "300ms of waiting, not the 1000ms of generating"
    )
    #expect(
        metadata.tokensPerSecond == 100,
        "100 tokens over the 1s the stream was actually producing"
    )
}

@Test func metadataOnlyChunkDoesNotCountAsTheFirstToken() {
    let clock = SettableClock(nanoseconds: 100_000_000)
    var accumulator = SparkStreamAccumulator(nodeID: "node-1", clock: clock.read)

    clock.nanoseconds = 200_000_000
    _ = accumulator.consume(.chunk(id: "1", model: "m", delta: nil, finishReason: nil))
    #expect(accumulator.metadata().timeToFirstTokenMilliseconds == nil)

    clock.nanoseconds = 450_000_000
    _ = accumulator.consume(.chunk(id: "1", model: "m", delta: "Hi", finishReason: nil))
    #expect(accumulator.metadata().timeToFirstTokenMilliseconds == 350)
}

@Test func samplingTheProxyCannotExpressIsRefusedNotIgnored() throws {
    // Reject unsupported top-k or top-p constraints instead of accepting server-default sampling (§39.7).
    var request = ChatCompletionRequest(model: "m", messages: [])
    #expect(throws: SparkInferenceError.self) {
        try SparkTranscriptMapper.apply(
            generationOptions: GenerationOptions(sampling: .random(top: 8)),
            to: &request
        )
    }
    #expect(throws: SparkInferenceError.self) {
        try SparkTranscriptMapper.apply(
            generationOptions: GenerationOptions(sampling: .random(probabilityThreshold: 0.9)),
            to: &request
        )
    }
}

@Test func supportedSamplingStillTranslates() throws {
    // Continue accepting representable greedy and temperature options.
    var greedy = ChatCompletionRequest(model: "m", messages: [])
    try SparkTranscriptMapper.apply(
        generationOptions: GenerationOptions(sampling: .greedy, temperature: 0.7),
        to: &greedy
    )
    #expect(greedy.temperature == 0, "greedy is deterministic decoding")

    var sampled = ChatCompletionRequest(model: "m", messages: [])
    try SparkTranscriptMapper.apply(
        generationOptions: GenerationOptions(temperature: 0.4, maximumResponseTokens: 256),
        to: &sampled
    )
    #expect(sampled.temperature == 0.4)
    #expect(sampled.maxTokens == 256)
}

/// Control named clock instants independently of how often production code reads them.
private final class SettableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(nanoseconds: UInt64) { self.value = nanoseconds }

    var nanoseconds: UInt64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    var read: @Sendable () -> DispatchTime {
        { [self] in DispatchTime(uptimeNanoseconds: nanoseconds) }
    }
}

// MARK: - §39.6 silent drops: content the proxy cannot carry

@Test func aGuidedGenerationSchemaIsRefusedRatherThanDropped() throws {
    // Reject unsupported response schemas before callers receive unstructured output they cannot safely decode.
    let prompt = Transcript.Prompt(
        segments: [.text(Transcript.TextSegment(content: "Summarise this"))],
        responseFormat: Transcript.ResponseFormat(type: AuditSummary.self)
    )
    let transcript = Transcript(entries: [.prompt(prompt)])
    #expect(throws: SparkInferenceError.self) {
        _ = try SparkTranscriptMapper.map(
            transcript: transcript,
            generationOptions: GenerationOptions(),
            modelID: "m"
        )
    }
}

@Test func toolDefinitionsAreRefusedWhereTheyAreDeclared() throws {
    // Reject tool definitions at transcript mapping rather than failing only when a later call is produced.
    let instructions = Transcript.Instructions(
        segments: [.text(Transcript.TextSegment(content: "You may search."))],
        toolDefinitions: [
            Transcript.ToolDefinition(
                name: "search",
                description: "Search the project",
                parameters: GenerationSchema(
                    type: String.self,
                    description: "query",
                    properties: []
                )
            )
        ]
    )
    let transcript = Transcript(entries: [.instructions(instructions)])
    #expect(throws: SparkInferenceError.self) {
        _ = try SparkTranscriptMapper.map(
            transcript: transcript,
            generationOptions: GenerationOptions(),
            modelID: "m"
        )
    }
}

@Test func perPromptGenerationOptionsAreNotIgnored() throws {
    // Honor each prompt's generation options in addition to request-level defaults.
    let prompt = Transcript.Prompt(
        segments: [.text(Transcript.TextSegment(content: "Hello"))],
        options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 32)
    )
    let request = try SparkTranscriptMapper.map(
        transcript: Transcript(entries: [.prompt(prompt)]),
        generationOptions: GenerationOptions(),
        modelID: "m"
    )
    #expect(request.temperature == 0.1)
    #expect(request.maxTokens == 32)
}

@Test func theStreamsOwnIdentifiersAndUsageAreKept() {
    // Retain request/model identifiers and usage totals directly from consumed stream events.
    var accumulator = SparkStreamAccumulator(nodeID: "node-1")
    _ = accumulator.consume(
        .chunk(id: "req-42", model: "qwen-72b-awq", delta: "Hi", finishReason: nil)
    )
    _ = accumulator.consume(.usage(prompt: 100, completion: 20, total: 120))
    _ = accumulator.consume(.done)

    let metadata = accumulator.metadata()
    #expect(metadata.requestID == "req-42", "the id the server gave this request")
    #expect(metadata.modelID == "qwen-72b-awq", "the model that actually answered")
    #expect(metadata.promptTokens == 100)
    #expect(metadata.completionTokens == 20)
}

/// Use a minimal Generable schema to exercise guided generation.
@Generable
private struct AuditSummary {
    @Guide(description: "one sentence")
    var summary: String
}

@Test func onlyTheAnsweredPromptsOptionsApply() throws {
    // Do not apply historical prompt token caps to the current answer.
    let earlier = Transcript.Prompt(
        segments: [.text(Transcript.TextSegment(content: "First"))],
        options: GenerationOptions(temperature: 0.9, maximumResponseTokens: 8)
    )
    let current = Transcript.Prompt(
        segments: [.text(Transcript.TextSegment(content: "Second"))],
        options: GenerationOptions(temperature: 0.2)
    )
    let request = try SparkTranscriptMapper.map(
        transcript: Transcript(entries: [.prompt(earlier), .prompt(current)]),
        generationOptions: GenerationOptions(maximumResponseTokens: 512),
        modelID: "m"
    )
    #expect(request.temperature == 0.2, "the turn being answered")
    #expect(request.maxTokens == 512, "and the request-level cap, not the old turn's 8")
}
