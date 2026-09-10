import Foundation
import Observation
import SparkAPI
import SparkDesignSystem
import SparkSecurity
import SwiftUI

/// Invitation copy that has to be exact, kept out of the form body so a test can name it.
enum SharedAccessInviteCopy {
    /// The name is signed into the invitation and returned to the guest, whose app shows it back.
    static var guestNameFooter: String {
        String(
            localized:
                "Your guest sees this name in their own app, and it labels their access on your Spark."
        )
    }
}

/// Choose what a friend may do with this Spark, then hand them a link by Messages or Mail.
struct SharedAccessInviteView: View {
    @Bindable var model: SharedAccessInvitationModel
    let onDone: () -> Void

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Their name"), text: $model.draft.guestName)
                    .textContentType(.name)
                    .accessibilityIdentifier("shared.access.invite.name")
            } header: {
                Text("Who are you sharing with?")
            } footer: {
                Text(SharedAccessInviteCopy.guestNameFooter)
            }

            Section {
                if model.availableModels.isEmpty {
                    Text("No models are installed on this Spark yet, so there is nothing to share.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.availableModels, id: \.self) { name in
                        Button {
                            model.toggle(model: name)
                        } label: {
                            HStack {
                                Text(name).foregroundStyle(.primary)
                                Spacer()
                                if model.draft.allowedModels.contains(name) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityAddTraits(
                            model.draft.allowedModels.contains(name) ? [.isSelected] : []
                        )
                    }
                }
            } header: {
                Text("Which models?")
            } footer: {
                Text("Nothing is shared until you choose at least one.")
            }

            Section {
                Toggle(String(localized: "Weekdays only"), isOn: $model.draft.weekdaysOnly)
                Stepper(value: $model.draft.startMinute, in: 0...1_380, step: 30) {
                    LabeledContent(
                        String(localized: "From"),
                        value: SharedAccessClock.label(model.draft.startMinute)
                    )
                }
                Stepper(value: $model.draft.endMinute, in: 60...1_440, step: 30) {
                    LabeledContent(
                        String(localized: "Until"),
                        value: SharedAccessClock.label(model.draft.endMinute)
                    )
                }
            } header: {
                Text("When?")
            } footer: {
                Text(.sharedAccessHoursInZone(model.draft.timeZone))
            }

            Section {
                Stepper(value: $model.draft.dailyTokenBudget, in: 1_000...1_000_000, step: 5_000) {
                    LabeledContent(
                        String(localized: "Daily tokens"),
                        value: "\(model.draft.dailyTokenBudget)"
                    )
                }
                Stepper(value: $model.draft.maxConcurrentRequests, in: 1...8) {
                    LabeledContent(
                        String(localized: "At a time"),
                        value: "\(model.draft.maxConcurrentRequests)"
                    )
                }
            } header: {
                Text("How much?")
            } footer: {
                Text("The daily budget starts again at midnight in your time zone.")
            }

            if let problem = model.draft.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if let share = model.share {
                Section {
                    ShareLink(
                        item: share.link,
                        subject: Text(share.subject),
                        message: Text(share.message)
                    ) {
                        Label("Send the invitation", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("shared.access.invite.share")
                    if !share.reachableRemotely {
                        Label(
                            String(
                                localized:
                                    "They must be on your Wi-Fi. Turn on remote access to let them join from anywhere."
                            ),
                            systemImage: "wifi"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Ready to send")
                } footer: {
                    Text(
                        "You will be asked to confirm on this device after they join, before anything works."
                    )
                }
            } else {
                Section {
                    Button {
                        Task { await model.createInvitation() }
                    } label: {
                        if model.isCreating {
                            ProgressView()
                        } else {
                            Text("Create the invitation")
                        }
                    }
                    .disabled(!model.draft.isReady || model.isCreating)
                    .accessibilityIdentifier("shared.access.invite.create")
                }
            }
        }
        .navigationTitle(Text("Share your Spark"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done"), action: onDone)
            }
        }
    }
}
