import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

func modelLibraryTestLibraryEntry(nodeID: SparkNodeID) -> LibraryEntry {
    LibraryEntry(
        logicalKey: .node(nodeID),
        name: "Studio Spark",
        members: [
            LibraryMember(
                nodeID: nodeID,
                name: "Studio Spark",
                role: .standalone,
                authorityFingerprint: "authority-a",
                routes: [
                    CachedRoute(
                        baseURL: URL(string: "https://studio-spark.local:7443")!,
                        kind: .localWiFi,
                        lastSuccess: modelLibraryTestLibraryEvidenceDate
                    )
                ],
                lastSeen: modelLibraryTestLibraryEvidenceDate,
                reachable: true
            )
        ],
        connectionState: .connectedWiFi,
        lastSeen: modelLibraryTestLibraryEvidenceDate,
        cachedAt: modelLibraryTestLibraryEvidenceDate
    )
}

func modelLibraryTestLibraryDecode<Value: Decodable>(_ json: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(json.utf8))
}

// MARK: - A refresh that was cancelled learned nothing

/// Treat view-task cancellation as navigation rather than evidence that a Spark failed.
actor ModelLibraryTestCancellingLibraryProvider: CrossTargetModelLibraryDataProviding {
    private(set) var calls = 0

    func callCount() -> Int { calls }

    @MainActor
    func fetchSnapshot() async throws -> CrossTargetModelLibrarySnapshot {
        await bump()
        throw CancellationError()
    }

    private func bump() { calls += 1 }
}

actor ModelLibraryTestFailingLibraryProvider: CrossTargetModelLibraryDataProviding {
    struct Unreachable: Error {}

    @MainActor
    func fetchSnapshot() async throws -> CrossTargetModelLibrarySnapshot {
        throw Unreachable()
    }
}
