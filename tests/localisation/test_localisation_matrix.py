"""Enforce complete shipping copy coverage, typed interpolation and exact source-language catalogue contents for PLAN §51.2."""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from computed import (  # noqa: E402
    assembled_copy,
    assembled_from_values,
    declared_assembly,
    declared_data_templates,
    declared_canonical,
    declared_internal,
    is_candidate,
    is_routed,
    mixed_ternary_arms,
    posix_formatting,
    survey,
    total,
)
from routing import SEPARATE_TABLE_ARGUMENTS  # noqa: E402
from swiftlex import INTERPOLATION, strings  # noqa: E402
from extract import (  # noqa: E402
    COUNTED_NOUN,
    EXCLUDED_TREES,
    ROOT,
    collect,
    collect_declared,
    declared_accessors,
    linked_modules,
    module_source_root,
    shipping_files,
    shipping_roots,
    stray_declaration_files,
    unused_declarations,
)

CATALOGUE = ROOT / "apple/SparkApp/Resources/Localizable.xcstrings"
VERBATIM = Path(__file__).resolve().parent / "nontranslatable.json"
PLURALS = Path(__file__).resolve().parent / "plurals.json"
UNROUTED = Path(__file__).resolve().parent / "unrouted.json"
INTERNAL = Path(__file__).resolve().parent / "internal.json"


