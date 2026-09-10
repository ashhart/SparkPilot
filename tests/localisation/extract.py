"""Extract shipping main-bundle catalogue keys and reject inline interpolation in favor of typed stable-key declarations."""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
from pathlib import Path

from routing import is_catalogue_key
from swiftlex import INTERPOLATION, strings

ROOT = Path(__file__).resolve().parents[2]

# Audit composition, app entry points and App Intents because all three ship visible copy.
APP_SOURCE_ROOTS = (
    ROOT / "apple/SparkApp/Shared",
    ROOT / "apple/SparkApp/iPhone",
    ROOT / "apple/SparkApp/macOS",
    ROOT / "apple/SparkApp/ExecutableShared",
    ROOT / "apple/SparkApp/WidgetShared",
    ROOT / "apple/SparkApp/Widgets",
    ROOT / "apple/SparkApp/ShareExtension",
)

#: The package manifest the products are built from.
COMPOSITION_MANIFEST = ROOT / "apple/SparkApp/Package.swift"
PACKAGES_DIRECTORY = ROOT / "apple/Packages"

# Generated-tree exclusions remain valid only while the no-visible-copy test passes.
EXCLUDED_TREES = {
    "apple/Packages/SparkAPI/Sources/SparkAPI/Generated": (
        "Generated from contracts/openapi.yaml by tools/generate-clients.sh and "
        "drift-gated by `just test-contracts`. It contains transport types, not "
        "copy: editing it by hand would be reverted by the generator."
    )
}

_TARGET_DEPENDENCIES = re.compile(
    r'name:\s*"SparkAppComposition"\s*,\s*dependencies:\s*\[(.*?)\]', re.DOTALL
)
_LOCAL_PACKAGE = re.compile(r'path:\s*"\.\./([A-Za-z]+)"')


def linked_modules() -> list[str]:
    """Discover first-party shipping modules from package manifests so newly linked copy cannot escape the audit."""
    manifest = COMPOSITION_MANIFEST.read_text(encoding="utf-8")
    match = _TARGET_DEPENDENCIES.search(manifest)
    if match is None:
        raise AssertionError(
            "the SparkAppComposition target's dependency list could not be read "
            f"from {COMPOSITION_MANIFEST}"
        )
    pending = re.findall(r'"([A-Za-z]+)"', match.group(1))
    seen: list[str] = []
    while pending:
        module = pending.pop()
        if module in seen:
            continue
        seen.append(module)
        package = PACKAGES_DIRECTORY / module / "Package.swift"
        if package.is_file():
            pending.extend(_LOCAL_PACKAGE.findall(package.read_text(encoding="utf-8")))
    return sorted(seen)


def shipping_roots() -> list[Path]:
    """Every source tree whose copy reaches a person using the app."""
    roots = list(APP_SOURCE_ROOTS)
    for module in linked_modules():
        source = module_source_root(module)
        if source.is_dir():
            roots.append(source)
    return roots


def module_source_root(module: str) -> Path:
    """Resolve explicit in-package targets as well as separate first-party packages."""
    manifest = COMPOSITION_MANIFEST.read_text(encoding="utf-8")
    local = re.search(r'\.target\(\s*name:\s*"' + re.escape(module) + r'"\s*,\s*path:\s*"([^\"]+)"', manifest)
    if local:
        return COMPOSITION_MANIFEST.parent / local.group(1)
    return PACKAGES_DIRECTORY / module / "Sources" / module


#: Initialisers whose first string argument is shown to a person.
VISIBLE_INITIALISERS = (
    "Text",
    "Label",
    "Button",
    "Toggle",
    "Section",
    "TextField",
    "SecureField",
    "LabeledContent",
    "Picker",
    "ContentUnavailableView",
    "Link",
    "NavigationLink",
    "Stepper",
)

#: Modifiers whose first string argument is shown or announced.
VISIBLE_MODIFIERS = (
    "navigationTitle",
    "alert",
    "confirmationDialog",
    "accessibilityLabel",
    "accessibilityHint",
    "accessibilityValue",
)

_STRING = r'"((?:[^"\\]|\\.)*)"'
# String(localized:) and LocalizedStringResource resolve declared copy against the shipping main-bundle catalogue.

def shipping_files() -> list[Path]:
    excluded = {ROOT / relative for relative in EXCLUDED_TREES}
    found: list[Path] = []
    for root in shipping_roots():
        for path in sorted(root.rglob("*.swift")):
            if any(parent in excluded for parent in path.parents):
                continue
            found.append(path)
    return found


def extract(source: str) -> tuple[set[str], set[str]]:
    """Classify lexed literals by the same argument-structure rules used by the computed-copy audit."""
    literals: set[str] = set()
    interpolated: set[str] = set()
    for token in strings(source):
        if not token.value.strip():
            continue
        if not is_catalogue_key(token):
            continue
        # A bare interpolation passes a value without adding words to translate.
        if token.value == INTERPOLATION:
            continue
        (interpolated if token.interpolated else literals).add(token.value)
    return literals, interpolated


def collect() -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    """Every visible string, mapped to the files it appears in."""
    literals: dict[str, list[str]] = {}
    interpolated: dict[str, list[str]] = {}
    for path in shipping_files():
        relative = str(path.relative_to(ROOT))
        plain, formatted = extract(path.read_text(encoding="utf-8"))
        for value in plain:
            literals.setdefault(value, []).append(relative)
        for value in formatted:
            interpolated.setdefault(value, []).append(relative)
    return literals, interpolated


