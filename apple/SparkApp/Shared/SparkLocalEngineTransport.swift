#if os(macOS)
    import Foundation

    protocol SparkLocalEngineTransporting: Sendable {
        func read(
            origin: SparkLocalEngineOrigin,
            endpoint: SparkLocalEngineEndpoint,
            token: SparkLocalEngineToken?
        ) async throws -> Data
    }

    final class SparkLocalEngineHTTPTransport: SparkLocalEngineTransporting {
        static let maximumBytes = 1_048_576
        private let session: URLSession
        init(protocolClasses: [AnyClass]? = nil) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.proxyConfigurations = []
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 3
            configuration.timeoutIntervalForResource = 5
            configuration.protocolClasses = protocolClasses
            // System server-trust evaluation only: no implicit Keychain, HTTP or client-certificate auth.
            session = URLSession(
                configuration: configuration,
                delegate: SparkRedirectRefusingSessionDelegate(),
                delegateQueue: nil
            )
        }
        deinit { session.invalidateAndCancel() }

        func read(
            origin: SparkLocalEngineOrigin,
            endpoint: SparkLocalEngineEndpoint,
            token: SparkLocalEngineToken?
        ) async throws -> Data {
            try Task.checkCancellation()
            // The credential is scoped to LM Studio's one allowed inventory API.
            guard token == nil || endpoint == .lmStudioModels else {
                throw SparkLocalEngineError.tokenInvalid
            }
            var request = URLRequest(url: origin.url(for: endpoint))
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let token {
                request.setValue(token.authorization, forHTTPHeaderField: "Authorization")
            }
            do {
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let response = response as? HTTPURLResponse,
                    response.url == request.url
                else { throw SparkLocalEngineError.responseInvalid }
                switch response.statusCode {
                case 200: break
                case 300...399: throw SparkLocalEngineError.redirected
                case 401: throw SparkLocalEngineError.authenticationRequired
                case 403: throw SparkLocalEngineError.permissionDenied
                case 404, 405: throw SparkLocalEngineError.unsupportedAPI
                default: throw SparkLocalEngineError.unavailable
                }
                guard response.expectedContentLength <= Int64(Self.maximumBytes) else {
                    throw SparkLocalEngineError.responseTooLarge
                }
                guard response.mimeType == "application/json" else {
                    throw SparkLocalEngineError.responseInvalid
                }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < Self.maximumBytes else {
                        throw SparkLocalEngineError.responseTooLarge
                    }
                    data.append(byte)
                }
                return data
            } catch is CancellationError { throw SparkLocalEngineError.cancelled } catch let error
                as SparkLocalEngineError
            { throw error } catch let error as URLError where error.code == .timedOut {
                throw SparkLocalEngineError.timedOut
            } catch let error as URLError
                where error.code == .userAuthenticationRequired
                || error.code == .userCancelledAuthentication
            {
                throw SparkLocalEngineError.authenticationRequired
            } catch let error as URLError where error.code == .cancelled {
                throw SparkLocalEngineError.cancelled
            } catch { throw SparkLocalEngineError.unavailable }
        }
    }

    struct SparkLocalEngineReader: SparkLocalEngineReading {
        let transport: any SparkLocalEngineTransporting
        init(transport: any SparkLocalEngineTransporting = SparkLocalEngineHTTPTransport()) {
            self.transport = transport
        }
        func inventory(
            engine: SparkLocalEngine,
            origin: SparkLocalEngineOrigin,
            token: SparkLocalEngineToken?
        ) async throws -> SparkLocalEngineSnapshot {
            switch engine {
            case .ollama:
                guard token == nil else { throw SparkLocalEngineError.tokenInvalid }
                let version = try await transport.read(
                    origin: origin,
                    endpoint: .ollamaVersion,
                    token: nil
                )
                let models = try await transport.read(
                    origin: origin,
                    endpoint: .ollamaModels,
                    token: nil
                )
                let loaded: Data?
                do {
                    loaded = try await transport.read(
                        origin: origin,
                        endpoint: .ollamaLoaded,
                        token: nil
                    )
                } catch SparkLocalEngineError.unsupportedAPI { loaded = nil }
                return try SparkLocalEngineDecoder.ollama(
                    origin: origin,
                    version: version,
                    models: models,
                    loaded: loaded
                )
            case .lmStudio:
                let models = try await transport.read(
                    origin: origin,
                    endpoint: .lmStudioModels,
                    token: token
                )
                return try SparkLocalEngineDecoder.lmStudio(origin: origin, models: models)
            }
        }
    }
#endif
