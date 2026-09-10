#if os(iOS)
    import Foundation
    import SparkLibrary
    import SparkWatchSupport
    import UIKit
    @preconcurrency import WatchConnectivity

    @MainActor
    public final class SparkWatchPhoneBridge: NSObject, WCSessionDelegate {
        public static let shared = SparkWatchPhoneBridge()
        private var router: SparkWatchRequestRouter?
        private var backgrounds: [UUID: UIBackgroundTaskIdentifier] = [:]
        private var deadlines: [UUID: Task<Void, Never>] = [:]

        public func activate(appLock: AppLockModel) {
            guard WCSession.isSupported(), router == nil else { return }
            let library = SparkLibrary.appLibrary()
            library.load()
            let router = SparkWatchRequestRouter(
                service: SparkWatchRuntimeService(library: library, appLock: appLock)
            )
            router.didFinish = { [weak self] id in self?.finishBackground(id) }
            self.router = router
            WCSession.default.delegate = self
            WCSession.default.activate()
        }

        public func privacyChanged() {
            router?.cancelAll()
        }

        private func receive(_ data: Data) -> Data {
            let response: SparkWatchResponse
            do {
                let request = try SparkWatchCodec.decode(SparkWatchRequest.self, from: data)
                guard let router else { throw SparkWatchFailure("Open SparkPilot on your iPhone.") }
                response = router.receive(request)
                if response.phase == .pending, backgrounds[response.id] == nil {
                    let id = response.id
                    let token = UIApplication.shared.beginBackgroundTask(
                        withName: "SparkPilot Watch"
                    ) { [weak self] in
                        Task { @MainActor in self?.router?.cancel(id: id) }
                    }
                    if token == .invalid {
                        router.cancel(id: id)
                    } else {
                        backgrounds[id] = token
                        deadlines[id] = Task { [weak self] in
                            try? await Task.sleep(for: .seconds(90))
                            guard !Task.isCancelled else { return }
                            self?.router?.cancel(id: id)
                        }
                    }
                }
            } catch {
                response = .init(
                    id: UUID(),
                    phase: .failed,
                    message: "The watch request was not understood. Update both apps."
                )
            }
            return (try? SparkWatchCodec.encode(response)) ?? Data()
        }

        private func finishBackground(_ id: UUID) {
            deadlines.removeValue(forKey: id)?.cancel()
            if let token = backgrounds.removeValue(forKey: id) {
                UIApplication.shared.endBackgroundTask(token)
            }
        }

        nonisolated public func session(
            _ session: WCSession,
            didReceiveMessageData messageData: Data,
            replyHandler: @escaping (Data) -> Void
        ) {
            let reply = SparkWatchReply(handler: replyHandler)
            Task { @MainActor in reply.handler(receive(messageData)) }
        }

        nonisolated public func session(
            _ session: WCSession,
            activationDidCompleteWith activationState: WCSessionActivationState,
            error: (any Error)?
        ) {}
        nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {
            Task { @MainActor in privacyChanged() }
        }
        nonisolated public func sessionDidDeactivate(_ session: WCSession) {
            Task { @MainActor in
                privacyChanged()
                session.activate()
            }
        }
    }
    // WatchConnectivity permits its reply on any queue; this handler moves once to the main actor.
    private struct SparkWatchReply: @unchecked Sendable {
        let handler: (Data) -> Void
    }
#endif
