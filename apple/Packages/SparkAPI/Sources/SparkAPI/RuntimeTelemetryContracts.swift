import Foundation
import SparkCore

public struct SystemStatus: Sendable, Equatable, Decodable {
    public let unifiedMemoryTotalBytes: Int64
    public let unifiedMemoryAvailableBytes: Int64
    public let memoryPressure: String
    public let cpuUtilisation: Double
    public let diskFreeBytes: Int64
    public let uptimeSeconds: Int64
    public let temperatureCelsius: Double?

    /// Decode unknown future pressure values as nil to preserve the rest of the telemetry response.
    public var pressure: MemoryPressure? {
        MemoryPressure(rawValue: memoryPressure)
    }

    enum CodingKeys: String, CodingKey {
        case unifiedMemoryTotalBytes = "unified_memory_total_bytes"
        case unifiedMemoryAvailableBytes = "unified_memory_available_bytes"
        case memoryPressure = "memory_pressure"
        case cpuUtilisation = "cpu_utilisation"
        case diskFreeBytes = "disk_free_bytes"
        case uptimeSeconds = "uptime_seconds"
        case temperatureCelsius = "temperature_celsius"
    }
}

public struct InferenceStatus: Sendable, Equatable, Codable {
    public let state: String
    public let modelID: String?
    public let profileID: String?
    public let activeRequests: Int
    public let queueDepth: Int
    public let tokensPerSecond: Double?
    public let timeToFirstTokenMs: Double?

    enum CodingKeys: String, CodingKey {
        case state
        case modelID = "model_id"
        case profileID = "profile_id"
        case activeRequests = "active_requests"
        case queueDepth = "queue_depth"
        case tokensPerSecond = "tokens_per_second"
        case timeToFirstTokenMs = "time_to_first_token_ms"
    }
}

public struct LiveInferenceTelemetry: Sendable, Equatable, Codable {
    public let state: String
    public let modelID: String?
    public let profileID: String?
    public let contextLength: Int?
    public let activeRequests: Int
    public let queueDepth: Int?
    public let tokensPerSecond: Double?
    public let timeToFirstTokenMs: Double?

    enum CodingKeys: String, CodingKey {
        case state
        case modelID = "model_id"
        case profileID = "profile_id"
        case contextLength = "context_length"
        case activeRequests = "active_requests"
        case queueDepth = "queue_depth"
        case tokensPerSecond = "tokens_per_second"
        case timeToFirstTokenMs = "time_to_first_token_ms"
    }
}

public struct InferenceEngineTelemetry: Identifiable, Sendable, Equatable, Codable {
    public var id: String { workloadID }

    public let workloadID: String
    public let engine: String
    public let ownership: String
    public let availability: String
    public let observedAt: Date?
    public let sampleAgeSeconds: Int64?
    public let servedModel: String?
    public let engineUptimeSeconds: Int64?
    public let totalRequests: Int64?
    public let promptTokens: Int64?
    public let generatedTokens: Int64?
    public let totalTokens: Int64?
    public let runningRequests: Int64?
    public let queueDepth: Int64?
    public let promptTokensPerSecond: Double?
    public let generationTokensPerSecond: Double?
    public let requestLatencyMs: Double?
    public let timeToFirstTokenMs: Double?
    public let timePerOutputTokenMs: Double?

    enum CodingKeys: String, CodingKey {
        case workloadID = "workload_id"
        case engine
        case ownership
        case availability
        case observedAt = "observed_at"
        case sampleAgeSeconds = "sample_age_seconds"
        case servedModel = "served_model"
        case engineUptimeSeconds = "engine_uptime_seconds"
        case totalRequests = "total_requests"
        case promptTokens = "prompt_tokens"
        case generatedTokens = "generated_tokens"
        case totalTokens = "total_tokens"
        case runningRequests = "running_requests"
        case queueDepth = "queue_depth"
        case promptTokensPerSecond = "prompt_tokens_per_second"
        case generationTokensPerSecond = "generation_tokens_per_second"
        case requestLatencyMs = "request_latency_ms"
        case timeToFirstTokenMs = "time_to_first_token_ms"
        case timePerOutputTokenMs = "time_per_output_token_ms"
    }
}

