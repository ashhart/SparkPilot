import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary

// MARK: - View state

@MainActor
@Observable
public final class CrossTargetModelLibraryModel {
    public private(set) var snapshot: CrossTargetModelLibrarySnapshot = .empty
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var hasLoaded = false

    @ObservationIgnored
    private let provider: any CrossTargetModelLibraryDataProviding

    public init(provider: any CrossTargetModelLibraryDataProviding) {
        self.provider = provider
    }

    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            snapshot = try await provider.fetchSnapshot()
            hasLoaded = true
        } catch is CancellationError {
            // Cancelled reads leave hasLoaded false so the next appearance retries instead of retaining stale evidence.
        } catch {
            hasLoaded = true
            errorMessage =
                String(
                    localized:
                        "The model library could not be refreshed. Existing evidence remains visible."
                )
        }
    }
}
