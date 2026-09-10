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
    struct MacSparkHomeView: View {
        let discovery: SparkDiscoveryService
        var onOpen: @MainActor (DiscoveredSpark) -> Void

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sparks Nearby")
                            .font(.largeTitle.bold())
                        Text(
                            "Spark Discovery is looking for runtime services on connected local networks. Discovery runs only while this window is open."
                        )
                        .foregroundStyle(.secondary)
                    }

                    if discovery.nodes.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 300), spacing: 16)],
                            spacing: 16
                        ) {
                            ForEach(discovery.nodes) { node in
                                Button {
                                    onOpen(node)
                                } label: {
                                    MacDiscoveredSparkCard(node: node)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxWidth: 1_100, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle("Sparks Nearby")
            .toolbar {
                Button("Look Again", systemImage: "arrow.clockwise") {
                    discovery.stop()
                    discovery.start()
                }
            }
            .onAppear {
                discovery.start()
            }
            // Stop Bonjour browsing when the discovery sheet closes.
            .onDisappear {
                discovery.stop()
            }
        }

        @ViewBuilder
        private var emptyState: some View {
            switch discovery.permissionState {
            case .notDetermined:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Looking for your Spark")
                        .font(.headline)
                    Text("Checking Ethernet and nearby networks.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            case .granted:
                ContentUnavailableView(
                    "No Spark Found",
                    systemImage: "network.slash",
                    description: Text(
                        "Check that your Spark is powered on and connected by Ethernet or to the same network."
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            case .denied:
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Local Network Access Is Off",
                        systemImage: "lock",
                        description: Text(
                            "Allow local network access in System Settings so Spark can find your hardware."
                        )
                    )
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(
                            URL(fileURLWithPath: "/System/Applications/System Settings.app")
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            case .restricted:
                ContentUnavailableView(
                    "Local Network Access Is Restricted",
                    systemImage: "exclamationmark.shield",
                    description: Text("A system policy is preventing local discovery.")
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
    }

    private struct MacDiscoveredSparkCard: View {
        let node: DiscoveredSpark

        private var presentation: MacDiscoveredSparkPresentation {
            MacDiscoveredSparkPresentation(
                name: node.displayName,
                interfaceKind: SparkInterfaceKind(interface: node.interface)
            )
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    SparkProductMark(size: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(presentation.name)
                            .font(.title3.weight(.semibold))
                        Label(
                            presentation.connectionLabel,
                            systemImage: presentation.connectionSymbol
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Label("Found", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }

                Text(
                    """
                    Spark Runtime is advertising on this connection. Pairing verifies \
                    its identity before this device can manage it.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain)
        }
    }

    struct MacPlaceholderView: View {
        let title: String
        let message: String
        let symbol: String

        var body: some View {
            ContentUnavailableView(title, systemImage: symbol, description: Text(message))
                .navigationTitle(title)
        }
    }
#endif