/// Read a signed telemetry sample without reloading catalogue or operation data.
public struct TelemetrySnapshot: Sendable, Equatable, Codable {
    public let apiVersion: Int
    public let observedAt: Date
    public let nodeID: SparkNodeID
    public let nodeName: String
    public let system: TelemetrySystem
    public let accelerator: AcceleratorTelemetry
    public let storage: StorageTelemetry
    public let usage: UsageTelemetry
    public let inference: LiveInferenceTelemetry
    public let engines: [InferenceEngineTelemetry]

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case observedAt = "observed_at"
        case nodeID = "node_id"
        case nodeName = "node_name"
        case system
        case accelerator
        case storage
        case usage
        case inference
        case engines
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try container.decode(Int.self, forKey: .apiVersion)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        nodeID = try container.decode(SparkNodeID.self, forKey: .nodeID)
        nodeName = try container.decode(String.self, forKey: .nodeName)
        system = try container.decode(TelemetrySystem.self, forKey: .system)
        accelerator = try container.decode(AcceleratorTelemetry.self, forKey: .accelerator)
        storage = try container.decode(StorageTelemetry.self, forKey: .storage)
        usage = try container.decode(UsageTelemetry.self, forKey: .usage)
        inference = try container.decode(LiveInferenceTelemetry.self, forKey: .inference)
        engines =
            try container.decodeIfPresent([InferenceEngineTelemetry].self, forKey: .engines) ?? []
    }
}

/// One signed, point-in-time view of NetworkManager's interface inventory.
public struct NetworkInterfacesSnapshot: Sendable, Equatable, Codable {
    public let apiVersion: Int
    public let observedAt: Date
    public let interfaces: [NetworkInterfaceStatus]

    public init(apiVersion: Int, observedAt: Date, interfaces: [NetworkInterfaceStatus]) {
        self.apiVersion = apiVersion
        self.observedAt = observedAt
        self.interfaces = interfaces
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case observedAt = "observed_at"
        case interfaces
    }
}

public struct NetworkInterfaceStatus: Identifiable, Sendable, Equatable, Codable {
    public var id: String { name }

    public let name: String
    public let type: String
    public let state: String
    public let connectionName: String?
    public let macAddress: String?
    public let mtu: Int64?
    public let linkSpeedMbps: Int64?
    public let addresses: [NetworkAddress]
    public let gateway: String?
    public let dnsServers: [String]
    public let wifiSSID: String?
    public let wifiSignalPercent: Int?
    public let internet: InternetReachability

    public init(
        name: String,
        type: String,
        state: String,
        connectionName: String?,
        macAddress: String?,
        mtu: Int64?,
        linkSpeedMbps: Int64?,
        addresses: [NetworkAddress],
        gateway: String?,
        dnsServers: [String],
        wifiSSID: String?,
        wifiSignalPercent: Int?,
        internet: InternetReachability
    ) {
        self.name = name
        self.type = type
        self.state = state
        self.connectionName = connectionName
        self.macAddress = macAddress
        self.mtu = mtu
        self.linkSpeedMbps = linkSpeedMbps
        self.addresses = addresses
        self.gateway = gateway
        self.dnsServers = dnsServers
        self.wifiSSID = wifiSSID
        self.wifiSignalPercent = wifiSignalPercent
        self.internet = internet
    }

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case state
        case connectionName = "connection_name"
        case macAddress = "mac_address"
        case mtu
        case linkSpeedMbps = "link_speed_mbps"
        case addresses
        case gateway
        case dnsServers = "dns_servers"
        case wifiSSID = "wifi_ssid"
        case wifiSignalPercent = "wifi_signal_percent"
        case internet
    }
}

