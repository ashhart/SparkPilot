import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

/// A pinned route probe must distinguish identity mismatch from transport unavailability.
public enum ProbeResult: Sendable, Equatable {
    case accepted(nodeID: SparkNodeID, apiVersion: Int, runtimeVersion: String)
    /// Reject identity-mismatched routes without downgrading trust.
    case identityMismatch(presented: SparkNodeID, expected: SparkNodeID)
    /// The route answered, but with a certificate other than the pinned one.
    case certificateRejected(pin: String)
    /// The node is the right one but speaks a signing protocol this build cannot; one side must update.
    case protocolUnsupported(runtimeVersion: String)
    case unreachable(error: String)
}

/// Verify the paired certificate at TLS before accepting the node ID returned by a candidate route.
public struct RouteProbe {
    private let client: SparkAPIClient
    private let pin: String

    /// - Parameter pin: the node's `tls_fingerprint`.
    public init(pin: String, signer: (any RequestSigning)? = nil) throws {
        self.pin = pin
        self.client = try SparkAPIClient.pinned(to: pin, signer: signer)
    }

    /// Reuse a caller's already pinned client for probing; the pin argument records trust rather than performing it.
    public init(pin: String, using client: SparkAPIClient) {
        self.pin = pin
        self.client = client
    }

    public func validate(
        route: SparkRoute,
        expectedNodeID: SparkNodeID
    ) async -> ProbeResult {
        do {
            let health: Health = try await client.health(route: route.baseURL)
            guard health.nodeID == expectedNodeID else {
                return .identityMismatch(presented: health.nodeID, expected: expectedNodeID)
            }
            guard health.speaksThisProtocol else {
                return .protocolUnsupported(runtimeVersion: health.runtimeVersion)
            }
            return .accepted(
                nodeID: health.nodeID,
                apiVersion: health.apiVersion,
                runtimeVersion: health.runtimeVersion
            )
        } catch {
            // Distinguish a rejected pin from network unavailability so recovery guidance preserves the trust failure.
            if RouteProbe.isCertificateRejection(error) {
                return .certificateRejected(pin: pin)
            }
            return .unreachable(error: "\(error)")
        }
    }

    static func isCertificateRejection(_ error: any Error) -> Bool {
        if case PinnedTransportError.certificateRejected = error { return true }
        return false
    }
}
