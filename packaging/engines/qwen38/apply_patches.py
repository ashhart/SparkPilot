"""Apply the pinned MiaAI-Lab patches and record their exact inputs and outputs."""
import hashlib
import json
from pathlib import Path
import py_compile
import shutil
import subprocess
import sys

root = Path(__file__).parent
files = root / "files"
package = Path("/usr/local/lib/python3.12/dist-packages/vllm")
mapping = {
    "ple_layer_patched.py": "models/qwen3_8_flash_next/nvidia/ple_layer.py",
    "modelopt_patched.py": "model_executor/layers/quantization/modelopt.py",
    "qsa_ops_patched.py": "models/qwen3_8_flash_next/nvidia/ops/qsa.py",
    "qsa_nvidia_patched.py": "models/qwen3_8_flash_next/nvidia/qsa.py",
    "mtp_patched.py": "models/qwen3_8_flash_next/nvidia/mtp.py",
    "ple_offload/ple_offload_layer.py": "model_executor/layers/ple_offload_layer.py",
    "ple_offload/connector.py": "v1/ple_offload/connector.py",
    "ple_offload/worker.py": "v1/ple_offload/worker.py",
    "ple_offload/protocol.py": "v1/ple_offload/protocol.py",
}
records = {}
for output, target in mapping.items():
    relative = Path(output)
    original = (files / "ple_offload/orig" / relative.name
                if relative.parent.name == "ple_offload"
                else files / (output + ".orig"))
    original.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(package / target, original)
    records[target] = {"original_sha256": hashlib.sha256(original.read_bytes()).hexdigest()}

for script in ["patch_ple_layer.py", "patch_modelopt_mxfp8.py", "patch_qsa_fp8_kv.py",
               "patch_mtp_draft_vocab.py", "patch_ple_offload.py"]:
    subprocess.run([sys.executable, str(files / script)], check=True)

for output, target in mapping.items():
    patched = files / output
    if target == "models/qwen3_8_flash_next/nvidia/ple_layer.py":
        if hashlib.sha256(patched.read_bytes()).hexdigest() != "0b06353e105d26aa62c64fa2803ec9a6a1fe456d5ff33f09fc319024aa4bad93":
            raise RuntimeError("PLE input differs from the reviewed module")
        source = patched.read_text()
        old = '                _ple_prefetch_rows(\n                    getattr(emb, "_packed_table_fd", None), ids, row_width\n                )'
        if source.count(old) != 1:
            raise RuntimeError("PLE gather no longer matches the reviewed call site")
        source = source.replace(old, '                _sparkpilot_prefetch_rows(emb, ids, row_width)')
        patched.write_text(source + '\n' + (root / 'bounded_ple_cache.py').read_text())
    py_compile.compile(str(patched), doraise=True)
    shutil.copy2(patched, package / target)
    records[target]["patched_sha256"] = hashlib.sha256(patched.read_bytes()).hexdigest()
target = "v1/worker/gpu_worker.py"
worker = package / target
source = worker.read_text()
original = hashlib.sha256(source.encode()).hexdigest()
if original != "923767cea120a027ca36683bd48b7659eadbfa4cbd4acbcf52a80cee0c0a0ec4":
    raise RuntimeError("Qwen GPU worker differs from the reviewed module")
old = '            self.model_runner.profile_run()\n\n            msg = ('
if source.count(old) != 1:
    raise RuntimeError("Qwen byte-budget profiling no longer matches the reviewed call site")
source = source.replace(old, '            _sparkpilot_release_weight_pages(self.model_config.model)\n'
                        '            self.model_runner.profile_run()\n'
                        '            torch.accelerator.empty_cache()\n\n            msg = (')
source += '\n\n' + (root / 'weight_page_cache.py').read_text()
worker.write_text(source)
py_compile.compile(str(worker), doraise=True)
records[target] = {"original_sha256": original,
                   "patched_sha256": hashlib.sha256(source.encode()).hexdigest()}
(root / "patch-evidence.json").write_text(json.dumps(records, indent=2) + "\n")
print(f"Applied and compiled {len(records)} patched vLLM modules.")
