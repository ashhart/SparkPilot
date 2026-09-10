"""Language identifiers retain the contract wire names."""

import re


def words(value: str) -> list[str]:
    return re.findall(r"[A-Z]+(?=[A-Z][a-z]|\d|$)|[A-Z]?[a-z]+|\d+", value.replace("-", "_").replace("_", " "))


def pascal(value: str) -> str:
    return "".join(part[:1].upper() + part[1:] for part in words(value))


def lower_camel(value: str) -> str:
    parts = words(value)
    return parts[0].lower() + "".join(part[:1].upper() + part[1:] for part in parts[1:])


# Escape only the emitted identifier; wire-name comparisons remain unescaped.
SWIFT_KEYWORDS = frozenset(
    {
        # Declarations
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
        "func", "import", "init", "inout", "internal", "let", "operator",
        "precedencegroup", "private", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var",
        # Statements
        "break", "case", "continue", "default", "defer", "do", "else",
        "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch",
        "where", "while",
        # Expressions and types
        "Any", "Self", "as", "await", "catch", "false", "is", "nil", "self",
        "super", "throw", "throws", "true", "try", "_",
    }
)


def swift_identifier(value: str) -> str:
    """Escape a Swift reserved word so it can be used as a declaration name."""
    return f"`{value}`" if value in SWIFT_KEYWORDS else value


def screaming_snake(value: str) -> str:
    return "_".join(part.upper() for part in words(value))


def snake(value: str) -> str:
    return "_".join(part.lower() for part in words(value))


RUST_RESERVED = {"type", "match", "ref", "self", "crate", "super", "enum", "struct", "move"}


def rust_name(value: str) -> str:
    name = snake(value)
    return f"r#{name}" if name in RUST_RESERVED else name


