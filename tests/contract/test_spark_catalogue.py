from __future__ import annotations

import contextlib
import copy
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "catalogue"))

import spark_catalogue

SIGNED_RECIPE = ROOT / "recipes/nvidia-nemotron-3.5-lightning-30b-a3b-nvfp4.json"
KEY_ID = "catalogue-test"
ZERO_DIGEST = "0" * 64


def run(*argv: str) -> tuple[int, str]:
    """Run the tool in-process and return its exit status with everything it printed."""
    output = io.StringIO()
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        try:
            status = spark_catalogue.main(list(argv))
        except SystemExit as error:
            status = int(error.code or 0)
    return status, output.getvalue()


class CatalogueToolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="spark-catalogue-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.key_dir = self.tmp / "keys"
        self.root = self.tmp / "catalogue-root.pub"
        status, output = run("keygen", "--key-id", KEY_ID, "--key-dir", str(self.key_dir),
                             "--root-out", str(self.root))
        self.assertEqual(status, 0, output)
        self.key = self.key_dir / f"{KEY_ID}.ed25519"
        self.recipe = json.loads(SIGNED_RECIPE.read_text(encoding="utf-8"))

    def assemble(self, recipe: dict, name: str = "recipe.json") -> tuple[int, str, Path]:
        recipe_path = self.tmp / name
        recipe_path.write_text(json.dumps(recipe, indent=2) + "\n", encoding="utf-8")
        catalogue = self.tmp / "catalogue.json"
        status, output = run("assemble", "--key", str(self.key), "--key-id", KEY_ID,
                             "--output", str(catalogue), str(recipe_path))
        return status, output, catalogue

    def verify(self, catalogue: Path) -> tuple[int, str]:
        return run("verify", "--root", str(self.root), "--key-id", KEY_ID, str(catalogue))

    def catalogue_with_unchecked_recipe(self, recipe: dict) -> Path:
        """Sign a catalogue the way an older tool would, without the arithmetic check, so verify can be exercised on it."""
        key = spark_catalogue.load_private_key(self.key)
        signed = spark_catalogue.signed_recipe(recipe, key, KEY_ID)
        snapshot = {
            "recipes": [signed],
            "signature": {
                "keyID": KEY_ID,
                "algorithm": spark_catalogue.ALGORITHM,
                "value": spark_catalogue.b64url(key.sign(spark_catalogue.catalogue_canonical([signed]))),
            },
        }
        catalogue = self.tmp / "unchecked-catalogue.json"
        spark_catalogue.write_json(catalogue, snapshot)
        return catalogue

    def test_a_conforming_catalogue_verifies(self) -> None:
        status, output, catalogue = self.assemble(self.recipe)
        self.assertEqual(status, 0, output)
        status, output = self.verify(catalogue)
        self.assertEqual(status, 0, output)
        self.assertIn("verified", output)

    def test_verify_rejects_a_signed_recipe_the_runtime_would_refuse(self) -> None:
        cases = {
            "trustRemoteCode": (("source", "trustRemoteCode"), True, "trustRemoteCode"),
            "absolute media root": (("security", "allowedMediaRoots"), ["/etc"], "allowedMediaRoots"),
            "traversing media root": (
                ("security", "allowedMediaRoots"),
                ["/var/lib/spark-runtime/assets/../identity"],
                "allowedMediaRoots",
            ),
            "traversing id": (("metadata", "id"), "a/../../etc", "metadata/id"),
            "zero digest": (("engine", "image"), f"vllm/vllm-openai@sha256:{ZERO_DIGEST}", "image"),
            "tag only": (("engine", "image"), "vllm/vllm-openai:latest", "image"),
        }
        for name, (path, value, expected) in cases.items():
            with self.subTest(case=name):
                recipe = copy.deepcopy(self.recipe)
                recipe[path[0]][path[1]] = value
                status, output, catalogue = self.assemble(recipe)
                self.assertEqual(status, 0, output)
                status, output = self.verify(catalogue)
                self.assertEqual(status, 1, output)
                self.assertIn(expected, output)

    def test_verify_refuses_a_peak_that_disagrees_with_the_recipe_arithmetic(self) -> None:
        """ADR-043: a signed recipe cannot claim a peak other than weights + cache + state + overhead."""
        self.assertIsNone(spark_catalogue.memory_arithmetic_error(self.recipe))
        recipe = copy.deepcopy(self.recipe)
        recipe["profiles"][0]["expectedPeakBytes"] = 96_000_000_000
        # Signing refuses the disagreement outright, so a lying recipe never reaches a catalogue.
        status, output, _ = self.assemble(recipe)
        self.assertEqual(status, 1, output)
        self.assertIn("memory arithmetic", output)
        self.assertIn("derives 47622320128", output)
        catalogue = self.catalogue_with_unchecked_recipe(recipe)
        status, output = self.verify(catalogue)
        self.assertEqual(status, 1, output)
        self.assertIn("memory arithmetic", output)
        self.assertIn("derives 47622320128", output)
        half = copy.deepcopy(self.recipe)
        del half["memory"]["stateBytesPerSequence"]
        self.assertIsNotNone(spark_catalogue.memory_arithmetic_error(half))
        older = copy.deepcopy(self.recipe)
        del older["memory"]["kvCacheBytesPerToken"]
        del older["memory"]["stateBytesPerSequence"]
        older["profiles"][0]["expectedPeakBytes"] = 96_000_000_000
        self.assertIsNone(spark_catalogue.memory_arithmetic_error(older))

    def test_verify_still_checks_signatures_first(self) -> None:
        status, output, catalogue = self.assemble(self.recipe)
        self.assertEqual(status, 0, output)
        snapshot = json.loads(catalogue.read_text(encoding="utf-8"))
        snapshot["recipes"][0]["metadata"]["displayName"] = "tampered"
        catalogue.write_text(json.dumps(snapshot) + "\n", encoding="utf-8")
        status, output = self.verify(catalogue)
        self.assertEqual(status, 1, output)
        self.assertIn("signature does not verify", output)

    def test_verify_refuses_to_run_without_a_schema(self) -> None:
        status, output, catalogue = self.assemble(self.recipe)
        self.assertEqual(status, 0, output)
        status, output = run("verify", "--root", str(self.root), "--key-id", KEY_ID,
                             "--schema", str(self.tmp / "missing.json"), str(catalogue))
        self.assertEqual(status, 1, output)
        self.assertIn("no recipe schema", output)

    def test_pinned_image_error_mirrors_the_runtime(self) -> None:
        self.assertIsNone(spark_catalogue.pinned_image_error("vllm/vllm-openai@sha256:" + "a" * 64))
        for image in (
            "vllm/vllm-openai:latest",
            "vllm/vllm-openai@sha256:" + ZERO_DIGEST,
            "vllm/vllm-openai@sha256:" + "A" * 64,
            "vllm/vllm openai@sha256:" + "a" * 64,
        ):
            with self.subTest(image=image):
                self.assertIsNotNone(spark_catalogue.pinned_image_error(image))


