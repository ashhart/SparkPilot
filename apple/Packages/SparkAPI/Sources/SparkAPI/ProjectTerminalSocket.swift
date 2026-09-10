import Foundation
@_spi(SparkInternal) import SparkTransport

enum ProjectTerminalFrameCodec {
    static let maximumInputBytes = 8 * 1_024
    static let maximumOutputBytes = 1_048_576
    private static let maximumEncodedFrameBytes = 8 * 1_048_576

    private struct Frame: Codable {
        let type: String
        let data: String
    }

    private struct ResizeFrame: Codable {
        let type = "resize"
        let cols: Int
        let rows: Int
    }

    /// The runtime clamps cols to 1-500 and rows to 1-250; clamp here so a frame is never refused.
    static func resize(columns: Int, rows: Int) throws -> String {
        let frame = ResizeFrame(
            cols: min(max(columns, 1), 500),
            rows: min(max(rows, 1), 250)
        )
        let data = try JSONEncoder().encode(frame)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw APIError(.malformedResponse)
        }
        return encoded
    }

    static func input(_ text: String) throws -> String {
        guard text.utf8.count <= maximumInputBytes else {
            throw APIError(.local(message: String(localized: "Terminal input is too large.")))
        }
        let data = try JSONEncoder().encode(Frame(type: "input", data: text))
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw APIError(.malformedResponse)
        }
        return encoded
    }

    static func output(from data: Data) throws -> String {
        guard data.count <= maximumEncodedFrameBytes else {
            throw APIError(.malformedResponse)
        }
        let frame: Frame
        do {
            frame = try JSONDecoder().decode(Frame.self, from: data)
        } catch {
            throw APIError(.malformedResponse)
        }
        guard frame.type == "output", frame.data.utf8.count <= maximumOutputBytes else {
            throw APIError(.malformedResponse)
        }
        return frame.data
    }
}

public actor ProjectTerminalSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let handshake: ProjectTerminalHandshake
    private var started = false
    private var heartbeat: Task<Void, Never>?

    init(
        baseURL: URL,
        pin: String,
        signer: any RequestSigning,
        projectID: String,
        terminalID: String
    ) throws {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw PinnedTransportError.insecureScheme(baseURL.scheme ?? "none")
        }
        guard URLSessionPinnedTransport.isFingerprint(pin) else {
            throw PinnedTransportError.malformedPin(pin)
        }
        var absolute = baseURL.absoluteString
        while absolute.hasSuffix("/") { absolute.removeLast() }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        func segment(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        let path = ["api", "v1", "projects", projectID, "terminals", terminalID, "ws"]
            .map(segment)
            .joined(separator: "/")
        guard var components = URLComponents(string: "\(absolute)/\(path)") else {
            throw APIError(.malformedRequestURL)
        }
        components.scheme = "wss"
        guard let url = components.url else {
            throw APIError(.malformedRequestURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("spark-terminal-v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request = try signer.authorize(request, body: Data())
        let pinned = PinnedSession.pinnedWithDelegate(to: pin)
        let handshake = ProjectTerminalHandshake(trust: pinned.delegate)
        self.handshake = handshake
        self.session = pinned.session
        self.task = pinned.session.webSocketTask(with: request)
        self.task.delegate = handshake
    }

    public func start() {
        guard !started else { return }
        started = true
        task.resume()
    }

    /// Verify the signed upgrade, then detect half-open connections even when the harness is quiet.
    public func waitUntilConnected() async throws {
        guard started else { throw URLError(.notConnectedToInternet) }
        let handshake = handshake
        let socketTask = task
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            if handshake.finish(.failure(URLError(.timedOut))) {
                socketTask.cancel(with: .goingAway, reason: nil)
            }
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try await handshake.wait()
        } onCancel: {
            handshake.finish(.failure(CancellationError()))
            socketTask.cancel(with: .goingAway, reason: nil)
        }
        try Task.checkCancellation()
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                    guard let self else { return }
                    try await self.ping()
                } catch {
                    await self?.cancel()
                    return
                }
            }
        }
    }

    private func ping() async throws {
        let socketTask = task
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let completion = ProjectTerminalPingCompletion(continuation)
                socketTask.sendPing { error in _ = completion.finish(error) }
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    if completion.finish(URLError(.timedOut)) {
                        socketTask.cancel(with: .goingAway, reason: nil)
                    }
                }
            }
        } onCancel: {
            socketTask.cancel(with: .goingAway, reason: nil)
        }
    }

    public func send(_ text: String) async throws {
        guard started else {
            throw APIError(.local(message: String(localized: "Terminal is not connected.")))
        }
        try await task.send(.string(ProjectTerminalFrameCodec.input(text)))
    }

    /// Follow a rotation or a Split View change instead of leaving the PTY at its opening size.
    public func resize(columns: Int, rows: Int) async throws {
        guard started else { return }
        try await task.send(
            .string(ProjectTerminalFrameCodec.resize(columns: columns, rows: rows))
        )
    }

    public func receive() async throws -> String {
        guard started else {
            throw APIError(.local(message: String(localized: "Terminal is not connected.")))
        }
        switch try await task.receive() {
        case .string(let text):
            return try ProjectTerminalFrameCodec.output(from: Data(text.utf8))
        case .data(let data):
            return try ProjectTerminalFrameCodec.output(from: data)
        @unknown default:
            throw APIError(.malformedResponse)
        }
    }

    deinit {
        heartbeat?.cancel()
        session.invalidateAndCancel()
    }

    public func cancel() {
        started = false
        handshake.finish(.failure(CancellationError()))
        heartbeat?.cancel()
        heartbeat = nil
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// URLSession's callback races its deadline; resume the waiter exactly once.
private final class ProjectTerminalPingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }
    func finish(_ error: (any Error)?) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        if let error { pending.resume(throwing: error) } else { pending.resume() }
        return true
    }
}
