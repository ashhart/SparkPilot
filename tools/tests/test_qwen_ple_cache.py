"""Keep packed table reads intact while discarding old file-backed pages."""
import mmap
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'packaging/engines/qwen38'))
import bounded_ple_cache as cache


def ids(count):
    return SimpleNamespace(numel=lambda: count)


class PackedCacheTests(unittest.TestCase):
    def test_eviction_happens_before_the_budget_is_exceeded(self):
        table = Mock()
        embedding = SimpleNamespace(_packed_table_fd=12, _packed_table_mmap=SimpleNamespace(_mmap=table))
        with patch.object(cache.os, 'sysconf', return_value=4096), \
                patch.object(cache.os, 'posix_fadvise', create=True) as discard, \
                patch.object(cache.os, 'POSIX_FADV_DONTNEED', 4, create=True), \
                patch.object(cache, '_ple_prefetch_rows', create=True) as prefetch:
            for _ in range(4):
                cache._sparkpilot_prefetch_rows(embedding, ids(16384), 90)
            self.assertEqual(discard.call_count, 1)
            cache._sparkpilot_prefetch_rows(embedding, ids(1), 90)
            self.assertEqual(discard.call_count, 2)
            self.assertEqual(embedding._sparkpilot_cached_rows, 1)
            self.assertEqual(prefetch.call_count, 5)

    def test_unqualified_shape_or_page_size_is_refused_before_io(self):
        for count, width, page in [(65537, 90, 4096), (1, 91, 4096), (1, 90, 65536)]:
            with self.subTest(count=count, width=width, page=page), \
                    patch.object(cache.os, 'sysconf', return_value=page), \
                    patch.object(cache, '_ple_prefetch_rows', create=True) as prefetch:
                with self.assertRaises(RuntimeError):
                    cache._sparkpilot_prefetch_rows(SimpleNamespace(), ids(count), width)
                prefetch.assert_not_called()

    @unittest.skipUnless(sys.platform == 'linux', 'Linux is the engine host')
    def test_real_readonly_mapping_retains_exact_rows_after_repeated_eviction(self):
        with tempfile.TemporaryFile() as stream:
            data = bytes(range(251)) * 10000
            stream.write(data)
            stream.flush()
            with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as table:
                embedding = SimpleNamespace(_packed_table_fd=stream.fileno(),
                                            _packed_table_mmap=SimpleNamespace(_mmap=table))
                def prefetch(_descriptor, _ids, _width):
                    for offset in range(0, len(data) - 90, 8191):
                        self.assertEqual(table[offset:offset + 90], data[offset:offset + 90])
                with patch.object(cache, '_ple_prefetch_rows', prefetch, create=True):
                    for _ in range(8):
                        cache._sparkpilot_prefetch_rows(embedding, ids(65536), 90)
                self.assertEqual(table[:], data)


if __name__ == '__main__':
    unittest.main()
