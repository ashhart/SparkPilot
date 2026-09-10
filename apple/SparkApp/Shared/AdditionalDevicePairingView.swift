import Observation
import SparkBootstrap
import SparkDesignSystem
import SparkDiscovery
import SwiftUI

struct AddSparkChoiceView: View {
    @Bindable var model: RetailOnboardingModel
    @State private var existingSparkHost = ""
    @State private var screen: SetupScreen = .choice

    private enum SetupScreen { case choice, existing, pairing }
    #if os(iOS)
        @State private var isScanning = false
        @State private var showsCodePairing = false
    #else
        @State private var showsCodePairing = true
    #endif

    var body: some View {
        VStack(spacing: 0) {
            switch screen {
            case .choice: choices
            case .existing: ExistingSparkSetupView(model: model)
            case .pairing: devicePairing
            }
        }
        .disabled(model.isPairingDevice)
        .navigationTitle(
            screen == .choice
                ? "Add Spark" : screen == .existing ? "Connect your Spark" : "Pair this device"
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") {
                    if screen == .choice { model.cancelChoosingSpark() } else { screen = .choice }
                }
                .disabled(model.isPairingDevice)
            }
        }
        .task { await model.detectExistingSparkConnection() }
        #if os(iOS)
            .sheet(isPresented: $isScanning) {
                NavigationStack {
                    PairingCodeScanner { scanned in
                        isScanning = false
                        Task { await model.pairThisDevice(payload: scanned) }
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan Pairing Invitation")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isScanning = false }
                        }
                    }
                }
            }
        #endif
    }

    private var choices: some View {
        List {
            Section {
                Button {
                    model.startAddingSpark()
                } label: {
                    Label("Set Up a New Spark", systemImage: "sparkles")
                        .padding(.vertical, 8)
                }
                .disabled(!model.canJoinSetupNetwork)
            } footer: {
                Text(
                    model.canJoinSetupNetwork
                        ? "For a new Spark showing its setup Wi-Fi network."
                        : "Use an iPhone or iPad for first-time setup."
                )
            }
            Section {
                Button {
                    screen = .existing
                } label: {
                    Label("Set up a Spark already in use", systemImage: "desktopcomputer")
                        .padding(.vertical, 8)
                }
                .accessibilityIdentifier("spark.setup.existing")
            } footer: {
                Text(
                    "Already on your home network? Spark Runtime is included in this app; no separate download is needed."
                )
            }
            Section {
                Button("Already using SparkPilot? Pair this device") {
                    screen = .pairing
                }
            }
        }
    }

    private var devicePairing: some View {
        List {
            Section {
                Text(
                    "Already using SparkPilot on another device? Open Add a Device there to create a pairing invitation."
                )
                .foregroundStyle(.secondary)
                #if os(iOS)
                    Button {
                        isScanning = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "qrcode.viewfinder")
                            Text("Pair with QR")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPairingDevice || !DataScannerViewController.isAvailable)
                    if !DataScannerViewController.isAvailable {
                        Text("Camera unavailable. Use the six-digit code below.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                #endif
                if model.isPairingDevice {
                    ProgressView(String(localized: "Verifying and pairing"))
                }
                if let error = model.pairingDeviceError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                DisclosureGroup(
                    String(localized: "Use a six-digit code"),
                    isExpanded: $showsCodePairing
                ) {
                    Text("Connect to the same network as your Spark, then choose it below.")
                        .font(.footnote).foregroundStyle(.secondary)
                    AddSparkDiscoveryResults(model: model)
                    DisclosureGroup(String(localized: "Enter an address manually")) {
                        manualAddress
                    }
                }
            }
            Section {
                DisclosureGroup(String(localized: "More ways to connect")) {
                    Button("Pair Several Sparks") { model.beginBatchPairingDevice() }
                }
            }
        }
        .disabled(model.isPairingDevice)
    }

    private var manualAddress: some View {
        Group {
            TextField("IP address or hostname", text: $existingSparkHost)
                .textContentType(.URL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
                .sparkField()
            Button("Continue with This Spark") {
                _ = model.chooseExistingSpark(host: existingSparkHost)
            }
            .disabled(existingSparkHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct BatchPairThisDeviceView: View {
    @Bindable var model: RetailOnboardingModel
    @State private var payload = ""
    #if os(iOS)
        @State private var isScanning = false
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Text("Pair Several Sparks")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "Show this request to an owner device, select the Sparks there, then scan or paste the returned package here."
                    )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }

                if let request = model.batchRecipientRequestPayload {
                    SparkPairingQRCode(payload: request)
                    DisclosureGroup(String(localized: "Copy request instead")) {
                        Text(request)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .privacySensitive()
                            .padding(.top, 8)
                    }
                }

                if let error = model.batchPairingError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let progress = model.batchPairingProgress {
                    VStack(spacing: 10) {
                        ForEach(progress.targets) { target in
                            HStack {
                                Image(systemName: batchPhaseIcon(target.phase))
                                    .foregroundStyle(batchPhaseColour(target.phase))
                                VStack(alignment: .leading) {
                                    Text(target.target.package.nodeName)
                                    if let message = target.lastError {
                                        Text(message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if target.phase == .failed {
                                    Button("Retry") {
                                        Task { await model.retryBatchPairing(nodeID: target.id) }
                                    }
                                    .disabled(model.isPairingDevice)
                                }
                            }
                            .padding(14)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                } else {
                    #if os(iOS)
                        Button {
                            isScanning = true
                        } label: {
                            Label("Scan Returned Package", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    #endif

                    TextField("Paste returned multi-Spark package", text: $payload, axis: .vertical)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        #endif
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...7)
                        .privacySensitive()

                    Button("Pair Selected Sparks") {
                        Task { await model.pairSeveralSparks(payload: payload) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(payload.isEmpty || model.isPairingDevice)
                }

                if model.isPairingDevice {
                    ProgressView(String(localized: "Pairing each Spark independently"))
                }
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        // The heading lives in the content; an inline empty bar title keeps it from rendering twice.
        .modifier(RetailOnboardingScrollEdge())
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(model.batchPairingProgress == nil ? "Back" : "Done") {
                    model.cancelBatchPairingDevice()
                }
                .disabled(model.isPairingDevice)
            }
        }
        #if os(iOS)
            .sheet(isPresented: $isScanning) {
                NavigationStack {
                    PairingCodeScanner(
                        acceptedRoutes: [BatchAdditionalDevicePairingPackage.route]
                    ) { scanned in
                        payload = scanned
                        isScanning = false
                        Task { await model.pairSeveralSparks(payload: scanned) }
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan Multi-Spark Package")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isScanning = false }
                        }
                    }
                }
            }
        #endif
    }

    private func batchPhaseIcon(_ phase: BatchPairingTargetPhase) -> String {
        switch phase {
        case .paired: "checkmark.circle.fill"
        case .failed, .revocationFailed: "exclamationmark.triangle.fill"
        case .revoked: "xmark.circle.fill"
        default: "clock"
        }
    }

    private func batchPhaseColour(_ phase: BatchPairingTargetPhase) -> Color {
        switch phase {
        case .paired: .green
        case .failed, .revocationFailed: .orange
        default: .secondary
        }
    }
}

struct PairThisDeviceView: View {
    @Bindable var model: RetailOnboardingModel
    @State private var joinCode = ""
    @State private var payload = ""
    @State private var lastAttempt: PairThisDeviceAttempt?
    #if os(iOS)
        @State private var isScanning = false
    #endif

    private var evidence: PairThisDeviceEvidence { .resolve(model.pairingDeviceTarget) }

    @ViewBuilder
    private func pairingError(at placement: PairThisDeviceErrorPlacement) -> some View {
        if let error = model.pairingDeviceError,
            PairThisDeviceErrorPlacement.resolve(lastAttempt) == placement
        {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                SparkProductArtwork(isConnected: evidence.showsConnectedArtwork)

                VStack(spacing: 8) {
                    Text("Pair This Device")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        """
                        On an iPhone or iPad that already manages this Spark, choose \
                        Add a Device and approve a pairing invitation.
                        """
                    )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }

                if let target = model.pairingDeviceTarget {
                    VStack(spacing: 6) {
                        Label(target.displayName, systemImage: "server.rack")
                            .font(.headline)
                        if evidence.saysNothingHasBeenChecked {
                            Text(
                                "Nothing has contacted this address yet. Pairing is the first thing that will try it."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                }

                pairingError(at: .aboveTheForm)

                #if os(iOS)
                    Button {
                        isScanning = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "qrcode.viewfinder")
                            Text("Pair with QR")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPairingDevice || !DataScannerViewController.isAvailable)
                #endif
                Text("Or enter the latest six-digit code from that device.")
                    .font(.callout).foregroundStyle(.secondary)

                TextField("6-digit join code", text: $joinCode)
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .privacySensitive()
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                    .onChange(of: joinCode) { _, value in
                        let normalized = String(
                            value.filter { $0.isASCII && $0.isNumber }.prefix(6)
                        )
                        if normalized != value { joinCode = normalized }
                    }
                    .sparkField()

                Button("Join This Spark") {
                    lastAttempt = .joinCode
                    Task {
                        await model.pairThisDevice(
                            joinCode: joinCode
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    joinCode.count != 6 || model.isPairingDevice
                )

                pairingError(at: .underJoinCode)

                DisclosureGroup(String(localized: "Paste an invitation instead")) {
                    VStack(spacing: 12) {
                        // QA-05: an invitation is a URL, so nothing here may capitalise or correct it.
                        TextField("Paste pairing invitation", text: $payload, axis: .vertical)
                            #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            #endif
                            .sparkField()
                            .lineLimit(2...5)
                            .privacySensitive()

                        Button("Pair with Invitation") {
                            lastAttempt = .invitation
                            Task { await model.pairThisDevice(payload: payload) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(payload.isEmpty || model.isPairingDevice)

                        pairingError(at: .underInvitation)
                    }
                    .padding(.top, 12)
                }

                Divider()
                    .padding(.vertical, 4)

                DisclosureGroup(String(localized: "Need to finish an earlier setup?")) {
                    Text(
                        String(
                            localized:
                                "If setup installed Spark features but pairing did not finish, resume it without resetting the Spark."
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    Button("Finish Interrupted Setup") {
                        model.finishInterruptedFirstOwnerSetup()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isPairingDevice)
                }

                if model.isPairingDevice {
                    ProgressView(String(localized: "Verifying and pairing"))
                }
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .modifier(RetailOnboardingScrollEdge())
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            if let pending = SparkWidgetNavigation.shared.takePendingPairingPayload() {
                payload = pending
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") { model.cancelPairingDevice() }
                    .disabled(model.isPairingDevice)
            }
        }
        #if os(iOS)
            .sheet(isPresented: $isScanning) {
                NavigationStack {
                    PairingCodeScanner { scanned in
                        payload = scanned
                        isScanning = false
                        lastAttempt = .invitation
                        Task { await model.pairThisDevice(payload: scanned) }
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan Pairing Invitation")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isScanning = false }
                        }
                    }
                }
            }
        #endif
    }
}

#if os(iOS)
    import UIKit
    import VisionKit

    struct PairingCodeScanner: UIViewControllerRepresentable {
        /// QA-04: match on the route, so a code minted under either the app's own scheme or the older unqualified one is read.
        var acceptedRoutes = [AdditionalDevicePairingPackage.route]
        let onPayload: (String) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(acceptedRoutes: acceptedRoutes, onPayload: onPayload)
        }

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])],
                qualityLevel: .balanced,
                recognizesMultipleItems: false,
                isHighFrameRateTrackingEnabled: false,
                isPinchToZoomEnabled: true,
                isGuidanceEnabled: true,
                isHighlightingEnabled: true
            )
            scanner.delegate = context.coordinator
            try? scanner.startScanning()
            return scanner
        }

        func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

        static func dismantleUIViewController(
            _ controller: DataScannerViewController,
            coordinator: Coordinator
        ) {
            controller.stopScanning()
        }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let acceptedRoutes: [String]
            let onPayload: (String) -> Void

            init(acceptedRoutes: [String], onPayload: @escaping (String) -> Void) {
                self.acceptedRoutes = acceptedRoutes
                self.onPayload = onPayload
            }

            func dataScanner(
                _ dataScanner: DataScannerViewController,
                didAdd addedItems: [RecognizedItem],
                allItems: [RecognizedItem]
            ) {
                for item in addedItems {
                    guard case .barcode(let barcode) = item,
                        let payload = barcode.payloadStringValue,
                        acceptedRoutes.contains(where: {
                            PairingLinkScheme.carries(payload, route: $0)
                        })
                    else { continue }
                    onPayload(payload)
                    return
                }
            }
        }
    }
#endif
