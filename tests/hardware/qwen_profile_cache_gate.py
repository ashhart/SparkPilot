"""Exercise byte-budget profiling from an exported, trusted engine GPU worker."""
import ast
from pathlib import Path
import sys
from types import SimpleNamespace


def check(worker_source):
    source = ast.parse(worker_source.read_text())
    method = next(node for node in ast.walk(source)
                  if isinstance(node, ast.FunctionDef)
                  and node.name == 'determine_available_memory')
    method.decorator_list = []
    state = {'cached': 0, 'live': 70 * 2**30, 'events': []}

    def profile():
        state['cached'] = 3 * 2**30
        state['events'].append('profile')

    def release():
        state['cached'] = 0
        state['events'].append('release')

    def reserve(value, *args):
        assert state['cached'] == 0, 'Profile scratch cache remains before KV allocation'
        assert state['live'] == 70 * 2**30, 'Live model allocations must remain intact'
        state['events'].append('reserve')
        return value

    namespace = {
        'torch': SimpleNamespace(accelerator=SimpleNamespace(empty_cache=release)),
        '_sparkpilot_release_weight_pages': lambda path: state['events'].append('weight-pages'),
        'maybe_apply_startup_plan': lambda worker: None,
        'format_gib': str,
        'logger': SimpleNamespace(info=lambda message: None),
        'reserve_mm_ipc_gpu_memory': reserve,
    }
    module = ast.fix_missing_locations(ast.Module(body=[method], type_ignores=[]))
    exec(compile(module, 'actual-engine-method', 'exec'), namespace)
    worker = SimpleNamespace(
        cache_config=SimpleNamespace(kv_cache_memory_bytes=4 * 2**30),
        model_runner=SimpleNamespace(profile_run=profile),
        init_snapshot=SimpleNamespace(free_memory=96 * 2**30),
        model_config=SimpleNamespace(model="/model", multimodal_config=None),
        parallel_config=SimpleNamespace(_api_process_count=1),
    )
    assert namespace['determine_available_memory'](worker) == 4 * 2**30
    assert state['events'] == ['weight-pages', 'profile', 'release', 'reserve']
    return state['events']


if __name__ == '__main__':
    print('PASS: profile scratch cache released before KV reservation:', check(Path(sys.argv[1])))