class ScaffoldDigestTests(unittest.TestCase):
    README = "docker run vllm/vllm-openai:v0.11.0 --model acme/model-7b --max-model-len 32768\n"

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="spark-scaffold-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.output = self.tmp / "draft.json"

    def fake_fetch_json(self, url: str):
        if url.endswith("/repos/acme/serve"):
            return {"default_branch": "main", "description": "Serve it"}
        if "/commits/" in url:
            return {"sha": "f" * 40}
        if url.endswith("/api/models/acme/model-7b"):
            return {"sha": "e" * 40, "gated": False}
        if url.endswith("/tree/main"):
            return [{"path": "model.safetensors", "size": 7_000_000_000}]
        raise AssertionError(f"unexpected fetch: {url}")

    def fake_fetch(self, url: str, accept: str = "application/json") -> bytes:
        if url.endswith("/README.md"):
            return self.README.encode("utf-8")
        raise spark_catalogue.urllib.error.HTTPError(url, 404, "missing", None, None)

    def scaffold(self, *extra: str) -> tuple[int, str]:
        with mock.patch.object(spark_catalogue, "fetch_json", self.fake_fetch_json), \
                mock.patch.object(spark_catalogue, "fetch", self.fake_fetch):
            return run("scaffold", "--github", "https://github.com/acme/serve",
                       "--output", str(self.output), *extra)

    def test_unresolved_digest_fails_instead_of_writing_a_placeholder(self) -> None:
        with mock.patch.object(spark_catalogue, "docker_hub_arm64_digest", lambda image: None):
            status, output = self.scaffold()
        self.assertEqual(status, 1, output)
        self.assertIn("could not resolve", output)
        self.assertFalse(self.output.exists())

    def test_resolved_digest_is_written_and_passes_the_schema(self) -> None:
        pinned = "vllm/vllm-openai@sha256:" + "b" * 64
        with mock.patch.object(spark_catalogue, "docker_hub_arm64_digest", lambda image: pinned):
            status, output = self.scaffold()
        self.assertEqual(status, 0, output)
        draft = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(draft["engine"]["image"], pinned)
        self.assertEqual(draft["metadata"]["id"], "acme/model-7b")
        self.assertEqual(draft["profiles"][0]["maxModelLength"], 32768)
        self.assertIsNone(spark_catalogue.pinned_image_error(draft["engine"]["image"]))

    def test_explicit_pinned_image_skips_docker_hub(self) -> None:
        pinned = "nvcr.io/nvidia/vllm@sha256:" + "c" * 64
        with mock.patch.object(spark_catalogue, "docker_hub_arm64_digest",
                               lambda image: self.fail("Docker Hub consulted")):
            status, output = self.scaffold("--image", pinned)
        self.assertEqual(status, 0, output)
        draft = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(draft["engine"]["image"], pinned)

    def test_explicit_zero_digest_is_refused(self) -> None:
        with mock.patch.object(spark_catalogue, "docker_hub_arm64_digest", lambda image: None):
            status, output = self.scaffold("--image", "vllm/vllm-openai@sha256:" + ZERO_DIGEST)
        self.assertEqual(status, 1, output)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
