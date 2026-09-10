"""Canonical byte representation used for contract identities."""

from typing import Any
import json


def canonical_json(document: Any, *, sort_keys: bool = True) -> bytes:
    return (
        json.dumps(
            document,
            sort_keys=sort_keys,
            separators=(",", ":"),
            ensure_ascii=False,
        )
        + "\n"
    ).encode()

