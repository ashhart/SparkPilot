import Foundation
import SparkAPI
import SparkLibrary
import Testing
@testable import SparkAppComposition

@MainActor
private final class PreparerClock {
    var now = Date(timeIntervalSince1970: 1_788_000_000)
}

@MainActor
@Test func aSparkIsAskedToPrepareOnceUntilTheRepeatIntervalPasses() async {
    let clock = PreparerClock()
    var asked: [String] = []
    let preparer = SparkDevelopmentPreparer(now: { clock.now }, perform: { _, id in
        asked.append(id)
        return GeneratedAPI.DevelopmentPreparation(
            status: .preparing,
            imageReady: false,
            harnessReady: true
        )
    })
    let library = SparkLibrary(store: MemoryLibraryStore())
    let first = await preparer.prepare(library: library, targetID: "spark-1")
    #expect(first?.status == .preparing)
    let second = await preparer.prepare(library: library, targetID: "spark-1")
    #expect(second?.status == .preparing)
    #expect(asked == ["spark-1"])

    _ = await preparer.prepare(library: library, targetID: "spark-1", force: true)
    #expect(asked.count == 2)

    clock.now = clock.now.addingTimeInterval(SparkDevelopmentPreparer.repeatInterval)
    _ = await preparer.prepare(library: library, targetID: "spark-1")
    #expect(asked.count == 3)
}

@MainActor
@Test func aSparkThatCouldNotBeAskedIsAskedAgainNextTime() async {
    var attempts = 0
    let preparer = SparkDevelopmentPreparer(perform: { _, _ in
        attempts += 1
        if attempts == 1 { throw APIError(.local(message: "offline")) }
        return GeneratedAPI.DevelopmentPreparation(
            status: .ready,
            imageReady: true,
            harnessReady: true
        )
    })
    let library = SparkLibrary(store: MemoryLibraryStore())
    let unanswered = await preparer.prepare(library: library, targetID: "spark-1")
    #expect(unanswered == nil)
    let answered = await preparer.prepare(library: library, targetID: "spark-1")
    #expect(answered?.status == .ready)
    #expect(attempts == 2)
}

@MainActor
@Test func aSparkWithoutTheCapabilityIsNotRememberedAsPrepared() async {
    let preparer = SparkDevelopmentPreparer(perform: { _, _ in nil })
    let library = SparkLibrary(store: MemoryLibraryStore())
    let answer = await preparer.prepare(library: library, targetID: "spark-1")
    #expect(answer == nil)
    #expect(preparer.statuses.isEmpty)
}
