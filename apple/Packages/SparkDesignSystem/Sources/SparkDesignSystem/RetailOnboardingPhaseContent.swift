import SwiftUI

extension RetailOnboardingView {
    @ViewBuilder
    var phaseContent: some View {
        let screen = RetailOnboardingScreen(
            phase: state.phase,
            canJoinSetupNetwork: canJoinSetupNetwork,
            canScanQuickStartCode: canScanQuickStartCode
        )
        VStack(spacing: 22) {
            phaseArtwork(screen: screen)

            VStack(spacing: 10) {
                Text(screen.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(screen.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if state.phase == .connectToSpark, canJoinSetupNetwork {
                if let detectedSetupSSID {
                    detectedNetworkRow(detectedSetupSSID)
                }
                if isShowingManualSetupDetails {
                    RetailSetupNetworkFields(
                        setupSSID: $setupSSID,
                        setupPassphrase: $setupPassphrase,
                        isSetupPasswordVisible: $isSetupPasswordVisible,
                        canScanQuickStartCode: canScanQuickStartCode,
                        detectedSetupSSID: detectedSetupSSID
                    )
                }
            }

            if state.phase == .runtimeInstall {
                if !isRuntimeInstalling {
                    RetailAdministratorCredentials(
                        administratorUsername: $administratorUsername,
                        administratorPassword: $administratorPassword,
                        isAdministratorPasswordVisible: $isAdministratorPasswordVisible
                    )
                }
                preparationList(runtimePreparation)
            }

            if state.phase == .starterModel {
                preparationList(
                    aiPreparation.filter {
                        ["runtime-health", "vllm", "catalogue"].contains($0.id)
                    }
                )
                if !isCheckingAIServices,
                    !RetailPreparationItem.requiredServicesAreReady(aiPreparation)
                {
                    Text(
                        "Your Spark is paired, but a required check needs attention. Check the connection and choose Check Again."
                    )
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: 440)
                }
                DisclosureGroup(String(localized: "Optional: voice and web access")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "You can start with text chat and add these later from Chats. Web access lets your Spark look up information online."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                        if let onVoiceSetup { Button("Set up voice", action: onVoiceSetup) }
                        if let onWebSetup { Button("Set up web access", action: onWebSetup) }
                    }
                }
                .frame(maxWidth: 440)
                DisclosureGroup(String(localized: "Optional: name your Spark")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name, such as Family Spark", text: $customLabel)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("spark.setup.name")
                        Text(
                            "Leave this blank to keep its current name. Up to 120 characters, saved only on this Apple device; you can change it later in Spark settings."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 440)
            }

            if state.phase == .reconnecting, sparkSetupNetworkStillActive {
                VStack(spacing: 12) {
                    Label(
                        "The Spark setup Wi-Fi is still active",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    Text(
                        "The Spark has not moved to your chosen Wi-Fi. Check the network and password, then try again."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    Button("Retry Wi-Fi details", action: onRetrySparkWiFi)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .frame(maxWidth: 440)
            }

            if isWaitingPhase {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel(screen.title)
                if state.phase == .rediscovering, let rediscovery {
                    RetailRediscoveryWait(progress: rediscovery, onLookAgain: onLookAgain)
                }
                if state.phase == .sparkRestarting, let restart {
                    RetailRestartWait(
                        progress: restart,
                        isChecking: isCheckingRestart,
                        detail: restartCheckDetail,
                        onSparkIsBack: onSparkIsBack
                    )
                }
            }

        }
    }

}
