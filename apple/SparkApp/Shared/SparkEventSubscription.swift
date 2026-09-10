import Foundation
import Observation
import SparkAPI
import SparkTransport

/// Turns one Spark's event stream into the refreshes the screen already knows how to do (§44.1).
@MainActor
@Observable
final class SparkEventSubscription {
    /// Opens the stream for a cursor; the caller owns the signed, pinned client behind it.
    typealias SparkEventStream = AsyncThrowingStream<SparkEventStreamElement, any Error>
    typealias Open = @MainActor (_ cursor: String?) async -> SparkEventStream

    /// True while the reader is attached; polling never stops, so this is information, not a switch.
    private(set) var isStreaming = false
    /// Set when this Spark will not serve the stream at all, so the app stops asking this session.
    private(set) var refusedByThisSpark = false
    /// The cursor a reconnection resumes from.
    private(set) var lastEventID: String?
    private(set) var heartbeatsSeen = 0
    private(set) var eventsSeen = 0

    @ObservationIgnored
    private let open: Open
    @ObservationIgnored
    private let apply: @MainActor (SparkEventRefresh) async -> Void
    @ObservationIgnored
    private var task: Task<Void, Never>?
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var pending: SparkEventRefresh = []
    @ObservationIgnored
    private var applying = false
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private let checkpoint: @MainActor (String?) -> Void

    init(
        open: @escaping Open,
        apply: @escaping @MainActor (SparkEventRefresh) async -> Void,
        checkpoint: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.open = open
        self.apply = apply
        self.checkpoint = checkpoint
    }

    /// Seed the cursor from a previous session so a relaunch resumes rather than replaying all.
    func resume(from id: String?) {
        lastEventID = id
    }

    /// Attach to the stream. Safe to call again; a Spark that already refused is not asked twice.
    func start() {
        guard task == nil, !refusedByThisSpark else { return }
        task = Task { [weak self] in await self?.run() }
    }

    /// Detach with the screen. Polling carries on either way.
    func stop() {
        epoch = UUID()
        task?.cancel()
        task = nil
        refreshTask?.cancel()
        refreshTask = nil
        pending = []
        applying = false
        isStreaming = false
    }

    /// Read until the stream ends, the Spark refuses it, or the caller stops.
    func run() async {
        let runEpoch = epoch
        isStreaming = true
        defer { if epoch == runEpoch { isStreaming = false } }
        do {
            for try await element in await open(lastEventID) {
                if Task.isCancelled || epoch != runEpoch { break }
                receive(element)
            }
        } catch {
            if epoch == runEpoch { note(error) }
        }
        if epoch == runEpoch { await refreshTask?.value }
    }

    // MARK: - Internals

    private func receive(_ element: SparkEventStreamElement) {
        switch element {
        case .heartbeat:
            heartbeatsSeen += 1
        case .cursorExpired:
            // The catalogue requires canonical state to be refreshed after an event-gap reset.
            lastEventID = nil
            checkpoint(nil)
            schedule(.everything)
        case .event(let event):
            eventsSeen += 1
            lastEventID = String(event.sequence)
            schedule(SparkEventRouting.refreshes(for: event.type))
        }
    }

    /// Fold a burst into one follow-up refresh rather than reading the same surfaces repeatedly.
    private func schedule(_ refresh: SparkEventRefresh) {
        guard !refresh.isEmpty else {
            if !applying { checkpoint(lastEventID) }
            return
        }
        pending.formUnion(refresh)
        guard !applying else { return }
        applying = true
        let epoch = epoch
        refreshTask = Task { [weak self] in
            while let self, self.epoch == epoch, !self.pending.isEmpty, !Task.isCancelled {
                let batch = self.pending
                let cursor = self.lastEventID
                self.pending = []
                await self.apply(batch)
                guard self.epoch == epoch, !Task.isCancelled else { return }
                self.checkpoint(cursor)
            }
            if self?.epoch == epoch { self?.applying = false }
        }
    }

    /// An older runtime that has no stream is not an error the owner should ever see.
    private func note(_ error: any Error) {
        if let refusal = error as? SSEOpenFailure, case .unsupported = refusal {
            refusedByThisSpark = true
            return
        }
        if error is APIError { refusedByThisSpark = true }
    }
}

/// Builds the subscription for one Spark, or nothing when this device cannot open a signed stream.
@MainActor
enum SparkEventStreamOpening {
    /// No pin, no signer or no HTTPS route means polling stays the only source; never an open stream.
    static func subscription(
        route: URL,
        pin: String?,
        signer: (any RequestSigning)?,
        apply: @escaping @MainActor (SparkEventRefresh) async -> Void
    ) -> SparkEventSubscription? {
        guard let pin, let signer else { return nil }
        guard let client = try? EventsClient(baseURL: route, pin: pin, signer: signer) else {
            return nil
        }
        let store = SparkEventCursorStore.shared
        let scope = (signer as? any SparkEventCursorIdentityProviding).map {
            SparkEventCursorStore.scope(identity: $0.eventCursorIdentity, pin: pin)
        }
        let subscription = SparkEventSubscription(
            open: { cursor in await client.events(resumingFrom: cursor) },
            apply: apply,
            checkpoint: { cursor in
                if let scope { store.checkpoint(cursor, for: scope) }
            }
        )
        if let scope { subscription.resume(from: store.cursor(for: scope)) }
        return subscription
    }
}

extension SparkRequestSigner: SparkEventCursorIdentityProviding {}
