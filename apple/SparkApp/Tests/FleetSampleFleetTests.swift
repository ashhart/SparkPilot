import Foundation
import SparkLibrary
import Testing

@testable import SparkAppComposition

// Proves the debug sample fleet is only ever reachable through its launch argument, and that it decodes.

@Test func theSampleFleetOnlyAnswersItsOwnLaunchArgument() {
    #expect(FleetSampleFleet.requested([]) == nil)
    #expect(FleetSampleFleet.requested(["--spark-sample-fleet"]) == nil)
    #expect(FleetSampleFleet.requested(["--spark-sample-fleet=0"]) == .fleet(size: 0))
    #expect(FleetSampleFleet.requested(["--spark-sample-fleet=9"]) == nil)
    #expect(FleetSampleFleet.requested(["--spark-sample-fleet=x"]) == nil)
    #expect(FleetSampleFleet.requested(["--spark-sample-fleet=1"]) == .fleet(size: 1))
    #expect(FleetSampleFleet.requested(["-other", "--spark-sample-fleet=3"]) == .fleet(size: 3))
    #expect(FleetSampleFleet.requested(["--spark-sample-fleet=idle"]) == .one(.idle))
    #expect(FleetSampleFleet.requested(["--spark-sample-fleet=loading"]) == .one(.loading))
    #expect(FleetSampleFleet.requested(["--spark-sample-fleet=running"]) == .one(.running))
}

@MainActor
@Test func eachNamedStateGivesOneSparkAndItsOwnModelAction() throws {
    func action(_ value: String) throws -> FleetHomeModelAction {
        let library = try #require(FleetSampleFleet.library(["--spark-sample-fleet=\(value)"]))
        let home = FleetModel(library: library).home
        #expect(home.mode == .single)
        #expect(home.sparks.count == 1)
        return try #require(home.sparks.first).action
    }

    #expect(try action("idle") == .launch)
    #expect(try action("running") == .switchModel)
    guard case .loading = try action("loading") else {
        Issue.record("the loading sample should offer the loading line, not a button")
        return
    }
}

@MainActor
@Test func oneSampleSparkComposesTheSingleSparkHome() throws {
    let library = try #require(FleetSampleFleet.library(["--spark-sample-fleet=1"]))
    let home = FleetModel(library: library).home

    #expect(home.mode == .single)
    #expect(home.rollUp.count == 4)
    let card = try #require(home.sparks.first)
    #expect(card.name == "Example Spark")
    #expect(card.connection.value == "On your network")
    #expect(card.action == .switchModel)
    #expect(card.metrics.map(\.key.reading) == [.model, .memory, .temperature])
    #expect(card.metrics.first?.value == "Nemotron 3.5 Lightning 30B")
    #expect(card.metrics.first?.detail?.contains("258.3") == true)
    #expect(card.metrics.last?.value == "38°C")
}

@MainActor
@Test func threeSampleSparksComposeAFleetHomeWithMixedStates() throws {
    let library = try #require(FleetSampleFleet.library(["--spark-sample-fleet=3"]))
    let home = FleetModel(library: library).home

    #expect(home.mode == .fleet)
    #expect(home.sparks.count == 3)
    // BH-49: with a Spark offline the Connectivity card carries the reading, not a tile too.
    #expect(home.rollUp.contains { $0.key.reading == .online })
    #expect(home.unreachableSparkNames == ["Loft Spark"])
    #expect(home.fleetCards.contains(.connectivity))
    #expect(home.fleetCards.contains(.loadedModels))
    let starting = try #require(home.sparks.first { $0.name == "Studio Spark" })
    guard case .loading(let line, let fraction) = starting.action else {
        Issue.record("The starting sample Spark should be shown loading: \(starting.action)")
        return
    }
    #expect(line.contains("Compact 8B"))
    #expect(fraction == 0.62)
}

@MainActor
@Test func aSampleFleetKeepsReadingAsLiveAfterItsHeartbeat() throws {
    let library = try #require(FleetSampleFleet.library(["--spark-sample-fleet=1"]))
    let later = Date().addingTimeInterval(600)
    FleetSampleFleet.restamp(library, at: later)
    let home = FleetModel(library: library, now: { later }).home

    #expect(try #require(home.sparks.first).connection.value == "On your network")
}

@MainActor
@Test func noSampleFleetWithoutTheArgument() {
    #expect(FleetSampleFleet.library([]) == nil)
}

@MainActor
@Test func theSampleSurvivesTheLoadThatDowngradesSavedCards() throws {
    let library = try #require(FleetSampleFleet.library(["--spark-sample-fleet=1"]))
    library.load()
    #expect(
        FleetModel(library: library).home.sparks.first?.connection.value
            == "Offline · showing saved state"
    )

    FleetSampleFleet.restamp(library, at: Date())

    let card = try #require(FleetModel(library: library).home.sparks.first)
    #expect(card.connection.value == "On your network")
    #expect(card.action == .switchModel)
}

@MainActor
@Test func aSampleFleetComesBackOnlineAfterTheLoadToo() throws {
    let library = try #require(FleetSampleFleet.library(["--spark-sample-fleet=3"]))
    library.load()
    FleetSampleFleet.restamp(library, at: Date())

    let home = FleetModel(library: library).home
    #expect(home.rollUp.contains { $0.key.reading == .online })
    #expect(home.fleetCards.contains(.connectivity))
    #expect(home.unreachableSparkNames == ["Loft Spark"])
}

@MainActor
@Test func theSampleFleetIsReachedBothWaysSoBothPathsCanBeSeen() throws {
    let library = try #require(FleetSampleFleet.library(["--spark-sample-fleet=3"]))
    let home = FleetModel(library: library).home

    let local = try #require(home.sparks.first { $0.name == "Example Spark" })
    #expect(local.connection.value == "On your network")
    let remote = try #require(home.sparks.first { $0.name == "Studio Spark" })
    #expect(remote.connection.value == "Over Tailscale · spark-4c02.tail1234.ts.net")
    #expect(remote.connection.symbol == "lock.shield.fill")
}

@MainActor
@Test func theSampleSparkThatIsNotAnsweringSaysWhenItLastDid() throws {
    let library = try #require(FleetSampleFleet.library(["--spark-sample-fleet=3"]))
    let home = FleetModel(library: library).home

    let quiet = try #require(home.sparks.first { $0.name == "Loft Spark" })
    #expect(quiet.connection.value == "Offline · showing saved state")
    #expect(quiet.freshness == "Latest reading 2 hours ago")
    let serving = try #require(home.sparks.first { $0.name == "Example Spark" })
    #expect(serving.freshness == "Latest reading just now")
}
