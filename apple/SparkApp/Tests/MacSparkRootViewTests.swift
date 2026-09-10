#if os(macOS)
    import SparkDiscovery
    import Testing
    @testable import SparkAppComposition

    @Test func macDiscoveryPresentsWiredSparkAsDirectConnection() {
        let presentation = MacDiscoveredSparkPresentation(
            name: "spark-a1b2",
            interfaceKind: .wiredEthernet
        )

        #expect(presentation.name == "spark-a1b2")
        #expect(presentation.connectionLabel == "Direct connection")
        #expect(presentation.connectionSymbol == "cable.connector")
    }

    @Test func macDiscoveryPresentsWiFiSparkAsLocalWiFi() {
        let presentation = MacDiscoveredSparkPresentation(
            name: "spark-c3d4",
            interfaceKind: .wifi
        )

        #expect(presentation.connectionLabel == "Local Wi-Fi")
        #expect(presentation.connectionSymbol == "wifi")
    }

    @Test func macSidebarRoutesTheFormerActivitySlotToWorkloads() {
        #expect(MacSidebarItem.activity.title == "Workloads")
        #expect(MacSidebarItem.activity.symbol == "tablecells")
        #expect(
            MacSidebarItem.allCases
                == [.home, .chats, .projects, .launch, .models, .clusters, .activity, .settings]
        )
    }

    @Test func launcherHasItsOwnSidebarDestination() {
        #expect(MacSidebarItem.launch.title == "Launch")
        #expect(MacSidebarItem.launch.symbol == "paperplane")
    }

    @Test func macHomeRendersFleetUntilTheOwnerOpensADashboard() {
        #expect(MacRootPresentationPlan.homeDestination(hasDashboard: false) == .fleet)
        #expect(MacRootPresentationPlan.homeDestination(hasDashboard: true) == .dashboard)
    }

    @Test func changingSidebarSectionPopsItsNestedDetail() {
        #expect(
            MacRootPresentationPlan.shouldResetDetailPath(from: .settings, to: .home)
        )
        #expect(
            !MacRootPresentationPlan.shouldResetDetailPath(from: .settings, to: .settings)
        )
    }

#endif
