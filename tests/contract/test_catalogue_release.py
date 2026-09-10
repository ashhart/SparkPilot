"""Exercise the public catalogue path without using release keys or real destinations."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/catalogue'))
import spark_catalogue


class CatalogueReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for folder in ('tools/catalogue', 'recipes', 'packaging/trust', 'packaging/catalogue',
                       'contracts/schemas', 'apple/SparkApp/Shared/Resources', 'website/public/models/v2'):
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        for name in ('publish.sh', 'spark_catalogue.py'):
            shutil.copyfile(ROOT / 'tools/catalogue' / name, self.root / 'tools/catalogue' / name)
        shutil.copyfile(ROOT / 'contracts/schemas/model-recipe.schema.json',
                        self.root / 'contracts/schemas/model-recipe.schema.json')
        self.recipe = json.loads((ROOT / 'recipes/nvidia-nemotron-3.5-lightning-30b-a3b-nvfp4.json').read_text())
        self.recipe_path = self.root / 'recipes/released.json'
        self.recipe_path.write_text(json.dumps(self.recipe))
        self.approvals = self.root / 'packaging/catalogue/release-approvals.json'
        self.approvals.write_text(json.dumps({'recipes': {
            self.recipe['metadata']['id']: hashlib.sha256(spark_catalogue.recipe_canonical(self.recipe)).hexdigest()
        }}))
        key = self.root / 'key'
        key.write_bytes(bytes(range(32)))
        key.chmod(0o600)
        public = spark_catalogue.load_private_key(key).public_key().public_bytes(
            spark_catalogue.serialization.Encoding.Raw, spark_catalogue.serialization.PublicFormat.Raw)
        (self.root / 'packaging/trust/catalogue-root.pub').write_text(public.hex())
        self.env = dict(os.environ, SPARK_CATALOGUE_KEY=str(key), SPARK_CATALOGUE_KEY_ID='test',
                        SPARK_WEBSITE_DIR=str(self.root / 'website'), CONTRACT_PYTHON=sys.executable)
        self.outputs = [self.root / path for path in (
            'packaging/catalogue/bootstrap.lab.json', 'apple/SparkApp/Shared/Resources/model-presets.json',
            'website/public/models/v2/catalogue.json')]
        for path in self.outputs:
            path.write_text('existing release')

    def publish(self, *paths):
        return subprocess.run(['bash', str(self.root / 'tools/catalogue/publish.sh'), *map(str, paths)],
                              env=self.env, capture_output=True, text=True)

    def assert_untouched(self):
        self.assertTrue(all(path.read_text() == 'existing release' for path in self.outputs))

    def test_unreviewed_recipe_never_reaches_any_destination(self):
        shutil.copyfile(ROOT / 'recipes/mia-ailab-qwen3.8-flash-next-nvfp4.json',
                        self.root / 'recipes/candidate.json')
        before = self.recipe_path.read_bytes()
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('not approved', result.stderr)
        self.assert_untouched()
        self.assertEqual(self.recipe_path.read_bytes(), before)

    def test_changed_recipe_requires_new_approval(self):
        self.recipe['engine']['image'] = 'vllm/vllm-openai@sha256:' + 'a' * 64
        self.recipe_path.write_text(json.dumps(self.recipe))
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('changed since approval', result.stderr)
        self.assert_untouched()

    def test_explicit_approved_selection_can_publish_with_candidate_present(self):
        (self.root / 'recipes/candidate.json').write_text('{}')
        result = self.publish(self.recipe_path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for output in self.outputs:
            recipes = json.loads(output.read_text())['recipes']
            self.assertEqual([entry['metadata']['id'] for entry in recipes], [self.recipe['metadata']['id']])

    def test_missing_approvals_fails_before_mutation(self):
        self.approvals.unlink()
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_untouched()

    def test_testflight_refuses_held_catalogue_before_building(self):
        shutil.copyfile(ROOT / 'tools/archive-testflight.sh', self.root / 'tools/archive-testflight.sh')
        marker = self.root / 'build-started'
        dependency_check = self.root / 'tools/check-swift-dependencies.sh'
        dependency_check.write_text(f'#!/bin/bash\ntouch "{marker}"\nexit 42\n')
        dependency_check.chmod(0o700)
        for held in (True, False):
            with self.subTest(held=held):
                recipe = json.loads((ROOT / 'recipes/mia-ailab-qwen3.8-flash-next-nvfp4.json').read_text()) if held else self.recipe
                self.outputs[1].write_text(json.dumps({'recipes': [recipe]}))
                result = subprocess.run(['bash', str(self.root / 'tools/archive-testflight.sh')],
                                        env=dict(self.env, DEVELOPMENT_TEAM='test', BUILD_NUMBER='34'),
                                        capture_output=True, text=True)
                self.assertEqual(marker.exists(), not held, result.stdout + result.stderr)
                self.assertEqual(result.returncode, 1 if held else 42, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
