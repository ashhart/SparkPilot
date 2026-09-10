"""Exercise Swift literal forms that previously defeated regex-based copy extraction."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from computed import _joined_to_something, is_candidate  # noqa: E402
from routing import is_routed  # noqa: E402
from swiftlex import INTERPOLATION, strings  # noqa: E402


def values(source: str) -> list[str]:
    return [token.value for token in strings(source)]


class LexerMatrix(unittest.TestCase):
    maxDiff = None

    def test_an_interpolation_may_contain_its_own_literals(self) -> None:
        """Quotes inside interpolation expressions must not split the surrounding Swift string."""
        source = 'let a = "\\(n == 1 ? "" : "s") files"'
        self.assertEqual(values(source), [f"{INTERPOLATION} files", "", "s"])

    def test_copy_inside_an_interpolation_is_copy(self) -> None:
        """An interpolation is code, so its literals are literals."""
        source = 'let a = "Status: \\(ok ? "Healthy" : "Failed")"'
        self.assertEqual(
            values(source), [f"Status: {INTERPOLATION}", "Healthy", "Failed"]
        )
        self.assertTrue(is_candidate("Healthy"))
        self.assertTrue(is_candidate("Failed"))

    def test_an_escaped_quote_does_not_end_a_literal(self) -> None:
        self.assertEqual(values(r'let a = "say \"hi\" now"'), ['say "hi" now'])

    def test_a_raw_string_has_no_escapes_and_may_hold_quotes(self) -> None:
        self.assertEqual(values('let a = #"a "quoted" b"#'), ['a "quoted" b'])
        self.assertEqual(values('let a = ##"one # two"##'), ["one # two"])

    def test_a_raw_string_interpolates_with_its_own_pound_count(self) -> None:
        token = strings('let a = #"raw \\#(x) here"#')[0]
        self.assertTrue(token.interpolated)
        self.assertEqual(token.value, f"raw {INTERPOLATION} here")
        # A backslash-paren without the pounds is literal text in a raw string.
        plain = strings('let a = #"not \\(x) an interpolation"#')[0]
        self.assertFalse(plain.interpolated)

    def test_a_multiline_literal_joins_its_lines(self) -> None:
        source = 'let a = """\n    first \\\n    second\n    """'
        self.assertEqual(values(source), ["first second"])

    def test_a_raw_multiline_literal_is_both_at_once(self) -> None:
        source = 'let a = #"""\n    keeps "quotes"\n    """#'
        self.assertEqual(values(source), ['keeps "quotes"'])

    def test_comments_hold_no_copy(self) -> None:
        self.assertEqual(values('// "not copy"\nlet a = "copy"'), ["copy"])
        self.assertEqual(values('/* "no" */ let a = "yes"'), ["yes"])

    def test_block_comments_nest_as_swift_says_they_do(self) -> None:
        source = '/* outer /* inner "no" */ still comment "no" */ let a = "yes"'
        self.assertEqual(values(source), ["yes"])

    def test_a_quote_inside_a_comment_does_not_open_a_literal(self) -> None:
        """The failure that would hide every literal after it."""
        source = '// it\'s a "quote\nlet a = "copy"\nlet b = "more"'
        self.assertEqual(values(source), ["copy", "more"])

    def test_routing_is_decided_by_the_construct_the_literal_belongs_to(self) -> None:
        for source, routed in [
            ('Text("Add Spark")', True),
            ('String(localized: "Add Spark")', True),
            ('.accessibilityLabel("Add Spark")', True),
            ('IntentDescription(\n    "Add Spark"\n)', True),
            ('@Parameter(\n    title: "File",\n)', True),
            ('let name = "Add Spark"', False),
            ('logger.debug("Add Spark")', False),
        ]:
            with self.subTest(source=source):
                token = strings(source)[0]
                self.assertEqual(is_routed(token), routed)

    def test_a_routed_call_immediately_before_does_not_route_the_next_literal(
        self,
    ) -> None:
        """Classify the literal's actual call argument rather than any nearby visible construct."""
        for source in [
            'Text("routed"); let stray = "not routed"',
            'Text("routed")\nlet stray = "not routed"',
            'String(localized: "routed"), stray: "not routed"',
            'Text("routed")\n' + "\n".join(f"// filler {n}" for n in range(8))
            + '\nlet stray = "not routed"',
        ]:
            with self.subTest(source=source[:40]):
                tokens = [t for t in strings(source) if t.value in {"routed", "not routed"}]
                routed = {t.value: is_routed(t) for t in tokens}
                self.assertEqual(routed, {"routed": True, "not routed": False})

    def test_a_construct_still_routes_its_own_argument_across_formatting(self) -> None:
        """The inverse: a line break or a comment must not un-route a literal."""
        for source in [
            'Text("copy")',
            'Text(\n    "copy"\n)',
            'Text(\n    // why this wording\n    "copy"\n)',
            'Text(\n    /* block */ "copy"\n)',
            '.accessibilityLabel(\n    condition\n        ? "copy"\n        : "other"\n)',
            'String(\n    localized: "copy"\n)',
        ]:
            with self.subTest(source=source[:40]):
                token = next(t for t in strings(source) if t.value == "copy")
                self.assertTrue(is_routed(token), source)

    def test_a_label_alone_does_not_route(self) -> None:
        """A title: label routes copy only on APIs whose parameter is a localisable resource."""
        self.assertTrue(
            is_routed(strings('@Parameter(title: "File")')[0])
        )
        helper = 'FleetSummaryItem(title: "Connected")'
        self.assertFalse(is_routed(strings(helper)[0]))

    def test_a_symbol_name_beside_copy_is_not_copy(self) -> None:
        source = 'Label("Support bundle", systemImage: "stethoscope")'
        tokens = strings(source)
        self.assertTrue(is_routed(tokens[0]))
        self.assertFalse(is_routed(tokens[1]))

    def test_a_verbatim_text_is_deliberately_not_routed(self) -> None:
        source = 'Text(verbatim: line.text) + Text(verbatim: "raw")'
        token = next(t for t in strings(source) if t.value == "raw")
        self.assertFalse(is_routed(token))

    def test_an_assignment_to_a_resource_type_is_routed_however_written(self) -> None:
        for source in [
            'static let title: LocalizedStringResource = "Ask Spark"',
            'public static let t: TypeDisplayRepresentation = "Spark Target"',
        ]:
            with self.subTest(source=source[:40]):
                self.assertTrue(is_routed(strings(source)[0]))
        plain = 'static let name: String = "Ask Spark"'
        self.assertFalse(is_routed(strings(plain)[0]))

    def test_a_nested_call_is_the_one_that_counts(self) -> None:
        source = 'Text(format(value, "%.1f"))'
        token = next(t for t in strings(source) if t.value == "%.1f")
        self.assertFalse(is_routed(token))

    def test_a_comment_inside_an_interpolation_does_not_break_nesting(self) -> None:
        """Ignore parentheses and quotes inside interpolation comments so they cannot terminate the expression."""
        for source in [
            'let a = "x \\(f(1 /* ) "trap" */, 2)) y"',
            'let a = "x \\(f(1, // ) "trap"\n  2)) y"',
            'let a = "x \\(f(1 /* nested /* ) */ */, 2)) y"',
        ]:
            with self.subTest(source=source[:40]):
                self.assertEqual(values(source), [f"x {INTERPOLATION} y"])

    def test_a_raw_interpolation_also_skips_its_comments(self) -> None:
        source = 'let a = #"raw \\#(g(1 /* " ) */, 2)) z"#'
        self.assertEqual(values(source), [f"raw {INTERPOLATION} z"])

    def test_a_multiline_interpolation_also_skips_its_comments(self) -> None:
        source = 'let a = """\n    x \\(f(1 /* ) */, 2)) y\n    """'
        self.assertEqual(values(source), [f"x {INTERPOLATION} y"])

    def test_copy_around_a_value_is_audited_wherever_it_sits(self) -> None:
        """Treat prefixes, short connectives and units surrounding an interpolation as visible copy."""
        for literal in [
            f"Blocked: {INTERPOLATION}",  # prefix
            f"{INTERPOLATION} remaining",  # suffix
            f"{INTERPOLATION} of {INTERPOLATION}",  # two-letter connective
            f"{INTERPOLATION} GB",  # unit-ish
            f"{INTERPOLATION} GbE",
            f"Version {INTERPOLATION}",
            f"{INTERPOLATION}, {INTERPOLATION} free",
        ]:
            with self.subTest(literal=literal):
                self.assertTrue(is_candidate(literal), literal)

    def test_a_value_with_nothing_around_it_is_not_copy(self) -> None:
        """A literal that is only a value carries no words to translate."""
        for literal in [
            INTERPOLATION,
            f"{INTERPOLATION}{INTERPOLATION}",
            f"{INTERPOLATION} · {INTERPOLATION}",
            f"({INTERPOLATION})",
        ]:
            with self.subTest(literal=literal):
                self.assertFalse(is_candidate(literal), literal)

    def test_a_collection_argument_keeps_its_own_label(self) -> None:
        """Carry the phrases: argument context into collection elements so App Shortcuts strings remain routed."""
        source = 'AppShortcut(intent: I(), phrases: ["Ask \\(.applicationName)", "Ask again"])'
        contexts = [(token.context.callee, token.context.label) for token in strings(source)]
        self.assertEqual(contexts, [("AppShortcut", "phrases")] * 2)

    def test_a_bare_collection_routes_nothing(self) -> None:
        """An array that is not an argument still excuses nothing inside it."""
        source = 'let names = ["Coordinator", "Worker"]'
        self.assertEqual(
            [token.context.label for token in strings(source)], [None, None]
        )

    def test_a_collection_argument_does_not_leak_past_its_brackets(self) -> None:
        """The label ends where the collection does."""
        source = (
            'AppShortcut(phrases: ["Ask \\(.applicationName)"], systemImageName: "bolt")'
        )
        contexts = [(token.context.callee, token.context.label) for token in strings(source)]
        self.assertEqual(
            contexts,
            [("AppShortcut", "phrases"), ("AppShortcut", "systemImageName")],
        )

    def test_any_routed_fragment_glued_with_a_plus_is_caught(self) -> None:
        """Treat every routed fragment as copy when checking concatenation, including lowercase single words."""
        for source in [
            'let a = String(localized: "of") + value',
            'let a = value + String(localized: "of")',
            'let a = String(localized: "of ") + String(localized: "the Spark")',
            'let a = Text("s") + other',
        ]:
            with self.subTest(source=source[:44]):
                token = strings(source)[0]
                self.assertTrue(is_routed(token), source)
                self.assertTrue(_joined_to_something(source, token), source)

    def test_a_routed_literal_standing_alone_is_not_a_concatenation(self) -> None:
        """`+` inside an argument list is not a sentence being assembled."""
        for source in [
            'let a = String(localized: "of")',
            'let a = f(String(localized: "of"), b + c)',
        ]:
            with self.subTest(source=source[:44]):
                token = strings(source)[0]
                self.assertFalse(_joined_to_something(source, token), source)

    def test_a_ternary_arm_is_not_routed_by_the_call_in_the_other_arm(self) -> None:
        """Routing one ternary arm must not excuse the raw literal in its sibling arm."""
        source = 'let a = isCluster ? "DGX Spark cluster" : String(localized: "DGX Spark")'
        raw, routed = strings(source)
        self.assertEqual(raw.value, "DGX Spark cluster")
        self.assertFalse(is_routed(raw), "the raw arm was covered by the other arm's call")
        self.assertEqual(routed.value, "DGX Spark")
        self.assertTrue(is_routed(routed))

    def test_the_lexer_terminates_on_an_unterminated_literal(self) -> None:
        """A file that does not compile must not hang the gate."""
        self.assertEqual(values('let a = "never closed'), ["never closed"])
        self.assertEqual(values('let a = """\nnever closed'), ["never closed"])
        self.assertEqual(values('/* never closed'), [])


if __name__ == "__main__":
    unittest.main()
