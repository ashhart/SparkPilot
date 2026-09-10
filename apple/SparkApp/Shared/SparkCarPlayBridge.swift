import Foundation
import Observation
import SwiftUI

/// The one place the phone app and a connected car share state; UIKit's scene reads from it.
@MainActor
@Observable
public final class SparkCarPlayBridge {
    public static let shared = SparkCarPlayBridge()

    public private(set) var onboarding: RetailOnboardingModel?
    public private(set) var appLock: AppLockModel?
    /// True between the car's connect and disconnect callbacks.
    public private(set) var isConnected = false
    public private(set) var drivingMode: SparkDrivingMode = .notDriving
    /// The live conversation while a car is connected, so the phone can show what the car hears.
    var conversation: SparkCarPlayConversation?
    @ObservationIgnored private var reducer = SparkDrivingStateReducer()

    @ObservationIgnored private var bootstrap: (() throws -> RetailOnboardingModel)?
    init() {}

    public func configure(
        appLock: AppLockModel,
        bootstrap: @escaping () throws -> RetailOnboardingModel
    ) {
        self.appLock = appLock
        self.bootstrap = bootstrap
    }
    public func ensureReady() throws {
        if onboarding == nil, let bootstrap { onboarding = try bootstrap() }
    }
    public func composedOnboarding() throws -> RetailOnboardingModel {
        try ensureReady()
        guard let onboarding else { throw CocoaError(.coderValueNotFound) }
        return onboarding
    }

    /// The app calls this once its models exist; a car that connects earlier waits for it.
    public func register(onboarding: RetailOnboardingModel, appLock: AppLockModel) {
        self.onboarding = onboarding
        self.appLock = appLock
    }

    /// The CarPlay scene reports its lifetime here; the driving mode falls back to normal on disconnect.
    public func carPlayConnected(_ connected: Bool, at date: Date = Date()) {
        isConnected = connected
        observe(
            SparkDrivingSignals(carPlayConnected: connected, observedAt: date)
        )
    }

    /// One car observation. The reducer decides; nothing here second-guesses it.
    public func observe(_ signals: SparkDrivingSignals) {
        let next = reducer.apply(signals)
        if next != drivingMode { drivingMode = next }
    }

    /// Whether text entry is paused right now, for chat, the terminal and any other keyboard.
    public var typingRestriction: SparkTypingRestriction {
        switch drivingMode {
        case .moving: .paused
        case .parked: .parkedHint
        case .notDriving: .none
        }
    }
}

/// What a text field should do about the car.
public enum SparkTypingRestriction: Equatable, Sendable {
    case none
    /// Stopped in the car: typing works, with a small reminder that voice is there.
    case parkedHint
    /// Moving: no keyboard, voice only.
    case paused

    public var isPaused: Bool { self == .paused }
}
