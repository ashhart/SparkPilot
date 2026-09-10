"""Keep successful HTTP responses from masking pressure or driver failures."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('qwen_memory_gate', ROOT / 'tests/hardware/qwen_memory_gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class QwenMemoryGateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.write('result.json', {
            'status': 'healthy_chat_parallel_and_long_context', 'healthy_after_seconds': 2,
            'parallel_61440': [{'prompt_tokens': 61440}] * 4,
            'long_context': {'prompt_tokens': 262080},
            'restored_vm': {'min_free_kbytes': 45155, 'watermark_scale_factor': 10},
            'final_memory': {'MemTotal': 122 * 2**30},
        })
        self.write('previous-vm.json', {'min_free_kbytes': 45155, 'watermark_scale_factor': 10})
        self.state = {'Running': False, 'OOMKilled': False, 'ExitCode': 0,
                      'StartedAt': '2026-09-09T12:10:27.123456789Z',
                      'FinishedAt': '2026-09-09T12:23:34.987654321Z'}
        self.write('container.json', {'State': self.state})
        self.write('kernel-window.json', {'started_at': self.state['StartedAt'],
                                         'finished_at': self.state['FinishedAt']})
        (self.root / 'kernel.log').write_text('-- No entries --\n')
        self.trace(24)

    def write(self, name, data):
        (self.root / name).write_text(json.dumps(data))

    def trace(self, available, pressure=True):
        rows = [{'elapsed': float(i), 'available': available * 2**30} for i in range(1, 11)]
        if pressure:
            for row in rows:
                row.update(psi_some_avg10=0.0, psi_full_avg10=0.0, oom_kills=0)
        (self.root / 'continuous-memory.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))

    def test_complete_calm_native_run_does_not_approve_release(self):
        result = gate.check(self.root)
        self.assertTrue(result['native_memory_passed'])
        self.assertFalse(result['release_approved'])

    def test_completed_workloads_fail_if_production_guard_drains(self):
        self.trace(12)
        result = gate.check(self.root)
        self.assertFalse(result['native_memory_passed'])
        self.assertTrue(any('StopAdmissions' in failure for failure in result['failures']))

    def test_driver_failure_fails_without_linux_oom(self):
        (self.root / 'kernel.log').write_text('NVRM: Check failed: Out of memory [NV_ERR_NO_MEMORY]\n')
        self.assertFalse(gate.check(self.root)['native_memory_passed'])

    def test_missing_pressure_is_not_a_pass(self):
        self.trace(24, pressure=False)
        self.assertFalse(gate.check(self.root)['native_memory_passed'])

    def test_incomplete_restoration_is_not_a_pass(self):
        self.write('previous-vm.json', {'min_free_kbytes': 123, 'watermark_scale_factor': 10})
        self.assertFalse(gate.check(self.root)['native_memory_passed'])

    def test_running_engine_is_not_a_completed_lifecycle(self):
        self.write('container.json', {'State': self.state | {'Running': True}})
        self.assertFalse(gate.check(self.root)['native_memory_passed'])

    def test_kernel_window_from_another_run_is_not_a_pass(self):
        self.write('kernel-window.json', {'started_at': 'another-run',
                                         'finished_at': self.state['FinishedAt']})
        self.assertFalse(gate.check(self.root)['native_memory_passed'])

    def test_kernel_collection_uses_absolute_time_instead_of_host_timezone(self):
        with patch.object(gate.subprocess, 'run') as run:
            run.return_value.stdout = '-- No entries --\n'
            gate.collect_kernel(self.root)
        command = run.call_args.args[0]
        self.assertEqual(command[command.index('--since') + 1], '@1788955827.0')
        self.assertEqual(command[command.index('--until') + 1], '@1788956615.0')
        self.assertIn('--utc', command)
        self.assertTrue(run.call_args.kwargs['check'])


if __name__ == '__main__':
    unittest.main()
