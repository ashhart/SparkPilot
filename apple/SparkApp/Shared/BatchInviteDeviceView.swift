import Foundation
import Observation
import SparkAPI
import SparkBootstrap
import SparkDesignSystem
import SparkSecurity
import SwiftUI

/// Present independent per-Spark invitation, retry, grant and compensating-revocation results during batch handoff.
struct BatchInviteDeviceView: View {
    @Bindable var model: RetailOnboardingModel
    let onDone: () -> Void

    @State private var recipientRequest = ""
    @State private var selectedNodeIDs = Set<String>()
    @State private var role: InvitedDeviceRole = .administrator
    #if os(iOS)
        @State private var isScanning = false
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Add a Device to Several Sparks")
                        .font(.largeTitle.bold())
                    Text(
                        "Scan the request shown by the new Apple device, then choose the standalone Sparks it may use."
                    )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }

                Picker("Access", selection: $role) {
                    ForEach(InvitedDeviceRole.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isCreatingBatchInvitation)

                VStack(spacing: 8) {
                    ForEach(model.batchInvitationSources) { source in
                        Toggle(
                            source.nodeName,
                            isOn: Binding(
                                get: { selectedNodeIDs.contains(source.id) },
                                set: { selected in
                                    if selected {
                                        selectedNodeIDs.insert(source.id)
                                    } else {
                                        selectedNodeIDs.remove(source.id)
                                    }
                                }
                            )
                        )
                        .padding(14)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    }
                }

                if let error = model.batchInvitationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let progress = model.batchInvitationProgress {
                    VStack(spacing: 8) {
                        ForEach(progress.targets) { target in
                            HStack {
                                Image(systemName: invitationPhaseIcon(target.phase))
                                    .foregroundStyle(invitationPhaseColour(target.phase))
                                VStack(alignment: .leading) {
                                    Text(target.source.nodeName)
                                    if let message = target.lastError {
                                        Text(message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if target.phase == .failed {
                                    Button("Retry") {
                                        Task { await model.retryBatchInvitation(nodeID: target.id) }
                                    }
                                    .disabled(model.isCreatingBatchInvitation)
                                }
                            }
                            .padding(14)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }

                if let payload = model.batchInvitationPayload {
                    SparkPairingQRCode(payload: payload)
                    Text("Scan this on the new Apple device. Each Spark will record its own grant.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    DisclosureGroup(String(localized: "Copy package instead")) {
                        Text(payload)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .privacySensitive()
                    }
                    Button("Undo Added Device", role: .destructive) {
                        Task { await model.revokeBatchInvitationGrants() }
                    }
                    .disabled(model.isCreatingBatchInvitation)
                } else if model.batchInvitationProgress == nil {
                    #if os(iOS)
                        Button {
                            isScanning = true
                        } label: {
                            Label("Scan Device Request", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    #endif
                    TextField("Paste device request", text: $recipientRequest, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...7)
                        .privacySensitive()
                    Button("Create Multi-Spark Package") {
                        Task {
                            await model.createBatchInvitation(
                                recipientRequestPayload: recipientRequest,
                                selectedNodeIDs: selectedNodeIDs,
                                role: role
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        recipientRequest.isEmpty || selectedNodeIDs.count < 2
                            || model.isCreatingBatchInvitation
                    )
                }

                if model.isCreatingBatchInvitation {
                    ProgressView(String(localized: "Updating each Spark independently"))
                }
            }
            .frame(maxWidth: 600)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Several Sparks")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onDone)
                    .disabled(model.isCreatingBatchInvitation)
            }
        }
        .onAppear {
            if selectedNodeIDs.isEmpty {
                selectedNodeIDs = Set(model.batchInvitationSources.map(\.id))
            }
        }
        #if os(iOS)
            .sheet(isPresented: $isScanning) {
                NavigationStack {
                    PairingCodeScanner(
                        acceptedRoutes: [BatchPairingRecipientRequest.route]
                    ) { request in
                        recipientRequest = request
                        isScanning = false
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan Device Request")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isScanning = false }
                        }
                    }
                }
            }
        #endif
    }

    private func invitationPhaseIcon(_ phase: BatchInvitationTargetPhase) -> String {
        switch phase {
        case .issued: "checkmark.circle.fill"
        case .failed, .revocationFailed: "exclamationmark.triangle.fill"
        case .revoked: "xmark.circle.fill"
        default: "clock"
        }
    }

    private func invitationPhaseColour(_ phase: BatchInvitationTargetPhase) -> Color {
        switch phase {
        case .issued: .green
        case .failed, .revocationFailed: .orange
        default: .secondary
        }
    }
}
