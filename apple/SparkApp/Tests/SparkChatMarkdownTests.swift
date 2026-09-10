import Foundation
import Testing

@testable import SparkAppComposition

@Test func chatMarkdownFencesKeepSourceLiteralAndPreserveWhitespace() {
    let source = "# not a heading\n- not a list\n\tlet value = 1  \n\n"
    #expect(
        SparkChatMarkdown.blocks(in: "```swift\n" + source + "```\nAfter") == [
            .code(language: "swift", text: source), .paragraph("After"),
        ]
    )
    #expect(
        SparkChatMarkdown.blocks(in: "~~~~text\n```\n# literal\n~~~\n~~~~") == [
            .code(language: "text", text: "```\n# literal\n~~~\n")
        ]
    )
    #expect(
        SparkChatMarkdown.blocks(in: "```\r\n  first\r\n\tsecond  \r\n```") == [
            .code(language: nil, text: "  first\r\n\tsecond  \r\n")
        ]
    )
}

@Test func chatMarkdownUnfinishedFenceUpdatesKeepEveryCodeCharacter() {
    let partial = "  let value = 1\n\n\tprint(value)"
    #expect(SparkChatMarkdown.blocks(in: "```swift\n") == [.code(language: "swift", text: "")])
    #expect(
        SparkChatMarkdown.blocks(in: "```swift\n" + partial) == [
            .code(language: "swift", text: partial)
        ]
    )
    #expect(
        SparkChatMarkdown.blocks(in: "```swift\n" + partial + "\n```\nDone") == [
            .code(language: "swift", text: partial + "\n"), .paragraph("Done"),
        ]
    )
}

@Test func chatMarkdownSeparatesCommonBlocksWithoutTreatingInlineMarkersAsBlocks() {
    let text = """
        ## A small plan ##
        First line
        second line.

        - Connect the Spark
        2. Check its model
        3) Send a message
        > Keep the last status.
        > Show when it was read.

        * * *
        #not-a-heading
        """
    #expect(
        SparkChatMarkdown.blocks(in: text) == [
            .heading(level: 2, text: "A small plan"),
            .paragraph("First line\nsecond line."),
            .listItem(marker: "•", text: "Connect the Spark"),
            .listItem(marker: "2.", text: "Check its model"),
            .listItem(marker: "3)", text: "Send a message"),
            .quote("Keep the last status.\nShow when it was read."),
            .divider,
            .paragraph("#not-a-heading"),
        ]
    )
}

@Test func chatMarkdownInlineKeepsWhitespaceAndOnlyEncryptedOrMailLinks() {
    let text =
        "  **Ready**  `let value = 1`\n[Web](https://example.invalid) [HTTP](http://example.invalid) [Mail](mailto:qa@example.invalid) [File](file:///tmp/example) [Action](spark://pair/example) [Script](javascript:alert) [Relative](../example)  "
    let rendered = SparkChatMarkdown.inline(text)
    #expect(String(rendered.characters).hasPrefix("  Ready  let value = 1\n"))
    #expect(String(rendered.characters).hasSuffix("HTTP Mail File Action Script Relative  "))
    #expect(rendered.runs.compactMap { $0.link?.scheme?.lowercased() } == ["https", "mailto"])
}

/// A cleartext link from model output would open Safari on an unencrypted page.
@Test func chatMarkdownDropsPlainHTTPLinksButKeepsTheirText() {
    let rendered = SparkChatMarkdown.inline("Open [the page](http://example.invalid/login) now.")
    #expect(String(rendered.characters) == "Open the page now.")
    #expect(rendered.runs.allSatisfy { $0.link == nil })
}

@Test func chatMarkdownImagesStayTextWithoutResourceAttributes() {
    let rendered = SparkChatMarkdown.inline("See ![Diagram](https://example.invalid/chart.png).")
    #expect(String(rendered.characters).contains("Diagram"))
    #expect(rendered.runs.allSatisfy { $0.imageURL == nil && $0.link == nil })
    let code = SparkChatMarkdown.inline("`![Diagram](https://example.invalid/chart.png)`")
    #expect(String(code.characters) == "![Diagram](https://example.invalid/chart.png)")
    #expect(code.runs.allSatisfy { $0.imageURL == nil && $0.link == nil })
}

@Test func chatMarkdownLargeOrVeryFragmentedResponsesRemainCompletePlainText() {
    let large = String(repeating: "**source**  \n", count: 30_000)
    #expect(SparkChatMarkdown.blocks(in: large) == [.paragraph(large)])
    #expect(String(SparkChatMarkdown.inline(large).characters) == large)
    let fragmented = String(repeating: "# Heading\n", count: 600)
    #expect(SparkChatMarkdown.blocks(in: fragmented) == [.paragraph(fragmented)])
}
