import Foundation
import SparkBootstrap
import SparkCore
import Testing

@testable import SparkAppComposition

/// Checks owner-facing closure copy while the localisation matrix independently verifies catalogue routing.
private func readableCopy(_ text: String, _ what: String) {
    #expect(!text.isEmpty, "\(what) says nothing")
    #expect(text.trimmingCharacters(in: .whitespaces) == text, "\(what) is padded")
    #expect(!text.contains("_"), "\(what) shows an identifier")
    #expect(!text.contains("://"), "\(what) shows a route")
}

// MARK: - Library cards

@Test func everyLibraryConnectionStateSaysHowTheSparkIsReached() {
    let states: [SparkConnectionState] = [
        .discovering, .foundUnpaired, .connecting, .connectedWiFi, .connectedDirect,
        .connectedRemote, .offlineCached, .identityMismatch, .updateRequired,
    ]
    var labels: Set<String> = []
    for state in states {
        let presentation = LibraryConnectionPresentation.resolve(state)
        readableCopy(presentation.label, "library \(state)")
        #expect(!presentation.symbol.isEmpty)
        labels.insert(presentation.label)
    }
    #expect(labels.count == states.count, "two library states read the same")
    // The card tints its label green only when the Spark is actually reachable.
    #expect(LibraryConnectionPresentation.resolve(.connectedDirect).isOnline)
    #expect(!LibraryConnectionPresentation.resolve(.offlineCached).isOnline)
}

// MARK: - Install preflight

/// Names installed paths, units and ports within localised disclosure sentences.
@Test func thePreflightNamesWhatItAddsAndPromisesWhatItLeaves() {
    let presentation = ExistingSparkPreflightPresentation(checkFailed: false)
    #expect(presentation.willAdd.isEmpty, "a failed check has no install to describe")

    // The §10.2 fixture: a Spark that is already running something.
    let described = ExistingSparkPreflightPresentation(
        preflight: HostPreflight(
            survey: HostSurvey.parse(
                """
                survey=1
                os=DGX OS 7.2 (Ubuntu 24.04)
                runtime_package=absent
                path_package=none
                unit_sparkd=absent
                unit_privd=absent
                state_dir=absent
                install_dir=absent
                disk=1921802240,1402398720
                memory_kb=131728896
                services=48
                listening=22,30000
                containers=1
                container=deepseek-serve lmsysorg/sglang:v0.4.1
                netplan=2
                """
            )
        )
    )
    #expect(described.willAdd.count == 4, "step 7 no longer names four things")
    for line in described.willAdd {
        readableCopy(line, "willAdd line")
    }
    // Show workload-preservation promises only when workloads exist.
    let assurance = try! #require(described.workloadAssurance)
    readableCopy(assurance, "workload assurance")
    #expect(assurance.contains("never"), "the promise does not say what it will not do")

    #expect(described.continueTitle != nil)
    readableCopy(try! #require(described.continueTitle), "install action")
}

// MARK: - Telemetry

/// Expected readings must display a waiting state rather than a zero that implies measurement.
@Test func everyTelemetryReadingSaysWhenItHasNoValueYet() {
    let readings: [(String, String)] = [
        ("gpu memory", SparkTelemetryPresentation.gpuMemory(nil)),
        ("usage", SparkTelemetryPresentation.usage(nil)),
        ("uptime", SparkTelemetryPresentation.uptime(nil)),
        ("unified memory", SparkTelemetryPresentation.unifiedMemoryDetail(nil)),
        ("inference", SparkTelemetryPresentation.inferenceDetail(nil)),
        ("usage detail", SparkTelemetryPresentation.usageDetail(nil)),
    ]
    for (name, text) in readings {
        readableCopy(text, "\(name) with no telemetry")
        #expect(text != "0", "\(name) shows a zero it did not measure")
    }
}

// MARK: - Power controls

@Test func bothPowerActionsSayWhatTheyDoToTheSpark() {
    let reboot = SparkPowerControlsPresentation.action(.reboot)
    let shutdown = SparkPowerControlsPresentation.action(.shutdown)
    for (name, action) in [("reboot", reboot), ("shutdown", shutdown)] {
        readableCopy(action.title, "\(name) title")
        readableCopy(action.subtitle, "\(name) subtitle")
        #expect(action.title != action.subtitle)
    }
    #expect(reboot.title != shutdown.title, "the two power actions read the same")
    #expect(reboot.subtitle != shutdown.subtitle)
}

// MARK: - First-run setup failures

/// Setup failure copy must not display response bodies from the unpaired temporary network.
@MainActor
@Test func everySetupFailureResolvesOwnerCopyRatherThanTheResponseBody() {
    let body = "SPARK_TEST_DIAGNOSTIC <html>500 nginx</html> token sk-live-4f3a"
    let failures: [(String, SparkOOBEClientError)] = [
        ("server", .server(statusCode: 500, diagnosticDetail: body)),
        ("firmware", .firmwareUpdateFailed),
        ("timeout", .updateTimedOut),
        ("invalid", .invalidResponse),
        ("decoding", .decoding(body)),
    ]
    var messages: Set<String> = []
    for (name, error) in failures {
        let message = NativeSparkSetupModel.describe(error)
        readableCopy(message, "setup failure \(name)")
        #expect(!message.contains("SPARK_TEST_DIAGNOSTIC"), "\(name) repeats the body")
        #expect(!message.contains("sk-live-4f3a"), "\(name) repeats a token from the body")
        #expect(!message.contains("nginx"), "\(name) repeats the server's own words")
        messages.insert(message)
    }
    // Group unreadable responses consistently while preserving distinct actionable failure types.
    #expect(messages.count == 4, "two setup failures that need different actions read the same")
}

// MARK: - Spotlight

/// Both node and cluster Spotlight titles must resolve through the catalogue.
@Test func bothSpotlightTitlesResolveFromTheCatalogue() {
    let cluster = String(localized: "DGX Spark cluster")
    let standalone = String(localized: "DGX Spark")
    #expect(cluster != standalone, "a cluster and a single Spark are indexed alike")
    #expect(cluster.contains(standalone), "the cluster title stopped naming the product")
    for title in [cluster, standalone] {
        readableCopy(title, "spotlight title")
    }
}