# Use Swift extraction for declared keys, defaults and typed format specifiers.
DECLARATION_FILES = (
    ROOT / "apple/SparkApp/Shared/SparkHouseholdCopy.swift",
    ROOT / "apple/SparkApp/Shared/SparkAutomationCopy.swift",
    ROOT / "apple/SparkApp/Shared/SparkCarPlayCopy.swift",
    ROOT / "apple/SparkApp/Shared/SparkCopy.swift",
    ROOT / "apple/SparkApp/Shared/SparkDashboardCopy.swift",
    ROOT / "apple/SparkApp/Shared/SparkEvidenceCopy.swift",
    ROOT / "apple/SparkApp/Shared/SparkModelCopy.swift",
    ROOT / "apple/SparkApp/Shared/SparkOnboardingClusterCopy.swift",
    ROOT / "apple/SparkApp/Shared/SharedAccessCopy.swift",
    ROOT / "apple/SparkApp/Shared/SparkRemoteAccessCopy.swift",
    ROOT / "apple/SparkApp/Shared/SparkSettingsCopy.swift",
    ROOT / "apple/SparkApp/Shared/SparkTelemetryCopy.swift",
    ROOT / "apple/SparkApp/Shared/SparkValueCopy.swift",
    ROOT / "apple/SparkApp/WidgetShared/WidgetCopy.swift",
    ROOT
    / "apple/Packages/SparkDesignSystem/Sources/SparkDesignSystem/DesignSystemCopy.swift",
    ROOT / "apple/Packages/SparkIntents/Sources/SparkIntents/IntentsCopy.swift",
    ROOT
    / "apple/Packages/SparkLanguageModel/Sources/SparkLanguageModel/LanguageModelCopy.swift",
    ROOT / "apple/Packages/SparkBootstrap/Sources/SparkBootstrap/BootstrapCopy.swift",
    ROOT / "apple/Packages/SparkAPI/Sources/SparkAPI/APICopy.swift",
)

# Reject declarations outside extraction inputs because their keys would otherwise display verbatim.
_DECLARATION_SITE = re.compile(r'\.init\(\s*"[a-z0-9.]+"\s*,\s*defaultValue:')


def stray_declaration_files() -> list[str]:
    """Shipping files that declare a key the extractor cannot see."""
    known = {path.resolve() for path in DECLARATION_FILES}
    stray = []
    for path in shipping_files():
        if path.resolve() in known:
            continue
        if _DECLARATION_SITE.search(path.read_text(encoding="utf-8")):
            stray.append(str(path.relative_to(ROOT)))
    return sorted(stray)


def collect_declared() -> dict[str, dict[str, str]]:
    """Use swiftc -emit-localized-strings to obtain English defaults, comments and compiler-derived argument specifiers."""
    found: dict[str, dict[str, str]] = {}
    with tempfile.TemporaryDirectory() as scratch:
        output = Path(scratch) / "strings"
        output.mkdir()
        for source in DECLARATION_FILES:
            result = subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    "-c",
                    "-emit-localized-strings",
                    "-emit-localized-strings-path",
                    str(output),
                    str(source),
                    "-o",
                    str(Path(scratch) / f"{source.stem}.o"),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode != 0:
                raise AssertionError(
                    f"swiftc could not extract strings from {source.name}:\n"
                    f"{result.stderr.strip()}"
                )
        for emitted in sorted(output.glob("*.stringsdata")):
            document = json.loads(emitted.read_text(encoding="utf-8"))
            for table, entries in document.get("tables", {}).items():
                if table != "Localizable":
                    continue
                for entry in entries:
                    found[entry["key"]] = {
                        "value": entry["value"],
                        "comment": entry.get("comment", ""),
                    }
    return found


#: A declared accessor's name, and the stable key the declaration immediately below it returns.
_ACCESSOR = re.compile(r"static\s+(?:func|var)\s+(\w+)\b")
_DECLARED_KEY = re.compile(r'\.init\(\s*"([a-z0-9._]+)"')
#: Any member reference, which is how every call site names an accessor.
_MEMBER = re.compile(r"\.([A-Za-z_]\w*)")
#: A counted specifier immediately qualifying a word that reads as a plural noun.
COUNTED_NOUN = re.compile(r"%(?:\d+\$)?lld\s+([A-Za-z][A-Za-z'’-]*s)\b")


def declared_accessors() -> dict[str, str]:
    """Every declared key mapped to the accessor a call site writes, so an unused one can be seen."""
    found: dict[str, str] = {}
    for path in DECLARATION_FILES:
        text = path.read_text(encoding="utf-8")
        matches = list(_ACCESSOR.finditer(text))
        for index, match in enumerate(matches):
            stop = matches[index + 1].start() if index + 1 < len(matches) else len(text)
            key = _DECLARED_KEY.search(text, match.end(), stop)
            if key is not None:
                found[key.group(1)] = match.group(1)
    return found


def unused_declarations() -> dict[str, str]:
    """Declared keys no shipping call site names; a declaration is not a call site."""
    accessors = declared_accessors()
    used: set[str] = set()
    for path in shipping_files():
        used.update(_MEMBER.findall(path.read_text(encoding="utf-8")))
    return {key: name for key, name in accessors.items() if name not in used}
