"""Run inside the pinned Qwen image with no network or GPU; use only disposable data."""
import json, tempfile
from pathlib import Path
from vllm.config import LoadConfig
from vllm.model_executor.model_loader.default_loader import DefaultModelLoader
from transformers import AutoConfig

with tempfile.TemporaryDirectory() as directory:
    root=Path(directory)
    (root/'model.pt').write_bytes(b'not a safetensors checkpoint')
    legacy=DefaultModelLoader(LoadConfig(load_format='pt'))
    _, paths, safe = legacy._prepare_weights(directory,None,None,True,None)
    assert paths and not safe
    loader=DefaultModelLoader(LoadConfig(load_format='safetensors'))
    try:
        loader._prepare_weights(directory,None,None,True,None)
    except RuntimeError as error:
        assert 'Cannot find any model weights' in str(error)
    else:
        raise AssertionError('unsafe .pt fallback accepted')
    (root/'config.json').write_text(json.dumps({'model_type':'spark_security_probe','auto_map':{'AutoConfig':'configuration_probe.ProbeConfig'}}))
    marker=root/'executed'
    (root/'configuration_probe.py').write_text('from pathlib import Path\nPath('+repr(str(marker))+').write_text("unsafe")\nfrom transformers import PretrainedConfig\nclass ProbeConfig(PretrainedConfig):\n    model_type="spark_security_probe"\n')
    try:
        AutoConfig.from_pretrained(directory,trust_remote_code=False,local_files_only=True)
    except ValueError:
        pass
    else:
        raise AssertionError('untrusted custom configuration accepted')
    assert not marker.exists()
    from vllm.transformers_utils.config import get_config
    try:
        get_config(directory, trust_remote_code=False)
    except ValueError:
        pass
    else:
        raise AssertionError('vLLM accepted the untrusted custom configuration')
    assert not marker.exists()
print(json.dumps({'safetensors_refuses_pt_fallback':True,'custom_configuration_not_executed':True,
                  'vllm_custom_configuration_refused':True}))

# Parsing needs a platform even though this probe does not allocate tensors or use a GPU.
import vllm.platforms
from vllm.platforms.cpu import CpuPlatform
from vllm.entrypoints.openai.cli_args import make_arg_parser
from vllm.utils.argparse_utils import FlexibleArgumentParser

vllm.platforms.current_platform = CpuPlatform()
parser = make_arg_parser(FlexibleArgumentParser())
assert parser.parse_args([]).enable_prefix_caching is None
assert parser.parse_args(['--no-enable-prefix-caching']).enable_prefix_caching is False
print(json.dumps({'prefix_caching_explicitly_disabled': True}))

from unittest.mock import patch
from vllm.plugins import load_plugins_by_group

loaded = []


class ProbePlugin:
    name = 'sparkpilot-security-probe'
    value = 'probe:record_load'

    def load(self):
        loaded.append(self.name)
        return lambda: None


with patch('importlib.metadata.entry_points', return_value=[ProbePlugin()]):
    discovered = load_plugins_by_group('vllm.general_plugins')
if discovered or loaded:
    raise AssertionError('The no-plugin policy permitted entry-point code to load')
print(json.dumps({'plugin_entrypoint_not_loaded': True}))

from transformers import PretrainedConfig
from vllm.model_executor.layers.pooler.activations import get_act_fn

activation_config = PretrainedConfig()
activation_config.sentence_transformers = {'activation_fn': 'probe.activation'}
with patch('vllm.model_executor.layers.pooler.activations.resolve_obj_by_qualname') as resolve:
    try:
        get_act_fn(activation_config)
    except ValueError:
        pass
    else:
        raise AssertionError('Pooler accepted an arbitrary activation function')
    if resolve.called:
        raise AssertionError('Untrusted activation reached the object resolver')
print(json.dumps({'pooler_rejects_untrusted_activation': True}))

from vllm.v1.serial_utils import MsgpackDecoder, CUSTOM_TYPE_PICKLE, CUSTOM_TYPE_CLOUDPICKLE

decoder = MsgpackDecoder()
for extension in [CUSTOM_TYPE_PICKLE, CUSTOM_TYPE_CLOUDPICKLE]:
    with patch('pickle.loads') as pickle_load, patch('cloudpickle.loads') as cloudpickle_load:
        try:
            decoder.ext_hook(extension, memoryview(b'untrusted payload'))
        except NotImplementedError:
            pass
        else:
            raise AssertionError('IPC accepted an insecure serialization extension')
        if pickle_load.called or cloudpickle_load.called:
            raise AssertionError('IPC reached an insecure deserializer')
print(json.dumps({'ipc_pickle_extensions_refused': True}))
