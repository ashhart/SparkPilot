import Foundation

@MainActor
public protocol SparkWatchServicing {
    func authorize(_ request: SparkWatchRequest) throws
    func execute(_ request: SparkWatchRequest) async throws -> SparkWatchResponse
}

@MainActor
public final class SparkWatchRequestRouter {
    private struct Job {
        var request: SparkWatchRequest
        var response: SparkWatchResponse
        var task: Task<Void, Never>?
    }
    private let service: any SparkWatchServicing
    private let receiptURL: URL
    private var receiptStoreUnavailable = false
    private let now: () -> Date
    private var jobs: [UUID: Job] = [:]
    private var receipts: [String: Double]
    public var didFinish: ((UUID) -> Void)?

    public init(
        service: any SparkWatchServicing,
        receiptURL: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.now = now
        self.receiptURL =
            receiptURL
            ?? URL.applicationSupportDirectory
            .appendingPathComponent("SparkPilot/watch-receipts.json")
        receipts = [:]
        if FileManager.default.fileExists(atPath: self.receiptURL.path) {
            do {
                receipts = try JSONDecoder().decode(
                    [String: Double].self,
                    from: Data(contentsOf: self.receiptURL)
                )
            } catch { receiptStoreUnavailable = true }
        }
    }

    public func receive(_ request: SparkWatchRequest) -> SparkWatchResponse {
        do {
            try request.validate(now: now())
            try service.authorize(request)
            if request.command == .poll || request.command == .cancel, let id = request.jobID {
                if request.command == .cancel { cancel(id: id) }
                if let job = jobs[id] {
                    try service.authorize(job.request)
                    return job.response
                }
                return .init(
                    id: id,
                    phase: .unknown,
                    message:
                        "The iPhone restarted or this request expired. Refresh status before trying a model change again."
                )
            }
            if let job = jobs[request.id] {
                guard job.request == request else {
                    throw SparkWatchFailure("This request identifier was already used.")
                }
                try service.authorize(job.request)
                return job.response
            }
            prune()
            guard receipts[request.id.uuidString] == nil else {
                return .init(
                    id: request.id,
                    phase: .unknown,
                    message:
                        "This request was already accepted. Refresh status to check its outcome."
                )
            }
            guard receipts.count < 128, jobs.values.filter({ $0.task != nil }).count < 3 else {
                throw SparkWatchFailure(
                    "Your iPhone is busy. Wait for the current request to finish."
                )
            }
            guard !receiptStoreUnavailable else {
                throw SparkWatchFailure("Watch request storage is unavailable on your iPhone.")
            }
            receipts[request.id.uuidString] = now().timeIntervalSince1970
            do {
                try FileManager.default.createDirectory(
                    at: receiptURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try JSONEncoder().encode(receipts).write(to: receiptURL, options: .atomic)
            } catch {
                receipts.removeValue(forKey: request.id.uuidString)
                throw SparkWatchFailure(
                    "Your iPhone could not save this request; nothing was started."
                )
            }
            let response = SparkWatchResponse(id: request.id, phase: .pending)
            jobs[request.id] = Job(request: request, response: response)
            jobs[request.id]?.task = Task { [weak self] in
                guard let self else { return }
                let result: SparkWatchResponse
                do {
                    try Task.checkCancellation()
                    try service.authorize(request)
                    result = try await service.execute(request)
                    try Task.checkCancellation()
                    try service.authorize(request)
                    _ = try SparkWatchCodec.encode(result)
                } catch is CancellationError {
                    return
                } catch {
                    finish(
                        id: request.id,
                        response: .init(
                            id: request.id,
                            phase: .failed,
                            message: (error as? SparkWatchFailure)?.message
                                ?? "The request could not finish. Check your Spark connection and try again."
                        )
                    )
                    return
                }
                finish(id: request.id, response: result)
            }
            return response
        } catch {
            return .init(
                id: request.jobID ?? request.id,
                phase: .failed,
                message: (error as? SparkWatchFailure)?.message ?? "This request is unavailable."
            )
        }
    }

    public func cancel(id: UUID) {
        guard jobs[id]?.task != nil else { return }
        jobs[id]?.task?.cancel()
        finish(
            id: id,
            response: .init(
                id: id,
                phase: .failed,
                message:
                    "Stopped waiting. A model change already accepted by your Spark may still finish; refresh its status."
            )
        )
    }

    public func cancelAll() {
        for id in Array(jobs.keys) { cancel(id: id) }
        jobs.removeAll()
    }

    private func finish(id: UUID, response: SparkWatchResponse) {
        jobs[id]?.response = response
        jobs[id]?.task = nil
        didFinish?(id)
    }

    private func prune() {
        let date = now()
        receipts = receipts.filter { date.timeIntervalSince1970 - $0.value <= 300 }
        jobs = jobs.filter {
            $0.value.task != nil || date.timeIntervalSince($0.value.request.createdAt) <= 300
        }
    }
}
