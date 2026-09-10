#if os(macOS)
    import AppKit
    import Foundation
    import Network
    import Observation
    import SparkAPI
    import SparkCore
    import SparkSecurity
    @_spi(SparkInternal) import SparkTransport

    public protocol SparkIntegrationGatewayServing: AnyObject, Sendable {
        func start() async throws -> SparkIntegrationEndpoint
        func stop()
    }

    final class SparkIntegrationGateway: SparkIntegrationGatewayServing, @unchecked Sendable {
        private let target: SparkChatTarget
        private let token: String
        private let queue = DispatchQueue(label: "app.spark.integration-gateway")
        private let lock = NSLock()
        private var listener: NWListener?
        private var connections: [UUID: NWConnection] = [:]
        // A client that connects and sends nothing is dropped after this long, so it cannot hold a slot until quit.
        static let firstRequestTimeout: TimeInterval = 30
        private var awaitingRequest: Set<UUID> = []

        init(target: SparkChatTarget) {
            self.target = target
            token = Self.makeToken()
        }

        func start() async throws -> SparkIntegrationEndpoint {
            try await verifyTargetIdentity()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            let port = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<NWEndpoint.Port, any Error>) in
                let resumed = LockedFlag()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard resumed.take(), let port = listener.port else { return }
                        continuation.resume(returning: port)
                    case .failed(let error):
                        guard resumed.take() else { return }
                        continuation.resume(throwing: error)
                    case .cancelled:
                        guard resumed.take() else { return }
                        continuation.resume(
                            throwing: SparkDeveloperToolLaunchError.gatewayUnavailable(
                                "Listener stopped."
                            )
                        )
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
                throw SparkDeveloperToolLaunchError.gatewayUnavailable("Invalid loopback address.")
            }
            return SparkIntegrationEndpoint(baseURL: url, token: token)
        }

        func stop() {
            listener?.cancel()
            lock.withLock {
                connections.values.forEach { $0.cancel() }
                connections.removeAll()
            }
        }

        private func verifyTargetIdentity() async throws {
            let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: target.nodeID.rawValue)
            let api = try SparkAPIClient.pinned(to: target.tlsFingerprint, signer: signer)
            let identity = try await api.identity(route: target.route)
            guard identity.nodeID == target.nodeID,
                identity.clusterID == target.clusterID,
                identity.authorityFingerprint == target.authorityFingerprint
            else {
                throw SparkDeveloperToolLaunchError.identityMismatch
            }
            let active = try await api.activeInference(route: target.route)
            guard [.ready, .idle].contains(active.state), active.modelID == target.modelID else {
                throw SparkDeveloperToolLaunchError.selectedModelChanged
            }
        }

        private func accept(_ connection: NWConnection) {
            let id = UUID()
            lock.withLock {
                connections[id] = connection
                awaitingRequest.insert(id)
            }
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.removeConnection(id) }
                if case .cancelled = state { self?.removeConnection(id) }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.firstRequestTimeout) { [weak self] in
                guard let self, self.lock.withLock({ self.awaitingRequest.contains(id) }) else {
                    return
                }
                self.sendError(408, "Request timed out", connection: connection, id: id)
            }
            receive(on: connection, id: id, buffer: Data())
        }

        private func receive(on connection: NWConnection, id: UUID, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }
                var next = buffer
                if let data { next.append(data) }
                if next.count > 16 * 1024 * 1024 {
                    self.sendError(413, "Request too large", connection: connection, id: id)
                    return
                }
                if let request = GatewayHTTPRequest.parse(next) {
                    self.lock.withLock { _ = self.awaitingRequest.remove(id) }
                    Task { await self.forward(request, connection: connection, id: id) }
                    return
                }
                if isComplete || error != nil {
                    self.sendError(400, "Invalid request", connection: connection, id: id)
                    return
                }
                self.receive(on: connection, id: id, buffer: next)
            }
        }

        private func forward(_ request: GatewayHTTPRequest, connection: NWConnection, id: UUID)
            async
        {
            guard Self.constantTimeEquals(request.authorizationToken, token) else {
                sendError(401, "Unauthorized", connection: connection, id: id)
                return
            }
            let allowed = ["/v1/models", "/v1/chat/completions", "/v1/responses", "/v1/messages"]
            guard allowed.contains(request.path) else {
                sendError(404, "Not found", connection: connection, id: id)
                return
            }
            var responseStarted = false
            do {
                let isAnthropic = request.path == "/v1/messages"
                let wantsStream = SparkIntegrationRequestAdapter.wantsStream(request.body)
                let remotePath = isAnthropic ? "/v1/chat/completions" : request.path
                guard let url = URL(string: remotePath, relativeTo: target.route)?.absoluteURL
                else {
                    throw SparkDeveloperToolLaunchError.invalidGatewayRequest
                }
                var body = request.body
                if request.method == "POST" {
                    body = try SparkIntegrationRequestAdapter.requestBody(
                        body,
                        path: request.path,
                        modelID: target.modelID,
                        visionSupported: target.visionSupported ?? false
                    )
                }
                var remote = URLRequest(url: url)
                remote.httpMethod = request.method
                remote.httpBody = body
                remote.setValue("application/json", forHTTPHeaderField: "Content-Type")
                remote.setValue(request.accept ?? "application/json", forHTTPHeaderField: "Accept")
                if let version = request.headers["anthropic-version"] {
                    remote.setValue(version, forHTTPHeaderField: "Anthropic-Version")
                }
                if let beta = request.headers["anthropic-beta"] {
                    remote.setValue(beta, forHTTPHeaderField: "Anthropic-Beta")
                }
                let signer = try DeviceIdentityStore.loadOrCreateSigner(
                    nodeID: target.nodeID.rawValue
                )
                remote = try signer.authorize(remote, body: body)
                let session = PinnedSession.pinned(to: target.tlsFingerprint)
                defer { session.finishTasksAndInvalidate() }
                let (bytes, response) = try await session.bytes(for: remote)
                guard let http = response as? HTTPURLResponse else {
                    throw SparkDeveloperToolLaunchError.gatewayUnavailable(
                        "Spark returned no HTTP response."
                    )
                }
                if isAnthropic && !wantsStream {
                    var responseBody = Data()
                    for try await byte in bytes {
                        responseBody.append(byte)
                        guard responseBody.count <= 16 * 1024 * 1024 else {
                            throw SparkDeveloperToolLaunchError.gatewayUnavailable(
                                "Response too large."
                            )
                        }
                    }
                    let adapted =
                        if (200..<300).contains(http.statusCode) {
                            try AnthropicResponseAdapter.responseBody(
                                responseBody,
                                modelID: target.modelID
                            )
                        } else {
                            responseBody
                        }
                    try await sendHead(
                        status: http.statusCode,
                        contentType: "application/json",
                        connection: connection
                    )
                    responseStarted = true
                    try await sendChunk(adapted, connection: connection)
                    try await sendChunk(Data(), connection: connection)
                    connection.cancel()
                    removeConnection(id)
                    return
                }
                let contentType =
                    isAnthropic && wantsStream
                    ? "text/event-stream"
                    : http.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
                try await sendHead(
                    status: http.statusCode,
                    contentType: contentType,
                    connection: connection
                )
                responseStarted = true
                if isAnthropic {
                    let adapter = AnthropicStreamAdapter(modelID: target.modelID)
                    var incoming = Data()
                    incoming.reserveCapacity(8192)
                    for try await byte in bytes {
                        incoming.append(byte)
                        if incoming.count >= 8192 {
                            let adapted = try adapter.append(incoming)
                            if !adapted.isEmpty {
                                try await sendChunk(adapted, connection: connection)
                            }
                            incoming.removeAll(keepingCapacity: true)
                        }
                    }
                    let adapted = try adapter.append(incoming) + adapter.finish()
                    if !adapted.isEmpty { try await sendChunk(adapted, connection: connection) }
                    try await sendChunk(Data(), connection: connection)
                    connection.cancel()
                    removeConnection(id)
                    return
                }
                var chunk = Data()
                chunk.reserveCapacity(8192)
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 8192 {
                        try await sendChunk(chunk, connection: connection)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty { try await sendChunk(chunk, connection: connection) }
                try await sendChunk(Data(), connection: connection)
                connection.cancel()
                removeConnection(id)
            } catch {
                if responseStarted {
                    connection.cancel()
                    removeConnection(id)
                } else if case SparkDeveloperToolLaunchError.unsupportedContent(let reason) = error
                {
                    sendError(400, reason, connection: connection, id: id)
                } else {
                    sendError(
                        502,
                        "Spark bridge failed: \(error.localizedDescription)",
                        connection: connection,
                        id: id
                    )
                }
            }
        }

        private func sendHead(status: Int, contentType: String, connection: NWConnection)
            async throws
        {
            let reason = HTTPURLResponse.localizedString(forStatusCode: status)
            let text =
                "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
            try await send(Data(text.utf8), connection: connection)
        }

        private func sendChunk(_ data: Data, connection: NWConnection) async throws {
            if data.isEmpty {
                try await send(Data("0\r\n\r\n".utf8), connection: connection)
                return
            }
            var framed = Data(String(data.count, radix: 16).utf8)
            framed.append(Data("\r\n".utf8))
            framed.append(data)
            framed.append(Data("\r\n".utf8))
            try await send(framed, connection: connection)
        }

        private func send(_ data: Data, connection: NWConnection) async throws {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                )
            }
        }

        private func sendError(_ status: Int, _ message: String, connection: NWConnection, id: UUID)
        {
            let body =
                (try? JSONSerialization.data(withJSONObject: [
                    "error": ["message": message]
                ])) ?? Data("{\"error\":{\"message\":\"Bridge error\"}}".utf8)
            let reason = HTTPURLResponse.localizedString(forStatusCode: status)
            let head =
                "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var response = Data(head.utf8)
            response.append(body)
            connection.send(
                content: response,
                completion: .contentProcessed { [weak self] _ in
                    connection.cancel()
                    self?.removeConnection(id)
                }
            )
        }

        private func removeConnection(_ id: UUID) {
            lock.withLock {
                _ = connections.removeValue(forKey: id)
                _ = awaitingRequest.remove(id)
            }
        }

        private static func makeToken() -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return Data(bytes).base64EncodedString()
        }

        private static func constantTimeEquals(_ candidate: String?, _ expected: String) -> Bool {
            guard let candidate else { return false }
            let lhs = Array(candidate.utf8)
            let rhs = Array(expected.utf8)
            var difference = lhs.count ^ rhs.count
            for index in 0..<max(lhs.count, rhs.count) {
                let left = lhs.isEmpty ? 0 : lhs[index % lhs.count]
                let right = rhs.isEmpty ? 0 : rhs[index % rhs.count]
                difference |= Int(left ^ right)
            }
            return difference == 0
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true

        func take() -> Bool {
            lock.withLock {
                guard value else { return false }
                value = false
                return true
            }
        }
    }

#endif
