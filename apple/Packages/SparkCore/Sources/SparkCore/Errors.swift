/// Preserve the stable server error code for client-side failure classification.
public struct SparkError: Error, Hashable, Sendable {
    public let code: String
    public let message: String
    public let requestID: String
    public let operationID: SparkOperationID?

    public init(
        code: String,
        message: String,
        requestID: String,
        operationID: SparkOperationID? = nil
    ) {
        self.code = code
        self.message = message
        self.requestID = requestID
        self.operationID = operationID
    }
}

/// Use the documented error families from docs/ERROR_CODES.md.
extension SparkError {
    public static func notPaired(requestID: String) -> SparkError {
        SparkError(
            code: "DEVICE_NOT_PAIRED",
            message: String(localized: "This device is not paired with the Spark."),
            requestID: requestID
        )
    }

    public static func revoked(requestID: String) -> SparkError {
        SparkError(
            code: "DEVICE_REVOKED",
            message: String(localized: "This device has been revoked."),
            requestID: requestID
        )
    }

    public static func roleForbidden(requestID: String) -> SparkError {
        SparkError(
            code: "ROLE_FORBIDDEN",
            message: String(localized: "Your role cannot perform this action."),
            requestID: requestID
        )
    }
}
