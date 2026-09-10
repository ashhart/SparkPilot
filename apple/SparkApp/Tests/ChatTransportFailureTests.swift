import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import SwiftUI
import Testing
@testable import SparkAppComposition

@MainActor
@Test func authenticationAndTransportErrorsStayRecoverable() async throws {
    let catalogue = try chatTestFixtureCatalogue()
    let denied = SparkChatModel(
        catalogue: catalogue,
        streamer: ChatTestFailingChatStreamer(
            error: ChatError(
                statusCode: 401,
                code: "INVALID_SIGNATURE",
                reason: .reported,
                diagnosticDetail: "denied"
            )
        )
    )
    denied.draft = "Hello"
    await denied.send()?.value
    guard case .failed(let authentication) = denied.generationState else {
        Issue.record("Expected an authentication failure")
        return
    }
    #expect(authentication.kind == .authentication)
    #expect(denied.messages.first?.content == "Hello")
    #expect(denied.canRetry)

    let offline = SparkChatModel(
        catalogue: catalogue,
        streamer: ChatTestNetworkFailingChatStreamer()
    )
    offline.draft = "Hello"
    await offline.send()?.value
    guard case .failed(let transport) = offline.generationState else {
        Issue.record("Expected a transport failure")
        return
    }
    #expect(transport.kind == .offline)
    #expect(offline.canRetry)
}

@MainActor
@Test(arguments: ChatTestChatTransportFailureScenario.allCases)
private func chatTransportFailuresShowOwnerInstructionsWithoutSystemDiagnostics(
    scenario: ChatTestChatTransportFailureScenario
) async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: streamer)
    model.draft = "Keep the prompt for retry"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.finish(throwing: scenario.error)
    await task.value
    guard case .failed(let failure) = model.generationState else {
        Issue.record("Expected an owner-facing chat failure")
        return
    }
    if scenario == .unknownFailure {
        #expect(failure.kind == .transport)
        #expect(
            failure.message
                == "The Spark did not answer this message. Check the connection and try again."
        )
    } else {
        #expect(failure.kind == .offline)
        #expect(failure.title == "Spark is offline")
        #expect(failure.message == "Reconnect to the Spark and retry this message.")
    }
    #expect(!failure.message.contains("NSURLErrorDomain"))
    #expect(!failure.message.contains("Private"))
    #expect(model.messages.map(\.content) == ["Keep the prompt for retry"])
    #expect(model.canRetry)
}

@MainActor
@Test func identityMismatchBlocksGenerationWithoutLosingThePrompt() async throws {
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestIdentityFailingChatStreamer()
    )
    model.draft = "Do not send this to an impostor"
    await model.send()?.value

    guard case .failed(let failure) = model.generationState else {
        Issue.record("Expected an identity mismatch")
        return
    }
    #expect(failure.kind == .identityMismatch)
    #expect(model.messages.map(\.content) == ["Do not send this to an impostor"])
    #expect(model.canRetry)

    let blockedCatalogue = SparkChatTargetCatalogue(
        targets: [],
        pairedTargetCount: 1,
        unavailableTargets: [
            SparkChatUnavailableTarget(name: "Desk Spark", reason: .identityMismatch)
        ]
    )
    #expect(blockedCatalogue.emptyState == .identityMismatch)
}
