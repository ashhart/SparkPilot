import Foundation
import SparkAPI
import SparkCore
import SparkLibrary

/// A pretend fleet for driving and screenshotting Home without pairing anything. Debug builds only.
enum FleetSampleFleet {
    static let argumentPrefix = "--spark-sample-fleet="
    /// How often a sample Spark pretends to answer; short because each load() downgrades it until the next beat.
    static let heartbeat: Duration = .seconds(1)

    /// The single-Spark states Home has to look right in, named so each can be launched on its own.
    enum SampleState: String, Sendable, Equatable, CaseIterable {
        case idle
        case loading
        case running
    }

    /// What a launch argument asks for: a fleet of a given size, or one Spark in a named state.
    enum Request: Sendable, Equatable {
        case fleet(size: Int)
        case one(SampleState)
    }

    /// Reads the request from the launch arguments; nil for anything else.
    static func requested(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Request? {
        guard
            let raw = arguments.first(where: { $0.hasPrefix(argumentPrefix) })?
                .dropFirst(argumentPrefix.count)
        else { return nil }
        if let size = Int(raw) {
            return (0...3).contains(size) ? .fleet(size: size) : nil
        }
        return SampleState(rawValue: String(raw)).map(Request.one)
    }

    /// Returns a seeded pretend library, or nil in Release and whenever the argument is absent.
    @MainActor
    static func library(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> SparkLibrary?
    {
        #if DEBUG
            guard let request = requested(arguments) else { return nil }
            let library = SparkLibrary(store: SampleLibraryStore())
            seed(library, samples(for: request), at: Date())
            return library
        #else
            return nil
        #endif
    }

    #if DEBUG
        /// The one sample library this process uses, so every composition root sees the same pretend fleet.
        @MainActor private static var shared: SparkLibrary?

        /// The library the app runs on when the sample argument is present, seeded once and kept live.
        @MainActor
        static func sharedLibrary() -> SparkLibrary? {
            if let shared { return shared }
            guard let library = library() else { return nil }
            shared = library
            keepLive(library)
            return library
        }

        /// Re-stamps the evidence the app's load() downgrades, then again on every heartbeat.
        @MainActor
        private static func keepLive(_ library: SparkLibrary) {
            Task { @MainActor [weak library] in
                while let library, !Task.isCancelled {
                    restamp(library, at: Date())
                    try? await Task.sleep(for: heartbeat)
                }
            }
        }

        /// Records another round of pretend evidence, matching each seeded entry to the sample it came from.
        @MainActor
        static func restamp(_ library: SparkLibrary, at date: Date) {
            let byEntry = Dictionary(
                uniqueKeysWithValues: SampleSpark.every.map { (entryID($0), $0) }
            )
            for entry in library.entries {
                guard let spark = byEntry[entry.id] else { continue }
                apply(spark, to: library, at: date)
            }
        }

        @MainActor
        private static func seed(_ library: SparkLibrary, _ samples: [SampleSpark], at date: Date) {
            for spark in samples {
                library.reconcile(
                    AuthenticatedTarget(
                        nodeID: spark.nodeID,
                        clusterID: nil,
                        name: spark.name,
                        role: .standalone,
                        authorityFingerprint: "sample-authority",
                        displayName: spark.hostname,
                        routes: [CachedRoute(baseURL: spark.route, kind: spark.routeKind)],
                        reachedAt: date.addingTimeInterval(-spark.lastAnsweredAgo)
                    )
                )
                apply(spark, to: library, at: date)
            }
        }

        /// Feeds pretend wire payloads through the real composer, so the sample cannot drift from production shapes.
        @MainActor
        private static func apply(
            _ spark: SampleSpark,
            to library: SparkLibrary,
            at date: Date
        ) {
            let entryID = entryID(spark)
            guard library.entry(id: entryID) != nil else { return }
            guard spark.isReachable else {
                library.markUnreachable(entryID: entryID, nodeID: spark.nodeID, at: date)
                return
            }
            library.markReachable(
                entryID: entryID,
                nodeID: spark.nodeID,
                route: CachedRoute(baseURL: spark.route, kind: spark.routeKind),
                at: date
            )
            library.recordOperationalEvidence(
                TargetOperationalEvidence(
                    identity: .node(spark.nodeID),
                    respondingNodeID: spark.nodeID,
                    health: TimedOperationalEvidence(
                        Health(
                            status: "ok",
                            apiVersion: 1,
                            runtimeVersion: SampleWire.runtimeVersion,
                            nodeID: spark.nodeID,
                            authProtocols: [Health.signingProtocol]
                        ),
                        observedAt: date
                    ),
                    status: decoded(SparkStatus.self, SampleWire.status(spark)).map {
                        TimedOperationalEvidence($0, observedAt: date)
                    },
                    inventory: decoded(ModelCatalogue.self, SampleWire.catalogue(spark)).map {
                        TimedOperationalEvidence($0, observedAt: date)
                    },
                    inference: decoded(ActiveInference.self, SampleWire.inference(spark)).map {
                        TimedOperationalEvidence($0, observedAt: date)
                    },
                    operations: TimedOperationalEvidence(spark.operations, observedAt: date)
                ),
                for: entryID,
                at: date
            )
        }

        private static func decoded<Value: Decodable>(_ type: Value.Type, _ json: String) -> Value?
        {
            try? JSONDecoder().decode(Value.self, from: Data(json.utf8))
        }

        /// A fleet takes the mixed-state samples in order; a named state takes the one Spark that shows it.
        private static func samples(for request: Request) -> [SampleSpark] {
            switch request {
            case .fleet(let size): Array(SampleSpark.all.prefix(max(0, size)))
            case .one(let state): [SampleSpark.showing(state)]
            }
        }

        private static func entryID(_ spark: SampleSpark) -> String {
            SparkTargetIdentity.node(spark.nodeID).description
        }
    #endif
}

#if DEBUG
    /// Reports itself durable so the sample never raises the storage-failure banner it is not demonstrating.
    @MainActor
    private final class SampleLibraryStore: SparkLibraryStoring {
        let isDurable = true
        private var saved: [LibraryEntry] = []

        func load() throws -> [LibraryEntry] { saved }

        func save(_ entries: [LibraryEntry]) throws { saved = entries }
    }

    /// One pretend Spark, in the states the owner actually meets: serving, starting a model, and not answering.
    struct SampleSpark: Sendable {
        let nodeID: SparkNodeID
        let name: String
        let hostname: String
        let route: URL
        /// How this Spark is reached, so the sample can show a local path and a tailnet one.
        let routeKind: SparkTransportKind
        let memoryUsedBytes: Int64
        let temperatureCelsius: Double
        let inferenceState: String
        let runningModelID: String?
        let tokensPerSecond: Double?
        let installedModelIDs: [String]
        let isReachable: Bool
        let operations: [SparkAPI.Operation]
        /// How long ago this Spark last answered, so a quiet one does not claim a reading from just now.
        var lastAnsweredAgo: TimeInterval = 0

        /// The fleet, in the order a fleet of one, two or three takes them.
        static let all: [SampleSpark] = [serving, starting, quiet]
        /// Every sample that exists, including the one only a named single-Spark state reaches.
        static let every: [SampleSpark] = all + [waiting]

        /// The one Spark that shows a named state on its own.
        static func showing(_ state: FleetSampleFleet.SampleState) -> SampleSpark {
            switch state {
            case .idle: waiting
            case .loading: starting
            case .running: serving
            }
        }

        static let serving = SampleSpark(
            nodeID: node(0x11),
            name: "Example Spark",
            hostname: "spark-example",
            route: URL(string: "https://192.168.1.40:7443")!,
            routeKind: .localWiFi,
            memoryUsedBytes: 103_400_000_000,
            temperatureCelsius: 38,
            inferenceState: "ready",
            runningModelID: "nvidia/nemotron-3.5-lightning-30b",
            tokensPerSecond: 258.3,
            installedModelIDs: ["nvidia/nemotron-3.5-lightning-30b", "open/compact-8b"],
            isReachable: true,
            operations: []
        )

        static let starting = SampleSpark(
            nodeID: node(0x12),
            name: "Studio Spark",
            hostname: "spark-4c02",
            route: URL(string: "https://spark-4c02.tail1234.ts.net:7443")!,
            routeKind: .privateOverlay,
            memoryUsedBytes: 41_800_000_000,
            temperatureCelsius: 52,
            inferenceState: "loading",
            runningModelID: "open/compact-8b",
            tokensPerSecond: nil,
            installedModelIDs: ["open/compact-8b"],
            isReachable: true,
            operations: [
                SparkAPI.Operation(
                    id: UUID(uuidString: "8f0f1c22-0000-4000-8000-000000000001")!,
                    kind: "model.load",
                    state: .running,
                    progress: 0.62,
                    stage: "health_check",
                    cancellable: true
                )
            ]
        )

        static let quiet = SampleSpark(
            nodeID: node(0x13),
            name: "Loft Spark",
            hostname: "spark-77d1",
            route: URL(string: "https://192.168.1.42:7443")!,
            routeKind: .localWiFi,
            memoryUsedBytes: 9_200_000_000,
            temperatureCelsius: 31,
            inferenceState: "unloaded",
            runningModelID: nil,
            tokensPerSecond: nil,
            installedModelIDs: ["open/compact-8b"],
            isReachable: false,
            operations: [],
            lastAnsweredAgo: 7_200
        )

        /// Answering, models installed, nothing running: the state whose one action is Launch.
        static let waiting = SampleSpark(
            nodeID: node(0x14),
            name: "Example Spark",
            hostname: "spark-example",
            route: URL(string: "https://192.168.1.40:7443")!,
            routeKind: .localWiFi,
            memoryUsedBytes: 6_100_000_000,
            temperatureCelsius: 33,
            inferenceState: "unloaded",
            runningModelID: nil,
            tokensPerSecond: nil,
            installedModelIDs: ["nvidia/nemotron-3.5-lightning-30b", "open/compact-8b"],
            isReachable: true,
            operations: []
        )

        static let totalMemoryBytes: Int64 = 128_000_000_000

        private static func node(_ seed: UInt8) -> SparkNodeID {
            var bytes = [UInt8](repeating: 0x5A, count: 16)
            bytes[0] = seed
            return SparkNodeID(
                rawValue: UUID(
                    uuid: (
                        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6],
                        bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13],
                        bytes[14], bytes[15]
                    )
                )
            )
        }
    }
#endif
