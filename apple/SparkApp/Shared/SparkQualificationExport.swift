import Foundation

/// Use a separate opt-in export type so future local fields cannot leak endpoints or persistent identity.
struct SparkQualificationExport: Encodable {
    struct Request: Encodable {
        let workload: SparkQualificationWorkload
        let startedSeconds: Double
        let elapsedSeconds: Double
        let firstOutputSeconds: Double?
        let promptTokens: Int?
        let completionTokens: Int?
        let exactAnswerMatched: Bool?
        let terminalConfirmed: Bool
        let outputReceived: Bool
        let finishReason: String?
    }
    let preset: SparkQualificationPreset
    let state: String
    let failureCode: String?
    let modelID: String?
    let profileID: String?
    let deployment: SparkInferenceDeploymentExport?
    let requests: [Request]
    let memorySamples: [SparkQualificationMemorySample]
    let cases: [SparkQualificationCaseResult]
    let missingAttestations: [String]
    let qualification = "incomplete_no_profile_promotion"
    init(_ manifest: SparkQualificationManifest) {
        preset = manifest.preset
        state = manifest.state
        failureCode = manifest.failureCode
        modelID = manifest.identity?.modelID
        profileID = manifest.identity?.profileID
        deployment = manifest.identity?.deployment.map(SparkInferenceDeploymentExport.init)
        requests = manifest.requests.map {
            Request(
                workload: $0.workload,
                startedSeconds: $0.startedSeconds,
                elapsedSeconds: $0.elapsedSeconds,
                firstOutputSeconds: $0.firstOutputSeconds,
                promptTokens: $0.promptTokens,
                completionTokens: $0.completionTokens,
                exactAnswerMatched: $0.exactAnswerMatched,
                terminalConfirmed: $0.terminalConfirmed,
                outputReceived: $0.outputReceived,
                finishReason: $0.finishReason
            )
        }
        memorySamples = manifest.memorySamples
        cases = manifest.cases
        missingAttestations = manifest.missingAttestations
    }
    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
