import Foundation
import SparkSecurity

public struct KokoroServiceStatus: Decodable, Sendable, Equatable {
    public let installed: Bool
    public let running: Bool
    public let healthy: Bool
    public let availableRevision: String
    public let updateAvailable: Bool
    public let voices: [String]
    enum CodingKeys: String, CodingKey {
        case installed, running, healthy, voices
        case availableRevision = "available_revision"
        case updateAvailable = "update_available"
    }
}

public enum KokoroServiceAction: String, Sendable {
    case install, update, remove, enable, disable
}

extension SparkAPIClient {
    public func kokoroStatus(route: URL) async throws -> KokoroServiceStatus {
        try await get(endpoint(route, "api", "v1", "services", "kokoro"), timeoutInterval: 10)
    }

    public func changeKokoro(
        route: URL,
        action: KokoroServiceAction,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(route, "api", "v1", "services", "kokoro", action.rawValue),
            body: Optional<String>.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: 30
        )
    }

    public func speech(route: URL, text: String, voice: String) async throws -> Data {
        struct Input: Encodable {
            let model = "kokoro"
            let input: String
            let voice: String
            let responseFormat = "wav"
            let speed = 1.0

            enum CodingKeys: String, CodingKey {
                case model, input, voice, speed
                case responseFormat = "response_format"
            }
        }
        let body = try JSONEncoder().encode(Input(input: text, voice: voice))
        var request = URLRequest(url: endpoint(route, "v1", "audio", "speech"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 190
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        try applySigning(to: &request, body: body)
        let (data, http) = try await transport.perform(request)
        try validate(http: http, data: data)
        guard data.count >= 44, data.count <= 32 * 1024 * 1024,
            data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8)
        else { throw APIError(.malformedResponse) }
        return data
    }
}
