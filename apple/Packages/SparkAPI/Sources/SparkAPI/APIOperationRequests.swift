import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

extension SparkAPIClient {
    /// `GET /api/v1/operations/{operationId}` for durable progress polling.
    public func operation(route base: URL, id: UUID) async throws -> Operation {
        try await get(endpoint(base, "api", "v1", "operations", id.uuidString))
    }

    /// `GET /api/v1/operations` for durable operation recovery after relaunch.
    public func operations(
        route base: URL,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> OperationPage {
        let url = endpoint(base, "api", "v1", "operations")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError(.malformedRequestURL, diagnosticDetail: "invalid operations URL")
        }
        var queryItems = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200)))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems
        guard let requestURL = components.url else {
            throw APIError(.malformedRequestURL, diagnosticDetail: "invalid operations URL")
        }
        return try await get(requestURL)
    }
}
