#!/usr/bin/env python3
"""Generate transport-neutral Swift and Rust contract bindings from OpenAPI 3.1."""

from __future__ import annotations

import argparse
from pathlib import Path

from contract_python import require_supported_python
from openapi_codegen.model import ContractModel
from openapi_codegen.normalization import canonical_json
from openapi_codegen.output import generate
from openapi_codegen.rust import render_rust
from openapi_codegen.swift import render_swift

ROOT = Path(__file__).resolve().parents[1]
GENERATOR_FORMAT_VERSION = 3


def main() -> None:
    require_supported_python()
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-root", type=Path, default=ROOT)
    args = parser.parse_args()
    generate(ROOT, args.output_root, GENERATOR_FORMAT_VERSION)


if __name__ == "__main__":
    main()
