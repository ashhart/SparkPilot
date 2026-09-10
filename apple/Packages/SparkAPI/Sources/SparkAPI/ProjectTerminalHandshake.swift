import Foundation
@_spi(SparkInternal) import SparkTransport

/// Observe the upgrade itself: a ping can wait behind unread startup output in URLSession.
final class ProjectTerminalHandshake: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let trust: PinnedSessionDelegate
    private let lock = NSLock()
    private var outcome: Result<Void, any Error>?
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    init(trust: PinnedSessionDelegate) { self.trust = trust }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    @discardableResult
    func finish(_ result: Result<Void, any Error>) -> Bool {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return false
        }
        outcome = result
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume(with: result) }
        return true
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        finish(.success(()))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(.failure(URLError(.networkConnectionLost)))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        finish(
            .failure(
                trust.transportError(
                    error ?? URLError(.networkConnectionLost),
                    host: task.originalRequest?.url?.host ?? ""
                )
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        trust.urlSession(
            session,
            task: task,
            didReceive: challenge,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
