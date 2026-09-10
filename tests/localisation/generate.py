#!/usr/bin/env python3
"""Refresh source-language catalogue entries with python3 tests/localisation/generate.py without inventing translations."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from extract import ROOT, collect, collect_declared  # noqa: E402

CATALOGUE = ROOT / "apple/SparkApp/Resources/Localizable.xcstrings"
NON_TRANSLATABLE = Path(__file__).resolve().parent / "nontranslatable.json"
PLURALS = Path(__file__).resolve().parent / "plurals.json"


def build() -> dict:
    literals, _ = collect()
    verbatim = set(
        json.loads(NON_TRANSLATABLE.read_text(encoding="utf-8"))["cases"]
    )
    counted = json.loads(PLURALS.read_text(encoding="utf-8"))
    plurals = counted["cases"]
    substitutions = counted.get("substitutions", {})
    strings = {}
    for value in sorted(literals):
        strings[value] = {
            # Mark entries manual because this gate performs extraction for SwiftPM library sources.
            "extractionState": "manual",
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": value}}
            },
        }
        if value in verbatim:
            # Protect identifiers from translation so hostnames and domain suffixes remain stable.
            strings[value]["shouldTranslate"] = False

    # Store typed copy under its stable key with the runtime English format string.
    for key, entry in sorted(collect_declared().items()):
        if key in plurals:
            english = {"variations": plural_variations(plurals[key])}
        elif key in substitutions:
            english = substitution_variations(substitutions[key], entry["value"])
        else:
            english = {"stringUnit": {"state": "translated", "value": entry["value"]}}
        strings[key] = {
            # Retain the compiler-emitted translator context alongside each value.
            "comment": entry["comment"],
            "extractionState": "manual",
            "localizations": {"en": english},
        }
        if key in verbatim:
            strings[key]["shouldTranslate"] = False
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def substitution_variations(case: dict, compiled: str) -> dict:
    """Validate the varying clause against compiler output so an edited declaration cannot leave a stale plural template."""
    # Reconstruct positional template and substitution arguments to compare with compiler-emitted specifiers.
    positional = {
        int(number): kind
        for number, kind in re.findall(r"%(\d+)\$(@|lld|lf)", case["template"])
    }
    positional[case["argNum"]] = case["formatSpecifier"]
    rebuilt = [positional[index] for index in sorted(positional)]
    emitted = re.findall(r"%(@|lld|lf)", compiled)
    if rebuilt != emitted:
        raise SystemExit(
            f"{case['template']!r} takes {rebuilt} but the compiler emits "
            f"{emitted} for this key ({compiled!r}); "
            f"update tests/localisation/plurals.json"
        )
    return {
        "stringUnit": {"state": "translated", "value": case["template"]},
        "substitutions": {
            case["name"]: {
                "argNum": case["argNum"],
                "formatSpecifier": case["formatSpecifier"],
                "variations": {
                    "plural": {
                        form: {
                            "stringUnit": {"state": "translated", "value": case[form]}
                        }
                        for form in ("one", "other")
                    }
                },
            }
        },
    }


def plural_variations(case: dict) -> dict:
    """Provide distinct English singular and plural sentences for counted copy."""
    return {
        "plural": {
            form: {"stringUnit": {"state": "translated", "value": case[form]}}
            for form in ("one", "other")
        }
    }


def main() -> None:
    CATALOGUE.parent.mkdir(parents=True, exist_ok=True)
    CATALOGUE.write_text(
        json.dumps(build(), indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"wrote {len(build()['strings'])} keys to {CATALOGUE.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
