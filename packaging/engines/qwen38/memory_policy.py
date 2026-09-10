"""Temporarily apply Qwen VM settings and restore them after the engine stops."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

from managed import STATE, atomic_json, run

VALUES = {'min_free_kbytes': 6291456, 'watermark_scale_factor': 100}
VM = Path('/proc/sys/vm')


def memory():
    return {line.split(':')[0]: int(line.split()[1]) * 1024
            for line in Path('/proc/meminfo').read_text().splitlines() if ':' in line}


def running(name):
    try:
        return run(['inspect', '--format={{.State.Running}}', name]) == 'true'
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or b'').lower()
        if b'no such object' in detail or b'no such container' in detail:
            return False
        raise


def restore(receipt):
    record = json.loads(receipt.read_text())
    applied = record.get('applied', VALUES)
    if running(record['container']):
        raise RuntimeError('Cannot restore Qwen VM settings while its engine is running')
    for key, old in record['previous'].items():
        if key not in VALUES:
            raise RuntimeError('Invalid Qwen VM receipt')
        path = VM / key
        # Preserve an administrator's later adjustment.
        if int(path.read_text()) == applied[key]:
            path.write_text(str(old))
    receipt.unlink()


def reservation_bytes(before, after):
    # Exclude concurrent page consumption so the credit cannot hide real allocations.
    consumed = sum(max(0, before[key] - after[key])
                   for key in ['MemFree', 'Cached', 'SReclaimable'])
    return max(0, before['MemAvailable'] - after['MemAvailable'] - consumed)


def activate(name):
    reading = memory()
    if reading['MemAvailable'] <= 94 * 2**30 or not 120 * 2**30 <= reading['MemTotal'] <= 130 * 2**30:
        raise RuntimeError('Qwen requires a 128 GB Spark with more than 94 GiB available')
    receipt = STATE / 'memory.json'
    if receipt.exists():
        restore(receipt)
    reading = memory()
    atomic_json(receipt, {'container': name, 'applied': VALUES,
                         'previous': {key: int((VM / key).read_text()) for key in VALUES}})
    try:
        for key, value in VALUES.items():
            (VM / key).write_text(str(value))
        reserved = reservation_bytes(reading, memory())
        record = json.loads(receipt.read_text())
        record['host_reserved_memory_bytes'] = reserved
        atomic_json(receipt, record)
        return {'host_reserved_memory_bytes': reserved}
    except OSError:
        restore(receipt)
        raise


def restore_for(name):
    receipt = STATE / 'memory.json'
    if receipt.exists() and json.loads(receipt.read_text())['container'] == name:
        restore(receipt)


def watch(name):
    failures = 0
    while running(name):
        reading = memory()
        low = reading['MemAvailable'] < 6 * 2**30 or reading['MemFree'] < 6 * 2**30
        failures = failures + 1 if low else 0
        if failures >= 3:
            run(['stop', '--time=30', name])
            break
        time.sleep(1)
    with (STATE / 'memory.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        restore_for(name)


def main():
    operation, instance = sys.argv[1:]
    name = 'spark-model-' + str(uuid.UUID(instance))
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    if operation == 'watch':
        watch(name)
        return
    with (STATE / 'memory.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if operation == 'activate':
            print(json.dumps(activate(name)))
        elif operation == 'restore':
            restore_for(name)
        else:
            raise ValueError('Unsupported Qwen memory operation')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Qwen memory policy failed: {error}', file=sys.stderr)
        sys.exit(1)
