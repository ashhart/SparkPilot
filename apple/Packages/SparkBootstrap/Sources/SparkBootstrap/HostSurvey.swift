import Foundation

/// Parse bounded pre-install evidence while keeping observed presence, absence and unknown values distinct.
public struct HostSurvey: Sendable, Equatable {
    /// A fact the Spark either stated, denied, or could not establish.
    public enum Presence: String, Sendable, Equatable {
        case present
        case absent
        /// Keep unavailable or malformed observations unknown rather than absent.
        case unknown
    }

    /// Leave container classification to the runtime's signed-recipe logic instead of adding a weaker SSH recognizer.
    public struct Container: Sendable, Equatable {
        public let name: String
        public let image: String?
    }

    /// A fabric-class interface and what `/sys` said about it.
    public struct FabricPort: Sendable, Equatable {
        public let interface: String
        public let carrier: Presence
        /// Report negotiated Mbit/s only when measured, separately from carrier state.
        public let speedMbps: Int?
    }

    /// Distribution string, or `nil` when `/etc/os-release` could not be read.
    public let operatingSystem: String?
    /// Use nil for an absent runtime package while runtimePackageState retains unknown observations.
    public let runtimePackageVersion: String?
    public let runtimePackageState: Presence
    /// The Debian package that owns `/usr/lib/spark-runtime`, when one does.
    public let installPathOwner: String?
    public let sparkdUnit: Presence
    public let privilegedHelperUnit: Presence
    public let stateDirectory: Presence
    public let installDirectory: Presence
    public let diskTotalKilobytes: Int?
    public let diskFreeKilobytes: Int?
    public let memoryTotalKilobytes: Int?
    public let runningServices: Int?
    /// Use nil for an unreadable socket table rather than reporting no listeners.
    public let listeningPorts: [Int]?
    public let containerCount: Int?
    public let containers: [Container]
    public let fabricPorts: [FabricPort]
    /// Distinguish an unreadable Netplan directory from an observed empty one.
    public let netplanFileCount: Int?

    /// Reject transcripts lacking the fixed survey marker before interpreting matching fields.
    public let isWellFormed: Bool

    /// PLAN 11.3.3 selects a .deb against the detected DGX OS, so the version has to be read.
    public var dgxOSVersion: String? {
        guard let operatingSystem else { return nil }
        // Only a host that says DGX OS is measured; an Ubuntu version would refuse a good Spark.
        guard operatingSystem.localizedCaseInsensitiveContains("dgx") else { return nil }
        let token = operatingSystem.split(whereSeparator: { $0 == " " || $0 == "-" })
            .first {
                $0.first?.isNumber == true
                    && $0.allSatisfy { $0.isNumber || $0 == "." }
            }
        return token.map(String.init)
    }

    /// Determine runtime installation from package state rather than leftover units or directories.
    public var hasSparkRuntimeInstalled: Bool {
        runtimePackageState == .present
    }
}

extension HostSurvey {
    /// Reserve API port 7443 and its derived optional-service listener 7444 before first installation.
    public static let requiredPorts = [7443, 7444]

    /// Bound host-provided free text before displaying it to the owner.
    static let maximumValueLength = 200
    /// Keep parser line limits larger than display limits so legitimate long socket inventories remain observable.
    static let maximumLineLength = 512
    /// Containers carried from one transcript.
    static let maximumContainers = 16
    /// Fabric ports carried from one transcript.
    static let maximumFabricPorts = 8
    /// Listening ports carried from one transcript.
    static let maximumListeningPorts = 32
    /// Bound the transcript bytes accepted by the fixed survey parser.
    static let maximumTranscriptBytes = 64 * 1024

