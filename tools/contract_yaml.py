#!/usr/bin/env python3
"""Strict YAML loading shared by contract validation and generation."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml


class DuplicateKeyError(ValueError):
    """Raised when a YAML mapping repeats a key."""


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def _construct_unique_mapping(
    loader: UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False
) -> dict[Any, Any]:
    loader.flatten_mapping(node)
    mapping: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in mapping
        except TypeError as error:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                "found an unhashable key",
                key_node.start_mark,
            ) from error
        if duplicate:
            raise DuplicateKeyError(
                f"duplicate YAML key {key!r} at "
                f"line {key_node.start_mark.line + 1}, "
                f"column {key_node.start_mark.column + 1}"
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _construct_unique_mapping,
)


def load_yaml_strict_text(text: str) -> Any:
    return yaml.load(text, Loader=UniqueKeyLoader)


def load_yaml_strict(path: Path) -> Any:
    return load_yaml_strict_text(path.read_text(encoding="utf-8"))
