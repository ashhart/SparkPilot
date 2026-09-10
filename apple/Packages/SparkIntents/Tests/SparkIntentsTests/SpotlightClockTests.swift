import Foundation
import Testing
@testable import SparkIntents

@Test func legacySpotlightInitializerRetainsItsDomainFunctionType() {
    let initializer: (String) -> SparkSpotlightIndexer =
        SparkSpotlightIndexer.init(domainIdentifier:)
    _ = initializer
}

@Test func spotlightUsesInjectedContentCreationTime() {
    let indexedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let indexer = SparkSpotlightIndexer(now: { indexedAt })
    let item = indexer.searchableItem(
        for: SparkSpotlightIndexer.nodeRecord(id: "node-1", name: "Studio Spark")
    )

    #expect(item.attributeSet.contentCreationDate == indexedAt)
}

// MARK: - §40.8 / ADR-017: the prompt-body rule has to be structural

@Test func aConversationRecordCannotBeBuiltCarryingItsPromptBody() {
    // Keep conversation record construction unable to accept body content.
    let record = SparkSpotlightIndexer.conversationRecord(
        id: "c1",
        title: "Kitchen renovation plan"
    )
    let conversation = try? #require(record)
    #expect(conversation?.title == "Kitchen renovation plan")
    #expect(conversation?.description == nil)
    #expect(conversation?.keywords.isEmpty == true)
}

@Test func aProjectMayCarryItsDescriptionBecauseTheSpecAllowsIt() {
    // Allow project descriptions through their domain-specific factory without broadening conversation metadata (§40.8).
    let project = SparkSpotlightIndexer.projectRecord(
        id: "p1",
        name: "Atlas",
        summary: "Rewrite the ingest pipeline"
    )
    #expect(project.title == "Atlas")
    #expect(project.description == "Rewrite the ingest pipeline")
}

@Test func anUntitledConversationIsNotIndexedAtAll() {
    // No title means the only thing left to index would be content.
    #expect(SparkSpotlightIndexer.conversationRecord(id: "c1", title: nil) == nil)
    #expect(SparkSpotlightIndexer.conversationRecord(id: "c1", title: "  ") == nil)
}

@Test func anIndexedItemAttributesItselfToTheApp() {
    // Include explicit app attribution rather than relying on the index domain identifier (§40.8).
    let indexer = SparkSpotlightIndexer()
    let item = indexer.searchableItem(
        for: SparkSpotlightIndexer.modelRecord(id: "m1", name: "Llama 70B")
    )
    #expect(item.attributeSet.displayName?.isEmpty == false)
    #expect(item.domainIdentifier == SparkSpotlightIndexer.Domain.identifier)
}
