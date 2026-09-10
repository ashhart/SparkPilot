import Foundation
import Observation
import SparkCore
import SparkDesignSystem
import SparkIntelligence
import SwiftUI

/// The owner's §39.2 execution policy, stored on this Apple device only.
@MainActor
@Observable
public final class SparkExecutionPolicyModel {
    public enum Choice: String, CaseIterable, Identifiable, Sendable {
        case anyPairedTarget
        case sparkOnly
        case myHardwareOnly
        case onDeviceOnly

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .anyPairedTarget: String(localized: "Any paired target")
            case .sparkOnly: String(localized: "My Sparks only")
            case .myHardwareOnly: String(localized: "My hardware only")
            case .onDeviceOnly: String(localized: "On this device only")
            }
        }

        public var detail: String {
            switch self {
            case .anyPairedTarget:
                String(localized: "Use whichever paired Spark or on-device model suits the task.")
            case .sparkOnly:
                String(localized: "Only run work on a paired Spark or Spark cluster.")
            case .myHardwareOnly:
                String(localized: "Only run work on this device or on hardware you own.")
            case .onDeviceOnly:
                String(localized: "Never send a prompt off this device.")
            }
        }

        var constraint: RoutingPolicy.Constraint? {
            switch self {
            case .anyPairedTarget: nil
            case .sparkOnly: .sparkOnly
            case .myHardwareOnly: .myHardwareOnly
            case .onDeviceOnly: .onDeviceOnly
            }
        }
    }

    static let choiceKey = "spark.execution.policy.choice"
    static let askKey = "spark.execution.policy.askBeforeRemote"

    private let defaults: UserDefaults

    public var choice: Choice {
        didSet { defaults.set(choice.rawValue, forKey: Self.choiceKey) }
    }

    /// §39.2's fourth policy: confirm before an answer travels over a remote route.
    public var asksBeforeRemoteExecution: Bool {
        didSet { defaults.set(asksBeforeRemoteExecution, forKey: Self.askKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.choiceKey).flatMap(Choice.init(rawValue:))
        choice = stored ?? .anyPairedTarget
        asksBeforeRemoteExecution =
            defaults.object(forKey: Self.askKey) as? Bool ?? true
    }

    /// A second surface may have changed these preferences since this model was composed.
    func reload() {
        let saved =
            defaults.string(forKey: Self.choiceKey).flatMap(Choice.init(rawValue:))
            ?? .anyPairedTarget
        let asks = defaults.object(forKey: Self.askKey) as? Bool ?? true
        if choice != saved { choice = saved }
        if asksBeforeRemoteExecution != asks { asksBeforeRemoteExecution = asks }
    }

    public var policy: RoutingPolicy {
        RoutingPolicy(
            constraint: choice.constraint,
            askBeforeRemoteExecution: asksBeforeRemoteExecution
        )
    }

    /// What this policy does to a target, so §39.11's decision is explainable rather than silent.
    public func decision(for transport: SparkExecutionTransport) -> SparkExecutionDecision {
        if choice == .onDeviceOnly, transport.leavesThisDevice {
            return .refused(
                String(
                    localized:
                        "Your execution policy is on this device only, so nothing can be sent to a Spark. Change it in Settings to use a Spark."
                )
            )
        }
        if asksBeforeRemoteExecution, transport == .remote {
            return .needsConfirmation(
                String(
                    localized:
                        "This answer would travel over a remote connection rather than your local network."
                )
            )
        }
        return .allowed
    }
}

/// The three outcomes a policy check can have before an AI action starts.
public enum SparkExecutionDecision: Equatable, Sendable {
    case allowed
    case needsConfirmation(String)
    case refused(String)

    public var explanation: String? {
        switch self {
        case .allowed: nil
        case .needsConfirmation(let text), .refused(let text): text
        }
    }
}

/// The §39.2 policy screen, on this device only and never uploaded.
public struct SparkExecutionPolicyView: View {
    @Bindable var model: SparkExecutionPolicyModel

    public init(model: SparkExecutionPolicyModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section("Where work may run") {
                ForEach(SparkExecutionPolicyModel.Choice.allCases) { choice in
                    Button {
                        model.choice = choice
                    } label: {
                        LabeledContent {
                            if model.choice == choice {
                                Image(systemName: "checkmark")
                                    .accessibilityLabel("Selected")
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: SparkSpacing.tiny) {
                                Text(choice.title)
                                Text(choice.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: SparkLayout.minimumTouchTarget,
                            alignment: .leading
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                Toggle("Ask before a remote connection", isOn: $model.asksBeforeRemoteExecution)
                    .frame(minHeight: SparkLayout.minimumTouchTarget)
            } footer: {
                Text(
                    "SparkPilot asks first when an answer would travel over a remote route instead of your local network. This choice stays on this device."
                )
            }
        }
        .navigationTitle("AI execution")
    }
}