    /// Drop malformed or control-bearing field values to unknown rather than sanitizing them into plausible facts.
    public static func parse(_ transcript: String) -> HostSurvey {
        let bounded = String(transcript.prefix(maximumTranscriptBytes))
        var fields: [String: String] = [:]
        var containers: [Container] = []
        var fabric: [FabricPort] = []

        for line in bounded.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let split = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<split])
            let raw = String(line[line.index(after: split)...])
            guard let value = readable(raw) else { continue }
            switch key {
            case "container":
                guard containers.count < maximumContainers,
                    let container = parseContainer(value)
                else { continue }
                containers.append(container)
            case "fabric":
                guard fabric.count < maximumFabricPorts, let port = parseFabricPort(value) else {
                    continue
                }
                fabric.append(port)
            default:
                // Keep the first value when a transcript repeats a fact.
                if fields[key] == nil { fields[key] = value }
            }
        }

        let runtimePackage = fields["runtime_package"]
        let disk = (fields["disk"] ?? "").split(separator: ",", maxSplits: 1)

        return HostSurvey(
            operatingSystem: displayable(fields["os"]),
            runtimePackageVersion: version(runtimePackage),
            runtimePackageState: presence(runtimePackage, presentWhenStated: true),
            installPathOwner: owner(fields["path_package"]),
            sparkdUnit: presence(fields["unit_sparkd"], presentWhenStated: true),
            privilegedHelperUnit: presence(fields["unit_privd"], presentWhenStated: true),
            stateDirectory: presence(fields["state_dir"], presentWhenStated: false),
            installDirectory: presence(fields["install_dir"], presentWhenStated: false),
            diskTotalKilobytes: disk.count == 2 ? Int(disk[0]) : nil,
            diskFreeKilobytes: disk.count == 2 ? Int(disk[1]) : nil,
            memoryTotalKilobytes: number(fields["memory_kb"]),
            runningServices: number(fields["services"]),
            listeningPorts: ports(fields["listening"]),
            containerCount: number(fields["containers"]),
            containers: containers,
            fabricPorts: fabric,
            netplanFileCount: number(fields["netplan"]),
            isWellFormed: fields["survey"] == "1"
        )
    }

    /// A value the survey stated, or `nil` when it said nothing readable.
    private static func stated(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "unknown" else { return nil }
        return value
    }

    /// A stated value short enough to put in front of an owner.
    private static func displayable(_ value: String?) -> String? {
        guard let value = stated(value), value.count <= maximumValueLength else { return nil }
        return value
    }

    private static func number(_ value: String?) -> Int? {
        stated(value).flatMap(Int.init)
    }

    /// A package version, or `nil` for the two answers that are not one.
    private static func version(_ value: String?) -> String? {
        guard let value = displayable(value), value != "absent" else { return nil }
        return value
    }

    private static func owner(_ value: String?) -> String? {
        guard let value = displayable(value), value != "none" else { return nil }
        return value
    }

    /// Distinguish explicitly spelled presence states from versions or unit states that imply presence.
    private static func presence(_ value: String?, presentWhenStated: Bool) -> Presence {
        guard let value = stated(value) else { return .unknown }
        if value == "absent" { return .absent }
        if value == "present" { return .present }
        return presentWhenStated ? .present : .unknown
    }

    private static func ports(_ value: String?) -> [Int]? {
        guard let value = stated(value) else { return nil }
        let parsed =
            value
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (0...65535).contains($0) }
        return Array(Set(parsed)).sorted().prefix(maximumListeningPorts).map { $0 }
    }

    private static func parseContainer(_ value: String) -> Container? {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let name = parts.first.map(String.init), !name.isEmpty else { return nil }
        let image = parts.count > 1 ? String(parts[1]) : nil
        return Container(name: name, image: image)
    }

    private static func parseFabricPort(_ value: String) -> FabricPort? {
        let parts = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let interface = parts.first, !interface.isEmpty else { return nil }
        let carrier: Presence =
            switch parts.count > 1 ? parts[1] : "" {
            case "1": .present
            case "0": .absent
            default: .unknown
            }
        // Treat the kernel's negative no-link speed as unavailable rather than a measurement.
        let speed = parts.count > 2 ? Int(parts[2]).flatMap { $0 > 0 ? $0 : nil } : nil
        return FabricPort(interface: interface, carrier: carrier, speedMbps: speed)
    }

    /// A value this build will repeat. Printable ASCII only, and bounded.
    private static func readable(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count <= maximumLineLength else { return nil }
        guard value.allSatisfy({ $0 == " " || ($0.isASCII && !$0.isNewline && !isControl($0)) })
        else { return nil }
        return value
    }

    private static func isControl(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return true }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }
}
