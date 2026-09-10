#!/usr/bin/env python3
"""Duplicate-key rejecting JSON loading for contract and lock inputs."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


class DuplicateJSONKeyError(ValueError):
    """Raised when a JSON object repeats a member name."""


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJSONKeyError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def load_json_strict_text(text: str) -> Any:
    return json.loads(text, object_pairs_hook=_unique_object)


def load_json_strict(path: Path) -> Any:
    return load_json_strict_text(path.read_text(encoding="utf-8"))
