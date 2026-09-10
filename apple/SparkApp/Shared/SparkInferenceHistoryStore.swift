import Foundation
import SparkAPI
import SwiftUI

@MainActor
public protocol SparkInferenceHistoryStoring: AnyObject {
    func load(targetID: String) throws -> [SparkInferenceExperienceSample]
    func save(_ sample: SparkInferenceExperienceSample, targetID: String) throws
}

@MainActor
public final class UserDefaultsSparkInferenceHistoryStore: SparkInferenceHistoryStoring {
    private let defaults: UserDefaults
    private let keyPrefix: String
    private let limit: Int
    private let bucketSeconds: TimeInterval
    private let retentionSeconds: TimeInterval

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "sparkpilot.inference-history.v1.",
        limit: Int = 1_440,
        bucketSeconds: TimeInterval = 60,
        retentionSeconds: TimeInterval = 24 * 60 * 60
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        self.limit = max(2, limit)
        let safeBucketSeconds = max(1, bucketSeconds)
        self.bucketSeconds = safeBucketSeconds
        self.retentionSeconds = max(safeBucketSeconds, retentionSeconds)
    }

    public func load(targetID: String) throws -> [SparkInferenceExperienceSample] {
        guard let data = defaults.data(forKey: keyPrefix + targetID) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SparkInferenceExperienceSample].self, from: data)
    }

    public func save(_ sample: SparkInferenceExperienceSample, targetID: String) throws {
        var samples = try load(targetID: targetID)
        let sampleBucket = bucket(for: sample.observedAt)
        samples.removeAll { bucket(for: $0.observedAt) == sampleBucket }
        samples.append(sample)
        samples.sort { $0.observedAt < $1.observedAt }
        if let newestDate = samples.last?.observedAt {
            let cutoff = newestDate.addingTimeInterval(-retentionSeconds)
            samples.removeAll { $0.observedAt < cutoff }
        }
        samples = Array(samples.suffix(limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(samples), forKey: keyPrefix + targetID)
    }

    private func bucket(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSinceReferenceDate / bucketSeconds))
    }
}
