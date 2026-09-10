import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

struct SparkDashboardOptionalServices: View {
    @Bindable var model: SparkDashboardModel
    @Binding var confirmingOpenWebUIRemoval: Bool
    @Binding var confirmingOpenWebUIRepair: Bool
    @Binding var showingCatalogueImporter: Bool
    @Binding var catalogueFileError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional services")
                .font(.title2.bold())
            openWebUICard
                .id("service-open-webui")
            catalogueRefreshCard
        }

    }
    @ViewBuilder
    private var catalogueRefreshCard: some View {
        if model.catalogueRefreshSupported, let status = model.catalogueStatus {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title2)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Signed catalogue updates")
                            .font(.headline)
                        Text(model.remoteCatalogueDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.remoteCatalogueStatus)
                        .font(.callout.weight(.semibold))
                }
                Label(
                    "The Spark verifies the signature before replacing its device-local snapshot.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if status.activeEngineUnaffected {
                    Text("The running model stays active during a catalogue refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if status.previousSnapshotAvailable {
                    Text("The previous verified snapshot is retained for automatic rollback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "globe")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recipes published on sparkpilot.dev")
                            .font(.subheadline.weight(.semibold))
                        Text(model.publishedCatalogueStatusLine)
                            .font(.caption)
                            .foregroundStyle(
                                model.publishedCatalogueIsNewer ? Color.accentColor : .secondary
                            )
                    }
                    Spacer()
                    if model.isCheckingPublishedCatalogue { ProgressView() }
                }
                .task { await model.checkPublishedCatalogue() }
                if model.publishedCatalogueIsNewer {
                    Button("Review and install new recipes") {
                        catalogueFileError = nil
                        Task { await model.preparePublishedCatalogueRefresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !status.refreshAvailable || model.isPreparingCatalogueRefresh
                            || model.isRefreshingCatalogue
                    )
                    .accessibilityIdentifier("spark.catalogue.published.install")
                } else {
                    Button("Check sparkpilot.dev again") {
                        Task { await model.checkPublishedCatalogue() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isCheckingPublishedCatalogue)
                }
                Text(
                    "New and updated recipes are signed with SparkPilot's catalogue key; this Spark verifies that signature before it changes anything."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                Button("Update model presets") {
                    catalogueFileError = nil
                    Task { await model.prepareBundledPresetUpdate() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !status.refreshAvailable || model.isPreparingCatalogueRefresh
                        || model.isRefreshingCatalogue
                )
                Text(
                    "Review the presets included with this app; your model files and safety history are kept."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Import signed catalogue…") {
                    catalogueFileError = nil
                    showingCatalogueImporter = true
                }
                .buttonStyle(.bordered)
                .disabled(
                    !status.refreshAvailable || model.isPreparingCatalogueRefresh
                        || model.isRefreshingCatalogue
                )
                if model.isPreparingCatalogueRefresh {
                    ProgressView(String(localized: "Verifying the selected catalogue…"))
                }
                if model.isRefreshingCatalogue {
                    ProgressView(model.catalogueRefreshStageLabel)
                }
                if let message = catalogueFileError ?? model.catalogueErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        } else {
            SparkDashboardStatusRow(
                title: String(localized: "Signed catalogue updates"),
                value: model.remoteCatalogueStatusValue,
                detail: model.remoteCatalogueDetail,
                symbol: "arrow.triangle.2.circlepath",
                help: String(
                    localized:
                        "Imports recipes only after this Spark verifies a signed local snapshot."
                )
            )
        }
    }
    @ViewBuilder
    private var openWebUICard: some View {
        if model.openWebUISupported, let service = model.openWebUIService {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title2)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open WebUI")
                            .font(.headline)
                        Text(model.openWebUIDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.openWebUIStatus)
                        .font(.callout.weight(.semibold))
                        .multilineTextAlignment(.trailing)
                }

                if service.installed {
                    if let port = service.servicePort {
                        Text(
                            service.adopted == true
                                ? "Existing installation · Port \(port)" : "Service port \(port)"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if service.healthy {
                            Button("Open") {
                                Task { await model.requestOpenWebUIAccess() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if service.updateAvailable {
                            Button("Update") {
                                Task { await model.updateOpenWebUI() }
                            }
                            .buttonStyle(.bordered)
                        }
                        if model.canRepairOpenWebUI {
                            Button("Repair") { confirmingOpenWebUIRepair = true }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Repair managed Open WebUI")
                        }
                        Button(
                            service.adopted == true ? "Disconnect" : "Remove",
                            role: .destructive
                        ) {
                            confirmingOpenWebUIRemoval = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(model.isChangingOpenWebUI)
                } else {
                    openWebUIInstallForm(revision: service.availableRevision)
                }

                if model.isChangingOpenWebUI {
                    if let progress = model.openWebUIOperation?.progress {
                        ProgressView(
                            value: progress,
                            total: 1,
                            label: {
                                Text(
                                    model.openWebUIActionLabel
                                        ?? String(localized: "Applying Open WebUI changes")
                                )
                            }
                        )
                    } else {
                        ProgressView(
                            model.openWebUIActionLabel
                                ?? String(localized: "Applying Open WebUI changes")
                        )
                    }
                }
                if let message = model.openWebUIErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        } else {
            SparkDashboardStatusRow(
                title: String(localized: "Open WebUI"),
                value: model.openWebUIStatusValue,
                detail: model.openWebUIDetail,
                symbol: "bubble.left.and.bubble.right",
                help: String(
                    localized:
                        "A verified local web interface recipe, when this runtime supports one."
                )
            )
        }
    }
    private func openWebUIInstallForm(revision: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.supportsOpenWebUIPorts {
                Picker("Installation", selection: $model.adoptExistingOpenWebUI) {
                    Text("Install new").tag(false)
                    Text("Use existing").tag(true)
                }
                .pickerStyle(.segmented)
                TextField("Service port", text: $model.openWebUIPort)
                    .sparkField()
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                Text(
                    model.adoptExistingOpenWebUI
                        ? "Enter the port your Open WebUI container already uses, such as 9090; its accounts, models and data stay unchanged."
                        : "The default local service port is 18080; choose another free port if needed. Browser access uses SparkPilot's secure connection."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if !model.supportsOpenWebUIPorts || !model.adoptExistingOpenWebUI {
                Text("Create a separate Open WebUI administrator")
                    .font(.subheadline.weight(.semibold))
                TextField("Administrator email (optional)", text: $model.openWebUIAdminEmail)
                    .sparkField()
                    .textContentType(.username)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    #endif
                TextField("Administrator name", text: $model.openWebUIAdminName)
                    .sparkField()
                HStack(spacing: 8) {
                    Group {
                        if model.revealsOpenWebUIAdminPassword {
                            TextField("Open WebUI password", text: $model.openWebUIAdminPassword)
                        } else {
                            SecureField("Open WebUI password", text: $model.openWebUIAdminPassword)
                        }
                    }
                    .sparkField()
                    // A new-password field lets the system keychain offer and save a strong password.
                    #if os(iOS)
                        .textContentType(.newPassword)
                    #else
                        .textContentType(.password)
                    #endif
                    Button {
                        model.revealsOpenWebUIAdminPassword.toggle()
                    } label: {
                        Image(
                            systemName: model.revealsOpenWebUIAdminPassword ? "eye.slash" : "eye"
                        )
                        .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        model.revealsOpenWebUIAdminPassword
                            ? String(localized: "Hide password")
                            : String(localized: "Show password")
                    )
                }
                Text(
                    "Use 16–128 characters. This is not your Spark account password. Leave the email blank to sign in as owner@spark.local."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Toggle(
                model.adoptExistingOpenWebUI
                    ? String(localized: "Connect without changing my existing installation")
                    : String(localized: .acceptSignedRecipe(revision)),
                isOn: Binding(
                    get: { model.acceptedOpenWebUIRecipeRevision == revision },
                    set: { accepted in model.acceptOpenWebUIRecipe(accepted) }
                )
            )
            Button(model.adoptExistingOpenWebUI ? "Connect Open WebUI" : "Install Open WebUI") {
                Task { await model.installOpenWebUI() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canInstallOpenWebUI || model.isChangingOpenWebUI)
            if let blocker = model.openWebUIInstallBlocker, !model.isChangingOpenWebUI {
                Text(blocker)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        String(localized: .openWebUIInstallUnavailable(blocker))
                    )
            }
        }
    }
}
