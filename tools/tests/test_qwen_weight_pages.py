"""Only clean pages belonging to managed weight shards may be released."""
import errno
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'packaging/engines/qwen38/weight_page_cache.py'
spec = importlib.util.spec_from_file_location('weight_page_cache', SOURCE)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class WeightPageTests(unittest.TestCase):
    def test_releases_read_only_shards_without_modifying_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            shard = Path(directory) / 'model.safetensors'
            shard.write_bytes(b'verified model weights')
            descriptors = []

            def release(fd, offset, length, advice):
                descriptors.append(fd)
                self.assertEqual(os.read(fd, 64), b'verified model weights')
                with self.assertRaises(OSError) as error:
                    os.write(fd, b'x')
                self.assertEqual(error.exception.errno, errno.EBADF)
                self.assertEqual((offset, length, advice), (0, 0, 4))

            with patch.object(Path, 'glob', return_value=[shard]), \
                    patch.object(os, 'POSIX_FADV_DONTNEED', 4, create=True), \
                    patch.object(os, 'posix_fadvise', side_effect=release, create=True):
                cache._sparkpilot_release_weight_pages('/model')
            self.assertEqual(shard.read_bytes(), b'verified model weights')
            with self.assertRaises(OSError):
                os.fstat(descriptors[0])

    def test_rejects_other_mounts_and_missing_shards(self):
        with self.assertRaisesRegex(RuntimeError, 'managed read-only'):
            cache._sparkpilot_release_weight_pages('/other')
        with patch.object(Path, 'glob', return_value=[]), \
                self.assertRaisesRegex(RuntimeError, 'No managed'):
            cache._sparkpilot_release_weight_pages('/model')

    def test_refuses_symlinks_and_nonregular_files_without_blocking(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / 'outside'
            target.write_bytes(b'other data')
            link = root / 'link.safetensors'
            link.symlink_to(target)
            fifo = root / 'fifo.safetensors'
            os.mkfifo(fifo)
            for candidate in [link, fifo]:
                with patch.object(Path, 'glob', return_value=[candidate]), \
                        self.assertRaises((OSError, RuntimeError)):
                    cache._sparkpilot_release_weight_pages('/model')
            self.assertEqual(target.read_bytes(), b'other data')


if __name__ == '__main__':
    unittest.main()
