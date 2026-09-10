import Foundation
import Testing

@testable import SparkAppComposition

private func cleaned(_ text: String) -> String {
    SparkChatPlainText.cleaned(text, isComplete: true)
}

@Test func aPairOfSpacedDashesInOneSentenceBecomesThePairOfCommasItStandsIn() {
    #expect(
        cleaned("The model \u{2014} a small one \u{2014} runs locally.")
            == "The model, a small one, runs locally."
    )
    #expect(
        cleaned("Spark \u{2013} the appliance \u{2013} is quiet.")
            == "Spark, the appliance, is quiet."
    )
}

@Test func aLoneSpacedDashBecomesTheColonItWasPretendingToBe() {
    #expect(
        cleaned("There is one rule \u{2014} keep it short.") == "There is one rule: keep it short."
    )
    #expect(cleaned("Two files changed \u{2013} both tests.") == "Two files changed: both tests.")
}

@Test func aDashWithASpaceOnOneSideIsStillASeparator() {
    #expect(cleaned("It works\u{2014} mostly.") == "It works: mostly.")
    #expect(cleaned("It works \u{2014}mostly.") == "It works: mostly.")
}

@Test func anUnspacedEnDashBetweenWordsBecomesAHyphenAndARealHyphenIsLeftAlone() {
    #expect(cleaned("A well\u{2013}known case.") == "A well-known case.")
    #expect(cleaned("A well-known case.") == "A well-known case.")
    #expect(
        cleaned("A state\u{2013}of\u{2013}the\u{2013}art model.") == "A state-of-the-art model."
    )
}

@Test func anEmDashIsASeparatorEvenWithNoSpaceAroundIt() {
    #expect(
        cleaned("The result\u{2014}which nobody expected\u{2014}was fine.")
            == "The result, which nobody expected, was fine."
    )
    #expect(cleaned("One rule\u{2014}keep it short.") == "One rule: keep it short.")
}

@Test func aDashThatOpensALineIsLeftWhereTheModelPutIt() {
    #expect(
        cleaned("A temporary fix is permanent.\n\n\u{2014} Anonymous")
            == "A temporary fix is permanent.\n\n\u{2014} Anonymous"
    )
}

@Test func numberRangesKeepTheirDashWhicheverWayTheyAreSpaced() {
    #expect(
        cleaned("Read pages 10\u{2013}20 of the manual.")
            == "Read pages 10\u{2013}20 of the manual."
    )
    #expect(cleaned("It shipped in 2020\u{2013}2024.") == "It shipped in 2020\u{2013}2024.")
    #expect(cleaned("Between 10 \u{2013} 20 tokens.") == "Between 10 \u{2013} 20 tokens.")
}

@Test func dashesInsideCodeSpansAndFencedBlocksAreLeftExactlyAsWritten() {
    let span = "Run `spark --sync \u{2014} now` and wait \u{2014} then stop."
    #expect(cleaned(span) == "Run `spark --sync \u{2014} now` and wait: then stop.")

    let fenced = """
        Here is the fix.

        ```swift
        let dash = "a \u{2014} b"
        ```

        That is all \u{2014} really.
        """
    let result = cleaned(fenced)
    #expect(result.contains("let dash = \"a \u{2014} b\""))
    #expect(result.contains("That is all: really."))
    #expect(result.contains("```swift"))
}

@Test func textTheOwnerPastedBackAsAQuoteIsNeverRewritten() {
    let quoted = """
        You wrote this.

        > Certainly! The plan \u{2014} such as it is \u{2014} is ready. I hope this helps!

        The dash above is yours \u{2014} I left it.
        """
    let result = cleaned(quoted)
    #expect(
        result.contains(
            "> Certainly! The plan \u{2014} such as it is \u{2014} is ready. I hope this helps!"
        )
    )
    #expect(result.contains("The dash above is yours: I left it."))
}

@Test func aDashInsideAQuotedSpanBelongsToWhoeverSaidIt() {
    #expect(
        cleaned("He said \"wait \u{2014} really?\" and left \u{2014} quickly.")
            == "He said \"wait \u{2014} really?\" and left: quickly."
    )
}

