import Foundation
import Observation
import SparkBootstrap
import SwiftUI

/// What the owner is being asked to confirm.
public struct HostKeyConfirmationRequest: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let host: String
    public let fingerprint: SSHHostKeyFingerprint

    /// Format owner-confirmed host fingerprints exactly as OpenSSH prints them.
    public var displayString: String { fingerprint.displayString }
}

/// Bridges asynchronous host-key confirmation to observable UI state before setup credentials can be sent.
@MainActor
@Observable
public final class HostKeyConfirmationCoordinator {
    /// Non-nil while confirmation is pending; the newest registered surface presents it.
    public private(set) var pending: HostKeyConfirmationRequest?

    /// Expire unanswered host-key confirmation with the SSH handshake that requested it.
    public static let unansweredQuestionLifetime: TimeInterval = 300

    @ObservationIgnored
    private var continuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored
    private var askedAt: Date?
    @ObservationIgnored
    private let now: () -> Date
    /// Only the most recently presented surface shows host-key prompts, preventing covered views from swallowing them.
    private var presenters: [UUID] = []

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func registerPresenter(_ id: UUID) {
        presenters.removeAll { $0 == id }
        presenters.append(id)
    }

    public func unregisterPresenter(_ id: UUID) {
        presenters.removeAll { $0 == id }
    }

    /// Whether the surface with this id is the one that shows the prompt.
    public func presents(_ id: UUID) -> Bool {
        presenters.last == id
    }

    /// The owner looked at the fingerprint and accepted it.
    public func confirm() {
        resume(with: true)
    }

    /// Treat dismissal as refusal so an unconfirmed host never receives credentials.
    public func decline() {
        resume(with: false)
    }

    private func resume(with decision: Bool) {
        pending = nil
        askedAt = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: decision)
    }

    fileprivate func ask(host: String, fingerprint: SSHHostKeyFingerprint) async -> Bool {
        // Keep one live confirmation prompt; decline an expired request before replacing it with a new connection's question.
        if continuation != nil {
            guard let askedAt, now().timeIntervalSince(askedAt) > Self.unansweredQuestionLifetime
            else { return false }
            resume(with: false)
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.askedAt = now()
            self.pending = HostKeyConfirmationRequest(host: host, fingerprint: fingerprint)
        }
    }

    /// The confirmer to hand to ``HostKeyPolicy``.
    public var confirmer: any HostKeyConfirming {
        CoordinatedHostKeyConfirmer(coordinator: self)
    }
}

private struct CoordinatedHostKeyConfirmer: HostKeyConfirming {
    let coordinator: HostKeyConfirmationCoordinator

    func confirmFirstUse(host: String, fingerprint: SSHHostKeyFingerprint) async -> Bool {
        await coordinator.ask(host: host, fingerprint: fingerprint)
    }
}

extension CoordinatedHostKeyConfirmer: @unchecked Sendable {}

/// Attach to every SSH-capable surface so the most recently shown screen presents the host-key question.
public struct HostKeyConfirmationPrompt: ViewModifier {
    @Environment(HostKeyConfirmationCoordinator.self) private var coordinator:
        HostKeyConfirmationCoordinator?
    @State private var presenterID = UUID()

    public init() {}

    public func body(content: Content) -> some View {
        content
            .onAppear { coordinator?.registerPresenter(presenterID) }
            .onDisappear { coordinator?.unregisterPresenter(presenterID) }
            .alert(
                "Is this your Spark?",
                isPresented: .constant(isPresented),
                presenting: coordinator?.pending
            ) { _ in
                Button("Not This One", role: .cancel) { coordinator?.decline() }
                Button("Yes, Continue") { coordinator?.confirm() }
            } message: { request in
                // Use the Spark's fingerprint format so the owner can compare keys before transmitting the administrator password.
                Text(
                    String(
                        localized: .hostKeyFingerprintPrompt(
                            host: request.host,
                            fingerprint: request.displayString
                        )
                    )
                )
            }
    }

    private var isPresented: Bool {
        guard let coordinator, coordinator.pending != nil else { return false }
        return coordinator.presents(presenterID)
    }
}

extension View {
    public func hostKeyConfirmationPrompt() -> some View {
        modifier(HostKeyConfirmationPrompt())
    }
}
