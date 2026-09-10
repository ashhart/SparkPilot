#if os(macOS)
    import Foundation
    import Observation

    enum SparkLocalInventoryTime {
        private static let origin = ContinuousClock().now
        static func now() -> Double {
            let value = origin.duration(to: ContinuousClock().now).components
            return Double(value.seconds) + Double(value.attoseconds) / 1e18
        }
    }

    @MainActor @Observable
    final class SparkLocalEngineInventoryModel {
        var engine: SparkLocalEngine = .ollama {
            didSet {
                if engine != oldValue {
                    address = engine.defaultAddress
                    invalidate()
                }
            }
        }
        var address = SparkLocalEngine.ollama.defaultAddress {
            didSet {
                if address != oldValue {
                    tokenInput = ""
                    rememberToken = false
                    invalidate()
                }
            }
        }
        var tokenInput = ""
        var rememberToken = false
        private(set) var snapshot: SparkLocalEngineSnapshot?
        private(set) var isChecking = false
        private(set) var error: SparkLocalEngineError?
        private(set) var hasSavedToken = false
        @ObservationIgnored private let reader: any SparkLocalEngineReading
        @ObservationIgnored private let credentials: SparkLocalEngineCredentials
        @ObservationIgnored private let now: @Sendable () -> TimeInterval
        @ObservationIgnored private var receivedAt: TimeInterval?
        @ObservationIgnored private var generation = UUID()
        @ObservationIgnored private var task: Task<Void, Never>?

        init(
            reader: any SparkLocalEngineReading = SparkLocalEngineReader(),
            credentials: SparkLocalEngineCredentials = SparkLocalEngineCredentials(),
            now: @escaping @Sendable () -> TimeInterval = { SparkLocalInventoryTime.now() }
        ) {
            self.reader = reader
            self.credentials = credentials
            self.now = now
            // Construction and navigation never probe engines or read credentials.
        }
        var status: String {
            if isChecking { return String(localized: "Checking local inventory") }
            guard snapshot != nil, let receivedAt else { return String(localized: "Not checked") }
            let elapsed = now() - receivedAt
            if elapsed < 0 || elapsed > 30 {
                return String(localized: "Check again for current state")
            }
            return String(localized: "Responded to your check")
        }
        private func invalidate() {
            generation = UUID()
            task?.cancel()
            task = nil
            isChecking = false
            snapshot = nil
            receivedAt = nil
            error = nil
            hasSavedToken = false
        }
        @discardableResult func check() -> Task<Void, Never>? {
            guard !isChecking else { return nil }
            let origin: SparkLocalEngineOrigin
            let token: SparkLocalEngineToken?
            do {
                origin = try SparkLocalEngineOrigin(address)
                if engine == .lmStudio {
                    if !tokenInput.isEmpty {
                        token = try SparkLocalEngineToken(tokenInput)
                        if rememberToken, let token { try credentials.save(token, origin: origin) }
                    } else {
                        token = try credentials.token(origin: origin)
                    }
                    hasSavedToken = try credentials.token(origin: origin) != nil
                } else {
                    token = nil
                }
            } catch {
                self.error = error as? SparkLocalEngineError ?? .credentialStorageFailed
                return nil
            }
            tokenInput = ""
            let generation = UUID(), engine = engine
            self.generation = generation
            isChecking = true
            error = nil
            snapshot = nil
            receivedAt = nil
            let task = Task {
                do {
                    let result = try await reader.inventory(
                        engine: engine,
                        origin: origin,
                        token: token
                    )
                    try Task.checkCancellation()
                    guard self.generation == generation else { return }
                    guard result.engine == engine, result.origin == origin else {
                        throw SparkLocalEngineError.responseInvalid
                    }
                    snapshot = result
                    receivedAt = now()
                    isChecking = false
                    self.task = nil
                } catch {
                    guard self.generation == generation else { return }
                    self.error =
                        error as? SparkLocalEngineError
                        ?? (error is CancellationError ? .cancelled : .unavailable)
                    isChecking = false
                    self.task = nil
                }
            }
            self.task = task
            return task
        }
        func cancel() {
            guard isChecking else { return }
            invalidate()
            error = .cancelled
        }
        func clear() {
            invalidate()
            tokenInput = ""
            rememberToken = false
        }
        func forgetToken() {
            cancel()
            do {
                try credentials.remove(origin: SparkLocalEngineOrigin(address))
                hasSavedToken = false
                tokenInput = ""
                rememberToken = false
                error = nil
            } catch { self.error = error as? SparkLocalEngineError ?? .credentialStorageFailed }
        }
    }
#endif
