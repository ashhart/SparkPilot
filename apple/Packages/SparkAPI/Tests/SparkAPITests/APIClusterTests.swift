import CryptoKit
import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

extension SparkAPITests {
    @Test func clusterValidationUsesStableKeyAndSignsTheEmptyBody() async throws {
        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"cluster.validate","state":"queued","progress":null,"stage":null,"cancellable":true}"#
                .utf8
        )
        let path = "/api/v1/cluster/validate"
        MockURLProtocol.responses = [path: .success(operation)]
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastBody = nil
        let key = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let presence = APIUserPresenceSession()

        _ = try await makeClient(signer: APIUserPresenceSigner()).validateCluster(
            route: URL(string: "https://spark.local:7443")!,
            idempotencyKey: key,
            userPresence: presence
        )

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == path)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        #expect(MockURLProtocol.lastBody == nil)
        try expectValidPresenceProof(on: request, body: Data(), signedBy: presence)
    }
}
