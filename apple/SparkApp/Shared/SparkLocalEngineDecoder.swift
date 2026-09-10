#if os(macOS)
    import Foundation

    enum SparkLocalEngineDecoder {
        static let maximumModels = 256
        static let maximumInstances = 512
        private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
            guard data.count <= SparkLocalEngineHTTPTransport.maximumBytes else {
                throw SparkLocalEngineError.responseTooLarge
            }
            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(type, from: data)
            } catch {
                throw SparkLocalEngineError.responseInvalid
            }
        }
        private static func text(_ value: String?, maximum: Int = 512) throws -> String? {
            guard let value else { return nil }
            guard !value.isEmpty, value.utf8.count <= maximum,
                value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { throw SparkLocalEngineError.responseInvalid }
            return value
        }
        private static func count<T: BinaryInteger>(_ value: T?, maximum: T) throws -> T? {
            guard value.map({ $0 >= 0 && $0 <= maximum }) ?? true else {
                throw SparkLocalEngineError.responseInvalid
            }
            return value
        }
        private static func digest(_ value: String?) throws -> String? {
            guard let value else { return nil }
            guard value.utf8.count == 64,
                value.utf8.allSatisfy({
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                })
            else { throw SparkLocalEngineError.responseInvalid }
            return value.lowercased()
        }
        private struct OllamaVersion: Decodable { let version: String }
        private struct OllamaList: Decodable { let models: [OllamaModel] }
        private struct OllamaModel: Decodable {
            let name: String
            let model: String?
            let size: Int64?
            let digest: String?
            let sizeVram: Int64?
            let contextLength: Int?
            let details: Details?
            struct Details: Decodable {
                let format: String?
                let quantizationLevel: String?
            }
        }
        static func ollama(
            origin: SparkLocalEngineOrigin,
            version: Data,
            models: Data,
            loaded: Data?
        ) throws -> SparkLocalEngineSnapshot {
            let version = try text(decode(OllamaVersion.self, version).version, maximum: 64)
            let installed = try decode(OllamaList.self, models).models
            let running = try loaded.map { try decode(OllamaList.self, $0).models } ?? []
            guard installed.count <= maximumModels, running.count <= maximumModels else {
                throw SparkLocalEngineError.responseTooLarge
            }
            guard Set(installed.map(\.name)).count == installed.count,
                Set(running.map(\.name)).count == running.count
            else { throw SparkLocalEngineError.responseInvalid }
            // Do not assign a tag's changed digest to an older loaded instance when inventory reads race.
            for item in running {
                guard let match = installed.first(where: { $0.name == item.name }),
                    try digest(match.digest) == digest(item.digest)
                else { throw SparkLocalEngineError.responseInvalid }
            }
            let result = try installed.map { item in
                let name = try text(item.name)!
                if let alias = item.model, alias != item.name {
                    throw SparkLocalEngineError.responseInvalid
                }
                var instances: [SparkLocalEngineLoadedInstance] = []
                if let instance = running.first(where: { $0.name == item.name }) {
                    if let alias = instance.model, alias != item.name {
                        throw SparkLocalEngineError.responseInvalid
                    }
                    instances.append(
                        .init(
                            id: name,
                            contextLength: try count(instance.contextLength, maximum: 100_000_000),
                            reportedParallelLimit: nil,
                            reportedMemoryBytes: try count(
                                instance.sizeVram,
                                maximum: 1_125_899_906_842_624
                            )
                        )
                    )
                }
                return SparkLocalEngineModel(
                    id: name,
                    name: name,
                    kind: "unknown",
                    format: try text(item.details?.format, maximum: 64),
                    quantization: try text(item.details?.quantizationLevel, maximum: 64),
                    sizeBytes: try count(item.size, maximum: 1_125_899_906_842_624),
                    reportedDigest: try digest(item.digest),
                    loadedInstances: instances,
                    reportedVision: nil,
                    reportedToolUse: nil
                )
            }
            return .init(
                engine: .ollama,
                origin: origin,
                observedAt: Date(),
                engineVersion: version,
                apiContract: "ollama-tags-ps-v1",
                models: result,
                loadedInventoryAvailable: loaded != nil
            )
        }

        private struct LMList: Decodable { let models: [LMModel] }
        private struct LMModel: Decodable {
            let type: String
            let key: String
            let displayName: String
            let format: String?
            let sizeBytes: Int64
            let maxContextLength: Int?
            let quantization: Quantization?
            let loadedInstances: [Instance]
            let capabilities: Capabilities?
            struct Quantization: Decodable { let name: String? }
            struct Instance: Decodable {
                let id: String
                let config: Configuration
                struct Configuration: Decodable {
                    let contextLength: Int
                    let parallel: Int?
                }
            }
            struct Capabilities: Decodable {
                let vision: Bool?
                let trainedForToolUse: Bool?
            }
        }
        static func lmStudio(origin: SparkLocalEngineOrigin, models: Data) throws
            -> SparkLocalEngineSnapshot
        {
            let models = try decode(LMList.self, models).models
            guard models.count <= maximumModels,
                models.reduce(0, { $0 + $1.loadedInstances.count }) <= maximumInstances
            else {
                throw SparkLocalEngineError.responseTooLarge
            }
            guard Set(models.map(\.key)).count == models.count else {
                throw SparkLocalEngineError.responseInvalid
            }
            var allInstances: Set<String> = []
            let result = try models.map { model in
                guard ["llm", "embedding"].contains(model.type) else {
                    throw SparkLocalEngineError.responseInvalid
                }
                let limit = try count(model.maxContextLength, maximum: 100_000_000)
                let instances = try model.loadedInstances.map { instance in
                    let id = try text(instance.id)!
                    guard allInstances.insert(id).inserted,
                        instance.config.contextLength > 0,
                        instance.config.parallel.map({ $0 > 0 }) ?? true,
                        limit.map({ instance.config.contextLength <= $0 }) ?? true
                    else { throw SparkLocalEngineError.responseInvalid }
                    return SparkLocalEngineLoadedInstance(
                        id: id,
                        contextLength: try count(
                            instance.config.contextLength,
                            maximum: 100_000_000
                        ),
                        reportedParallelLimit: try count(instance.config.parallel, maximum: 4096),
                        reportedMemoryBytes: nil
                    )
                }
                return SparkLocalEngineModel(
                    id: try text(model.key)!,
                    name: try text(model.displayName)!,
                    kind: model.type,
                    format: try text(model.format, maximum: 64),
                    quantization: try text(model.quantization?.name, maximum: 64),
                    sizeBytes: try count(model.sizeBytes, maximum: 1_125_899_906_842_624),
                    reportedDigest: nil,
                    loadedInstances: instances,
                    reportedVision: model.capabilities?.vision,
                    reportedToolUse: model.capabilities?.trainedForToolUse
                )
            }
            return .init(
                engine: .lmStudio,
                origin: origin,
                observedAt: Date(),
                engineVersion: nil,
                apiContract: "lm-studio-models-v1",
                models: result,
                loadedInventoryAvailable: true
            )
        }
    }
#endif
