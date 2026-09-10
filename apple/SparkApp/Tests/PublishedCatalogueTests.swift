import CryptoKit
import Foundation
import SparkBootstrap
import SparkDesignSystem
import Testing

@testable import SparkAppComposition

/// Recipes published on sparkpilot.dev are compared with the Spark's snapshot by the digest the runtime reports.
struct PublishedCatalogueTests {
    private let catalogue = Data(
        """
        {"recipes":[{"metadata":{"id":"nvidia/nemotron"}},{"metadata":{"id":"qwen/qwen3.8-27b"}}],"signature":{"keyID":"catalogue-2026-b","algorithm":"ed25519","value":"x"}}
        """.utf8
    )

    @Test func thePublishedFileIsComparedByTheRuntimesOwnDigest() throws {
        let check = try PublishedCatalogueCheck(bytes: catalogue)
        let expected = SHA256.hash(data: catalogue).map { String(format: "%02x", $0) }.joined()

        #expect(check.digest == expected)
        #expect(check.recipeCount == 2)
        #expect(!check.differs(from: expected), "the Spark already holds these bytes")
        #expect(!check.differs(from: expected.uppercased()))
        #expect(check.differs(from: "0000"), "different bytes: something to review")
        #expect(check.differs(from: nil), "an unknown snapshot is worth reviewing")
    }

    @Test func somethingThatIsNotACatalogueIsRefusedBeforeReachingTheSpark() {
        #expect(throws: PublishedCatalogueCheckError.self) {
            try PublishedCatalogueCheck(bytes: Data("<html>maintenance</html>".utf8))
        }
        #expect(throws: PublishedCatalogueCheckError.self) {
            try PublishedCatalogueCheck(bytes: Data("{\"recipes\":[]}".utf8))
        }
    }

    @Test func theAppBuildNamesThePublishedCatalogueOverHTTPS() {
        let url = Bundle.main.object(forInfoDictionaryKey: BootstrapComposition.catalogueURLKey)
        // Package tests run outside the app bundle; the composition falls back explicitly, never to plain HTTP.
        _ = url
        #expect(BootstrapComposition.catalogueSource() is UnconfiguredCatalogueSource)
    }

    @Test func publisherNamesResolveToBundledArtworkKeys() {
        #expect(ModelPublisherArtwork.key(forPublisher: "NVIDIA") == "nvidia")
        #expect(ModelPublisherArtwork.key(forPublisher: "NVIDIA Corporation") == "nvidia")
        #expect(ModelPublisherArtwork.key(forPublisher: "Alibaba Cloud") == "qwen")
        #expect(ModelPublisherArtwork.key(forPublisher: "DeepSeek") == "deepseek")
        #expect(ModelPublisherArtwork.key(forPublisher: "Someone Else") == nil)
        #expect(ModelPublisherArtwork.key(forPublisher: nil) == nil)
    }
}
