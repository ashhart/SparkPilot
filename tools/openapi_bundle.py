#!/usr/bin/env python3
"""Bundle repository-local OpenAPI references before validation and generation."""

from __future__ import annotations

from pathlib import Path
from typing import Any
from urllib.parse import unquote, urldefrag, urlsplit

from contract_yaml import load_yaml_strict


def load_openapi_document(path: Path) -> dict[str, Any]:
    root = path.resolve()
    documents: dict[Path, Any] = {}
    resolving: set[tuple[Path, str]] = set()

    def read(target: Path) -> Any:
        if not target.is_relative_to(root.parent):
            raise ValueError(f"OpenAPI reference escapes the contract directory: {target.name}")
        if target not in documents:
            documents[target] = load_yaml_strict(target)
        return documents[target]

    def resolve_pointer(document: Any, fragment: str) -> Any:
        if not fragment:
            return document
        if not fragment.startswith("/"):
            raise ValueError(f"OpenAPI reference requires a JSON pointer: #{fragment}")
        for token in fragment[1:].split("/"):
            key = token.replace("~1", "/").replace("~0", "~")
            try:
                document = document[int(key)] if isinstance(document, list) else document[key]
            except (KeyError, IndexError, ValueError, TypeError) as error:
                raise ValueError(f"Unresolved OpenAPI reference: #{fragment}") from error
        return document

    def expand(value: Any, source: Path) -> Any:
        if isinstance(value, list):
            return [expand(item, source) for item in value]
        if not isinstance(value, dict):
            return value
        reference = value.get("$ref")
        if not reference:
            return {key: expand(item, source) for key, item in value.items()}
        if not isinstance(reference, str):
            raise ValueError("OpenAPI references must be strings")
        url = urlsplit(reference)
        if url.scheme or url.netloc or url.query:
            raise ValueError(f"Only local OpenAPI references are supported: {reference}")
        relative, fragment = urldefrag(reference)
        target = (source.parent / unquote(relative)).resolve() if relative else source
        fragment = unquote(fragment)
        if target == root and fragment:
            # Canonical root references stay symbolic so recursive component schemas remain legal.
            return {key: "#" + fragment if key == "$ref" else expand(item, source) for key, item in value.items()}
        if len(value) != 1:
            raise ValueError(f"External OpenAPI reference cannot have sibling fields: {reference}")
        identity = (target, fragment)
        if identity in resolving:
            raise ValueError(f"Cyclic OpenAPI document reference: {reference}")
        resolving.add(identity)
        try:
            selected = resolve_pointer(read(target), fragment)
            return expand(selected, target)
        finally:
            resolving.remove(identity)

    document = expand(read(root), root)
    if not isinstance(document, dict):
        raise ValueError("OpenAPI document must be a mapping")
    return document
