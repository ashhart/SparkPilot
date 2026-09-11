import SwiftUI
import SparkDesignSystem

#if os(iOS)
    @MainActor
    struct AppleSparkSettingsView: View {
        @AppStorage(SparkEngineeringMode.preferenceKey) private var engineeringMode = false
        let model: RetailOnboardingModel
        let chat: SparkChatModel
        let appLock: AppLockModel
        let executionPolicy: SparkExecutionPolicyModel
        let notifications: SparkNotificationModel
        let spotlight: SparkSpotlightModel
        let onOpenSpark: (String) -> Void

        var body: some View {
            List {
                Section {
                    NavigationLink {
                        SparkAppleAppsView(chat: chat)
                    } label: {
                        SparkNavigationLabel(
                            title: String(localized: "Siri & Apple Apps"),
                            systemImage: "sparkles"
                        )
                    }
                    NavigationLink {
                        SparkAudioSettingsView(chat: chat)
                    } label: {
                        SparkNavigationLabel(
                            title: String(localized: "Audio"),
                            systemImage: "speaker.wave.2"
                        )
                    }
                    NavigationLink {
                        SparkChatSettingsView()
                    } label: {
                        SparkNavigationLabel(
                            title: String(localized: "Chat"),
                            systemImage: "text.bubble"
                        )
                    }
                } header: {
                    Text("Apple integration").foregroundStyle(Color.primary)
                }
                Section {
                    NavigationLink {
                        AppLockSettingsView(model: appLock)
                    } label: {
                        LabeledContent {
                            Text(appLock.isEnabled ? "On" : "Off").foregroundStyle(Color.primary)
                        } label: {
                            SparkNavigationLabel(
                                title: String(localized: "App lock"),
                                systemImage: "lock"
                            )
                        }
                    }
                    NavigationLink {
                        SparkExecutionPolicyView(model: executionPolicy)
                    } label: {
                        LabeledContent {
                            Text(executionPolicy.choice.title).foregroundStyle(Color.primary)
                        } label: {
                            SparkNavigationLabel(
                                title: String(localized: "AI execution"),
                                systemImage: "point.3.filled.connected.trianglepath.dotted"
                            )
                        }
                    }
                    NavigationLink {
                        SparkNotificationSettingsView(model: notifications)
                    } label: {
                        LabeledContent {
                            Text(notifications.isEnabled ? "On" : "Off").foregroundStyle(
                                Color.primary
                            )
                        } label: {
                            SparkNavigationLabel(
                                title: String(localized: "Notifications"),
                                systemImage: "bell"
                            )
                        }
                    }
                    NavigationLink {
                        SparkSpotlightSettingsView(model: spotlight)
                    } label: {
                        LabeledContent {
                            Text(spotlight.isEnabled ? "On" : "Off").foregroundStyle(Color.primary)
                        } label: {
                            SparkNavigationLabel(
                                title: String(localized: "Spotlight"),
                                systemImage: "magnifyingglass"
                            )
                        }
                    }
                } header: {
                    Text("Security").foregroundStyle(Color.primary)
                }

                if let settings = model.settingsModel {
                    // Present the opened Spark with the same settings destinations offered by its dashboard.
                    Section(model.identitySettingsModel?.displayName ?? "Spark") {
                        SparkSettingsGroupRows(
                            context: SparkSettingsContext(
                                settings: settings,
                                networkStatus: model.networkStatusModel,
                                remoteAccess: model.remoteAccessModel
                            ),
                            style: .list
                        )
                        if let devices = model.deviceManagementModel {
                            NavigationLink {
                                DeviceManagementView(model: devices)
                            } label: {
                                Label("Paired devices", systemImage: "laptopcomputer.and.iphone")
                            }
                        }
                        SharedAccessSettingsRows(model: model)
                    }
                } else if model.networkStatusModel != nil || model.remoteAccessModel != nil {
                    // Keep network pages available on runtimes without appliance-settings support.
                    Section("Network") {
                        if let network = model.networkStatusModel {
                            NavigationLink {
                                SparkNetworkStatusView(model: network)
                            } label: {
                                Label("Network status", systemImage: "network")
                            }
                        }
                        if let remote = model.remoteAccessModel {
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
                } else if !model.library.entries.isEmpty {
                    // Offer to open a Spark when its settings require an active dashboard.
                    Section {
                        ForEach(model.library.entries) { entry in
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

                Section("Engineering") { SparkEngineeringModeToggle(library: model.library) }
                Section {
                    SparkBugFeedbackLink()
                    SparkAboutLink()
                    #if DEBUG
                        NavigationLink("Family flow preview") { SparkFamilyPreview() }
                        if engineeringMode {
                            NavigationLink("Development preview") { SparkDevelopmentPreview() }
                        }
                    #endif
                    if let diagnostics = model.diagnosticsExportModel {
                        NavigationLink {
                            DiagnosticsExportView(model: diagnostics)
                        } label: {
                            Label("Support bundle", systemImage: "stethoscope")
                        }
                    }
                } header: {
                    Text("Support").foregroundStyle(Color.primary)
                }
            }
            .navigationTitle("Settings")
        }

    }
#endif
