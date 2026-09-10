import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity

@MainActor
public protocol SparkWarmupProviding {
    func models() async throws -> [SparkModel]
    func schedules() async throws -> WarmupCollection
    func preview(_ request: WarmupRequest) async throws -> WarmupPreview
    func create(_ request: WarmupRequest, key: UUID, presence: any UserPresenceProofSigning)
        async throws -> WarmupSchedule
    func disable(_ id: UUID, key: UUID, presence: any UserPresenceProofSigning) async throws
        -> WarmupSchedule
}

/// Each request resolves a saved target and checks its pinned identity again.
@MainActor
final class SignedSparkWarmupProvider: SparkWarmupProviding {
    private let library: SparkLibrary
    private let targetID: String
    init(library: SparkLibrary, targetID: String) {
        self.library = library
        self.targetID = targetID
    }

    private func connection() async throws -> (SparkAPIClient, URL) {
        guard let entry = library.entry(id: targetID), entry.issue == nil,
            entry.externalClusterRegistration == nil, entry.clusterID == nil,
            let nodeID = entry.coordinatorNodeID, let route = entry.preferredRoute?.baseURL,
            let trust = StoredNodeTrust.reader(nodeID.rawValue.uuidString.lowercased())
        else {
            throw SparkWarmupError(
                message: String(
                    localized: "Connect to a paired standalone Spark to manage warm-ups."
                )
            )
        }
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: nodeID.rawValue)
        let api = try SparkAPIClient.pinned(to: trust.tlsFingerprint, signer: signer)
        let identity = try await api.identity(route: route)
        guard identity.nodeID == nodeID, identity.authorityFingerprint == trust.authorityFingerprint
        else {
            throw SparkWarmupError(
                message: String(localized: "This connection does not match the paired Spark.")
            )
        }
        let capabilities = try await api.capabilities(route: route)
        guard capabilities.isEnabled("scheduled_warmup") else {
            throw SparkWarmupError(
                message: String(localized: "Update this Spark's runtime to use scheduled warm-up.")
            )
        }
        return (api, route)
    }
    func models() async throws -> [SparkModel] {
        let (api, route) = try await connection()
        return try await api.models(route: route).items
    }
    func schedules() async throws -> WarmupCollection {
        let (api, route) = try await connection()
        return try await api.warmups(route: route)
    }
    func preview(_ request: WarmupRequest) async throws -> WarmupPreview {
        let (api, route) = try await connection()
        return try await api.previewWarmup(route: route, request: request)
    }
    func create(_ request: WarmupRequest, key: UUID, presence: any UserPresenceProofSigning)
        async throws -> WarmupSchedule
    {
        let (api, route) = try await connection()
        return try await api.createWarmup(
            route: route,
            request: request,
            idempotencyKey: key,
            userPresence: presence
        )
    }
    func disable(_ id: UUID, key: UUID, presence: any UserPresenceProofSigning) async throws
        -> WarmupSchedule
    {
        let (api, route) = try await connection()
        return try await api.disableWarmup(
            route: route,
            scheduleID: id,
            idempotencyKey: key,
            userPresence: presence
        )
    }
}
struct SparkWarmupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor @Observable
public final class SparkWarmupModel {
    public private(set) var models: [SparkModel] = []
    public private(set) var schedules: [WarmupSchedule] = []
    public private(set) var review: WarmupPreview?
    public private(set) var isWorking = false
    public private(set) var hasLoaded = false
    public private(set) var errorMessage: String?
    public var modelID = "" {
        didSet {
            if oldValue != modelID {
                discardReview()
                profileID = profiles.first?.id ?? ""
            }
        }
    }
    public var profileID = "" { didSet { if oldValue != profileID { discardReview() } } }
    public var dueDate = Date().addingTimeInterval(600) {
        didSet { if oldValue != dueDate { discardReview() } }
    }
    @ObservationIgnored private let provider: any SparkWarmupProviding
    @ObservationIgnored private let authorizer: any UserPresenceAuthorizing
    @ObservationIgnored private var reviewedRequest: WarmupRequest?
    @ObservationIgnored private var createKey: UUID?
    @ObservationIgnored private var disableKeys: [UUID: UUID] = [:]

