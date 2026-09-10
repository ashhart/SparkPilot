"""Read both built app bundles to verify actual main-bundle catalogue resolution, failing when either product is absent."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from extract import ROOT  # noqa: E402

# tools/build-apple.sh builds Release; a developer's Xcode build is Debug. Either bundle proves the lookup.
PRODUCTS = {
    "iOS": ("Debug-iphoneos/Spark.app", "Release-iphoneos/Spark.app", "Debug-iphonesimulator/Spark.app", "Release-iphonesimulator/Spark.app"),
    "macOS": ("Debug/SparkPilot.app", "Release/SparkPilot.app"),
}

# Probe plain, Siri and typed interpolated keys to detect missing tables or fallback-to-key rendering.
REPRESENTATIVE_PLAIN = "Settings"
REPRESENTATIVE_PHRASE = "Ask \\(.applicationName) a question"
REPRESENTATIVE_KEY = "action.download"
REPRESENTATIVE_KEY_VALUE = "Download %@"
# A counted clause must remain a compiled substitution rather than flattening into one sentence.
REPRESENTATIVE_SUBSTITUTION_KEY = "status.load.model.waiting"

# Check compiled singular and plural forms because package test runners lack the shipping catalogue.
REPRESENTATIVE_PLURAL_KEYS = {
    "fleet.cluster.of.sparks": ("Cluster of %lld Spark", "Cluster of %lld Sparks"),
    "diff.removals": ("%lld removal", "%lld removals"),
    "diff.hunks": ("%lld hunk", "%lld hunks"),
    "change.files.changed": ("%lld file changed", "%lld files changed"),
    "fleet.elapsed.minutes": ("%lld minute ago", "%lld minutes ago"),
    "fleet.elapsed.hours": ("%lld hour ago", "%lld hours ago"),
    "fleet.elapsed.days": ("%lld day ago", "%lld days ago"),
    "fleet.home.cluster.count": ("%lld cluster", "%lld clusters"),
    "automations.every.hours": ("Every %lld hour", "Every %lld hours"),
    "fleet.models.installed": ("%lld model installed", "%lld models installed"),
    "elapsed.minutes.ago": ("%lld minute ago", "%lld minutes ago"),
    "elapsed.hours.ago": ("%lld hour ago", "%lld hours ago"),
    "elapsed.days.ago": ("%lld day ago", "%lld days ago"),
    "elapsed.weeks.ago": ("%lld week ago", "%lld weeks ago"),
    "elapsed.months.ago": ("%lld month ago", "%lld months ago"),
    "elapsed.years.ago": ("%lld year ago", "%lld years ago"),
}


def derived_data_root() -> Path | None:
    """Where Xcode put this workspace's products."""
    if explicit := os.environ.get("SPARK_APP_PRODUCTS"):
        return Path(explicit)
    # tools/build-apple.sh builds into .build/apple-ci; prefer it so this check follows that script.
    script_products = ROOT / ".build/apple-ci/Build/Products"
    if any(script_products.glob("*/*.app")):
        return script_products
    try:
        settings = subprocess.run(
            [
                "xcodebuild",
                "-workspace",
                str(ROOT / "apple/Spark.xcworkspace"),
                "-scheme",
                "Spark",
                "-showBuildSettings",
                "-json",
            ],
            capture_output=True,
            text=True,
            timeout=180,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if settings.returncode != 0:
        return None
    try:
        built = json.loads(settings.stdout)[0]["buildSettings"]["BUILT_PRODUCTS_DIR"]
    except (json.JSONDecodeError, KeyError, IndexError):
        return None
    return Path(built).parent


def strings_in(bundle: Path, name: str) -> dict[str, str]:
    """Read compiled tables from iOS en.lproj and macOS Contents/Resources to verify both bundle layouts."""
    candidates = [
        bundle / "en.lproj" / f"{name}.strings",
        bundle / "Contents" / "Resources" / "en.lproj" / f"{name}.strings",
    ]
    for path in candidates:
        if not path.is_file():
            continue
        # Use plutil to accept both binary and UTF-16 XML tables emitted by Xcode.
        converted = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
        if converted.returncode != 0:
            raise AssertionError(f"{path} is not a readable strings table")
        return json.loads(converted.stdout)
    raise AssertionError(
        f"{name}.strings is in neither layout of {bundle.name}: "
        + ", ".join(str(path) for path in candidates)
    )


def stringsdict_in(bundle: Path) -> dict:
    """The compiled plural table, or an empty one when there is none."""
    for path in (
        bundle / "en.lproj" / "Localizable.stringsdict",
        bundle / "Contents" / "Resources" / "en.lproj" / "Localizable.stringsdict",
    ):
        if not path.is_file():
            continue
        converted = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
        if converted.returncode != 0:
            raise AssertionError(f"{path} is not a readable stringsdict")
        return json.loads(converted.stdout)
    return {}


def plural_forms(bundle: Path, key: str) -> dict[str, str]:
    """Read counted English forms from .stringsdict so missing plurals cannot hide behind the flat table."""
    candidates = [
        bundle / "en.lproj" / "Localizable.stringsdict",
        bundle / "Contents" / "Resources" / "en.lproj" / "Localizable.stringsdict",
    ]
    for path in candidates:
        if not path.is_file():
            continue
        document = stringsdict_in(bundle)
        if key not in document:
            raise AssertionError(f"{key} has no plural entry in {path.name}")
        rule = next(
            value
            for name, value in document[key].items()
            if isinstance(value, dict) and "one" in value
        )
        return {form: rule[form] for form in ("one", "other")}
    raise AssertionError(
        "no Localizable.stringsdict in either layout of " + bundle.name
    )


class BundleLookupMatrix(unittest.TestCase):
    maxDiff = None

    @classmethod
    def setUpClass(cls) -> None:
        root = derived_data_root()
        if root is None:
            raise AssertionError(
                "xcodebuild did not report a products directory, so the shipped "
                "bundles could not be checked at all"
            )
        cls.bundles = {}
        missing = []
        for platform, relatives in PRODUCTS.items():
            candidates = [root / relative for relative in relatives]
            built = next((candidate for candidate in candidates if candidate.is_dir()), None)
            if built is not None:
                cls.bundles[platform] = built
            else:
                missing.append(f"{platform}: {' or '.join(map(str, candidates))}")
        if missing:
            raise AssertionError(
                "run ./tools/build-apple.sh first; these products are absent so "
                "their string tables could not be checked:\n  " + "\n  ".join(missing)
            )

    def test_share_extensions_are_embedded_and_have_localised_copy(self) -> None:
        for platform, app in self.bundles.items():
            with self.subTest(platform=platform):
                extension = (app / "PlugIns" / "SparkShare.appex" if platform == "iOS"
                             else app / "Contents" / "PlugIns" / "SparkMacShare.appex")
                self.assertTrue(extension.is_dir(), "the share extension was not embedded")
                info_path = extension / ("Info.plist" if platform == "iOS" else "Contents/Info.plist")
                result = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(info_path)],
                                        capture_output=True, text=True, check=True)
                info = json.loads(result.stdout)["NSExtension"]
                self.assertEqual(info["NSExtensionPointIdentifier"], "com.apple.share-services")
                self.assertTrue(info["NSExtensionPrincipalClass"].endswith(".ShareViewController"))
                rules = info["NSExtensionAttributes"]["NSExtensionActivationRule"]
                self.assertEqual(rules["NSExtensionActivationSupportsFileWithMaxCount"], 8)
                self.assertEqual(rules["NSExtensionActivationSupportsImageWithMaxCount"], 8)
                self.assertTrue(rules["NSExtensionActivationSupportsText"])
                table = strings_in(extension, "Localizable")
                self.assertEqual(table["Save to SparkPilot"], "Save to SparkPilot")
                self.assertEqual(table["Saved to SparkPilot"], "Saved to SparkPilot")

    def test_both_products_carry_the_string_catalogue(self) -> None:
        for platform in PRODUCTS:
            with self.subTest(platform=platform):
                table = strings_in(self.bundles[platform], "Localizable")
                self.assertGreater(len(table), 400, "the table is implausibly small")

    def test_a_typed_interpolated_key_resolves_to_english(self) -> None:
        """A declared key must reach the app as its sentence, not its name."""
        for platform, bundle in self.bundles.items():
            with self.subTest(platform=platform):
                table = strings_in(bundle, "Localizable")
                self.assertIn(
                    REPRESENTATIVE_KEY,
                    table,
                    "a declared key is absent, so the app would show the key "
                    "name where a sentence belongs",
                )
                self.assertEqual(table[REPRESENTATIVE_KEY], REPRESENTATIVE_KEY_VALUE)
                self.assertNotEqual(
                    table[REPRESENTATIVE_KEY],
                    REPRESENTATIVE_KEY,
                    "the value is the key, which is what a failed lookup looks like",
                )

    def test_counted_copy_keeps_both_english_forms_after_compilation(self) -> None:
        """Plural variations compile into a `.stringsdict`, not `.strings`."""
        for platform, bundle in self.bundles.items():
            for key, (one, other) in REPRESENTATIVE_PLURAL_KEYS.items():
                with self.subTest(platform=platform, key=key):
                    forms = plural_forms(bundle, key)
                    self.assertEqual(
                        forms["one"],
                        one,
                        f"{key} would read ungrammatically at a count of one",
                    )
                    self.assertEqual(forms["other"], other)

    def test_a_plain_value_resolves_in_every_product(self) -> None:
        for platform, bundle in self.bundles.items():
            with self.subTest(platform=platform):
                table = strings_in(bundle, "Localizable")
                self.assertIn(
                    REPRESENTATIVE_PLAIN,
                    table,
                    "shipping copy is not in the compiled table, so the app "
                    "would fall through to the key",
                )
                self.assertEqual(table[REPRESENTATIVE_PLAIN], REPRESENTATIVE_PLAIN)

    def test_the_siri_phrases_resolve_in_every_product(self) -> None:
        """App Shortcuts phrases need their own table (Apple's contract)."""
        for platform, bundle in self.bundles.items():
            with self.subTest(platform=platform):
                table = strings_in(bundle, "AppShortcuts")
                self.assertIn(REPRESENTATIVE_PHRASE, table)

    def test_a_substituted_clause_survives_compilation(self) -> None:
        """§40.4's spoken sentence varies one clause by a count."""
        for platform, bundle in self.bundles.items():
            with self.subTest(platform=platform):
                document = stringsdict_in(bundle)
                entry = document.get(REPRESENTATIVE_SUBSTITUTION_KEY)
                self.assertIsNotNone(
                    entry,
                    f"{REPRESENTATIVE_SUBSTITUTION_KEY} lost its substitution "
                    f"in the built product",
                )
                formats = entry["NSStringLocalizedFormatKey"]
                # Accept Xcode positionalisation while requiring the counted clause to remain a substitution.
                self.assertRegex(formats, r"%\d*\$?#@jobs@", formats)
                jobs = entry["jobs"]
                self.assertEqual(jobs["one"], "1 job is waiting")
                self.assertIn("jobs are waiting", jobs["other"])

    def test_a_counted_clause_beside_another_argument_keeps_its_singular(self) -> None:
        for platform, bundle in self.bundles.items():
            with self.subTest(platform=platform):
                entry = stringsdict_in(bundle).get("shared.access.budget.today")
                self.assertIsNotNone(entry, "the guest budget lost its counted token clause")
                self.assertEqual(entry["tokens"]["one"], "%2$lld token")
                self.assertEqual(entry["tokens"]["other"], "%2$lld tokens")

    def test_total_count_controls_multi_count_plurals(self) -> None:
        for platform, bundle in self.bundles.items():
            document = stringsdict_in(bundle)
            for key, variable in (
                ("fleet.showing.count", "sparks"),
                ("devices.trusted.of.paired", "devices"),
                ("shared.access.budget.today", "tokens"),
                ("onboarding.rediscovery.elapsed", "minutes"),
            ):
                with self.subTest(platform=platform, key=key):
                    entry = document[key]
                    self.assertIn(variable, entry, "plural argument must be explicit")
                    self.assertIn(f"%2$#@{variable}@", entry["NSStringLocalizedFormatKey"])

    def test_the_built_table_matches_the_checked_in_catalogue(self) -> None:
        catalogue = json.loads(
            (ROOT / "apple/SparkApp/Resources/Localizable.xcstrings").read_text(
                encoding="utf-8"
            )
        )
        for platform, bundle in self.bundles.items():
            with self.subTest(platform=platform):
                # Union .strings and .stringsdict because Xcode compiles plain and counted keys into separate tables.
                built = set(strings_in(bundle, "Localizable")) | set(
                    stringsdict_in(bundle)
                )
                self.assertEqual(
                    sorted(built),
                    sorted(catalogue["strings"]),
                    "the built product and the checked-in catalogue disagree; "
                    "the product is stale or the catalogue is",
                )


if __name__ == "__main__":
    unittest.main()
