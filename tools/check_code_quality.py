#!/usr/bin/env python3
"""Check source size and multiline explanations without rewriting source."""

import argparse
import json
from pathlib import Path
import sys

from code_quality.lexical import inspect
from code_quality.source import sources

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 600


def survey(root: Path) -> dict:
    return {str(path.relative_to(root)): inspect(path, path.read_text(encoding='utf-8'))
            for path in sources(root)}


def debt(inventory: dict, notices: dict) -> dict:
    result = {}
    for path, item in inventory.items():
        multiline = [part for part in item['explanations'] if part['end'] > part['start']]
        allowed = notices.get(path, {})
        outstanding = [part for part in multiline if part['sha256'] not in allowed]
        count = len(outstanding)
        lines = item['physical_lines']
        if lines > LIMIT or count:
            result[path] = {'physical_lines': lines if lines > LIMIT else 0,
                            'multiline_explanations': count}
    return result


def compare(found: dict, baseline: dict) -> list[str]:
    errors = []
    for path, metrics in found.items():
        accepted = baseline.get(path, {})
        for metric, value in metrics.items():
            ceiling = accepted.get(metric, 0)
            if value > ceiling:
                errors.append(f'{path}: {metric} = {value}, permitted {ceiling}')
    return errors


def validate_notices(inventory: dict, notices: dict) -> list[str]:
    errors = []
    for path, hashes in notices.items():
        current = {part['sha256'] for part in inventory.get(path, {}).get('explanations', [])}
        for digest, reason in hashes.items():
            if digest not in current or not isinstance(reason, str) or not reason.strip():
                errors.append(f'{path}: missing or unexplained mandatory notice {digest}')
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--notices', type=Path)
    parser.add_argument('--report', type=Path)
    arguments = parser.parse_args()
    inventory = survey(arguments.root)
    baseline = json.loads(arguments.baseline.read_text()) if arguments.baseline else {}
    notices = json.loads(arguments.notices.read_text()) if arguments.notices else {}
    current = debt(inventory, notices)
    errors = validate_notices(inventory, notices) + compare(current, baseline)
    if arguments.report:
        arguments.report.parent.mkdir(parents=True, exist_ok=True)
        arguments.report.write_text(json.dumps({'files': inventory, 'debt': current}, indent=2) + '\n')
    oversized = sum(item['physical_lines'] > LIMIT for item in inventory.values())
    multiline = sum(value['multiline_explanations'] for value in current.values())
    print(f'{len(inventory)} source files; {oversized} oversized; {multiline} multiline explanations')
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == '__main__':
    raise SystemExit(main())
