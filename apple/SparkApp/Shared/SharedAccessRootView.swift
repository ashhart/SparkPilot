import Foundation
import SparkAPI
import SparkSecurity
import SwiftUI

/// Hold the owner's Shared access list and the invitation sheet together in one place.
struct SharedAccessRootView: View {
    @Bindable var model: SharedAccessModel
    let trust: NodeTrust
    let availableModels: [String]

    @State private var invitation: SharedAccessInvitationModel?

    var body: some View {
        SharedAccessView(model: model) {
            invitation = model.invitationModel(trust: trust, availableModels: availableModels)
        }
        .sheet(
            isPresented: Binding(
                get: { invitation != nil },
                set: { if !$0 { invitation = nil } }
            )
        ) {
            if let invitation {
                NavigationStack {
                    SharedAccessInviteView(model: invitation) {
                        self.invitation = nil
                        Task { await model.refresh() }
                    }
                }
            }
        }
    }
}
