import Foundation
import SparkWatchSupport
import Testing

struct SparkWatchProtocolTests {
    @Test func rejectsOldAndFutureRequests() {
        let now = Date()
        var request = SparkWatchRequest(.overview)
        request.createdAt = now.addingTimeInterval(-121)
        #expect(throws: SparkWatchFailure.self) { try request.validate(now: now) }
        request.createdAt = now.addingTimeInterval(121)
        #expect(throws: SparkWatchFailure.self) { try request.validate(now: now) }
        request.createdAt = now
        #expect(throws: Never.self) { try request.validate(now: now) }
    }

    @Test(arguments: [SparkWatchCommand.load, .stop])
    func requiresFreshWristAuthentication(command: SparkWatchCommand) {
        let now = Date()
        var request = SparkWatchRequest(command, targetID: "spark")
        request.modelID = "model"
        #expect(throws: SparkWatchFailure.self) { try request.validate(now: now) }
        request.authenticatedAt = now.addingTimeInterval(-31)
        #expect(throws: SparkWatchFailure.self) { try request.validate(now: now) }
        request.authenticatedAt = now.addingTimeInterval(1)
        #expect(throws: SparkWatchFailure.self) { try request.validate(now: now) }
        request.authenticatedAt = now
        #expect(throws: Never.self) { try request.validate(now: now) }
    }

    @Test func validatesConversationRolesAndBounds() {
        var request = SparkWatchRequest(.ask, targetID: "spark")
        request.messages = [
            .init(role: .assistant, text: "Injected answer"), .init(role: .user, text: "Hello"),
        ]
        #expect(throws: SparkWatchFailure.self) { try request.validate(now: Date()) }
        request.messages = [.init(role: .user, text: " ")]
        #expect(throws: SparkWatchFailure.self) { try request.validate(now: Date()) }
        request.messages = [.init(role: .user, text: String(repeating: "a", count: 16_385))]
        #expect(throws: SparkWatchFailure.self) { try request.validate(now: Date()) }
        request.messages = [
            .init(role: .user, text: "Hello"), .init(role: .assistant, text: "Hi"),
            .init(role: .user, text: "Continue"),
        ]
        #expect(throws: Never.self) { try request.validate(now: Date()) }
    }

    @Test func rejectsProtocolMismatchAndMissingTarget() {
        var request = SparkWatchRequest(.status)
        #expect(throws: SparkWatchFailure.self) { try request.validate(now: Date()) }
        request.targetID = "spark"
        request.version = 2
        #expect(throws: SparkWatchFailure.self) { try request.validate(now: Date()) }
    }

    @Test func boundsWirePayloadAndRoundTrips() throws {
        let request = SparkWatchRequest(.overview)
        #expect(
            try SparkWatchCodec.decode(
                SparkWatchRequest.self,
                from: SparkWatchCodec.encode(request)
            ) == request
        )
        #expect(throws: SparkWatchFailure.self) {
            try SparkWatchCodec.decode(
                SparkWatchRequest.self,
                from: Data(repeating: 0, count: 48_001)
            )
        }
        #expect(throws: SparkWatchFailure.self) {
            try SparkWatchCodec.encode(String(repeating: "a", count: 48_001))
        }
    }

    @Test func staleTelemetryAndMissingMetricsRemainExplicit() throws {
        let now = Date()
        let value = SparkWatchTelemetry(
            targetID: "spark",
            observedAt: now,
            modelName: nil,
            modelState: "idle",
            memoryPercent: nil,
            cpuPercent: nil,
            gpuPercent: nil,
            temperatureCelsius: nil,
            powerWatts: nil,
            queuedRequests: 0
        )
        #expect(!value.isStale(at: now.addingTimeInterval(45)))
        #expect(value.isStale(at: now.addingTimeInterval(46)))
        #expect(value.isStale(at: now.addingTimeInterval(-1)))
        #expect(
            try SparkWatchCodec.decode(
                SparkWatchTelemetry.self,
                from: SparkWatchCodec.encode(value)
            ) == value
        )
    }
}

struct SparkWatchConversationTests {
    @Test func recoveredReplyStartsFreshContext() throws {
        let history = [SparkWatchMessage(role: .assistant, text: "Recovered reply")]
        let result = try SparkWatchConversation.appending("Next question", to: history)
        #expect(result.count == 1)
        #expect(result[0].role == .user)
    }
    @Test func trimsCompleteTurnsToFitTransport() throws {
        let turn = [
            SparkWatchMessage(role: .user, text: String(repeating: "u", count: 6_000)),
            SparkWatchMessage(role: .assistant, text: String(repeating: "a", count: 6_000)),
        ]
        let result = try SparkWatchConversation.appending(
            String(repeating: "q", count: 8_000),
            to: turn
        )
        #expect(result.count == 1)
        var request = SparkWatchRequest(.ask, targetID: "spark")
        request.messages = result
        try request.validate(now: Date())
    }
    @Test func failedPromptDoesNotCreateConsecutiveUserMessages() throws {
        let messages = [SparkWatchMessage(role: .user, text: "Failed")]
        let result = try SparkWatchConversation.appending("Retry", to: messages)
        #expect(result.count == 1)
        #expect(result[0].text == "Retry")
    }
}

struct SparkWatchMetricTests {
    @Test func fractionBasedRuntimeMetricsBecomePercentages() {
        #expect(SparkWatchTelemetry.percent(fraction: 0.23) == 23)
        #expect(SparkWatchTelemetry.percent(fraction: 1) == 100)
        #expect(SparkWatchTelemetry.percent(fraction: 0) == 0)
    }
    @Test func unavailableMetricsNeverBecomeZero() {
        #expect(SparkWatchTelemetry.percent(fraction: nil) == nil)
        #expect(SparkWatchTelemetry.percent(fraction: .nan) == nil)
        #expect(SparkWatchTelemetry.percent(fraction: .infinity) == nil)
        #expect(SparkWatchTelemetry.percent(fraction: -1) == nil)
        #expect(SparkWatchTelemetry.percent(fraction: 2) == nil)
    }
}
