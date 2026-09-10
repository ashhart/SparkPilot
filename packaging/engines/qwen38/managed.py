"""Prepare the fixed, offline Qwen engine and its revision-specific packed table."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import dependencies

BASE = 'vllm/vllm-openai@sha256:3b0e188ffceb3d07e09c3cb5215433a0020eacf02d7f882ed3a8bfd15454477e'
REVISION = '925d7be6c14c6c9442ef83e8f05b5a3c39304f69'
ROOT = Path(__file__).resolve().parent
STATE = Path('/var/lib/spark-privd/qwen38')
DOCKER = '/usr/bin/docker'


def run(args, timeout=120):
    return subprocess.run([DOCKER, *args], check=True, timeout=timeout,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()


def atomic_json(path, value):
    temporary = path.with_suffix('.pending')
    with temporary.open('w') as stream:
        json.dump(value, stream)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def inputs():
    manifest = json.loads((ROOT / 'sources.json').read_text())
    for relative, expected in manifest['sha256'].items():
        path = ROOT / relative
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError('Qwen engine source verification failed')
    return hashlib.sha256((ROOT / 'sources.json').read_bytes()).hexdigest()


def prepare_image():
    fingerprint = inputs()
    receipt = STATE / 'image.json'
    if receipt.exists():
        saved = json.loads(receipt.read_text())
        if saved['inputs'] == fingerprint and re.fullmatch(r'sha256:[0-9a-f]{64}', saved['image']):
            try:
                observed = json.loads(run(['image', 'inspect', saved['image']]))[0]
                if observed['Id'] == saved['image'] and observed['Architecture'] == 'arm64':
                    return saved['image']
            except subprocess.CalledProcessError:
                pass
    base = json.loads(run(['image', 'inspect', BASE]))[0]
    if base['Architecture'] != 'arm64':
        raise RuntimeError('This Qwen recipe requires the tested arm64 engine')
    # Copy only verified build inputs, never a writable model directory or caller Dockerfile.
    with tempfile.TemporaryDirectory(dir=STATE, prefix='build-') as directory:
        context = Path(directory)
        for relative in json.loads((ROOT / 'sources.json').read_text())['sha256']:
            target = context / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        dependencies.fetch(context)
        image = run(['build', '--network=none', '--pull=false', '--quiet', str(context)], 1800).splitlines()[-1]
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', image):
        raise RuntimeError('Docker did not return an immutable prepared image ID')
    evidence = json.loads(run(['run', '--rm', '--network=none', '--read-only', '--cap-drop=ALL',
                               '--entrypoint=cat', image, '/opt/sparkpilot-qwen38/patch-evidence.json']))
    if evidence != json.loads((ROOT / 'expected-patches.json').read_text()):
        raise RuntimeError('Prepared engine differs from the hardware-qualified patches')
    atomic_json(receipt, {'inputs': fingerprint, 'image': image})
    return image


def checksum(path):
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if hasattr(os, 'posix_fadvise'):
            os.posix_fadvise(stream.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
        return digest


def valid_table(directory, fingerprint):
    try:
        receipt = json.loads((directory / 'ready.json').read_text())
        if receipt['inputs'] != fingerprint or receipt['revision'] != REVISION:
            return False
        files = list(directory.glob('*.packed_u8'))
        if len(files) != 1 or files[0].is_symlink():
            return False
        meta = json.loads(Path(str(files[0]) + '.json').read_text())
        expected = meta['total_rows'] * meta['row_width']
        return (expected == receipt['bytes'] == files[0].stat().st_size and expected > 0
                and receipt['sha256'] == checksum(files[0]))
    except (OSError, ValueError, KeyError, TypeError):
        return False


def prepare_table(snapshot):
    path = Path(snapshot)
    if path.name != REVISION or not path.is_dir():
        raise RuntimeError('Qwen requires its qualified model revision')
    fingerprint = inputs()
    image = prepare_image()
    packed = STATE / ('packed-' + fingerprint)
    if valid_table(packed, fingerprint):
        return {'image': image, 'packed': str(packed)}
    if shutil.disk_usage(STATE).free < 30 * 2**30:
        raise RuntimeError('Qwen needs 30 GiB free to prepare its reusable offload table')
    # No ready receipt is published until the complete table and metadata are durable.
    with tempfile.TemporaryDirectory(dir=STATE, prefix='packed-') as directory:
        run(['run', '--rm', '--pull=never', '--network=none', '--memory=6g', '--memory-swap=6g',
             '--cpus=8', '--pids-limit=256', '--cap-drop=ALL', '--cap-add=DAC_OVERRIDE',
             '--security-opt=no-new-privileges:true', '--read-only', '--tmpfs=/tmp:rw,noexec,size=1g',
             '--user=0:0', f'--volume={path}:/model:ro', f'--volume={directory}:/packed:rw',
             '--entrypoint=python3', image, '/opt/sparkpilot-qwen38/files/build_ple_packed_table.py',
             '/model', '/packed'], 1800)
        staging = Path(directory)
        files = list(staging.glob('*.packed_u8'))
        if len(files) != 1:
            raise RuntimeError('Qwen table preparation produced an unexpected file count')
        for entry in staging.iterdir():
            if entry.is_symlink() or not entry.is_file():
                raise RuntimeError('Qwen table preparation produced an unexpected entry')
            with entry.open('rb') as stream:
                os.fsync(stream.fileno())
            entry.chmod(0o444)
        atomic_json(staging / 'ready.json', {'inputs': fingerprint, 'revision': REVISION,
                                           'bytes': files[0].stat().st_size, 'sha256': checksum(files[0])})
        if not valid_table(staging, fingerprint):
            raise RuntimeError('Qwen packed table failed validation')
        if packed.exists():
            shutil.rmtree(packed)
        staging.rename(packed)
        packed.chmod(0o755)
    return {'image': image, 'packed': str(packed)}


def main():
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE / 'prepare.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if sys.argv[1:] == ['image']:
            result = {'image': prepare_image()}
        elif len(sys.argv) == 3 and sys.argv[1] == 'table':
            result = prepare_table(sys.argv[2])
        else:
            raise ValueError('Unsupported Qwen preparation operation')
        print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Qwen preparation failed: {error}', file=sys.stderr)
        sys.exit(1)
