"""Lex Swift comments, raw and multiline literals, and nested interpolation code while retaining each literal's call context."""

from __future__ import annotations

import re
from dataclasses import dataclass, field

#: Interpolation marker used to classify surrounding literal words independently of embedded expressions.
INTERPOLATION = "\\(…)"


@dataclass
class CallContext:
    """The call a literal is an argument to, and which argument it is."""

    #: Identifier or member chain immediately before the opening parenthesis.
    callee: str
    #: Argument label attached to this literal, when present.
    label: str | None = None
    #: Keeps a collection argument label fixed for every element of the collection.
    fixed_label: bool = False
    #: Offset of the callee or collection bracket so routing checks inspect context preceding the whole call.
    call_start: int | None = None


@dataclass
class StringToken:
    """One string literal, and where it sits."""

    #: Byte offset of the opening delimiter.
    start: int
    #: Byte offset just past the closing delimiter.
    end: int
    #: Resolved literal text with interpolation expressions replaced by markers.
    value: str
    #: Whether the literal carried an interpolation.
    interpolated: bool = False
    #: Literals found inside this one's interpolations.
    nested: list["StringToken"] = field(default_factory=list)
    #: The innermost call this literal is an argument to, if any.
    context: "CallContext | None" = None
    #: Declared assignment type, such as LocalizedStringResource, when present.
    assigned_type: str | None = None


def _pounds_at(text: str, index: int) -> int:
    count = 0
    while index + count < len(text) and text[index + count] == "#":
        count += 1
    return count


def _string_start(text: str, index: int) -> tuple[int, int, str] | None:
    """`(pounds, delimiter length, delimiter)` if a literal starts here."""
    pounds = _pounds_at(text, index)
    after = index + pounds
    if text.startswith('"""', after):
        return pounds, 3, '"""'
    if text.startswith('"', after):
        return pounds, 1, '"'
    return None


def _skip_block_comment(text: str, index: int) -> int:
    """Past a `/* … */`, honouring Swift's nesting."""
    depth = 0
    while index < len(text):
        if text.startswith("/*", index):
            depth += 1
            index += 2
            continue
        if text.startswith("*/", index):
            depth -= 1
            index += 2
            if depth == 0:
                return index
            continue
        index += 1
    return index


def lex_string(text: str, index: int) -> StringToken:
    """Lex one literal beginning at `index`. Assumes a literal starts there."""
    start = index
    found = _string_start(text, index)
    assert found is not None, "lex_string called off a literal"
    pounds, width, delimiter = found
    index += pounds + width
    escape = "\\" + "#" * pounds

    parts: list[str] = []
    nested: list[StringToken] = []
    interpolated = False
    while index < len(text):
        if text.startswith(delimiter, index) and _pounds_at(text, index + width) >= pounds:
            index += width + pounds
            break
        if text.startswith(escape, index):
            rest = index + len(escape)
            if rest < len(text) and text[rest] == "(":
                interpolated = True
                parts.append(INTERPOLATION)
                index, inner = _skip_interpolation(text, rest)
                nested.extend(inner)
                continue
            # Decode escapes that change rendered text and preserve the others.
            if rest < len(text):
                parts.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(text[rest], text[rest]))
                index = rest + 1
                continue
        parts.append(text[index])
        index += 1

    value = "".join(parts)
    if width == 3:
        # Strip multiline indentation and line continuations because they are source layout.
        value = value.replace("\\\n", "")
        value = " ".join(value.split())
    return StringToken(
        start=start, end=index, value=value, interpolated=interpolated, nested=nested
    )


def _skip_interpolation(text: str, index: int) -> tuple[int, list[StringToken]]:
    """Skip balanced interpolation code while ignoring parentheses and quotes inside comments."""
    assert text[index] == "("
    depth = 0
    found: list[StringToken] = []
    while index < len(text):
        if text.startswith("//", index):
            newline = text.find("\n", index)
            index = len(text) if newline < 0 else newline
            continue
        if text.startswith("/*", index):
            index = _skip_block_comment(text, index)
            continue
        character = text[index]
        if _string_start(text, index) is not None:
            token = lex_string(text, index)
            found.append(token)
            found.extend(token.nested)
            index = token.end
            continue
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return index + 1, found
        index += 1
    return index, found


#: An identifier or member chain: `Text`, `.accessibilityLabel`, `Foo.bar`.
_CALLEE = re.compile(r"[.\w]+$")
#: `label:` immediately before a position, with any whitespace between.
_LABEL = re.compile(r"(\w+)\s*:\s*$")
#: `: SomeType =` on a declaration, so an assignment's type is known.
_DECLARED_TYPE = re.compile(r":\s*([\w.<>?\[\] ]+?)\s*=\s*$")


def strings(text: str) -> list[StringToken]:
    """Track delimiter frames to attach every literal to its actual enclosing call and argument."""
    found: list[StringToken] = []
    stack: list[CallContext] = []
    index = 0
    while index < len(text):
        if text.startswith("//", index):
            newline = text.find("\n", index)
            index = len(text) if newline < 0 else newline
            continue
        if text.startswith("/*", index):
            index = _skip_block_comment(text, index)
            continue
        if _string_start(text, index) is not None:
            token = lex_string(text, index)
            before = _significant_before(text, index)
            if stack:
                if not stack[-1].fixed_label:
                    label = _LABEL.search(before)
                    stack[-1].label = label.group(1) if label else None
                token.context = CallContext(
                    stack[-1].callee,
                    stack[-1].label,
                    call_start=stack[-1].call_start,
                )
            declared = _DECLARED_TYPE.search(before)
            if declared:
                token.assigned_type = declared.group(1)
            found.append(token)
            found.extend(token.nested)
            index = token.end
            continue
        character = text[index]
        if character in "([":
            before = _significant_before(text, index)
            if character == "(":
                match = _CALLEE.search(before)
                callee = match.group(0) if match else ""
                stack.append(CallContext(callee, call_start=index - len(callee)))
            else:
                # Collection elements inherit the enclosing argument call and label, including App Shortcuts phrase arrays.
                label = _LABEL.search(before)
                if label and stack:
                    stack.append(
                        CallContext(
                            stack[-1].callee,
                            label.group(1),
                            fixed_label=True,
                            call_start=stack[-1].call_start,
                        )
                    )
                else:
                    stack.append(CallContext("", call_start=index))
        elif character in ")]":
            if stack:
                stack.pop()
        elif character == "," and stack and not stack[-1].fixed_label:
            stack[-1].label = None
        index += 1
    return found


def _significant_before(text: str, index: int, span: int = 200) -> str:
    """Return adjacent code without comments to identify a callee or argument label, never to infer routing by proximity."""
    window = text[max(0, index - span) : index]
    without_comments = re.sub(r"/\*.*?\*/", " ", window, flags=re.DOTALL)
    without_comments = re.sub(r"//[^\n]*", " ", without_comments)
    return " ".join(without_comments.split()) + (
        " " if window and window[-1].isspace() else ""
    )


def code_before(text: str, token: StringToken, span: int = 120) -> str:
    """Inspect bounded adjacent code only for canonical-formatting calls; routing remains structural."""
    return " ".join(text[max(0, token.start - span) : token.start].split())
