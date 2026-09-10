import Foundation
import SparkWatchSupport
import Testing

@MainActor
struct SparkWatchRouterTests {
    @MainActor private final class Service: SparkWatchServicing {
        var calls = 0
        var blocked = false
        var wait = false
        func authorize(_ request: SparkWatchRequest) throws {
            if blocked { throw SparkWatchFailure("Locked") }
        }
        func execute(_ request: SparkWatchRequest) async throws -> SparkWatchResponse {
            calls += 1
            if wait { try await Task.sleep(for: .seconds(60)) }
            return .init(id: request.id, phase: .complete, message: "Reply")
        }
    }

    private func storage() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "watch-test-\(UUID())/receipts.json"
        )
    }
    private func settle() async { for _ in 0..<100 { await Task.yield() } }
    private func poll(_ id: UUID, router: SparkWatchRequestRouter) -> SparkWatchResponse {
        var request = SparkWatchRequest(.poll)
        request.jobID = id
        return router.receive(request)
    }

    @Test func returnsReceiptImmediatelyAndExecutesDuplicateOnlyOnce() async {
        let service = Service()
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let router = SparkWatchRequestRouter(service: service, receiptURL: url)
        let request = SparkWatchRequest(.overview)
        #expect(router.receive(request).phase == .pending)
        #expect(router.receive(request).phase == .pending)
        await settle()
        #expect(service.calls == 1)
        #expect(poll(request.id, router: router).message == "Reply")
        #expect(router.receive(request).phase == .complete)
    }

    @Test func rejectsIdentifierReuseWithDifferentPayload() async {
        let service = Service()
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let router = SparkWatchRequestRouter(service: service, receiptURL: url)
        var request = SparkWatchRequest(.overview)
        _ = router.receive(request)
        request.targetID = "different-target"
        #expect(router.receive(request).phase == .failed)
        await settle()
        #expect(service.calls == 1)
    }

    @Test func restartCannotRepeatAcceptedMutation() async {
        let service = Service()
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var request = SparkWatchRequest(.stop, targetID: "spark")
        request.authenticatedAt = Date()
        let first = SparkWatchRequestRouter(service: service, receiptURL: url)
        _ = first.receive(request)
        await settle()
        let second = SparkWatchRequestRouter(service: service, receiptURL: url)
        #expect(second.receive(request).phase == .unknown)
        #expect(service.calls == 1)
    }

    @Test func unreadableReceiptStoreFailsClosed() async throws {
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("corrupt".utf8).write(to: url)
        let service = Service()
        let router = SparkWatchRequestRouter(service: service, receiptURL: url)
        #expect(router.receive(.init(.overview)).phase == .failed)
        await settle()
        #expect(service.calls == 0)
    }

    @Test func lockedPhoneCannotStartOrCollectWork() async {
        let service = Service()
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let router = SparkWatchRequestRouter(service: service, receiptURL: url)
        service.blocked = true
        #expect(router.receive(.init(.overview)).phase == .failed)
        service.blocked = false
        let request = SparkWatchRequest(.overview)
        _ = router.receive(request)
        await settle()
        service.blocked = true
        #expect(poll(request.id, router: router).phase == .failed)
        #expect(service.calls == 1)
    }

    @Test func cancellationCannotPublishLateSuccess() async {
        let service = Service()
        service.wait = true
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let router = SparkWatchRequestRouter(service: service, receiptURL: url)
        let request = SparkWatchRequest(.overview)
        _ = router.receive(request)
        await settle()
        router.cancel(id: request.id)
        await settle()
        #expect(poll(request.id, router: router).phase == .failed)
    }

    @Test func limitsConcurrentWork() async {
        let service = Service()
        service.wait = true
        let url = storage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let router = SparkWatchRequestRouter(service: service, receiptURL: url)
        for _ in 0..<3 { #expect(router.receive(.init(.overview)).phase == .pending) }
        #expect(router.receive(.init(.overview)).phase == .failed)
        router.cancelAll()
    }
}
