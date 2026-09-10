"""Exercise interrupted preparation and VM policy rollback without a GPU."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ASSETS = Path(__file__).resolve().parents[2] / 'packaging/engines/qwen38'
sys.path.insert(0, str(ASSETS))
import managed
import memory_policy


class QwenPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def table(self):
        table = self.root / 'table.packed_u8'
        table.write_bytes(b'12345678')
        (self.root / 'table.packed_u8.json').write_text(json.dumps({'total_rows': 2, 'row_width': 4}))
        managed.atomic_json(self.root / 'ready.json', {'inputs': 'tested', 'revision': managed.REVISION, 'bytes': 8, 'sha256': 'ef797c8118f02dfb649607dd5d3f8c7623048c9c063d532cc95c5ed7a898a64f'})
        return table

    def test_removed_container_restores_vm_with_current_docker_error_case(self):
        import subprocess
        for message in [b'error: no such object: spark-model-test', b'Error: No such container: spark-model-test']:
            with self.subTest(message=message), patch.object(memory_policy, 'run', side_effect=subprocess.CalledProcessError(1, ['docker'], stderr=message)):
                self.assertFalse(memory_policy.running('spark-model-test'))
        with patch.object(memory_policy, 'run', side_effect=subprocess.CalledProcessError(1, ['docker'], stderr=b'permission denied')):
            with self.assertRaises(subprocess.CalledProcessError):
                memory_policy.running('spark-model-test')

    def test_verified_table_hash_does_not_leave_its_pages_resident(self):
        table = self.table()
        with patch.object(managed.os, 'posix_fadvise', create=True) as discard, \
                patch.object(managed.os, 'POSIX_FADV_DONTNEED', 4, create=True):
            self.assertEqual(managed.checksum(table), 'ef797c8118f02dfb649607dd5d3f8c7623048c9c063d532cc95c5ed7a898a64f')
            discard.assert_called_once()
            self.assertEqual(discard.call_args.args[1:], (0, 0, 4))
        self.assertEqual(table.read_bytes(), b'12345678')

    def test_partial_table_or_other_revision_is_never_reused(self):
        table = self.table()
        self.assertTrue(managed.valid_table(self.root, 'tested'))
        self.assertFalse(managed.valid_table(self.root, 'new-patches'))
        table.write_bytes(b'1234')
        self.assertFalse(managed.valid_table(self.root, 'tested'))
        table.write_bytes(b'12345678')
        (self.root / 'ready.json').unlink()
        self.assertFalse(managed.valid_table(self.root, 'tested'))

    def test_missing_metadata_and_symlink_are_rejected(self):
        table = self.table()
        (self.root / 'table.packed_u8.json').unlink()
        self.assertFalse(managed.valid_table(self.root, 'tested'))
        table.unlink()
        table.symlink_to('/etc/passwd')
        self.assertFalse(managed.valid_table(self.root, 'tested'))

    def test_same_size_corruption_is_never_reused(self):
        table = self.table()
        table.write_bytes(b'87654321')
        self.assertFalse(managed.valid_table(self.root, 'tested'))

    def test_pinned_patch_sources_match_qualification(self):
        self.assertEqual(len(managed.inputs()), 64)

    def test_restore_waits_for_stop_and_preserves_later_admin_changes(self):
        for key, value in memory_policy.VALUES.items():
            (self.root / key).write_text(str(value))
        receipt = self.root / 'memory.json'
        managed.atomic_json(receipt, {'container': 'spark-model-test', 'previous': {'min_free_kbytes': 45155, 'watermark_scale_factor': 10}})
        with patch.object(memory_policy, 'VM', self.root), patch.object(memory_policy, 'running', return_value=True):
            with self.assertRaises(RuntimeError):
                memory_policy.restore(receipt)
        self.assertTrue(receipt.exists())
        (self.root / 'watermark_scale_factor').write_text('350')
        with patch.object(memory_policy, 'VM', self.root), patch.object(memory_policy, 'running', return_value=False):
            memory_policy.restore(receipt)
        self.assertEqual((self.root / 'min_free_kbytes').read_text(), '45155')
        self.assertEqual((self.root / 'watermark_scale_factor').read_text(), '350')
        self.assertFalse(receipt.exists())

    def test_vm_reserve_credit_excludes_concurrent_allocations(self):
        before = dict(MemAvailable=120, MemFree=104, Cached=16, SReclaimable=2)
        after = dict(MemAvailable=101, MemFree=101, Cached=16, SReclaimable=2)
        self.assertEqual(memory_policy.reservation_bytes(before, after), 16)
        after['MemAvailable'] = 121
        self.assertEqual(memory_policy.reservation_bytes(before, after), 0)

    def test_low_memory_refuses_before_any_settings_change(self):
        with patch.object(memory_policy, 'STATE', self.root), patch.object(memory_policy, 'memory', return_value={'MemTotal': 122 * 2**30, 'MemAvailable': 90 * 2**30}):
            with self.assertRaises(RuntimeError):
                memory_policy.activate('spark-model-test')
        self.assertFalse((self.root / 'memory.json').exists())

    def test_restore_uses_the_policy_recorded_before_an_upgrade(self):
        (self.root / 'watermark_scale_factor').write_text('300')
        receipt = self.root / 'memory.json'
        managed.atomic_json(receipt, {'container': 'spark-model-test',
                                     'previous': {'watermark_scale_factor': 10},
                                     'applied': {'watermark_scale_factor': 300}})
        with patch.object(memory_policy, 'VM', self.root), \
                patch.object(memory_policy, 'running', return_value=False):
            memory_policy.restore(receipt)
        self.assertEqual((self.root / 'watermark_scale_factor').read_text(), '10')

    def test_watch_stops_at_the_runtime_emergency_floor(self):
        with patch.object(memory_policy, 'STATE', self.root), \
                patch.object(memory_policy, 'running', side_effect=[True, True, True, False]), \
                patch.object(memory_policy, 'memory', return_value={'MemAvailable': 5 * 2**30, 'MemFree': 8 * 2**30}), \
                patch.object(memory_policy.time, 'sleep'), \
                patch.object(memory_policy, 'run') as run:
            memory_policy.watch('spark-model-test')
        run.assert_called_once_with(['stop', '--time=30', 'spark-model-test'])

    def test_watch_does_not_stop_a_healthy_engine(self):
        with patch.object(memory_policy, 'STATE', self.root), \
                patch.object(memory_policy, 'running', side_effect=[True, True, True, False]), \
                patch.object(memory_policy, 'memory', return_value={'MemAvailable': 7 * 2**30, 'MemFree': 8 * 2**30}), \
                patch.object(memory_policy.time, 'sleep'), \
                patch.object(memory_policy, 'run') as run:
            memory_policy.watch('spark-model-test')
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
