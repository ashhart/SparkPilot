import Observation
import SparkDesignSystem
import SwiftUI

public struct NativeSparkSetupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum FocusedField: Hashable {
        case username
        case password
        case passwordConfirmation
        case wifiPassword
    }

    @Bindable private var model: NativeSparkSetupModel
    @FocusState private var focusedField: FocusedField?
    private let onExit: () -> Void

    public init(model: NativeSparkSetupModel, onExit: @escaping () -> Void) {
        self.model = model
        self.onExit = onExit
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                progress
                artwork
                stepContent

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                if model.step != .connecting {
                    Button(primaryAction) {
                        Task { await model.continueSetup() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.primaryActionIsDisabled)
                }
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("")
        .toolbar {
            if model.step != .connecting {
                ToolbarItem(placement: .navigation) {
                    Button {
                        if model.step == .region {
                            onExit()
                        } else {
                            model.goBack()
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(model.isWorking)
                }
            }
        }
        .task { await model.load() }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Spark setup")
                Spacer()
                Text(.stepOfFive(min(model.step.rawValue + 1, 5)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ProgressView(value: Double(min(model.step.rawValue + 1, 5)), total: 5)
                .accessibilityLabel("Spark setup progress")
                .accessibilityValue(Text(.stepOfFive(min(model.step.rawValue + 1, 5))))
        }
    }

    private var artwork: some View {
        SparkProductArtwork(isConnected: false)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .region:
            regionContent
        case .licence:
            licenceContent
        case .account:
            accountContent
        case .privacy:
            privacyContent
        case .wifi:
            wifiContent
        case .connecting:
            connectingContent
        }
    }

    private var regionContent: some View {
        VStack(spacing: 18) {
            heading(for: .region)

            Picker("Language", selection: $model.selectedLanguageIndex) {
                ForEach(model.languages) { language in
                    Text(.joined(language.countryCode, language.displayName))
                        .tag(Optional(language.index))
                }
            }
            .pickerStyle(.menu)

            Picker("Time zone", selection: $model.selectedTimeZoneIndex) {
                ForEach(Array(model.timeZones.enumerated()), id: \.offset) { index, timeZone in
                    Text(timeZone.replacingOccurrences(of: "_", with: " "))
                        .tag(Optional(index))
                }
            }
            .pickerStyle(.menu)

            if model.isWorking { ProgressView() }
        }
    }

    private var licenceContent: some View {
        VStack(spacing: 18) {
            heading(for: .licence)

            ScrollView {
                Text(verbatim: model.licenceText)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(height: 260)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))

            Toggle("I agree to these terms", isOn: $model.hasAcceptedLicence)
                .font(.body.weight(.semibold))
        }
    }

    private var accountContent: some View {
        VStack(spacing: 18) {
            heading(for: .account)

            VStack(spacing: 14) {
                setupInput(
                    String(localized: "Username"),
                    systemImage: "person.fill",
                    focus: .username
                ) {
                    TextField("Choose a username", text: $model.username)
                        .textContentType(.username)
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        #endif
                }
                setupInput(
                    String(localized: "Password"),
                    systemImage: "lock.fill",
                    focus: .password
                ) {
                    SecureField("Create a password", text: $model.password)
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .passwordConfirmation }
                }
                setupInput(
                    String(localized: "Confirm password"),
                    systemImage: "checkmark.shield.fill",
                    focus: .passwordConfirmation
                ) {
                    SecureField("Type it again", text: $model.confirmPassword)
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .passwordConfirmation)
                        .submitLabel(.done)
                }
            }

            Text(
                "Use at least 6 characters. Usernames start with a letter and use lowercase letters, numbers, _ or -."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            transportNotice
        }
    }

    /// The one-line cleartext notice, only when the model was given one.
    @ViewBuilder
    private var transportNotice: some View {
        if let notice = model.transportNotice {
            Label(notice, systemImage: "lock.open")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("native-setup-transport-notice")
        }
    }

    private var privacyContent: some View {
        VStack(spacing: 18) {
            heading(for: .privacy)

            VStack(alignment: .leading, spacing: 16) {
                Toggle("Share functional diagnostics", isOn: $model.functionalTelemetry)
                Toggle("Share technical diagnostics", isOn: $model.technicalTelemetry)
                    .disabled(!model.functionalTelemetry)
            }
            .padding()
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var wifiContent: some View {
        VStack(spacing: 18) {
            if let selectedNetwork = model.selectedNetwork {
                wifiCredentialsContent(selectedNetwork)
                transportNotice
            } else {
                wifiSelectionContent
            }
        }
    }

    private var wifiSelectionContent: some View {
        Group {
            heading(for: .wifi)

            ethernetStatus

            if !model.ethernetHasInternet {
                VStack(spacing: 0) {
                    ForEach(model.networks) { network in
                        Button {
                            withAnimation(reduceMotion ? nil : .snappy) {
                                model.selectNetwork(network)
                            }
                            guard network.isProtected else { return }
                            Task { @MainActor in
                                await Task.yield()
                                focusedField = .wifiPassword
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: wifiSymbol(strength: network.strength))
                                    .foregroundStyle(Color.accentColor)
                                Text(network.ssid)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if network.isProtected {
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 15)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if network.id != model.networks.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .background(
                    .quaternary.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            }

            Button(model.ethernetHasInternet ? "Check Again" : "Check Connections Again") {
                Task { await model.refreshNetworks() }
            }
            .disabled(model.isWorking)
        }
    }

    private func wifiCredentialsContent(_ network: SparkOOBEWiFiNetwork) -> some View {
        Group {
            heading(
                NativeSparkSetupPresentation.networkHeading(
                    name: network.ssid,
                    isProtected: network.isProtected
                )
            )

            HStack(spacing: 14) {
                Image(systemName: wifiSymbol(strength: network.strength))
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(network.ssid)
                        .font(.headline)
                    Text(network.isProtected ? "Secured network" : "Open network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if network.isProtected {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .quaternary.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )

            if network.isProtected {
                setupInput(
                    String(localized: "Wi-Fi password"),
                    systemImage: "key.fill",
                    focus: .wifiPassword
                ) {
                    SecureField("Enter network password", text: $model.wifiPassword)
                        .textContentType(.password)
                        .focused($focusedField, equals: .wifiPassword)
                        .submitLabel(.done)
                }
            }

            Button("Choose a different network") {
                focusedField = nil
                withAnimation(reduceMotion ? nil : .snappy) {
                    model.chooseDifferentNetwork()
                }
            }
            .disabled(model.isWorking)
        }
    }

    private var ethernetStatus: some View {
        HStack(spacing: 14) {
            Image(
                systemName: model.ethernetHasInternet
                    ? "checkmark.circle.fill" : "cable.connector.horizontal"
            )
            .font(.title2)
            .foregroundStyle(model.ethernetHasInternet ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.ethernetHasInternet ? "Ethernet connected" : "Ethernet not detected")
                    .font(.headline)
                Text(
                    model.ethernetHasInternet
                        ? "Your Spark confirmed that the cable provides internet access."
                        : "For wired setup, plug a network cable into the Spark, then check connections again."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var connectingContent: some View {
        VStack(spacing: 18) {
            heading(for: .connecting)
            ProgressView()
                .controlSize(.large)
        }
    }

    private func heading(for step: NativeSparkSetupStep) -> some View {
        heading(NativeSparkSetupPresentation.heading(for: step))
    }

    private func heading(_ copy: NativeSparkSetupPresentation.Heading) -> some View {
        let (title, message) = (copy.title, copy.message)
        return VStack(spacing: 10) {
            Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func setupInput<Content: View>(
        _ title: String,
        systemImage: String,
        focus: FocusedField,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isFocused = focusedField == focus

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                content()
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(
                .quaternary.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isFocused ? Color.accentColor : Color.secondary.opacity(0.18),
                        lineWidth: isFocused ? 2 : 1
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                focusedField = focus
            }
        )
    }

    private var primaryAction: String {
        NativeSparkSetupPresentation.primaryAction(
            step: model.step,
            ethernetHasInternet: model.ethernetHasInternet,
            hasSelectedNetwork: model.selectedNetworkIndex != nil
        )
    }

    private func wifiSymbol(strength: Int) -> String {
        strength < 20 ? "wifi.slash" : "wifi"
    }
}
