from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from jsonschema import Draft202012Validator, FormatChecker

from contract_json import load_json_strict

SCHEMA = load_json_strict(ROOT / "contracts/schemas/model-recipe.schema.json")
SIGNED_RECIPE = ROOT / "recipes/nvidia-nemotron-3.5-lightning-30b-a3b-nvfp4.json"
ASSET_ROOT = "/var/lib/spark-runtime/assets/"


def errors(recipe: dict) -> list[str]:
    validator = Draft202012Validator(SCHEMA, format_checker=FormatChecker())
    return [error.message for error in validator.iter_errors(recipe)]


class RecipeSchemaMirrorsRuntimeTests(unittest.TestCase):
    """The schema must refuse what sparkd's model_paths.rs and spark-models' recipe.rs refuse."""

    def setUp(self) -> None:
        self.recipe = load_json_strict(SIGNED_RECIPE)
        self.assertEqual(errors(self.recipe), [])

    def with_id(self, model_id: str) -> dict:
        recipe = copy.deepcopy(self.recipe)
        recipe["metadata"]["id"] = model_id
        return recipe

    def with_media_roots(self, roots: list[str]) -> dict:
        recipe = copy.deepcopy(self.recipe)
        recipe["security"]["allowedMediaRoots"] = roots
        return recipe

    def test_model_id_is_exactly_one_safe_owner_name_pair(self) -> None:
        for model_id in (
            "nvidia/nemotron-3.5-lightning-30b-a3b-nvfp4",
            "acme/model-32b",
            "a/b",
            "owner/...",
            "owner/.hidden",
            "a" * 100 + "/" + "b" * 99,
        ):
            with self.subTest(model_id=model_id):
                self.assertEqual(errors(self.with_id(model_id)), [])

    def test_model_id_traversal_and_shape_violations_are_rejected(self) -> None:
        for model_id in (
            "a/../../etc",
            "assets/../../etc",
            "../model",
            "acme/..",
            "acme/.",
            "./acme/model",
            "model",
            "acme/model/extra",
            "acme//model",
            "/acme/model",
            "acme/model/",
            "acme/Model",
            "acme/model?x",
            "a" * 100 + "/" + "b" * 100,
        ):
            with self.subTest(model_id=model_id):
                self.assertNotEqual(errors(self.with_id(model_id)), [])

    def test_media_roots_stay_under_the_asset_root(self) -> None:
        accepted = [
            ASSET_ROOT,
            ASSET_ROOT + "images",
            ASSET_ROOT + "images/",
            ASSET_ROOT + "images/2026-09/photo.png",
            ASSET_ROOT + "...",
            ASSET_ROOT + ".hidden/..cache",
        ]
        self.assertEqual(errors(self.with_media_roots(accepted)), [])

    def test_media_root_traversal_is_rejected(self) -> None:
        for root in (
            "/etc",
            "/var/lib/spark-runtime/assets",
            "/var/lib/spark-runtime/assets-other/x",
            ASSET_ROOT + "../identity",
            ASSET_ROOT + "a/../../etc",
            ASSET_ROOT + "assets/../../etc",
            ASSET_ROOT + "..",
            ASSET_ROOT + ".",
            ASSET_ROOT + "./x",
            ASSET_ROOT + "a/./x",
            ASSET_ROOT + "a//x",
            "var/lib/spark-runtime/assets/x",
        ):
            with self.subTest(root=root):
                self.assertNotEqual(errors(self.with_media_roots([root])), [])

    def test_all_zero_image_digest_is_a_placeholder_not_a_pin(self) -> None:
        recipe = copy.deepcopy(self.recipe)
        recipe["engine"]["image"] = "vllm/vllm-openai@sha256:" + "0" * 64
        self.assertNotEqual(errors(recipe), [])
        recipe["engine"]["image"] = "vllm/vllm-openai@sha256:" + "0" * 63 + "1"
        self.assertEqual(errors(recipe), [])
        recipe["engine"]["image"] = "vllm/vllm openai@sha256:" + "a" * 64
        self.assertNotEqual(errors(recipe), [])

    def test_launch_arithmetic_fields_are_declared_together_and_positive(self) -> None:
        """ADR-043: the shipped recipe declares both per-token fields; one without the other is not a recipe."""
        self.assertEqual(self.recipe["memory"]["kvCacheBytesPerToken"], 3072)
        self.assertEqual(self.recipe["memory"]["stateBytesPerSequence"], 134_217_728)
        self.assertEqual(
            [profile["id"] for profile in self.recipe["profiles"]],
            ["agent-256k", "long-1m", "agent-64k"],
        )
        half = copy.deepcopy(self.recipe)
        del half["memory"]["stateBytesPerSequence"]
        self.assertNotEqual(errors(half), [])
        zero = copy.deepcopy(self.recipe)
        zero["memory"]["kvCacheBytesPerToken"] = 0
        self.assertNotEqual(errors(zero), [])
        older = copy.deepcopy(self.recipe)
        del older["memory"]["kvCacheBytesPerToken"]
        del older["memory"]["stateBytesPerSequence"]
        self.assertEqual(errors(older), [])

    def test_trust_remote_code_cannot_be_requested(self) -> None:
        recipe = copy.deepcopy(self.recipe)
        recipe["source"]["trustRemoteCode"] = True
        self.assertNotEqual(errors(recipe), [])


if __name__ == "__main__":
    unittest.main()
