"""Find candidate UI copy that is neither catalogue-routed nor explicitly classified internal in its source file."""

from __future__ import annotations

import json
import re
from pathlib import Path

from extract import ROOT, shipping_files
from routing import is_routed
from swiftlex import INTERPOLATION, strings

INTERNAL = Path(__file__).resolve().parent / "internal.json"
CANONICAL_FORMATTING = Path(__file__).resolve().parent / "canonical-formatting.json"
DATA_TEMPLATES = Path(__file__).resolve().parent / "data-templates.json"

# Search beyond the token because String( and format: can occupy separate lines.
_POSIX_CALL = re.compile(r"String\( *format: *$")
_POSIX_CONVERSION = re.compile(r"%[-+ #0-9.]*(?:l?[dioufFeEgG]|@)")

#: Conversions that are not numbers a person reads: a hex digest, a pointer.
_NON_NUMERIC = re.compile(r"^%0?\d*[xX]$")

# Lowercase dotted/underscored tokens and screaming error codes are identifiers, not visible copy.
_IDENTIFIER = re.compile(r"^[a-z0-9_.\-/]+$")
_SCREAMING = re.compile(r"^[A-Z0-9_]+$")


def is_candidate(value: str) -> bool:
    """Count words around interpolations as visible copy while treating a bare interpolation as a passing value."""
    if not value.strip():
        return False
    words = value.replace(INTERPOLATION, "")
    if not re.search(r"[A-Za-z]", words):
        return False
    if _IDENTIFIER.match(value) or _SCREAMING.match(value):
        return False
    if "://" in value or value.startswith("%") or value.startswith("/"):
        return False
    if INTERPOLATION in value:
        # Any letters around an interpolation count as copy, including prefixes, short connectives and units.
        return bool(re.search(r"[A-Za-z]", words))
    # Capitalised words and phrases are copy; lowercase state identifiers are not.
    return value[0].isupper() or " " in value


def declared_internal() -> dict[str, dict[str, str]]:
    """Scope non-copy declarations by file so identical words elsewhere can still require translation."""
    document = json.loads(INTERNAL.read_text(encoding="utf-8"))
    return document["files"]


CONCATENATION = Path(__file__).resolve().parent / "assembled.json"


def declared_assembly() -> dict[str, dict[str, str]]:
    """Concatenations someone has ruled non-copy, by file and by literal."""
    return json.loads(CONCATENATION.read_text(encoding="utf-8"))["files"]


def _joined_to_something(source: str, token: StringToken) -> bool:
    """Detect concatenation around the complete routed call, skipping balanced delimiters to distinguish nested arguments."""
    index = token.end
    while index < len(source) and (source[index].isspace() or source[index] in ")]"):
        index += 1
    if source[index : index + 1] == "+":
        return True
    start = token.start
    if token.context is not None and token.context.call_start is not None:
        start = min(start, token.context.call_start)
    index = start - 1
    while index >= 0 and (source[index].isspace() or source[index] in "(["):
        index -= 1
    return source[index : index + 1] == "+"


def assembled_copy() -> dict[str, list[str]]:
    """Reject concatenated catalogue fragments because translators need a complete sentence they can reorder."""
    allowed = declared_assembly()
    found: dict[str, list[str]] = {}
    for path in shipping_files():
        relative = str(path.relative_to(ROOT))
        source = path.read_text(encoding="utf-8")
        for token in strings(source):
            if not is_routed(token) or not token.value:
                continue
            if token.value in allowed.get(relative, {}):
                continue
            if _joined_to_something(source, token):
                found.setdefault(relative, []).append(token.value)
    return found


def declared_data_templates() -> dict[str, dict[str, str]]:
    """Value-only literals ruled non-copy, by file, with the reason."""
    return json.loads(DATA_TEMPLATES.read_text(encoding="utf-8"))["files"]


def assembled_from_values() -> dict[str, list[str]]:
    """Find undeclared assemblies made only from interpolations and punctuation, excluding catalogue default values."""
    allowed = declared_data_templates()
    found: dict[str, list[str]] = {}
    for path in shipping_files():
        relative = str(path.relative_to(ROOT))
        source = path.read_text(encoding="utf-8")
        for token in strings(source):
            if token.value.count(INTERPOLATION) < 2 or is_routed(token):
                continue
            if re.search(r"[A-Za-z]", token.value.replace(INTERPOLATION, " ")):
                continue
            if token.value in allowed.get(relative, {}):
                continue
            found.setdefault(relative, []).append(token.value)
    return found


# Match only sibling ternary arms, allowing a localized call around the routed literal.
_TERNARY_ARMS = re.compile(r"[?:]\s*(String\(\s*localized:)?")


def mixed_ternary_arms() -> dict[str, list[str]]:
    """Flag an internal literal opposite routed copy in the same ternary because both occupy the same UI slot."""
    internal = declared_internal()
    found: dict[str, list[str]] = {}
    for path in shipping_files():
        relative = str(path.relative_to(ROOT))
        scoped = internal.get(relative, {})
        if not scoped:
            continue
        source = path.read_text(encoding="utf-8")
        tokens = strings(source)
        for first, second in zip(tokens, tokens[1:]):
            between = " ".join(
                re.sub(r"//[^\n]*", " ", source[first.end : second.start]).split()
            )
            if not _TERNARY_ARMS.fullmatch(between):
                continue
            for arm, other in ((first, second), (second, first)):
                if is_routed(other) and not is_routed(arm) and arm.value in scoped:
                    found.setdefault(relative, []).append(arm.value)
    return found


def survey() -> dict[str, list[str]]:
    """Candidate copy that is neither routed nor declared internal, by file."""
    internal = declared_internal()
    found: dict[str, list[str]] = {}
    for path in shipping_files():
        relative = str(path.relative_to(ROOT))
        source = path.read_text(encoding="utf-8")
        for token in strings(source):
            if is_routed(token):
                continue
            if not is_candidate(token.value):
                continue
            if token.value in internal.get(relative, {}):
                continue
            found.setdefault(relative, []).append(token.value)
    return found


def declared_canonical() -> dict[str, str]:
    """Files that format outside the reader's locale on purpose, and why."""
    return json.loads(CANONICAL_FORMATTING.read_text(encoding="utf-8"))["files"]


def posix_formatting() -> dict[str, list[str]]:
    """Find non-localised numeric formatting, except explicitly declared canonical wire or diagnostic values."""
    canonical = declared_canonical()
    found: dict[str, list[str]] = {}
    for path in shipping_files():
        relative = str(path.relative_to(ROOT))
        if relative in canonical:
            continue
        source = path.read_text(encoding="utf-8")
        for token in strings(source):
            if not _POSIX_CONVERSION.search(token.value):
                continue
            if token.context is None or token.context.callee != "String":
                continue
            if token.context.label != "format":
                continue
            if _NON_NUMERIC.match(token.value):
                continue
            found.setdefault(relative, []).append(token.value)
    return found


def total(found: dict[str, list[str]] | None = None) -> int:
    return sum(len(values) for values in (found or survey()).values())
