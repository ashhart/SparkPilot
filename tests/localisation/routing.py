"""Classify catalogue routing from a literal's enclosing call and argument label rather than nearby source text."""

from __future__ import annotations

from swiftlex import StringToken

# Only the first unlabelled argument of these calls is visible copy; labelled symbol names remain identifiers.
UNLABELLED_COPY_CALLEES = frozenset(
    {
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
        "IntentDescription",
        "IntentDialog",
        ".navigationTitle",
        ".alert",
        ".confirmationDialog",
        ".accessibilityLabel",
        ".accessibilityHint",
        ".accessibilityValue",
        ".configurationDisplayName",
        ".description",
    }
)

# Declared defaultValue and comment arguments are catalogue metadata, not separate keys.
DECLARATION_PARTS = frozenset(
    {
        (".init", "defaultValue"),
        (".init", "comment"),
        ("LocalizedStringResource", "defaultValue"),
        ("LocalizedStringResource", "comment"),
    }
)

# Match callee and label together because title: is localisable only for specific resource-typed APIs.
COPY_ARGUMENTS = frozenset(
    {
        ("String", "localized"),
        ("Parameter", "title"),
        ("AppShortcut", "shortTitle"),
        ("DisplayRepresentation", "title"),
        ("DisplayRepresentation", "subtitle"),
    }
)

# Assignments to these types are catalogue keys by construction.
COPY_TYPES = frozenset({"LocalizedStringResource", "TypeDisplayRepresentation"})


# Route App Shortcuts phrases to their required AppShortcuts table, whose coverage is checked independently.
SEPARATE_TABLE_ARGUMENTS = frozenset({("AppShortcut", "phrases")})


def is_catalogue_key(token: StringToken) -> bool:
    """Whether this literal is itself a key the catalogue must contain."""
    if token.assigned_type in COPY_TYPES:
        return True
    context = token.context
    if context is None:
        return False
    if (context.callee, context.label) in COPY_ARGUMENTS:
        return True
    return context.label is None and context.callee in UNLABELLED_COPY_CALLEES


def is_routed(token: StringToken) -> bool:
    """Include declaration defaults and translator comments as routed metadata without treating them as keys."""
    if is_catalogue_key(token):
        return True
    context = token.context
    if context is None:
        return False
    return (context.callee, context.label) in (
        DECLARATION_PARTS | SEPARATE_TABLE_ARGUMENTS
    )
