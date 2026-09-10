import Foundation
import SparkAPI
import SwiftUI

/// A Spark-confirmed setting for one model profile; nil disables only idle unloading.
public struct SparkModelIdleSetting: Equatable, Sendable {
    public var minutes: Int?

    public init(minutes: Int? = 30) { self.minutes = minutes }

    init(profile: SparkModelProfile) {
        switch profile.idlePolicy {
        case "keep_ready", "manual_only": minutes = nil
        case "unload_after_15m": minutes = (profile.idleTimeoutSeconds ?? 900) / 60
        case "unload_after_60m": minutes = (profile.idleTimeoutSeconds ?? 3600) / 60
        default: minutes = (profile.idleTimeoutSeconds ?? 1800) / 60
        }
    }

    func request(modelID: String, profile: SparkModelProfile) throws
        -> GeneratedAPI.ModelIdlePolicySettings
    {
        let policy: GeneratedAPI.ModelIdlePolicySettingsIdlePolicy
        switch minutes {
        case nil:
            policy =
                profile.supportedIdlePolicies?.contains("keep_ready") == true
                ? .keepReady : .manualOnly
        case 15: policy = .unloadAfter15M
        case 60: policy = .unloadAfter60M
        default: policy = .unloadAfter30M
        }
        guard profile.supportedIdlePolicies?.contains(policy.rawValue) == true,
            minutes.map({ (1...10080).contains($0) }) ?? true
        else {
            throw SparkModelLaunchError(
                message: String(localized: "This unload setting is not supported by this Spark.")
            )
        }
        let custom = minutes.flatMap { [15, 30, 60].contains($0) ? nil : $0 * 60 }
        guard custom == nil || profile.supportsCustomIdleTimeout == true else {
            throw SparkModelLaunchError(
                message: String(localized: "Update this Spark to choose a custom unload time.")
            )
        }
        return .init(
            modelId: modelID,
            profileId: profile.id,
            idlePolicy: policy,
            idleTimeoutSeconds: custom
        )
    }
}

struct SparkModelIdleControls: View {
    @Binding var setting: SparkModelIdleSetting
    let profile: SparkModelProfile
    @State private var custom = false
    @State private var customMinutes = "30"

    private var selection: String {
        if custom { return "custom" }
        return setting.minutes.map(String.init) ?? "never"
    }

    var body: some View {
        Picker(
            "Unload when idle",
            selection: Binding(
                get: { selection },
                set: { value in
                    custom = value == "custom"
                    setting.minutes = custom ? (Int(customMinutes) ?? 0) : Int(value)
                }
            )
        ) {
            if profile.supportedIdlePolicies?.contains("unload_after_15m") == true {
                Text("After 15 minutes").tag("15")
            }
            if profile.supportedIdlePolicies?.contains("unload_after_30m") == true {
                Text("After 30 minutes").tag("30")
            }
            if profile.supportedIdlePolicies?.contains("unload_after_60m") == true {
                Text("After 1 hour").tag("60")
            }
            if profile.supportedIdlePolicies?.contains("keep_ready") == true
                || profile.supportedIdlePolicies?.contains("manual_only") == true
            {
                Text("Never unload").tag("never")
            }
            if profile.supportsCustomIdleTimeout == true { Text("Custom time").tag("custom") }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("spark.model.unload-time")
        if custom {
            HStack {
                Text("Idle minutes")
                TextField(
                    "Minutes",
                    text: Binding(
                        get: { customMinutes },
                        set: {
                            customMinutes = $0
                            setting.minutes = Int($0) ?? 0
                        }
                    )
                )
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
                .accessibilityIdentifier("spark.model.unload-minutes")
            }
            Text("Choose 1 to 10,080 minutes; the timer starts after the last request finishes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text(
            "Saved on this Spark for this preset. Never unload keeps it ready until you switch models or stop it; memory protection still applies."
        )
        .font(.caption).foregroundStyle(.secondary)
        .onChange(of: setting.minutes, initial: true) { _, minutes in
            if let minutes, ![15, 30, 60].contains(minutes), !custom {
                customMinutes = String(minutes)
                custom = true
            } else if minutes == nil {
                custom = false
            }
        }
    }
}

@MainActor
extension SparkSettingsModel {
    func saveModelIdleSetting(
        _ setting: SparkModelIdleSetting,
        modelID: String,
        profile: SparkModelProfile
    ) async throws {
        let request = try setting.request(modelID: modelID, profile: profile)
        await saveIdlePolicy(
            modelID: modelID,
            profileID: profile.id,
            policy: request.idlePolicy,
            idleTimeoutSeconds: request.idleTimeoutSeconds
        )
        if let errorMessage { throw SparkModelLaunchError(message: errorMessage) }
        guard lastOperation?.state == .succeeded else {
            throw SparkModelLaunchError(
                message: String(localized: "The Spark did not apply this setting.")
            )
        }
    }
}
