import SwiftUI

/// Present the §39.2 policy decision before a prompt leaves this device, never silently.
struct SparkExecutionPolicyPrompts: ViewModifier {
    @Bindable var model: SparkChatModel

    func body(content: Content) -> some View {
        content
            .alert(
                "Send over a remote connection?",
                isPresented: Binding(
                    get: { model.pendingRemoteExecution != nil },
                    set: { if !$0 { model.cancelRemoteExecution() } }
                )
            ) {
                Button("Send Anyway") { model.confirmRemoteExecution() }
                Button("Keep It Local", role: .cancel) { model.cancelRemoteExecution() }
            } message: {
                Text(verbatim: model.pendingRemoteExecution ?? "")
            }
            .alert(
                "This device's policy blocked that",
                isPresented: Binding(
                    get: { model.executionPolicyRefusal != nil },
                    set: { if !$0 { model.dismissExecutionPolicyRefusal() } }
                )
            ) {
                Button("OK", role: .cancel) { model.dismissExecutionPolicyRefusal() }
            } message: {
                Text(verbatim: model.executionPolicyRefusal ?? "")
            }
    }
}

extension View {
    func sparkExecutionPolicyPrompts(model: SparkChatModel) -> some View {
        modifier(SparkExecutionPolicyPrompts(model: model))
    }
}
