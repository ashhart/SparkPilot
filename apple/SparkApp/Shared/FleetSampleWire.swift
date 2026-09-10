#if DEBUG
    import Foundation

    /// The pretend Spark's wire payloads, written as the runtime writes them so the real decoders read them.
    enum SampleWire {
        static let runtimeVersion = "0.1.13"

        static func status(_ spark: SampleSpark) -> String {
            let available = SampleSpark.totalMemoryBytes - spark.memoryUsedBytes
            return """
                {"api_version": 1,
                 "node": {"node_id": "\(spark.nodeID.rawValue.uuidString.lowercased())",
                          "cluster_id": null,
                          "name": "\(spark.name)",
                          "role": "standalone",
                          "authority_fingerprint": "sample-authority",
                          "tls_fingerprint": null,
                          "runtime_version": "\(runtimeVersion)",
                          "dgx_os_version": "7.2.3"},
                 "cluster": null,
                 "system": {"unified_memory_total_bytes": \(SampleSpark.totalMemoryBytes),
                            "unified_memory_available_bytes": \(available),
                            "memory_pressure": "normal",
                            "cpu_utilisation": 0.24,
                            "disk_free_bytes": 2400000000000,
                            "uptime_seconds": 486000,
                            "temperature_celsius": \(spark.temperatureCelsius)},
                 "inference": \(inference(spark))}
                """
        }

        static func inference(_ spark: SampleSpark) -> String {
            let model = spark.runningModelID.map { "\"\($0)\"" } ?? "null"
            let tokens = spark.tokensPerSecond.map { "\($0)" } ?? "null"
            return """
                {"state": "\(spark.inferenceState)",
                 "model_id": \(model),
                 "profile_id": "agent-64k",
                 "context_length": 65536,
                 "active_requests": \(spark.tokensPerSecond == nil ? 0 : 1),
                 "queue_depth": 0,
                 "tokens_per_second": \(tokens),
                 "time_to_first_token_ms": \(spark.tokensPerSecond == nil ? "null" : "180")}
                """
        }

        static func catalogue(_ spark: SampleSpark) -> String {
            let items = spark.installedModelIDs.map { item($0, spark: spark) }
            return "{\"items\": [\(items.joined(separator: ","))], \"next_cursor\": null}"
        }

        private static func item(_ modelID: String, spark: SampleSpark) -> String {
            """
            {"id": "\(modelID)",
             "display_name": "\(displayName(modelID))",
             "description": null,
             "recipe_revision": "sample-recipe-1",
             "source_revision": "sample-source-1",
             "install_state": "installed",
             "total_bytes": 61000000000,
             "capabilities": {"chat": true},
             "fit": "safe",
             "profiles": []}
            """
        }

        /// Names the sample models the way a Spark's catalogue would.
        static func displayName(_ modelID: String) -> String {
            switch modelID {
            case "nvidia/nemotron-3.5-lightning-30b": "Nemotron 3.5 Lightning 30B"
            case "open/compact-8b": "Compact 8B"
            default: modelID
            }
        }
    }
#endif
