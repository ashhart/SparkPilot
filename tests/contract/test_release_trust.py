"""Exercise the shipping trust-document gate with authenticated offline delegation."""

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import validate_contracts


class ReleaseTrustContractTests(unittest.TestCase):
    def test_shipping_gate_accepts_delegation_but_refuses_policy_tampering(self):
        trust = json.loads((ROOT / "contracts/fixtures/release-delegation.json").read_text())["trust"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "packaging/trust/release-keys.json"
            path.parent.mkdir(parents=True)
            with patch.object(validate_contracts, "ROOT", root):
                path.write_text(json.dumps(trust))
                validate_contracts.validate_release_trust_root()
                invalid = copy.deepcopy(trust)
                invalid["keys"][0]["channels"].append("lab")
                path.write_text(json.dumps(invalid))
                with self.assertRaises(SystemExit):
                    validate_contracts.validate_release_trust_root()
                path.write_text(json.dumps(dict(schema=1, keys=trust["keys"])))
                with self.assertRaises(SystemExit):
                    validate_contracts.validate_release_trust_root()


if __name__ == "__main__":
    unittest.main()