class LocalisationMatrix(unittest.TestCase):
    maxDiff = None

    @classmethod
    def setUpClass(cls) -> None:
        cls.literals, cls.interpolated = collect()
        cls.catalogue = json.loads(CATALOGUE.read_text(encoding="utf-8"))
        cls.verbatim = json.loads(VERBATIM.read_text(encoding="utf-8"))["cases"]
        counted = json.loads(PLURALS.read_text(encoding="utf-8"))
        cls.plurals = counted["cases"]
        cls.substitutions = counted.get("substitutions", {})
        cls.uncounted = counted.get("uncounted", {})
        cls.keyed = collect_declared()

    def test_every_visible_string_is_in_the_catalogue(self) -> None:
        wanted = set(self.literals) | set(self.keyed)
        missing = sorted(wanted - set(self.catalogue["strings"]))
        self.assertEqual(
            missing,
            [],
            "visible copy is not in the catalogue; run "
            "`python3 tests/localisation/generate.py`",
        )

    def test_the_catalogue_names_no_string_the_app_stopped_showing(self) -> None:
        stale = sorted(
            set(self.catalogue["strings"]) - set(self.literals) - set(self.keyed)
        )
        self.assertEqual(
            stale,
            [],
            "the catalogue describes copy the sources no longer contain; run "
            "`python3 tests/localisation/generate.py`",
        )

    def test_the_catalogue_carries_the_source_language_only(self) -> None:
        self.assertEqual(self.catalogue["sourceLanguage"], "en")
        languages = {
            language
            for entry in self.catalogue["strings"].values()
            for language in entry.get("localizations", {})
        }
        self.assertEqual(
            languages,
            {"en"},
            "a language appeared without a translation pass; a machine "
            "translation shipped as a real one is worse than English copy",
        )

    def test_every_source_value_is_the_string_the_app_shows(self) -> None:
        """A plain literal is its own key; a declared key holds its format."""
        wrong = []
        for key, entry in self.catalogue["strings"].items():
            english = entry["localizations"]["en"]
            # Validate plural forms and substitution templates separately from plain compiler values.
            if "variations" in english or key in self.substitutions:
                continue
            value = english["stringUnit"]["value"]
            expected = self.keyed[key]["value"] if key in self.keyed else key
            if value != expected:
                wrong.append(key)
        self.assertEqual(wrong, [], "a source entry disagrees with what it renders")

    def test_counted_copy_carries_both_english_forms(self) -> None:
        """§51.2: a count changes the sentence, so both forms are written."""
        for key in self.plurals:
            with self.subTest(key=key):
                self.assertIn(key, self.keyed, f"{key} is declared plural but unused")
                english = self.catalogue["strings"][key]["localizations"]["en"]
                forms = english["variations"]["plural"]
                self.assertEqual(sorted(forms), ["one", "other"])
                self.assertNotEqual(
                    forms["one"]["stringUnit"]["value"],
                    forms["other"]["stringUnit"]["value"],
                    "the two forms are identical, so the plural is decorative",
                )

    def test_every_declared_key_is_named_by_a_call_site(self) -> None:
        """A key nothing calls ships a string to translators that nobody can ever read (BH-30)."""
        accessors = declared_accessors()
        self.assertEqual(
            sorted(set(self.keyed) - set(accessors)),
            [],
            "a declared key has no accessor the gate can look for; the declaration "
            "does not follow `static func <name>` immediately above `.init(\"key\"`",
        )
        orphans = unused_declarations()
        self.assertEqual(
            {key: orphans[key] for key in sorted(orphans)},
            {},
            "these keys are declared and never used; delete the declaration or call "
            "it, because the catalogue is the truth (PLAN §51.2)",
        )

    def test_counted_copy_declares_its_plural_forms(self) -> None:
        """A count that qualifies a noun needs both English forms, or "1 clusters" ships (BH-30)."""
        covered = set(self.plurals) | set(self.substitutions)
        missing = {
            key: COUNTED_NOUN.findall(entry["value"])
            for key, entry in self.keyed.items()
            if COUNTED_NOUN.search(entry["value"])
            and key not in covered
            and key not in self.uncounted
        }
        self.assertEqual(
            {key: missing[key] for key in sorted(missing)},
            {},
            "these interpolate a count in front of a noun with no plural forms; add "
            "an entry to tests/localisation/plurals.json, or record in its "
            '"uncounted" list why the following word is not the noun being counted',
        )
        stale = sorted(
            key
            for key in self.uncounted
            if key not in self.keyed or not COUNTED_NOUN.search(self.keyed[key]["value"])
        )
        self.assertEqual(
            stale,
            [],
            'these are excused in plurals.json "uncounted" but the gate no longer '
            "flags them; remove the excuse",
        )

    def test_every_declared_key_carries_a_translator_comment(self) -> None:
        """A translator without context guesses, and a guess ships."""
        bare = sorted(key for key, entry in self.keyed.items() if not entry["comment"])
        self.assertEqual(bare, [], "a declared key has no comment for a translator")

    def test_no_declared_key_is_left_without_a_specifier(self) -> None:
        """A declared key's value is a format string, or it takes no value."""
        for key, entry in self.keyed.items():
            with self.subTest(key=key):
                self.assertNotIn(
                    "\\(",
                    entry["value"],
                    f"{key} still holds a Swift interpolation rather than a specifier",
                )

    def test_no_visible_string_interpolates_inline(self) -> None:
        self.assertEqual(
            sorted(self.interpolated),
            [],
            "a visible string interpolates inline, so its runtime key depends "
            "on a type the call site does not state; declare it on "
            "LocalizedStringResource with a stable key instead",
        )

    def test_no_model_identifier_is_translated(self) -> None:
        """§51.2: model names are not translated."""
        identifiers = sorted(
            key
            for key in self.catalogue["strings"]
            if "/" in key and " " not in key and not key.endswith(".")
        )
        self.assertEqual(
            identifiers,
            [],
            "a publisher/model identifier is in the catalogue; those are "
            "shown verbatim and must never be localised",
        )

    def test_only_declared_identifiers_are_marked_untranslatable(self) -> None:
        """A `shouldTranslate: false` is a decision, so it is declared."""
        marked = {
            key
            for key, entry in self.catalogue["strings"].items()
            if entry.get("shouldTranslate") is False
        }
        self.assertEqual(
            sorted(marked),
            sorted(self.verbatim),
            "the catalogue and tests/localisation/nontranslatable.json disagree "
            "about which visible strings are identifiers rather than copy",
        )
        for key in self.verbatim:
            self.assertTrue(
                key in self.literals or key in self.keyed,
                f"{key!r} is declared untranslatable but nothing shows it",
            )

    def test_every_internal_declaration_is_real_and_classified(self) -> None:
        """Reject stale internal declarations before they can excuse newly introduced visible copy."""
        document = json.loads(INTERNAL.read_text(encoding="utf-8"))
        categories = set(document["categories"])
        for relative, literals in document["files"].items():
            path = ROOT / relative
            self.assertTrue(path.is_file(), f"{relative} is not in the tree")
            present = {token.value for token in strings(path.read_text(encoding="utf-8"))}
            for literal, category in literals.items():
                with self.subTest(file=relative, literal=literal):
                    self.assertIn(
                        category,
                        categories,
                        f"{literal!r} is classified {category!r}, which is not "
                        f"a declared category",
                    )
                    self.assertTrue(
                        is_candidate(literal),
                        f"{literal!r} would never have been counted as copy, so "
                        f"declaring it internal excuses nothing",
                    )
                    self.assertIn(
                        literal,
                        present,
                        f"{literal!r} is declared internal in {relative}, which "
                        f"does not contain it",
                    )

    def test_an_exclusion_does_not_reach_beyond_its_own_file(self) -> None:
        """Keep internal exclusions file-scoped because the same words can be diagnostics in one place and UI copy in another."""
        document = json.loads(INTERNAL.read_text(encoding="utf-8"))
        scoped = document["files"]
        shared = [
            literal
            for literal in {lit for lits in scoped.values() for lit in lits}
            if sum(literal in lits for lits in scoped.values()) > 1
        ]
        for literal in shared:
            with self.subTest(literal=literal):
                files = [f for f, lits in scoped.items() if literal in lits]
                self.assertGreater(
                    len(files),
                    1,
                    f"{literal!r} is excluded in {files}, each decided separately",
                )

    def test_no_declaration_hides_from_the_extractor(self) -> None:
        """Every stable-key declaration must be included in compiler extraction or the app displays its key."""
        self.assertEqual(
            stray_declaration_files(),
            [],
            "these files declare a catalogue key the extractor never sees; "
            "move the declaration into a module copy file",
        )

    def test_no_number_is_formatted_outside_the_readers_locale(self) -> None:
        """Require locale-aware display formatting while preserving explicitly declared canonical wire formats (§51.2)."""
        offenders = posix_formatting()
        self.assertEqual(
            {path: sorted(set(sites)) for path, sites in offenders.items()},
            {},
            "these format a number in the POSIX locale; use formatted() or a "
            "Measurement instead",
        )

    def test_every_canonical_formatting_declaration_is_real(self) -> None:
        """An exemption for a file that no longer formats anything is dead."""
        for relative, reason in declared_canonical().items():
            with self.subTest(file=relative):
                path = ROOT / relative
                self.assertTrue(path.is_file(), f"{relative} is not in the tree")
                self.assertTrue(reason, f"{relative} is exempt without a reason")
                from computed import _POSIX_CALL, _POSIX_CONVERSION

                source = path.read_text(encoding="utf-8")
                from swiftlex import code_before

                formats = any(
                    _POSIX_CONVERSION.search(token.value)
                    and _POSIX_CALL.search(code_before(source, token, span=60))
                    for token in strings(source)
                )
                self.assertTrue(
                    formats,
                    f"{relative} is declared as canonical formatting but formats "
                    f"nothing that way; remove the exemption",
                )

    def test_the_audit_covers_every_linked_module(self) -> None:
        """Copy in a module nobody audited is copy nobody translates."""
        modules = linked_modules()
        self.assertEqual(
            modules,
            sorted(modules),
            "the derived module list is not deterministic",
        )
        covered = {str(root.relative_to(ROOT)) for root in shipping_roots()}
        for module in modules:
            expected = str(module_source_root(module).relative_to(ROOT))
            self.assertTrue(module_source_root(module).is_dir())
            with self.subTest(module=module):
                self.assertIn(
                    expected,
                    covered,
                    f"{module} is linked into the products but its sources are "
                    f"outside the copy audit",
                )

    def test_generated_code_contains_no_copy(self) -> None:
        """Exclude generated transport trees only while they contain no visible-copy constructs."""
        for relative, reason in EXCLUDED_TREES.items():
            with self.subTest(tree=relative):
                self.assertTrue(reason, f"{relative} is excluded without a reason")
                tree = ROOT / relative
                self.assertTrue(tree.is_dir(), f"{relative} is not in the tree")
                offenders: list[str] = []
                for path in sorted(tree.rglob("*.swift")):
                    source = path.read_text(encoding="utf-8")
                    for token in strings(source):
                        if is_routed(token):
                            offenders.append(f"{path.name}: {token.value}")
                self.assertEqual(
                    offenders,
                    [],
                    f"{relative} now contains localisable copy, so excluding it "
                    f"hides that copy from the catalogue",
                )

    def test_nothing_classified_internal_is_also_a_catalogue_lookup(self) -> None:
        """Forbid routing internal literals because translating fixed remote commands would violate the allowlist contract (§11.4)."""
        internal = declared_internal()
        offenders: list[str] = []
        for path in shipping_files():
            source = path.read_text(encoding="utf-8")
            relative = str(path.relative_to(ROOT))
            scoped = internal.get(relative, {})
            for token in strings(source):
                if is_routed(token) and token.value in scoped:
                    offenders.append(
                        f"{relative}: {token.value[:60]!r} is "
                        f"classified {scoped[token.value]!r}"
                    )
        self.assertEqual(
            sorted(offenders),
            [],
            "these are declared not-copy and also routed through the catalogue",
        )

    def test_every_siri_phrase_is_in_its_own_catalogue(self) -> None:
        """Require every AppShortcut phrase in AppShortcuts.xcstrings rather than the main application table."""
        table = json.loads(
            (ROOT / "apple/SparkApp/Resources/AppShortcuts.xcstrings").read_text(
                encoding="utf-8"
            )
        )["strings"]
        phrases = [
            token.value
            for path in shipping_files()
            for token in strings(path.read_text(encoding="utf-8"))
            if token.context is not None
            and (token.context.callee, token.context.label) in SEPARATE_TABLE_ARGUMENTS
        ]
        self.assertNotEqual(phrases, [], "no phrases were found, so nothing was checked")
        # Normalize source expressions and lexer interpolation markers before comparing Siri phrases.
        declared = {
            re.sub(r"\\\(.*?\)", lambda _: INTERPOLATION, key) for key in table
        }
        missing = sorted(set(phrases) - declared)
        self.assertEqual(
            missing,
            [],
            "these App Shortcuts phrases are not in AppShortcuts.xcstrings, so "
            "Siri would offer the key name",
        )

    def test_no_sentence_is_assembled_from_localised_fragments(self) -> None:
        """Require complete translated sentences so word order and grammatical agreement remain controllable (§51.2)."""
        offenders = {
            path: sorted(set(values)) for path, values in assembled_copy().items()
        }
        self.assertEqual(
            offenders,
            {},
            "these glue localised copy to another expression; make each one a "
            "single catalogue sentence with typed arguments",
        )

    def test_no_owner_string_is_assembled_only_from_values(self) -> None:
        """Detect punctuation-only assemblies of translated interpolations that neither word nor concatenation checks can see."""
        offenders = {
            path: sorted(set(values)) for path, values in assembled_from_values().items()
        }
        self.assertEqual(
            offenders,
            {},
            "these build a value from interpolations alone; make it a "
            "catalogue sentence with typed arguments, or declare it in "
            "tests/localisation/data-templates.json with the reason it is data",
        )

    def test_no_declared_identifier_is_the_untranslated_arm_of_a_ternary(self) -> None:
        """Treat ternary siblings as the same visible slot so internal declarations cannot hide a raw copy alternative."""
        offenders = {
            path: sorted(set(values)) for path, values in mixed_ternary_arms().items()
        }
        self.assertEqual(
            offenders,
            {},
            "these are declared not-copy opposite an arm that is copy; route "
            "them, and mark a product name shouldTranslate:false through "
            "nontranslatable.json rather than hiding it from the audit",
        )

    def test_every_data_template_declaration_is_real_and_file_scoped(self) -> None:
        """Reject stale template declarations before they can excuse new untranslated assembly."""
        for relative, literals in declared_data_templates().items():
            path = ROOT / relative
            self.assertTrue(path.is_file(), f"{relative} is not in the tree")
            present = {token.value for token in strings(path.read_text(encoding="utf-8"))}
            for literal, reason in literals.items():
                with self.subTest(file=relative, literal=literal):
                    self.assertTrue(reason, f"{literal!r} is declared without a reason")
                    self.assertIn(
                        literal,
                        present,
                        f"{literal!r} is declared in {relative}, which does not "
                        f"contain it",
                    )

    def test_every_assembly_exemption_is_real_and_file_scoped(self) -> None:
        """An exemption for a concatenation that no longer exists is dead."""
        for relative, literals in declared_assembly().items():
            path = ROOT / relative
            self.assertTrue(path.is_file(), f"{relative} is not in the tree")
            present = {token.value for token in strings(path.read_text(encoding="utf-8"))}
            for literal, reason in literals.items():
                with self.subTest(file=relative, literal=literal):
                    self.assertTrue(reason, f"{literal!r} is exempt without a reason")
                    self.assertIn(
                        literal,
                        present,
                        f"{literal!r} is exempt in {relative}, which does not "
                        f"contain it",
                    )

    # Only tested wire-field owners may populate diagnosticDetail; other shipping sites must not display it.
    DIAGNOSTIC_OWNERS = (
        "apple/Packages/SparkAPI/Sources/SparkAPI/",
        "apple/SparkApp/Shared/SparkOOBEClient.swift",
    )

    def test_no_shipping_view_reads_a_transport_diagnostic(self) -> None:
        """Keep wire diagnostics out of visible copy because remote prose and decoding details are not catalogue translations."""
        offenders = sorted(
            relative
            for path in shipping_files()
            if not (relative := str(path.relative_to(ROOT))).startswith(
                self.DIAGNOSTIC_OWNERS
            )
            and "diagnosticDetail" in path.read_text(encoding="utf-8")
        )
        self.assertEqual(
            offenders,
            [],
            "these read the transport's diagnostic text; present the failure "
            "with APIError.message(for:) instead",
        )

    def test_a_local_api_failure_carries_catalogue_copy(self) -> None:
        """Require APIFailure.local values to come from local catalogue lookups rather than literal or server prose."""
        offenders: list[str] = []
        for path in shipping_files():
            source = path.read_text(encoding="utf-8")
            for match in re.finditer(r"\.local\(message:", source):
                # Collapse whitespace so Swift formatting cannot alter argument-shape matching.
                tail = " ".join(source[match.end() : match.end() + 60].split())
                if not tail.startswith("String( localized:") and not tail.startswith(
                    "String(localized:"
                ):
                    line = source.count("\n", 0, match.start()) + 1
                    offenders.append(f"{path.relative_to(ROOT)}:{line}")
        self.assertEqual(
            sorted(offenders),
            [],
            "these build a local API failure from something other than "
            "catalogue copy",
        )

    def test_unrouted_prose_never_grows(self) -> None:
        """Keep unrouted-copy debt at zero and report failures per source file (§51.2)."""
        recorded = json.loads(UNROUTED.read_text(encoding="utf-8"))
        found = survey()
        current = total(found)
        self.assertLessEqual(
            current,
            recorded["total"],
            "copy was added outside the catalogue; route it through "
            "String(localized:) or a LocalizedStringResource key",
        )
        grown = sorted(
            path
            for path, values in found.items()
            if len(values) > recorded["by_file"].get(path, 0)
        )
        self.assertEqual(grown, [], "these files gained copy outside the catalogue")
        if current < recorded["total"]:
            print(
                f"\n== §51.2 unrouted prose is down to {current} "
                f"from {recorded['total']}; refresh tests/localisation/unrouted.json"
            )

    def test_coverage_is_reported(self) -> None:
        print(f"\n== PLAN §51.2: {len(self.catalogue['strings'])} strings in the catalogue")
        print(f"==   {len(self.literals)} plain visible literals")
        print(f"==   {len(self.keyed)} declared keys carrying a value")
        print(f"==   {len(self.plurals)} of those carry English plural forms")
        print(f"==   {len(self.verbatim)} identifiers shown verbatim")
        print("==   0 deferred")
        recorded = json.loads(UNROUTED.read_text(encoding="utf-8"))
        if recorded["total"]:
            print(
                f"==   {recorded['total']} prose literals still outside the catalogue "
                f"across {len(recorded['by_file'])} files (PLAN §51.2 not met)"
            )
        else:
            print("==   0 prose literals outside the catalogue")
            print("==   §51.2's catalogue clause is met; the catalogue holds en only")
            print("==   §51.1's four physical checks are PARKED FOR 2026-09-02")


if __name__ == "__main__":
    unittest.main()