@Test func openersAreStrippedFromTheStartOfAMessageAndOfEveryParagraph() {
    #expect(
        cleaned("Certainly! Here is the answer.\n\nGreat question, the second point matters.")
            == "Here is the answer.\n\nThe second point matters."
    )
    #expect(cleaned("As an AI language model, I cannot browse.") == "I cannot browse.")
    #expect(cleaned("Sure, the build is green.") == "The build is green.")
}

@Test func closersAreStrippedFromTheEndOfAMessageAndOfEveryParagraph() {
    #expect(
        cleaned(
            "The build is green. I hope this helps!\n\nRun the tests. Let me know if you need anything else."
        )
            == "The build is green.\n\nRun the tests."
    )
    #expect(cleaned("Done. Feel free to ask.") == "Done.")
}

@Test func aParagraphThatIsNothingButFillerDisappears() {
    #expect(cleaned("Sure!\n\nThe answer is 42.") == "The answer is 42.")
    #expect(cleaned("The answer is 42.\n\nHope this helps!") == "The answer is 42.")
}

@Test func slopWordsInTheMiddleOfARealSentenceAreLeftAlone() {
    #expect(cleaned("Certainly the tests pass.") == "Certainly the tests pass.")
    #expect(cleaned("I will let you know if it fails.") == "I will let you know if it fails.")
    #expect(cleaned("Sure enough, the test failed.") == "Sure enough, the test failed.")
}

@Test func anAnswerThatIsOnlyFillerIsShownRatherThanErased() {
    #expect(cleaned("I hope this helps!") == "I hope this helps!")
    #expect(cleaned("Certainly!") == "Certainly!")
}

@Test func aPartialStreamIsCleanedOnlyUpToItsLastParagraphBreak() {
    let partial = "Certainly! Here it is.\n\nAnd then \u{2014} a dash"
    #expect(
        SparkChatPlainText.cleaned(partial, isComplete: false)
            == "Here it is.\n\nAnd then \u{2014} a dash"
    )
    #expect(
        SparkChatPlainText.cleaned("Certainly! Here it", isComplete: false) == "Certainly! Here it"
    )
}

@Test func anUnclosedCodeFenceHoldsTheBoundaryBackSoNoHalfBlockIsRewritten() {
    let partial = "Look at this.\n\n```swift\nlet a = \"x \u{2014} y\"\n\nlet b = 1"
    #expect(SparkChatPlainText.cleaned(partial, isComplete: false) == partial)
}

@Test func everyPrefixOfAStreamEndsInTheExactBytesTheModelSentLast() {
    let answer = """
        Certainly! The plan \u{2014} in short \u{2014} is ready.

        Run `make \u{2014} all`, then read pages 10\u{2013}20.

        I hope this helps!
        """
    for length in 1...answer.count {
        let raw = String(answer.prefix(length))
        let rendered = SparkChatPlainText.cleaned(raw, isComplete: false)
        let tail = raw.components(separatedBy: "\n\n").last ?? raw
        #expect(rendered.hasSuffix(tail), "prefix of \(length) mangled the live tail")
    }
    #expect(
        SparkChatPlainText.cleaned(answer, isComplete: true) == """
            The plan, in short, is ready.

            Run `make \u{2014} all`, then read pages 10\u{2013}20.
            """
    )
}

@Test func cleaningAlreadyPlainTextChangesNothing() {
    let plain = "The build is green. Two files changed, both tests.\n\nRun it again."
    #expect(cleaned(plain) == plain)
    #expect(cleaned("") == "")
}

@Test func aStreamRendererAgreesWithTheFilterAtEveryPrefixWithoutRedoingSettledText() {
    let answer = """
        Certainly! The plan \u{2014} in short \u{2014} is ready.

        ```swift
        let dash = "a \u{2014} b"
        ```

        Run `make \u{2014} all`, then read pages 10\u{2013}20.

        I hope this helps!
        """
    var stream = SparkChatPlainTextStream()
    var raw = ""
    for character in answer {
        raw.append(character)
        #expect(
            stream.rendered(raw, isComplete: false)
                == SparkChatPlainText.cleaned(raw, isComplete: false)
        )
    }
    #expect(
        stream.rendered(raw, isComplete: true)
            == SparkChatPlainText.cleaned(answer, isComplete: true)
    )
    #expect(stream.settledRenderCount <= 4, "a settled paragraph should be rewritten once")
}
