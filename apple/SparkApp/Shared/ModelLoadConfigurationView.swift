import Foundation
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import IOKit.ps
#endif
import Observation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkSecurity
import SwiftUI
import UniformTypeIdentifiers

public struct ModelLoadConfigurationView: View {
    public let configuration: ModelLoadConfiguration
    public let isPreparing: Bool
    public let errorMessage: String?
    public let cancel: () -> Void
    public let review: (String) -> Void
    private let saveIdleSetting: ((SparkModelProfile, SparkModelIdleSetting) async throws -> Void)?
    @State private var selectedProfileID: String?
    @State private var idleSetting = SparkModelIdleSetting()
    @State private var savingIdleSetting = false
    @State private var idleError: String?
    private var defaultProfileID: String? {
        SparkModelDefaults.defaultProfile(profiles: configuration.profiles)
    }

    public init(
        configuration: ModelLoadConfiguration,
        isPreparing: Bool,
        errorMessage: String?,
        cancel: @escaping () -> Void,
        review: @escaping (String) -> Void,
        saveIdleSetting: ((SparkModelProfile, SparkModelIdleSetting) async throws -> Void)? = nil
    ) {
        self.configuration = configuration
        self.isPreparing = isPreparing
        self.errorMessage = errorMessage
        self.cancel = cancel
        self.review = review
        self.saveIdleSetting = saveIdleSetting
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(configuration.modelName).font(.headline)
                    Text(
                        "Choose a profile to set the context window and simultaneous request limit."
                    )
                }
                Section("Profiles") {
                    if let stale = configuration.staleSavedProfileID {
                        Text(.savedPresetNoLongerOffered(stale))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(configuration.profiles) { profile in
                        Button {
                            selectedProfileID = profile.id
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(profile.displayName).font(.headline)
                                    Spacer()
                                    Image(
                                        systemName: selectedProfileID == profile.id
                                            ? "checkmark.circle.fill" : "circle"
                                    )
                                    .accessibilityHidden(true)
                                }
                                LabeledContent(
                                    "Context tokens",
                                    value: profile.maxModelLength.formatted()
                                )
                                LabeledContent(
                                    "Maximum simultaneous requests",
                                    value: profile.maxSequences.formatted()
                                )
                                if profile.id == defaultProfileID {
                                    Text("Default preset")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                if !profile.safe {
                                    Text(
                                        "Unavailable for the current hardware or memory conditions."
                                    )
                                    .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!profile.safe || isPreparing || savingIdleSetting)
                        .accessibilityAddTraits(selectedProfileID == profile.id ? .isSelected : [])
                    }
                }
                if saveIdleSetting != nil,
                    let profile = configuration.profiles.first(where: { $0.id == selectedProfileID }
                    ),
                    profile.supportedIdlePolicies?.isEmpty == false
                {
                    Section {
                        SparkModelIdleControls(setting: $idleSetting, profile: profile)
                            .id(profile.id)
                            .disabled(isPreparing || savingIdleSetting)
                        if let idleError { Text(idleError).foregroundStyle(.red) }
                    }
                }
                Section {
                    Text(
                        "Context includes input and output tokens. Simultaneous requests share the available cache, so long requests may queue."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                    if isPreparing { ProgressView(String(localized: "Checking this profile")) }
                }
            }
            .onChange(of: selectedProfileID) { _, id in
                if let profile = configuration.profiles.first(where: { $0.id == id }) {
                    idleSetting = SparkModelIdleSetting(profile: profile)
                }
            }
            .interactiveDismissDisabled(savingIdleSetting)
            .navigationTitle("Model profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).disabled(savingIdleSetting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        guard
                            let profile = configuration.profiles.first(where: {
                                $0.id == selectedProfileID
                            })
                        else { return }
                        Task { @MainActor in
                            savingIdleSetting = true
                            idleError = nil
                            defer { savingIdleSetting = false }
                            do {
                                if idleSetting != SparkModelIdleSetting(profile: profile) {
                                    try await saveIdleSetting?(profile, idleSetting)
                                }
                                review(profile.id)
                            } catch { idleError = error.localizedDescription }
                        }
                    }
                    .disabled(isPreparing || savingIdleSetting || selectedProfileID == nil)
                }
            }
        }
    }
}
