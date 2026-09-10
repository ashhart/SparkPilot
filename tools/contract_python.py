#!/usr/bin/env python3
"""Python runtime policy shared by contract tooling."""

from __future__ import annotations

import sys

SUPPORTED_PYTHON = (3, 12)


def require_supported_python(version: tuple[int, int] | None = None) -> None:
    actual = version or sys.version_info[:2]
    if actual != SUPPORTED_PYTHON:
        expected = ".".join(map(str, SUPPORTED_PYTHON))
        found = ".".join(map(str, actual))
        raise RuntimeError(
            f"contract tooling requires CPython {expected}.x; found {found}. "
            "Run `just _contract-env` and use .build/contracts-venv312/bin/python3."
        )
