import Foundation
import SparkAPI
import SparkLanguageModel
@_spi(SparkInternal) import SparkTransport
import Testing

@testable import SparkAppComposition

/// Checks chat failure and recovery copy for titles and messages that never expose diagnostics.
private let diagnosticMarkers = [
    "SPARK_TEST_DIAGNOSTIC",
    "decode failed",
    "keyNotFound",
    "sk-live-4f3a",
    "/var/lib/spark-runtime",
    "192.168.1.44",
    "meta-llama/Llama-3.1-70B-Instruct",
]

private func isOwnerCopy(_ failure: SparkChatFailure, from what: String) {
    #expect(!failure.title.isEmpty, "\(what) has no title")
    #expect(!failure.message.isEmpty, "\(what) has no message")
    #expect(failure.title != failure.message, "\(what) says the same thing twice")
    #expect(!failure.message.contains("_"), "\(what) shows an identifier")
    #expect(!failure.message.contains("://"), "\(what) shows a route")
    for marker in diagnosticMarkers {
        #expect(!failure.title.contains(marker), "\(what) title repeats \(marker)")
        #expect(!failure.message.contains(marker), "\(what) message repeats \(marker)")
    }
}

/// Verify every chat error hides its supplied diagnostic payload.
private func everyChatFailure() -> [(String, SparkChatFailure)] {
    let poison = "SPARK_TEST_DIAGNOSTIC sk-live-4f3a /var/lib/spark-runtime"
    var errors: [(String, any Error)] = [
        ("identityMismatch", SparkChatConnectionError.identityMismatch),
        ("activeModelChanged", SparkChatConnectionError.activeModelChanged),
        ("modelNotInstalled", SparkInferenceError.modelNotInstalled(modelID: poison)),
        (
            "modelReplacementRequired",
            SparkInferenceError.modelReplacementRequired(
                activeModelID: poison,
                requestedModelID: poison
            )
        ),
        ("readinessTimeout", SparkInferenceError.readinessTimeout(modelID: poison)),
        ("unsupportedContent", SparkInferenceError.unsupportedContent(poison)),
        ("unsupportedCapability", SparkInferenceError.unsupportedCapability(poison)),
        ("inferenceTransport", SparkInferenceError.transport(poison)),
        ("certificateRejected", PinnedTransportError.certificateRejected(host: "192.168.1.44")),
        ("unreachable", PinnedTransportError.unreachable(poison)),
        ("nonHTTPResponse", PinnedTransportError.nonHTTPResponse),
        ("insecureScheme", PinnedTransportError.insecureScheme("http")),
        ("redirected", PinnedTransportError.redirected(to: "http://192.168.1.44/")),
        ("malformedPin", PinnedTransportError.malformedPin(poison)),
        ("urlError", URLError(.notConnectedToInternet)),
    ]
    for status in [401, 403, 500] {
        errors.append(
            (
                "apiError \(status)",
                APIError(.reported, statusCode: status, code: "X", diagnosticDetail: poison)
            )
        )
        errors.append(
            (
                "chatError \(status)",
                ChatError(
                    statusCode: status,
                    code: "X",
                    reason: .reported,
                    diagnosticDetail: poison
                )
            )
        )
    }
    errors.append(("malformedResponse", APIError(.malformedResponse, diagnosticDetail: poison)))
    struct Unknown: Error { let note = "SPARK_TEST_DIAGNOSTIC" }
    errors.append(("unknown", Unknown()))
    return errors.map { ($0.0, SparkChatFailure.resolve($0.1)) }
}

@Test func everyChatFailureBranchResolvesOwnerCopyRatherThanADiagnostic() {
    let failures = everyChatFailure()
    #expect(failures.count >= 22, "the sweep did not reach every branch")
    for (name, failure) in failures {
        isOwnerCopy(failure, from: name)
    }
}

/// Verify recovery kinds because they determine whether the view offers pairing or retry.
@Test func eachFailureKeepsTheKindItsRecoveryDependsOn() {
    let byName = Dictionary(uniqueKeysWithValues: everyChatFailure())
    #expect(byName["identityMismatch"]?.kind == .identityMismatch)
    #expect(byName["certificateRejected"]?.kind == .identityMismatch)
    #expect(byName["activeModelChanged"]?.kind == .activeModelChanged)
    #expect(byName["modelNotInstalled"]?.kind == .activeModelChanged)
    #expect(byName["unreachable"]?.kind == .offline)
    #expect(byName["urlError"]?.kind == .offline)
    #expect(byName["apiError 401"]?.kind == .authentication)
    #expect(byName["apiError 403"]?.kind == .authentication)
    #expect(byName["chatError 401"]?.kind == .authentication)
    #expect(byName["malformedResponse"]?.kind == .transport)
}

/// Distinguish recovery guidance for inference failures sharing the same title.
@Test func theThreeInferenceFailuresAreNotOneSentenceRepeated() {
    let byName = Dictionary(uniqueKeysWithValues: everyChatFailure())
    let messages = Set(
        ["unsupportedContent", "unsupportedCapability", "inferenceTransport"]
            .compactMap { byName[$0]?.message }
    )
    #expect(messages.count == 3, "two of the three read the same, so one of them is wrong")
}

/// Provide useful chat empty-state copy before any failure occurs.
@Test func everyChatEmptyStateSaysWhatToDoNext() {
    let states: [SparkChatEmptyState] = [
        .emptyFleet, .noActiveModel, .offline, .identityMismatch, .authenticationUnavailable,
    ]
    var titles: Set<String> = []
    var messages: Set<String> = []
    for state in states {
        #expect(!state.title.isEmpty)
        #expect(!state.message.isEmpty)
        #expect(!state.symbol.isEmpty)
        #expect(!state.title.contains("_"))
        #expect(!state.message.contains("_"))
        titles.insert(state.title)
        messages.insert(state.message)
    }
    #expect(titles.count == states.count, "two empty states share a title")
    #expect(messages.count == states.count, "two empty states share a message")
}
