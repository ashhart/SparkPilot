"""Reject tampered or redirected security packages before the image build."""
import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'packaging/engines/qwen38'))
import dependencies


class DependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.item = {'filename': 'test_1_arm64.deb', 'bytes': 7,
                     'sha256': hashlib.sha256(b'package').hexdigest(),
                     'url': 'https://ports.ubuntu.com/ubuntu-ports/pool/main/t/test_1_arm64.deb'}

    def opener(self, data, url=None):
        response = io.BytesIO(data)
        response.geturl = lambda: url or self.item['url']
        return Mock(open=Mock(return_value=response))

    def test_exact_package_is_published(self):
        dependencies.fetch_package(self.item, self.root, self.opener(b'package'))
        self.assertEqual((self.root / self.item['filename']).read_bytes(), b'package')

    def test_corruption_truncation_and_oversize_leave_no_artifact(self):
        for data in [b'corrupt', b'pack', b'package-extra']:
            with self.subTest(data=data), self.assertRaises(RuntimeError):
                dependencies.fetch_package(self.item, self.root, self.opener(data))
            self.assertEqual(list(self.root.iterdir()), [])

    def test_bad_paths_and_origins_are_rejected_before_download(self):
        for field, value in [('filename', '../outside.deb'), ('url', 'https://example.com/test.deb'),
                             ('url', self.item['url'].replace('https:', 'http:'))]:
            opener = self.opener(b'package')
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                dependencies.fetch_package(dict(self.item, **{field: value}), self.root, opener)
            opener.open.assert_not_called()

    def test_redirect_cannot_probe_other_hosts_or_plaintext(self):
        handler = dependencies.PinnedRedirect()
        for url in ['http://ports.ubuntu.com/ubuntu-ports/pool/a.deb',
                    'https://127.0.0.1/private', 'https://ports.ubuntu.com.evil.test/a.deb']:
            with self.subTest(url=url), self.assertRaises(RuntimeError):
                handler.redirect_request(None, None, 302, '', {}, url)

    def test_unapproved_final_url_leaves_no_artifact(self):
        with self.assertRaises(RuntimeError):
            dependencies.fetch_package(self.item, self.root, self.opener(b'package', 'https://example.com'))
        self.assertEqual(list(self.root.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
