#if os(macOS)
    import Foundation
    import SparkSecurity
    import Testing
    @testable import SparkAppComposition

    private func localJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }
    private func ollamaFixture(digest: String = String(repeating: "a", count: 64)) -> [String: Any]
    {
        [
            "name": "example:local", "model": "example:local", "size": 1024, "digest": digest,
            "details": ["format": "gguf", "quantization_level": "Q4_K_M"],
        ]
    }
    private func lmFixture() -> [String: Any] {
        [
            "type": "llm", "key": "example/model", "display_name": "Example model",
            "format": "gguf",
            "size_bytes": 2048, "max_context_length": 16384, "quantization": ["name": "Q4_K_M"],
            "capabilities": ["vision": true, "trained_for_tool_use": false],
            "loaded_instances": [
                ["id": "instance-1", "config": ["context_length": 4096, "parallel": 2]]
            ],
        ]
    }

    private actor LocalEngineFixtureTransport: SparkLocalEngineTransporting {
        private(set) var calls: [SparkLocalEngineEndpoint] = []
        let missingLoaded: Bool
        init(missingLoaded: Bool = false) { self.missingLoaded = missingLoaded }
        func read(
            origin: SparkLocalEngineOrigin,
            endpoint: SparkLocalEngineEndpoint,
            token: SparkLocalEngineToken?
        ) async throws -> Data {
            calls.append(endpoint)
            switch endpoint {
            case .ollamaVersion: return try localJSON(["version": "0.19.0"])
            case .ollamaModels: return try localJSON(["models": [ollamaFixture()]])
            case .ollamaLoaded:
                if missingLoaded { throw SparkLocalEngineError.unsupportedAPI }
                return try localJSON(["models": []])
            case .lmStudioModels: return try localJSON(["models": [lmFixture()]])
            }
        }
    }
    private final class LocalInventoryClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 100.0
        func now() -> Double { lock.withLock { seconds } }
        func advance(_ value: Double) { lock.withLock { seconds += value } }
    }
    private actor LocalInventoryReader: SparkLocalEngineReading {
        var shouldHold = false
        private(set) var calls = 0
        private(set) var cancelled = 0
        init(hold: Bool = false) { shouldHold = hold }
        func inventory(
            engine: SparkLocalEngine,
            origin: SparkLocalEngineOrigin,
            token: SparkLocalEngineToken?
        ) async throws -> SparkLocalEngineSnapshot {
            calls += 1
            if shouldHold {
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    cancelled += 1
                    throw error
                }
            }
            return .init(
                engine: engine,
                origin: origin,
                observedAt: Date(),
                engineVersion: nil,
                apiContract: "fixture",
                models: [],
                loadedInventoryAvailable: false
            )
        }
    }

    private final class LocalInventoryURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var fixture:
            (status: Int, data: Data, length: Int?, hold: Bool) = (200, Data(), nil, false)
        nonisolated(unsafe) private static var requests: [URLRequest] = []
        nonisolated(unsafe) private static var stops = 0
        static func configure(
            status: Int = 200,
            data: Data = Data(),
            length: Int? = nil,
            hold: Bool = false
        ) {
            lock.withLock {
                fixture = (status, data, length, hold)
                requests = []
                stops = 0
            }
        }
        static var observed: [URLRequest] { lock.withLock { requests } }
        static var stopCount: Int { lock.withLock { stops } }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let value = Self.lock.withLock {
                Self.requests.append(request)
                return Self.fixture
            }
            if value.hold { return }
            var headers = ["Content-Type": "application/json", "Set-Cookie": "engine_secret=value"]
            if let length = value.length { headers["Content-Length"] = String(length) }
            if (300...399).contains(value.status) {
                headers["Location"] = "http://example.invalid/private"
            }
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!,
                    statusCode: value.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!,
                cacheStoragePolicy: .notAllowed
            )
            if !value.data.isEmpty { client?.urlProtocol(self, didLoad: value.data) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { Self.lock.withLock { Self.stops += 1 } }
    }

    @Suite(.serialized)
    struct SparkLocalEngineTests {
        @Test func exactNumericLoopbackOriginsOnly() throws {
            for address in [
                "http://127.0.0.1:11434", "http://[::1]:1234/", "http://127.0.0.1:50001/",
            ] {
                _ = try SparkLocalEngineOrigin(address)
            }
            for address in [
                "http://localhost:1234", "https://127.0.0.1:1234", "http://127.0.0.2:1234",
                "http://2130706433:1234", "http://0177.0.0.1:1234", "http://127.0.0.1",
                "http://127.0.0.1:0",
                "http://user:secret@127.0.0.1:1234", "http://127.0.0.1:1234/api",
                "http://127.0.0.1:1234?secret=x",
                "http://127.0.0.1:1234#x", "http://[::ffff:127.0.0.1]:1234",
                "http://[::1%25lo0]:1234",
                "http://127.0.0.1:01234", "http://127.0.0.1:65536", "http://127%2e0.0.1:1234",
            ] {
                #expect(throws: SparkLocalEngineError.originInvalid) {
                    try SparkLocalEngineOrigin(address)
                }
            }
        }
        @Test func localTokensStayBoundToExactOriginAndSeparateNamespace() throws {
            let store = InMemoryStore(),
                credentials = SparkLocalEngineCredentials(store: InMemoryStore())
            let scoped = SparkLocalEngineCredentials(store: store)
            let first = try SparkLocalEngineOrigin("http://127.0.0.1:1234")
            let other = try SparkLocalEngineOrigin("http://127.0.0.1:1235")
            try scoped.save(SparkLocalEngineToken("private-test-token"), origin: first)
            #expect(try scoped.token(origin: first)?.authorization == "Bearer private-test-token")
            #expect(try scoped.token(origin: other) == nil)
            #expect(try credentials.token(origin: first) == nil)
            #expect(try store.accounts(service: SparkLocalEngineCredentials.service).count == 1)
            #expect(try store.accounts(service: "spark.device").isEmpty)
            try scoped.remove(origin: first)
            #expect(try scoped.token(origin: first) == nil)
            for token in ["", "a b", "a\r\nCookie: secret", String(repeating: "x", count: 4097)] {
                #expect(throws: SparkLocalEngineError.tokenInvalid) {
                    try SparkLocalEngineToken(token)
                }
            }
        }
        @Test func ollamaReadsOnlyDocumentedInventoryAndKeepsUnknownLoadedState() async throws {
            let transport = LocalEngineFixtureTransport(missingLoaded: true)
            let snapshot = try await SparkLocalEngineReader(transport: transport).inventory(
                engine: .ollama,
                origin: SparkLocalEngineOrigin("http://127.0.0.1:11434"),
                token: nil
            )
            #expect(await transport.calls == [.ollamaVersion, .ollamaModels, .ollamaLoaded])
            #expect(!snapshot.loadedInventoryAvailable)
            #expect(snapshot.engineVersion == "0.19.0")
            #expect(snapshot.models.first?.reportedDigest?.count == 64)
            #expect(snapshot.models.first?.reportedVision == nil)
            #expect(snapshot.models.first?.strictPoolEligible == false)
            #expect(snapshot.models.first?.isShared == false)
        }
        @Test func lmInventoryKeepsCapabilitiesAsClaimsAndMissingVersionDigestUnknown() async throws
        {
            let transport = LocalEngineFixtureTransport()
            let snapshot = try await SparkLocalEngineReader(transport: transport).inventory(
                engine: .lmStudio,
                origin: SparkLocalEngineOrigin("http://127.0.0.1:1234"),
                token: SparkLocalEngineToken("test-token")
            )
            #expect(await transport.calls == [.lmStudioModels])
            #expect(snapshot.engineVersion == nil)
            #expect(snapshot.models.first?.reportedDigest == nil)
            #expect(snapshot.models.first?.reportedVision == true)
            #expect(snapshot.models.first?.loadedInstances.first?.reportedParallelLimit == 2)
            #expect(snapshot.models.first?.strictPoolEligible == false)
        }
        @Test func conflictingOrExcessiveOrMalformedInventoryIsRefused() throws {
            let origin = try SparkLocalEngineOrigin("http://127.0.0.1:11434")
            let version = try localJSON(["version": "0.19.0"])
            let model = ollamaFixture()
            #expect(throws: SparkLocalEngineError.responseInvalid) {
                try SparkLocalEngineDecoder.ollama(
                    origin: origin,
                    version: version,
                    models: localJSON(["models": [model]]),
                    loaded: localJSON([
                        "models": [ollamaFixture(digest: String(repeating: "b", count: 64))]
                    ])
                )
            }
            #expect(throws: SparkLocalEngineError.responseTooLarge) {
                try SparkLocalEngineDecoder.ollama(
                    origin: origin,
                    version: version,
                    models: localJSON(["models": Array(repeating: model, count: 257)]),
                    loaded: nil
                )
            }
            var invalid = lmFixture()
            invalid["loaded_instances"] = [["id": "unsafe", "config": ["context_length": -1]]]
            #expect(throws: SparkLocalEngineError.responseInvalid) {
                try SparkLocalEngineDecoder.lmStudio(
                    origin: origin,
                    models: localJSON(["models": [invalid]])
                )
            }
            invalid = lmFixture()
            invalid["display_name"] = "line\nprivate"
            #expect(throws: SparkLocalEngineError.responseInvalid) {
                try SparkLocalEngineDecoder.lmStudio(
                    origin: origin,
                    models: localJSON(["models": [invalid]])
                )
            }
        }
        @MainActor @Test func ownerCheckOnlyAndFreshnessNeverClaimsOffline() async throws {
            let reader = LocalInventoryReader(), clock = LocalInventoryClock()
            let model = SparkLocalEngineInventoryModel(
                reader: reader,
                credentials: .init(store: InMemoryStore()),
                now: clock.now
            )
            #expect(await reader.calls == 0)
            #expect(model.status == "Not checked")
            await model.check()?.value
            #expect(await reader.calls == 1)
            #expect(model.status == "Responded to your check")
            clock.advance(31)
            #expect(model.status == "Check again for current state")
            model.clear()
            #expect(model.snapshot == nil)
            #expect(await reader.calls == 1)
        }
        @MainActor @Test func changingOriginOrCancellationClosesInFlightReadAndDiscardsResult()
            async throws
        {
            let reader = LocalInventoryReader(hold: true)
            let model = SparkLocalEngineInventoryModel(
                reader: reader,
                credentials: .init(store: InMemoryStore())
            )
            let task = model.check()
            for _ in 0..<1000 {
                if await reader.calls > 0 { break }
                await Task.yield()
            }
            model.address = "http://127.0.0.1:50001"
            await task?.value
            #expect(await reader.cancelled == 1)
            #expect(!model.isChecking)
            #expect(model.snapshot == nil)
        }
        @Test func transportUsesGETNoCookiesAndNeverForwardsLMTokenToOllama() async throws {
            LocalInventoryURLProtocol.configure(data: try localJSON(["models": []]))
            let transport = SparkLocalEngineHTTPTransport(protocolClasses: [
                LocalInventoryURLProtocol.self
            ])
            let origin = try SparkLocalEngineOrigin("http://127.0.0.1:1234")
            let token = try SparkLocalEngineToken("test-secret")
            _ = try await transport.read(origin: origin, endpoint: .lmStudioModels, token: token)
            _ = try await transport.read(origin: origin, endpoint: .lmStudioModels, token: token)
            #expect(LocalInventoryURLProtocol.observed.count == 2)
            #expect(
                LocalInventoryURLProtocol.observed.allSatisfy {
                    $0.httpMethod == "GET" && $0.httpBody == nil
                        && $0.value(forHTTPHeaderField: "Cookie") == nil
                }
            )
            #expect(LocalInventoryURLProtocol.observed.first?.url?.path == "/api/v1/models")
            await #expect(throws: SparkLocalEngineError.tokenInvalid) {
                try await transport.read(origin: origin, endpoint: .ollamaModels, token: token)
            }
            #expect(LocalInventoryURLProtocol.observed.count == 2)
        }
        @Test func transportRefusesRedirectAndOversizeBeforeReadingBody() async throws {
            let transport = SparkLocalEngineHTTPTransport(protocolClasses: [
                LocalInventoryURLProtocol.self
            ])
            let origin = try SparkLocalEngineOrigin("http://127.0.0.1:1234")
            LocalInventoryURLProtocol.configure(status: 302)
            await #expect(throws: SparkLocalEngineError.redirected) {
                try await transport.read(origin: origin, endpoint: .lmStudioModels, token: nil)
            }
            #expect(LocalInventoryURLProtocol.observed.count == 1)
            LocalInventoryURLProtocol.configure(
                length: SparkLocalEngineHTTPTransport.maximumBytes + 1
            )
            await #expect(throws: SparkLocalEngineError.responseTooLarge) {
                try await transport.read(origin: origin, endpoint: .lmStudioModels, token: nil)
            }
        }
        @Test func transportEnforcesBodyLimitWhenLengthIsUnknown() async throws {
            LocalInventoryURLProtocol.configure(
                data: Data(repeating: 32, count: SparkLocalEngineHTTPTransport.maximumBytes + 1)
            )
            let transport = SparkLocalEngineHTTPTransport(protocolClasses: [
                LocalInventoryURLProtocol.self
            ])
            let origin = try SparkLocalEngineOrigin("http://127.0.0.1:1234")
            await #expect(throws: SparkLocalEngineError.responseTooLarge) {
                try await transport.read(origin: origin, endpoint: .lmStudioModels, token: nil)
            }
        }
        @Test func transportCancellationStopsTheUnderlyingTask() async throws {
            LocalInventoryURLProtocol.configure(hold: true)
            let transport = SparkLocalEngineHTTPTransport(protocolClasses: [
                LocalInventoryURLProtocol.self
            ])
            let origin = try SparkLocalEngineOrigin("http://127.0.0.1:1234")
            let task = Task {
                try await transport.read(origin: origin, endpoint: .lmStudioModels, token: nil)
            }
            defer { task.cancel() }
            let startedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while LocalInventoryURLProtocol.observed.isEmpty
                && ContinuousClock.now < startedDeadline
            {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(!LocalInventoryURLProtocol.observed.isEmpty)
            task.cancel()
            await #expect(throws: SparkLocalEngineError.cancelled) { try await task.value }
            // URLSession completes the task before delivering its protocol's asynchronous stop callback.
            let stoppedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while LocalInventoryURLProtocol.stopCount == 0 && ContinuousClock.now < stoppedDeadline
            {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(LocalInventoryURLProtocol.stopCount >= 1)
        }
    }
#endif
