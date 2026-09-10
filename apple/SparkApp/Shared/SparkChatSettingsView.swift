import Foundation
import Observation
import SwiftUI

public struct SparkChatSettingsView: View {
    @Bindable private var settings: SparkChatSettings

    public init(settings: SparkChatSettings = .shared) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section {
                Toggle(
                    SparkChatSettings.plainStyleTitle,
                    isOn: $settings.isPlainStyleEnabled
                )
            } footer: {
                Text(SparkChatSettings.plainStyleExplanation)
            }
            Section {
                Text(
                    "A single chat can go its own way from its entry in the chat list, under Plain style."
                )
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Chat")
    }
}

/// The per-conversation control, offered wherever one conversation is named.
public struct SparkChatPlainStyleMenuItems: View {
    private let model: SparkChatModel

    public init(model: SparkChatModel) {
        self.model = model
    }

    public var body: some View {
        Toggle(
            SparkChatSettings.plainStyleTitle,
            isOn: Binding(
                get: { model.usesPlainStyle },
                set: { model.setPlainStyleOverride($0) }
            )
        )
        if model.plainStyleOverride != nil {
            Button("Follow the chat setting", systemImage: "arrow.uturn.backward") {
                model.setPlainStyleOverride(nil)
            }
        }
    }
}