public struct NetworkAddress: Sendable, Equatable, Codable {
    public let family: String
    public let address: String

    public init(family: String, address: String) {
        self.family = family
        self.address = address
    }
}

public struct InternetReachability: Sendable, Equatable, Codable {
    public let reachable: Bool
    public let gatewayReachable: Bool?
    public let dnsReachable: Bool?
    public let checkedAt: Date

    public init(
        reachable: Bool,
        gatewayReachable: Bool?,
        dnsReachable: Bool?,
        checkedAt: Date
    ) {
        self.reachable = reachable
        self.gatewayReachable = gatewayReachable
        self.dnsReachable = dnsReachable
        self.checkedAt = checkedAt
    }

    enum CodingKeys: String, CodingKey {
        case reachable
        case gatewayReachable = "gateway_reachable"
        case dnsReachable = "dns_reachable"
        case checkedAt = "checked_at"
    }
}

public struct TelemetrySystem: Sendable, Equatable, Codable {
    public let cpuUtilisation: Double
    public let loadAverage1m: Double
    public let unifiedMemoryTotalBytes: Int64
    public let unifiedMemoryAvailableBytes: Int64
    public let unifiedMemoryUsedBytes: Int64
    public let memoryPressure: String
    public let memoryPSISomeAvg10: Double?
    public let memoryPSIFullAvg10: Double?
    public let temperatureCelsius: Double?
    public let powerState: String
    public let uptimeSeconds: Int64

    enum CodingKeys: String, CodingKey {
        case cpuUtilisation = "cpu_utilisation"
        case loadAverage1m = "load_average_1m"
        case unifiedMemoryTotalBytes = "unified_memory_total_bytes"
        case unifiedMemoryAvailableBytes = "unified_memory_available_bytes"
        case unifiedMemoryUsedBytes = "unified_memory_used_bytes"
        case memoryPressure = "memory_pressure"
        case memoryPSISomeAvg10 = "memory_psi_some_avg10"
        case memoryPSIFullAvg10 = "memory_psi_full_avg10"
        case temperatureCelsius = "temperature_celsius"
        case powerState = "power_state"
        case uptimeSeconds = "uptime_seconds"
    }
}

public struct AcceleratorTelemetry: Sendable, Equatable, Codable {
    public let utilisation: Double?
    public let temperatureCelsius: Double?
    public let powerDrawWatts: Double?
    public let powerLimitWatts: Double?
    public let memoryUsedBytes: Int64?
    public let memoryTotalBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case utilisation
        case temperatureCelsius = "temperature_celsius"
        case powerDrawWatts = "power_draw_watts"
        case powerLimitWatts = "power_limit_watts"
        case memoryUsedBytes = "memory_used_bytes"
        case memoryTotalBytes = "memory_total_bytes"
    }
}

public struct StorageTelemetry: Sendable, Equatable, Codable {
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let usedBytes: Int64

    enum CodingKeys: String, CodingKey {
        case totalBytes = "total_bytes"
        case freeBytes = "free_bytes"
        case usedBytes = "used_bytes"
    }
}

public struct UsageTelemetry: Sendable, Equatable, Codable {
    public let day: String
    public let requests: Int64
    /// Use nil for uncounted failures, reserving zero for a measured absence of failures.
    public let failures: Int64?
    public let promptTokens: Int64
    public let cachedPromptTokens: Int64
    public let generatedTokens: Int64
    public let reasoningTokens: Int64
    public let totalTokens: Int64

    enum CodingKeys: String, CodingKey {
        case day
        case requests
        case failures
        case promptTokens = "prompt_tokens"
        case cachedPromptTokens = "cached_prompt_tokens"
        case generatedTokens = "generated_tokens"
        case reasoningTokens = "reasoning_tokens"
        case totalTokens = "total_tokens"
    }
}
