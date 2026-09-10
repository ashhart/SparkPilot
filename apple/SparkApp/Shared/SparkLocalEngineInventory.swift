#if os(macOS)
    import CryptoKit
    import Foundation
    import SparkSecurity

    enum SparkLocalEngine: String, CaseIterable, Sendable, Identifiable {
        case ollama, lmStudio
        var id: String { rawValue }
        var title: String {
            self == .ollama ? String(localized: "Ollama") : String(localized: "LM Studio")
        }
        var defaultAddress: String {
            self == .ollama ? "http://127.0.0.1:11434" : "http://127.0.0.1:1234"
        }
    }

    enum SparkLocalEngineError: String, Error, Sendable {
        case originInvalid, responseInvalid, responseTooLarge, unsupportedAPI
        case authenticationRequired, permissionDenied, unavailable, timedOut, cancelled
        case tokenInvalid, credentialStorageFailed, redirected
        var message: String {
            switch self {
            case .originInvalid:
                String(
                    localized:
                        "Enter an HTTP address with 127.0.0.1 or [::1] and an explicit port; paths, credentials and hostnames are not accepted."
                )
            case .responseInvalid:
                String(
                    localized:
                        "The engine returned inventory this version of SparkPilot cannot safely read."
                )
            case .responseTooLarge:
                String(localized: "The inventory exceeded the local check's size or model limit.")
            case .unsupportedAPI:
                String(
                    localized:
                        "This server does not support the selected inventory API; LM Studio requires its native v1 models API."
                )
            case .authenticationRequired:
                String(
                    localized:
                        "This engine requires an API token; enter a token with permission to list models."
                )
            case .permissionDenied:
                String(
                    localized:
                        "The engine refused inventory access; check the token's permissions in the engine app."
                )
            case .unavailable:
                String(
                    localized:
                        "The local engine did not answer; check its server address in the engine app."
                )
            case .timedOut:
                String(localized: "The local inventory check timed out.")
            case .cancelled:
                String(localized: "The local check was cancelled; no engine work was stopped.")
            case .tokenInvalid:
                String(
                    localized:
                        "Use a token without spaces or control characters, up to 4,096 characters."
                )
            case .credentialStorageFailed:
                String(localized: "The token could not be read or changed in this Mac's Keychain.")
            case .redirected:
                String(
                    localized:
                        "The engine redirected the check; SparkPilot only reads the exact local address you selected."
                )
            }
        }
    }

    /// No DNS, arbitrary path, user-info, proxy origin, or implicit default port.
    struct SparkLocalEngineOrigin: Equatable, Sendable {
        let url: URL
        init(_ value: String) throws {
            guard value.utf8.count <= 128,
                let parts = URLComponents(string: value),
                parts.scheme == "http", parts.user == nil, parts.password == nil,
                parts.query == nil, parts.fragment == nil,
                parts.path.isEmpty || parts.path == "/",
                let port = parts.port, (1...65535).contains(port),
                let host = parts.host, ["127.0.0.1", "[::1]", "::1"].contains(host),
                value == "http://127.0.0.1:\(port)" || value == "http://127.0.0.1:\(port)/"
                    || value == "http://[::1]:\(port)" || value == "http://[::1]:\(port)/",
                let url = URL(string: "http://\(host == "127.0.0.1" ? host : "[::1]"):\(port)")
            else { throw SparkLocalEngineError.originInvalid }
            self.url = url
        }
        func url(for endpoint: SparkLocalEngineEndpoint) -> URL {
            url.appendingPathComponent(endpoint.rawValue)
        }
    }

    enum SparkLocalEngineEndpoint: String, Sendable {
        case ollamaVersion = "api/version"
        case ollamaModels = "api/tags"
        case ollamaLoaded = "api/ps"
        case lmStudioModels = "api/v1/models"
        var engine: SparkLocalEngine { self == .lmStudioModels ? .lmStudio : .ollama }
    }

    struct SparkLocalEngineToken: Sendable {
        fileprivate let value: String
        init(_ value: String) throws {
            guard !value.isEmpty, value.utf8.count <= 4096,
                value.utf8.allSatisfy({ (33...126).contains($0) })
            else { throw SparkLocalEngineError.tokenInvalid }
            self.value = value
        }
        var authorization: String { "Bearer " + value }
    }

    /// A separate namespace from device, user-presence, provider and router keys.
    struct SparkLocalEngineCredentials: Sendable {
        static let service = "app.sparkpilot.local-engine-observation.v1"
        let store: any SecureStore
        init(store: any SecureStore = KeychainStore()) { self.store = store }
        private func account(_ origin: SparkLocalEngineOrigin) -> String {
            SHA256.hash(data: Data(("lmStudio:" + origin.url.absoluteString).utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        func token(origin: SparkLocalEngineOrigin) throws -> SparkLocalEngineToken? {
            do {
                guard let data = try store.data(service: Self.service, account: account(origin))
                else { return nil }
                guard let value = String(data: data, encoding: .utf8) else {
                    throw SparkLocalEngineError.credentialStorageFailed
                }
                return try SparkLocalEngineToken(value)
            } catch { throw SparkLocalEngineError.credentialStorageFailed }
        }
        func save(_ token: SparkLocalEngineToken, origin: SparkLocalEngineOrigin) throws {
            do {
                try store.set(
                    Data(token.value.utf8),
                    service: Self.service,
                    account: account(origin)
                )
            } catch { throw SparkLocalEngineError.credentialStorageFailed }
        }
        func remove(origin: SparkLocalEngineOrigin) throws {
            do { try store.delete(service: Self.service, account: account(origin)) } catch {
                throw SparkLocalEngineError.credentialStorageFailed
            }
        }
    }

    struct SparkLocalEngineModel: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let kind: String
        let format: String?
        let quantization: String?
        let sizeBytes: Int64?
        let reportedDigest: String?
        let loadedInstances: [SparkLocalEngineLoadedInstance]
        let reportedVision: Bool?
        let reportedToolUse: Bool?
        // Treat external engine metadata as claims rather than proof of execution location or complete artifact equivalence.
        var isShared: Bool { false }
        var strictPoolEligible: Bool { false }
    }
    struct SparkLocalEngineLoadedInstance: Equatable, Sendable, Identifiable {
        let id: String
        let contextLength: Int?
        let reportedParallelLimit: Int?
        let reportedMemoryBytes: Int64?
    }
    struct SparkLocalEngineSnapshot: Equatable, Sendable {
        let engine: SparkLocalEngine
        let origin: SparkLocalEngineOrigin
        let observedAt: Date
        let engineVersion: String?
        let apiContract: String
        let models: [SparkLocalEngineModel]
        let loadedInventoryAvailable: Bool
    }

    protocol SparkLocalEngineReading: Sendable {
        func inventory(
            engine: SparkLocalEngine,
            origin: SparkLocalEngineOrigin,
            token: SparkLocalEngineToken?
        ) async throws -> SparkLocalEngineSnapshot
    }
#endif
