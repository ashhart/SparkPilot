import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

final class ModelLibraryTestChatEvidenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = modelLibraryTestLibraryEvidenceDate

    func now() -> Date { lock.withLock { date } }
    func advance(by seconds: TimeInterval) { lock.withLock { date += seconds } }
}

let modelLibraryTestChatEvidenceNodeID = SparkNodeID(
    rawValue: UUID(uuidString: "8c1e55f1-71f9-401b-90e0-7d73508fdc82")!
)

@MainActor
func modelLibraryTestChatEvidenceFixture(
    runtime: ModelLibraryTestModelLibraryRuntimeStub,
    clock: ModelLibraryTestChatEvidenceClock,
    expectedClusterID: SparkClusterID? = nil
) throws -> (
    library: SparkLibrary, provider: SignedCrossTargetModelLibraryProvider, entryID: String
) {
    let entry = modelLibraryTestLibraryEntry(nodeID: modelLibraryTestChatEvidenceNodeID)
    let store = MemoryLibraryStore()
    try store.save([entry])
    let library = SparkLibrary(store: store, now: { clock.now() })
    library.load()
    let provider = SignedCrossTargetModelLibraryProvider(
        library: library,
        now: { clock.now() },
        runtimeResolver: { _ in
            ModelLibraryRuntimeConnection(
                route: entry.preferredRoute!.baseURL,
                expectedNodeID: modelLibraryTestChatEvidenceNodeID,
                expectedClusterID: expectedClusterID,
                expectedAuthorityFingerprint: "authority-a",
                runtime: runtime
            )
        }
    )
    return (library, provider, entry.id)
}
