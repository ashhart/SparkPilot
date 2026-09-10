import Foundation
import Observation
#if os(iOS)
    @preconcurrency import AVFoundation
#endif

/// One microphone, one speaker: a new voice session claims them and the previous owner is stopped.
@MainActor
@Observable
public final class SparkVoiceCoordinator {
    public static let shared = SparkVoiceCoordinator()

    public enum Owner: String, Equatable, Sendable {
        case phone
        case carPlay
    }

    public private(set) var activeOwner: Owner?
    @ObservationIgnored private weak var activeSession: SparkVoiceSession?

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    init() {
        #if os(iOS)
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    let interruption = SparkVoiceInterruption.parse(userInfo: note.userInfo)
                    Task { @MainActor [weak self] in
                        if let interruption { self?.activeSession?.interrupted(by: interruption) }
                    }
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.routeChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    let disconnected =
                        (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                        == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                    if disconnected {
                        Task { @MainActor [weak self] in self?.activeSession?.stop() }
                    }
                }
            )
        #endif
    }
    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Take the audio for this session. Any other live session is stopped first.
    func claim(_ session: SparkVoiceSession, as owner: Owner) {
        if let activeSession, activeSession !== session { activeSession.stop() }
        activeSession = session
        activeOwner = owner
        session.canUseAudio = { [weak self, weak session] in
            guard let session else { return false }
            return self?.holds(session) == true
        }
    }

    /// Give the audio back, but only if this session still holds it.
    func release(_ session: SparkVoiceSession) {
        guard activeSession === session else { return }
        activeSession = nil
        activeOwner = nil
    }

    func holds(_ session: SparkVoiceSession) -> Bool { activeSession === session }
}
