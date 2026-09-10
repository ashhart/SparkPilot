"""Gate a disposable Qwen run on workload, production-guard and kernel evidence."""
import json
from datetime import datetime, timezone
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent.parent


def collect_kernel(directory):
    state = json.loads((directory / 'container.json').read_text())['State']
    if state['Running']:
        raise ValueError('Stop the probe before collecting its kernel window')
    def epoch(value):
        return datetime.fromisoformat(value[:19] + '+00:00').timestamp()
    command = ['journalctl', '-k', '--utc', '--no-pager',
               '--since', '@' + str(epoch(state['StartedAt'])),
               '--until', '@' + str(epoch(state['FinishedAt']) + 1)]
    output = subprocess.run(command, check=True, capture_output=True, text=True)
    (directory / 'kernel.log').write_text(output.stdout)
    (directory / 'kernel-window.json').write_text(json.dumps({
        'started_at': state['StartedAt'], 'finished_at': state['FinishedAt'],
        'collected_at': datetime.now(timezone.utc).isoformat(), 'command': command,
    }, indent=2) + '\n')


def check(directory):
    result = json.loads((directory / 'result.json').read_text())
    kernel = (directory / 'kernel.log').read_text()
    trace = directory / 'continuous-memory.jsonl'
    rows = [json.loads(line) for line in trace.read_text().splitlines()]
    failures = []
    if result.get('status') != 'healthy_chat_parallel_and_long_context':
        failures.append('Synthetic workloads did not all complete')
    parallel = result.get('parallel_61440', [])
    if len(parallel) != 4 or any(row.get('prompt_tokens') != 61440 for row in parallel):
        failures.append('Four concurrent 61,440-token inputs were not recorded')
    if result.get('long_context', {}).get('prompt_tokens') != 262080:
        failures.append('The near-limit context input was not recorded')
    healthy = result['healthy_after_seconds']
    if not rows or rows[-1]['elapsed'] <= healthy:
        failures.append('Memory sampling did not cover serving')
    if result.get('restored_vm') != json.loads((directory / 'previous-vm.json').read_text()):
        failures.append('Host VM settings were not restored')
    container = json.loads((directory / 'container.json').read_text())
    state = container['State']
    window = json.loads((directory / 'kernel-window.json').read_text())
    if (window.get('started_at') != state['StartedAt']
            or window.get('finished_at') != state['FinishedAt']):
        failures.append('Kernel collection does not cover this container run')
    if state.get('Running') or state.get('OOMKilled') or state.get('ExitCode') != 0:
        failures.append('The engine did not stop cleanly')
    if re.search(r'NVRM:.*(?:Xid|[Ff]ail|[Ee]rror|[Mm]emory)', kernel):
        failures.append('NVIDIA driver errors were recorded during this run')
    if re.search(r'Out of memory|oom-kill|Killed process|allocation failure', kernel, re.I):
        failures.append('Kernel memory allocation failures were recorded during this run')
    replay = subprocess.run([
        'cargo', 'run', '--quiet', '--locked', '--manifest-path', str(ROOT / 'runtime/Cargo.toml'),
        '-p', 'spark-telemetry', '--example', 'replay_memory_guard', '--', str(trace),
        str(result['final_memory']['MemTotal']), str(healthy),
    ], check=True, capture_output=True, text=True)
    guard = json.loads(replay.stdout)
    if not guard['psi_and_oom_recorded']:
        failures.append('The pressure trace omits PSI or OOM observations')
    for transition in guard['transitions']:
        if transition['action'] in {'StopAdmissions', 'GracefulUnload', 'EmergencyStop'}:
            failures.append(f"Production guard issued {transition['action']} at {transition['elapsed']}s")
    return {'native_memory_passed': not failures, 'failures': failures, 'guard': guard,
            'release_approved': False, 'scope': 'Native memory experiment; packaged lifecycle and security review are separate gates'}


def main():
    try:
        if len(sys.argv) == 3 and sys.argv[1] == '--collect-kernel':
            collect_kernel(Path(sys.argv[2]))
            return 0
        if len(sys.argv) != 2:
            raise ValueError('usage: qwen_memory_gate.py EVIDENCE_DIRECTORY')
        outcome = check(Path(sys.argv[1]))
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        outcome = {'native_memory_passed': False, 'failures': [f'Incomplete or invalid evidence: {error}']}
    print(json.dumps(outcome, indent=2))
    return 0 if outcome['native_memory_passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
