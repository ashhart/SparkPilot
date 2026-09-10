import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import SwiftUI
import Testing
@testable import SparkAppComposition

struct ChatTestStaticChatStreamer: SparkChatStreaming {
    let events: [ChatStreamEvent]

    func stream(
        target: SparkChatTarget,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

struct ChatTestFailingChatStreamer: SparkChatStreaming {
    let error: ChatError

    func stream(
        target: SparkChatTarget,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        throw error
    }
}

actor ChatTestControlledChatStreamer: SparkChatStreaming {
    private var continuations: [AsyncThrowingStream<ChatStreamEvent, any Error>.Continuation] = []
    private(set) var requests: [ChatCompletionRequest] = []

    func stream(
        target: SparkChatTarget,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatStreamEvent, any Error>.makeStream()
        continuations.append(continuation)
        requests.append(request)
        return stream
    }

    func isConnected() -> Bool { !continuations.isEmpty }
    func emit(_ event: ChatStreamEvent, streamIndex: Int? = nil) {
        guard let index = streamIndex ?? continuations.indices.last else { return }
        continuations[index].yield(event)
    }
    func finish(throwing error: (any Error)? = nil) {
        continuations.last?.finish(throwing: error)
    }
}

struct ChatTestNetworkFailingChatStreamer: SparkChatStreaming {
    func stream(
        target: SparkChatTarget,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        throw URLError(.notConnectedToInternet)
    }
}

enum ChatTestChatTransportFailureScenario: CaseIterable, Sendable {
    case disconnected
    case unknownURLFailure
    case unknownFailure

    var error: any Error {
        switch self {
        case .disconnected: URLError(.notConnectedToInternet)
        case .unknownURLFailure:
            URLError(
                .unknown,
                userInfo: [NSLocalizedDescriptionKey: "Private transport diagnostic"]
            )
        case .unknownFailure:
            NSError(
                domain: "PrivateTransportDiagnostic",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Private connection metadata"]
            )
        }
    }
}

struct ChatTestIdentityFailingChatStreamer: SparkChatStreaming {
    func stream(
        target: SparkChatTarget,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        throw SparkChatConnectionError.identityMismatch
    }
}

struct ChatTestDelayedChatStreamer: SparkChatStreaming {
    let delay: Duration

    func stream(
        target: SparkChatTarget,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(
                    .chunk(id: "request-1", model: target.modelID, delta: "Hel", finishReason: nil)
                )
                do {
                    try await Task.sleep(for: delay)
                    continuation.yield(
                        .chunk(
                            id: "request-1",
                            model: target.modelID,
                            delta: "lo",
                            finishReason: "stop"
                        )
                    )
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

actor ChatTestChatStreamGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

struct ChatTestGatedChatStreamer: SparkChatStreaming {
    let gate: ChatTestChatStreamGate

    func stream(
        target: SparkChatTarget,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(
                    .chunk(id: "request-1", model: target.modelID, delta: "Hel", finishReason: nil)
                )
                await gate.wait()
                guard !Task.isCancelled else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.yield(
                    .chunk(
                        id: "request-1",
                        model: target.modelID,
                        delta: "lo",
                        finishReason: "stop"
                    )
                )
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

actor ChatTestTargetRecorder {
    private(set) var targetIDs: [String] = []

    func record(_ id: String) {
        targetIDs.append(id)
    }
}

struct ChatTestRecordingChatStreamer: SparkChatStreaming {
    let recorder: ChatTestTargetRecorder

    func stream(
        target: SparkChatTarget,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        await recorder.record(target.id)
        return AsyncThrowingStream { continuation in
            continuation.yield(
                .chunk(
                    id: "request",
                    model: target.modelID,
                    delta: target.displayName,
                    finishReason: nil
                )
            )
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

/// The messages a request carries besides the app's own standing instruction.
func chatTestSpoken(_ request: ChatCompletionRequest) -> [ChatMessage] {
    request.messages.filter { $0.role != "system" }
}

func chatTestConversation(_ request: ChatCompletionRequest) -> [String] {
    chatTestSpoken(request).map(\.content)
}
