import Foundation
import SparkLibrary
import SparkWatchSupport
import Testing
@testable import SparkAppComposition

@MainActor
struct SparkWatchAuthorizationTests {
    @Test func phoneAppLockBlocksWatchAccess() throws {
        let name = "watch-lock-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: AppLockModel.enabledKey)
        let service = SparkWatchRuntimeService(
            library: SparkLibrary(store: MemoryLibraryStore()),
            appLock: AppLockModel(defaults: defaults)
        )
        #expect(throws: SparkWatchFailure.self) { try service.authorize(.init(.overview)) }
        #expect(throws: SparkWatchFailure.self) {
            try service.authorize(.init(.ask, targetID: "spark"))
        }
    }

    @Test func deviceOnlyPolicyBlocksWatchPromptsButAllowsStatus() throws {
        let name = "watch-policy-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let policy = SparkExecutionPolicyModel(defaults: defaults)
        policy.choice = .onDeviceOnly
        let service = SparkWatchRuntimeService(
            library: SparkLibrary(store: MemoryLibraryStore()),
            appLock: AppLockModel(defaults: defaults),
            executionPolicy: policy
        )
        #expect(throws: SparkWatchFailure.self) {
            try service.authorize(.init(.ask, targetID: "spark"))
        }
        #expect(throws: Never.self) { try service.authorize(.init(.status, targetID: "spark")) }
        policy.choice = .sparkOnly
        #expect(throws: Never.self) { try service.authorize(.init(.ask, targetID: "spark")) }
    }
    @Test func ownHardwarePolicyRejectsSharedAndUnknownOwnership() throws {
        let name = "watch-ownership-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let policy = SparkExecutionPolicyModel(defaults: defaults)
        policy.choice = .myHardwareOnly
        let service = SparkWatchRuntimeService(
            library: SparkLibrary(store: MemoryLibraryStore()),
            appLock: AppLockModel(defaults: defaults),
            executionPolicy: policy
        )
        #expect(throws: SparkWatchFailure.self) {
            try service.authorizeInference(role: .administrator)
        }
        #expect(throws: SparkWatchFailure.self) { try service.authorizeInference(role: nil) }
        #expect(throws: Never.self) { try service.authorizeInference(role: .owner) }
    }

}
