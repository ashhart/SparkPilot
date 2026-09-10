import Foundation
import Testing

@testable import SparkAppComposition

@MainActor
private final class TestAppLockAuthenticator: AppLockAuthenticating {
    var method: AppLockMethod
    var results: [Result<Void, AppLockAuthenticationError>]
    private(set) var reasons: [String] = []

    init(
        method: AppLockMethod = .faceID,
        results: [Result<Void, AppLockAuthenticationError>] = [.success(())]
    ) {
        self.method = method
        self.results = results
    }

    func availableMethod() -> AppLockMethod { method }

    func authenticate(reason: String) async throws {
        reasons.append(reason)
        let result = results.isEmpty ? .success(()) : results.removeFirst()
        try result.get()
    }
}

private func appLockDefaults() throws -> UserDefaults {
    let suite = "spark.app-lock.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@MainActor
@Test func appLockStartsOffWithoutPrompting() throws {
    let authenticator = TestAppLockAuthenticator()
    let model = AppLockModel(defaults: try appLockDefaults(), authenticator: authenticator)

    #expect(!model.isEnabled)
    #expect(!model.isLocked)
    #expect(authenticator.reasons.isEmpty)
}

@MainActor
@Test func enablingAppLockRequiresAuthenticationAndPersists() async throws {
    let defaults = try appLockDefaults()
    let authenticator = TestAppLockAuthenticator(method: .touchID)
    let model = AppLockModel(defaults: defaults, authenticator: authenticator)

    await model.setEnabled(true)

    #expect(model.isEnabled)
    #expect(!model.isLocked)
    #expect(model.method == .touchID)
    #expect(defaults.bool(forKey: AppLockModel.enabledKey))
    #expect(authenticator.reasons == ["Turn on app lock"])

    let reopened = AppLockModel(defaults: defaults, authenticator: authenticator)
    #expect(reopened.isEnabled)
    #expect(reopened.isLocked, "a newly launched app starts behind the lock")
}

@MainActor
@Test func leavingTheAppLocksItAndReturningCanUnlockIt() async throws {
    let defaults = try appLockDefaults()
    defaults.set(true, forKey: AppLockModel.enabledKey)
    let authenticator = TestAppLockAuthenticator()
    let model = AppLockModel(defaults: defaults, authenticator: authenticator)

    await model.unlock()
    #expect(!model.isLocked)

    model.appBecameInactive()
    #expect(model.isLocked)

    await model.unlock()
    #expect(!model.isLocked)
    #expect(authenticator.reasons == ["Unlock SparkPilot", "Unlock SparkPilot"])
}

@MainActor
@Test func cancelledUnlockNeverRevealsTheApp() async throws {
    let defaults = try appLockDefaults()
    defaults.set(true, forKey: AppLockModel.enabledKey)
    let authenticator = TestAppLockAuthenticator(results: [.failure(.cancelled)])
    let model = AppLockModel(defaults: defaults, authenticator: authenticator)

    await model.unlock()

    #expect(model.isLocked)
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func failedSettingChangeKeepsTheExistingLockChoice() async throws {
    let defaults = try appLockDefaults()
    let authenticator = TestAppLockAuthenticator(results: [.failure(.failed)])
    let model = AppLockModel(defaults: defaults, authenticator: authenticator)

    await model.setEnabled(true)

    #expect(!model.isEnabled)
    #expect(!defaults.bool(forKey: AppLockModel.enabledKey))
    #expect(model.errorMessage?.contains("setting was not changed") == true)
}

@MainActor
@Test func disablingAppLockAlsoRequiresAuthentication() async throws {
    let defaults = try appLockDefaults()
    defaults.set(true, forKey: AppLockModel.enabledKey)
    let authenticator = TestAppLockAuthenticator()
    let model = AppLockModel(defaults: defaults, authenticator: authenticator)

    await model.setEnabled(false)

    #expect(!model.isEnabled)
    #expect(!model.isLocked)
    #expect(!defaults.bool(forKey: AppLockModel.enabledKey))
    #expect(authenticator.reasons == ["Turn off app lock"])
}

@MainActor
@Test func intentAppLockHonorsOptInAndPropagatesAuthenticationFailure() async throws {
    let defaults = try appLockDefaults()
    let authenticator = TestAppLockAuthenticator(results: [.failure(.cancelled), .success(())])
    try await SparkIntentAppLock.authenticate(defaults: defaults, authenticator: authenticator)
    #expect(authenticator.reasons.isEmpty)
    defaults.set(true, forKey: AppLockModel.enabledKey)
    await #expect(throws: AppLockAuthenticationError.cancelled) {
        try await SparkIntentAppLock.authenticate(defaults: defaults, authenticator: authenticator)
    }
    try await SparkIntentAppLock.authenticate(defaults: defaults, authenticator: authenticator)
    #expect(authenticator.reasons.count == 2)
}

@MainActor
private final class SuspendedAppLockAuthenticator: AppLockAuthenticating {
    private(set) var attempts = 0
    private(set) var pending: CheckedContinuation<Void, Error>?

    func availableMethod() -> AppLockMethod { .faceID }

    func authenticate(reason: String) async throws {
        attempts += 1
        if attempts == 1 {
            try await withCheckedThrowingContinuation { pending = $0 }
        }
    }

    func complete(_ result: Result<Void, AppLockAuthenticationError>) {
        let continuation = pending
        pending = nil
        switch result {
        case .success: continuation?.resume()
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}

@MainActor
@Test(arguments: [true, false], [true, false])
func automaticAppLockCancellationDoesNotRepromptWhenItsSheetReactivates(
    activeBeforeCompletion: Bool,
    manualAttempt: Bool
) async throws {
    let defaults = try appLockDefaults()
    defaults.set(true, forKey: AppLockModel.enabledKey)
    let authenticator = SuspendedAppLockAuthenticator()
    let model = AppLockModel(defaults: defaults, authenticator: authenticator)
    model.scenePhaseChanged(.active)
    let automaticAttempt = Task {
        if manualAttempt { await model.unlock() } else { await model.unlockAutomatically() }
    }
    while authenticator.pending == nil { await Task.yield() }
    model.scenePhaseChanged(.inactive)
    if activeBeforeCompletion {
        model.scenePhaseChanged(.active)
        await model.unlockAutomatically()
    }
    authenticator.complete(.failure(.cancelled))
    await automaticAttempt.value
    if !activeBeforeCompletion { model.scenePhaseChanged(.active) }
    await model.unlockAutomatically()

    #expect(authenticator.attempts == 1)
    #expect(model.isLocked)
    #expect(!model.isAuthenticating)
    #expect(model.errorMessage == nil)

    // The explicit lock-screen button remains a working retry.
    await model.unlock()
    #expect(authenticator.attempts == 2)
    #expect(!model.isLocked)
}

@MainActor
@Test func lateAppLockAuthenticationCannotUnlockAfterBackgrounding() async throws {
    let defaults = try appLockDefaults()
    defaults.set(true, forKey: AppLockModel.enabledKey)
    let authenticator = SuspendedAppLockAuthenticator()
    let model = AppLockModel(defaults: defaults, authenticator: authenticator)
    model.scenePhaseChanged(.active)
    let automaticAttempt = Task { await model.unlockAutomatically() }
    while authenticator.pending == nil { await Task.yield() }
    model.scenePhaseChanged(.inactive)
    model.scenePhaseChanged(.background)
    authenticator.complete(.success(()))
    await automaticAttempt.value

    #expect(model.isLocked, "A late success must not reveal the backgrounded app")
    await model.unlockAutomatically()
    #expect(authenticator.attempts == 1)
    model.scenePhaseChanged(.active)
    await model.unlockAutomatically()
    #expect(authenticator.attempts == 2, "A real foreground visit permits a fresh attempt")
    #expect(!model.isLocked)
    model.scenePhaseChanged(.inactive)
    #expect(model.isLocked, "Inactive scenes remain immediately protected")
}

@MainActor
@Test func automaticAppLockDoesNotStartAfterItsActiveCallbackBecameObsolete() async throws {
    let defaults = try appLockDefaults()
    defaults.set(true, forKey: AppLockModel.enabledKey)
    let authenticator = TestAppLockAuthenticator()
    let model = AppLockModel(defaults: defaults, authenticator: authenticator)
    model.scenePhaseChanged(.active)
    model.scenePhaseChanged(.inactive)
    // An .active callback's queued Task can run after the next phase change.
    await model.unlockAutomatically()
    #expect(authenticator.reasons.isEmpty)
    #expect(model.isLocked)
    model.scenePhaseChanged(.active)
    await model.unlockAutomatically()
    #expect(authenticator.reasons.count == 1)
    #expect(!model.isLocked)
}

@MainActor
@Test func lateAppLockSettingAuthenticationDoesNotUnlockTheBackgroundedApp() async throws {
    let defaults = try appLockDefaults()
    defaults.set(true, forKey: AppLockModel.enabledKey)
    let authenticator = SuspendedAppLockAuthenticator()
    let model = AppLockModel(defaults: defaults, authenticator: authenticator)
    model.scenePhaseChanged(.active)
    let disable = Task { await model.setEnabled(false) }
    while authenticator.pending == nil { await Task.yield() }
    model.scenePhaseChanged(.background)
    authenticator.complete(.success(()))
    await disable.value
    #expect(model.isEnabled)
    #expect(model.isLocked)
    #expect(defaults.bool(forKey: AppLockModel.enabledKey))
}
