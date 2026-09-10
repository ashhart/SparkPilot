from __future__ import annotations

import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from runtime_schema import load_runtime_schema


def sql_statements(text: str) -> list[str]:
    statements = []
    pending = ""
    for line in text.splitlines(keepends=True):
        if line.lstrip().startswith("--"):
            continue
        pending += line
        if sqlite3.complete_statement(pending):
            statements.append(pending.strip())
            pending = ""
    if pending.strip():
        raise ValueError("Incomplete SQL statement")
    return statements


class RuntimeSchemaTests(unittest.TestCase):
    def test_concatenation_preserves_every_original_statement_and_its_order(self) -> None:
        expected = json.loads((ROOT / "contracts/fixtures/runtime-schema-statements.json").read_text())
        self.assertEqual(sql_statements(load_runtime_schema(ROOT)), expected["statements"])

    def test_ordered_schema_executes_with_all_constraints_and_triggers(self) -> None:
        connection = sqlite3.connect(":memory:")
        self.addCleanup(connection.close)
        connection.executescript(load_runtime_schema(ROOT))
        objects = dict(connection.execute("SELECT name, type FROM sqlite_master"))
        self.assertEqual(sum(kind == "table" for kind in objects.values()), 38)
        self.assertEqual(objects["devices_owner_guard"], "trigger")
        self.assertEqual(objects["devices_owner_delete_guard"], "trigger")
        self.assertEqual(connection.execute("PRAGMA foreign_keys").fetchone(), (1,))

    def test_invalid_composition_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schema = root / "database/schema"
            schema.mkdir(parents=True)
            (schema / "first.sql").write_text("SELECT 1;\n")
            entry = root / "database/runtime-schema.sql"
            for contents in (
                ".read ../outside.sql\n",
                ".read database/schema/first.sql\n.read database/schema/first.sql\n",
                "SELECT 1;\n",
                "-- no fragments\n",
            ):
                with self.subTest(contents=contents), self.assertRaises(ValueError):
                    entry.write_text(contents)
                    load_runtime_schema(root)

    def test_symlinked_fragments_cannot_escape(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schema = root / "database/schema"
            schema.mkdir(parents=True)
            (root / "outside.sql").write_text("SELECT 1;\n")
            (schema / "escape.sql").symlink_to(root / "outside.sql")
            (root / "database/runtime-schema.sql").write_text(".read database/schema/escape.sql\n")
            with self.assertRaisesRegex(ValueError, "inside database/schema"):
                load_runtime_schema(root)


if __name__ == "__main__":
    unittest.main()
