"""Serial same-byte A/B of macOS FFI sessions and thread pools (local audio only)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import statistics
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('audio', type=Path)
parser.add_argument('--binary', type=Path, default=ROOT / 'build/reazon_macos_round4')
parser.add_argument('--cpu', action='store_true')
parser.add_argument('--runs', type=int, default=3)
parser.add_argument('--configs', default='baseline,single,no-spin,single-no-spin,cpu4,greedy2')
args = parser.parse_args()
if args.runs < 2:
    parser.error('--runs must include a first request and at least one subsequent request')
configs = {
    'baseline': {},
    'single': {'ASR_MACOS_GREEDY_SESSIONS': '1'},
    'no-spin': {'ASR_MACOS_ORT_SPINNING': '0'},
    'single-no-spin': {'ASR_MACOS_GREEDY_SESSIONS': '1', 'ASR_MACOS_ORT_SPINNING': '0'},
    'cpu4': {'ASR_MACOS_GREEDY_SESSIONS': '1', 'ASR_MACOS_ORT_SPINNING': '0', 'ASR_MACOS_CPU_THREADS': '4'},
    'greedy2': {'ASR_MACOS_GREEDY_SESSIONS': '1', 'ASR_MACOS_ORT_SPINNING': '0', 'ASR_MACOS_CPU_THREADS': '4', 'ASR_MACOS_GREEDY_THREADS': '2'},
    'greedy1': {'ASR_MACOS_GREEDY_SESSIONS': '1', 'ASR_MACOS_GREEDY_THREADS': '1'},
    'batch8': {'ASR_MACOS_BATCH_SIZE': '8'},
    'batch16': {'ASR_MACOS_BATCH_SIZE': '16'},
    'batch64': {'ASR_MACOS_BATCH_SIZE': '64'},
    'fast-prediction': {'ASR_COREML_SPECIALIZATION': 'FastPrediction'},
}
labels = args.configs.split(',')
if any(label not in configs for label in labels):
    parser.error('unknown configuration')
out = ROOT / 'build/benchmark' / (time.strftime('%Y%m%d-%H%M%S') + '-mac-threads-' + uuid.uuid4().hex[:8])
out.mkdir(parents=True)
source_sha = hashlib.sha256(args.audio.read_bytes()).hexdigest()
reference = None
report = []
print(out, flush=True)
for index, label in enumerate(labels):
    key = f'{index}-{label}'
    files = []
    for i in range(args.runs):
        dest = out / f'{out.name}-{key}-{i}{args.audio.suffix}'
        shutil.copyfile(args.audio, dest)
        assert hashlib.sha256(dest.read_bytes()).hexdigest() == source_sha
        files.append(str(dest))
    env = {k: v for k, v in os.environ.items() if not k.startswith(('ASR_MACOS_', 'ASR_COREML_'))}
    env.pop('ASR_ORT_PROFILE_DIR', None)
    env.update(ASR_COREML_STATIC_INPUTS='1', ASR_COREML_COMPUTE_UNITS='ALL')
    env.update(configs[label])
    print(key, configs[label], flush=True)
    cpu_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    process = subprocess.run([str(args.binary.resolve())] + ([] if args.cpu else ['--coreml']) + files,
        capture_output=True, text=True, env=env, timeout=300)
    cpu_after = resource.getrusage(resource.RUSAGE_CHILDREN)
    (out / f'{key}.log').write_text(process.stderr)
    (out / f'{key}.json').write_text(process.stdout)
    if process.returncode:
        raise RuntimeError(f'{key} failed ({process.returncode}): {out}')
    runs = json.loads(process.stdout)['runs']
    if reference is None:
        reference = runs[0]['segments']
    times = [r['pipeline_seconds'] for r in runs]
    row = dict(label=label, settings=configs[label], seconds=times,
        subsequent_median=statistics.median(times[1:]),
        process_cpu_seconds=cpu_after.ru_utime + cpu_after.ru_stime - cpu_before.ru_utime - cpu_before.ru_stime,
        exact_reference_equal=all(r['segments'] == reference for r in runs),
        provider=runs[0]['provider'], stats=[r.get('decode_stats') for r in runs])
    report.append(row)
    (out / 'results.json').write_text(json.dumps(dict(audio=str(args.audio), sha256=source_sha,
        cpu=args.cpu, runs_per_process=args.runs, results=report), indent=2))
    print(row, flush=True)