    public init(
        provider: any SparkWarmupProviding,
        authorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer()
    ) {
        self.provider = provider
        self.authorizer = authorizer
    }
    public convenience init(library: SparkLibrary, targetID: String) {
        self.init(provider: SignedSparkWarmupProvider(library: library, targetID: targetID))
    }
    public var profiles: [SparkModelProfile] {
        models.first { $0.id == modelID }?.profiles.filter(\.safe) ?? []
    }
    public var canReview: Bool {
        hasLoaded && !isWorking && !modelID.isEmpty && profiles.contains { $0.id == profileID }
    }
    public func canConfirm(at now: Date = Date()) -> Bool {
        guard !isWorking, let review, reviewedRequest != nil, review.review.blockers.isEmpty,
            Date(timeIntervalSince1970: TimeInterval(review.dueAt)) > now
        else {
            return false
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return
            (fractional.date(from: review.review.expiresAt)
            ?? ISO8601DateFormatter().date(from: review.review.expiresAt)).map { $0 > now } ?? false
    }
    public func discardReview() {
        review = nil
        reviewedRequest = nil
        createKey = nil
    }
    public func refresh() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            let catalogue = try await provider.models()
            let collection = try await provider.schedules()
            models = catalogue.filter {
                $0.installState == .installed && $0.profiles.contains(where: \.safe)
            }
            schedules = collection.items
            if !models.contains(where: { $0.id == modelID }) { modelID = models.first?.id ?? "" }
            if !profiles.contains(where: { $0.id == profileID }) {
                profileID = profiles.first?.id ?? ""
            }
            hasLoaded = true
        } catch {
            hasLoaded = false
            models = []
            schedules = []
            discardReview()
            errorMessage =
                (error as? APIError)?.code == "ROLE_FORBIDDEN"
                ? String(localized: "Only a Spark owner can schedule or manage warm-ups.")
                : error.localizedDescription
        }
    }
    public func prepareReview() async {
        guard canReview else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        discardReview()
        let request = WarmupRequest(
            modelID: modelID,
            profileID: profileID,
            dueAt: Int64(dueDate.timeIntervalSince1970)
        )
        do {
            let result = try await provider.preview(request)
            guard request.modelID == modelID, request.profileID == profileID,
                request.dueAt == Int64(dueDate.timeIntervalSince1970),
                result.review.action.rawValue == "warmup", result.dueAt == request.dueAt,
                result.review.recipe?.modelId == request.modelID,
                result.review.recipe?.profileId == request.profileID,
                result.review.consequences.modelToStop == nil,
                !result.review.consequences.routeWithdrawal
            else {
                throw SparkWarmupError(
                    message: String(
                        localized:
                            "The warm-up review does not match your selection. Refresh and try again."
                    )
                )
            }
            review = result
            reviewedRequest = request
            createKey = UUID()
        } catch { errorMessage = error.localizedDescription }
    }
    public func confirm() async {
        guard canConfirm(), let review, var request = reviewedRequest, let key = createKey else {
            return
        }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            let presence = try await authorizer.authorize(
                localizedReason: String(
                    localized: "Schedule this model to load only when the Spark is idle."
                )
            )
            request.acceptedPreviewDigest = review.review.previewDigest
            let schedule = try await provider.create(request, key: key, presence: presence)
            schedules.removeAll { $0.id == schedule.id }
            schedules.insert(schedule, at: 0)
            discardReview()
        } catch { errorMessage = error.localizedDescription }
    }
    public func disable(_ schedule: WarmupSchedule) async {
        guard !isWorking, schedule.canDisable else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        let key = disableKeys[schedule.id] ?? UUID()
        disableKeys[schedule.id] = key
        do {
            let presence = try await authorizer.authorize(
                localizedReason: String(localized: "Disable this scheduled model warm-up.")
            )
            let updated = try await provider.disable(schedule.id, key: key, presence: presence)
            schedules = schedules.map { $0.id == updated.id ? updated : $0 }
            disableKeys[schedule.id] = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

extension WarmupSchedule {
    public var statusDescription: String {
        switch state {
        case "pending": String(localized: "Scheduled · only if idle")
        case "dispatching", "running": String(localized: "Loading model")
        case "succeeded": String(localized: "Warm-up completed")
        case "disabled": String(localized: "Disabled by owner")
        case "revoked": String(localized: "Cancelled because the owner's access changed")
        case "expired": String(localized: "Skipped because the scheduled time was missed")
        case "interrupted":
            String(localized: "Interrupted by a restart · check the model before scheduling again")
        case "skipped", "failed": failureDescription
        default: String(localized: "Status unavailable")
        }
    }
    private var failureDescription: String {
        switch resultCode {
        case "ENGINE_ACTIVE", "ENGINE_NOT_READY", "EXTERNAL_ENGINE_ACTIVE":
            String(localized: "Skipped because another workload was active")
        case "MODEL_INSUFFICIENT_MEMORY", "MEMORY_PRESSURE_ACTIVE":
            String(localized: "Skipped because there was not enough safe memory")
        case "WARMUP_REVIEW_CHANGED", "MODEL_RECIPE_UNTRUSTED", "MODEL_NOT_INSTALLED":
            String(localized: "Skipped because the reviewed model or requirements changed")
        case "MODEL_PROFILE_UNSAFE":
            String(localized: "Skipped because the profile is marked unsafe")
        default: String(localized: "Could not safely start the model · review its current status")
        }
    }
}
