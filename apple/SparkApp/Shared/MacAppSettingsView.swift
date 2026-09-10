#if os(macOS)
    import AppKit
    import Network
    import SparkAPI
    import SparkCore
    import SparkDesignSystem
    import SparkDiscovery
    import SparkLibrary
    import SparkProjects
    import SparkSecurity
    import SwiftUI

    @MainActor
    struct MacAppSettingsView: View {
        @AppStorage(SparkEngineeringMode.preferenceKey) private var engineeringMode = false
        let onboarding: RetailOnboardingModel
        let appLock: AppLockModel
        let buildWorker: BuildWorkerSettingsModel
        let notifications: SparkNotificationModel
        let spotlight: SparkSpotlightModel
        let chat: SparkChatModel
        let onOpenSpark: (String) -> Void
        @State private var executionPolicy = SparkExecutionPolicyModel()

        var body: some View {
            List {
                Section("Help") { SparkBugFeedbackLink() }
                #if DEBUG
                    NavigationLink("Family flow preview") { SparkFamilyPreview() }
                    if engineeringMode {
                        NavigationLink("Development preview") { SparkDevelopmentPreview() }
                    }
                #endif
                Section("Engineering") { SparkEngineeringModeToggle(library: onboarding.library) }
                Section("App") {
                    NavigationLink {
                        SparkAppleAppsView(chat: chat)
                    } label: {
                        Label("Siri & Apple Apps", systemImage: "sparkles")
                    }
                    NavigationLink {
                        SparkChatSettingsView()
                    } label: {
                        Label("Chat", systemImage: "text.bubble")
                    }
                    NavigationLink {
                        AppLockSettingsView(model: appLock)
                    } label: {
                        Label {
                            LabeledContent("App lock", value: appLock.isEnabled ? "On" : "Off")
                        } icon: {
                            Image(systemName: "lock")
                        }
                    }
                    NavigationLink {
                        SparkLocalEngineInventoryView()
                    } label: {
                        Label("Models on this Mac", systemImage: "desktopcomputer")
                    }
                    NavigationLink {
                        BuildWorkerSettingsView(model: buildWorker)
                    } label: {
                        Label {
                            LabeledContent("Build worker", value: buildWorker.phaseText)
                        } icon: {
                            Image(systemName: "hammer")
                        }
                    }
                    NavigationLink {
                        SparkExecutionPolicyView(model: executionPolicy)
                    } label: {
                        Label {
                            LabeledContent("AI execution", value: executionPolicy.choice.title)
                        } icon: {
                            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        }
                    }
                    NavigationLink {
                        SparkNotificationSettingsView(model: notifications)
                    } label: {
                        Label {
                            LabeledContent(
                                "Notifications",
                                value: notifications.isEnabled
                                    ? String(localized: "On") : String(localized: "Off")
                            )
                        } icon: {
                            Image(systemName: "bell")
                        }
                    }
                    NavigationLink {
                        SparkSpotlightSettingsView(model: spotlight)
                    } label: {
                        Label {
                            LabeledContent(
                                "Spotlight",
                                value: spotlight.isEnabled
                                    ? String(localized: "On") : String(localized: "Off")
                            )
                        } icon: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
                if let settings = onboarding.settingsModel {
                    Section(onboarding.identitySettingsModel?.displayName ?? "Spark") {
                        SparkSettingsGroupRows(
                            context: SparkSettingsContext(
                                settings: settings,
                                networkStatus: onboarding.networkStatusModel,
                                remoteAccess: onboarding.remoteAccessModel
                            ),
                            style: .list
                        )
                        if let devices = onboarding.deviceManagementModel {
                            NavigationLink {
                                DeviceManagementView(model: devices)
                            } label: {
                                Label(
                                    "Paired devices",
                                    systemImage: "laptopcomputer.and.iphone"
                                )
                            }
                        }
                    }
                } else if onboarding.networkStatusModel != nil
                    || onboarding.remoteAccessModel != nil
                {
                    // Keep network pages available on runtimes without appliance-settings support.
                    Section("Network") {
                        if let network = onboarding.networkStatusModel {
                            NavigationLink {
                                SparkNetworkStatusView(model: network)
                            } label: {
                                Label("Network status", systemImage: "network")
                            }
                        }
                        if let remote = onboarding.remoteAccessModel {
                            NavigationLink {
                                RemoteAccessSettingsView(model: remote)
                            } label: {
                                Label(
                                    "Remote access",
                                    systemImage: "network.badge.shield.half.filled"
                                )
                            }
                        }
                    }
                } else if !onboarding.library.entries.isEmpty {
                    // Offer to open a Spark directly when no settings target is active.
                    Section {
                        ForEach(onboarding.library.entries) { entry in
                            Button {
                                onOpenSpark(entry.id)
                            } label: {
                                Label(entry.displayName, systemImage: "server.rack")
                            }
                        }
                    } header: {
                        Text("Your Sparks")
                    } footer: {
                        Text(
                            "Open a Spark to configure its network, hardware, updates, storage and paired devices."
                        )
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
#endif
