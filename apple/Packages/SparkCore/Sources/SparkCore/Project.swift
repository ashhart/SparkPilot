/// Project state on a Spark node (OpenAPI `Project.state`).
public enum SparkProjectState: String, Codable, Sendable {
    case creating
    case ready
    case stopped
    case failed
    case deleting
}
