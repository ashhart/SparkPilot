import Foundation
import SparkDesignSystem
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

public enum SparkChatAccessibility {
    public static let targetPickerLabel = String(localized: "Choose Spark and active model")
    public static let composerLabel = String(localized: "Message to Spark")
    public static let composerHint = String(localized: "Sends the message to the selected Spark")
    public static let sendLabel = String(localized: "Send message")
    public static let cancelLabel = String(localized: "Stop generating")
    public static let retryLabel = String(localized: "Retry last message")
    public static let addSparkLabel = String(localized: "Add a Spark for chat")
}

public enum SparkChatLayoutPlan {
    public static func stacksComposerVertically(_ dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }
}

@MainActor
public struct SparkChatView: View {
    @State private var workspace: SparkChatWorkspace
    @Environment(\.scenePhase) private var scenePhase
    private let onAddSpark: (@MainActor () -> Void)?

    public init(workspace: SparkChatWorkspace, onAddSpark: (@MainActor () -> Void)? = nil) {
        _workspace = State(initialValue: workspace)
        self.onAddSpark = onAddSpark
    }

    public init(model: SparkChatModel, onAddSpark: (@MainActor () -> Void)? = nil) {
        self.init(workspace: SparkChatWorkspace(initialModel: model), onAddSpark: onAddSpark)
    }

    public var body: some View {
        SparkChatConversationView(
            model: workspace.selected.model,
            workspace: workspace,
            onAddSpark: onAddSpark
        )
        .id(workspace.selectedID)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { workspace.flush() }
        }
        .onDisappear { workspace.flush() }
    }
}
