"""Same-byte, unique-job A/B of macOS CoreML CPU partition thread counts."""
import json
import argparse
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import time
import uuid

root = Path(__file__).resolve().parents[1]
out = root / 'build/benchmark' / (time.strftime('%Y%m%d-%H%M%S') + '-tuning-' + uuid.uuid4().hex[:8])
out.mkdir(parents=True)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('audio', type=Path, nargs='?', default=root / 'build/benchmark/20260907-165302/sample-300s.wav')
parser.add_argument('--partition', action='store_true')
args = parser.parse_args()
source = args.audio
report = []
configs = [
    ('baseline', 'reazon_tuning', None, True),
    ('threads-1', 'reazon_tuning', '1', True),
    ('threads-2', 'reazon_tuning', '2', True),
    ('threads-4', 'reazon_tuning', '4', True),
    ('int8-original', 'reazon_tuning', None, False),
]
if args.partition:
    configs = [('baseline-repeat', 'reazon_tuning', None, True),
        ('static-inputs', 'reazon_tuning', None, True),
        ('gpu-only', 'reazon_tuning', None, True)]
for label, binary, threads, coreml in configs:
    files = []
    for i in range(4):
        dest = out / f'{out.name}-{label}-{i}.wav'
        shutil.copyfile(source, dest)
        files.append(str(dest))
    env = dict(os.environ)
    env.pop('ASR_COREML_ENCODER_THREADS', None)
    env['ASR_COREML_STATIC_INPUTS'] = '0'
    env['ASR_COREML_COMPUTE_UNITS'] = 'ALL'
    if threads: env['ASR_COREML_ENCODER_THREADS'] = threads
    if label == 'static-inputs': env['ASR_COREML_STATIC_INPUTS'] = '1'
    if label == 'gpu-only': env['ASR_COREML_COMPUTE_UNITS'] = 'CPUAndGPU'
    print(label, flush=True)
    process = subprocess.run([str(root / 'build' / binary)] + (['--coreml'] if coreml else []) + files,
        capture_output=True, text=True, env=env, timeout=300)
    (out / f'{label}.log').write_text(process.stderr)
    (out / f'{label}.json').write_text(process.stdout)
    if process.returncode: raise RuntimeError(f'{label} failed: {out}')
    runs = json.loads(process.stdout)['runs']
    times = [r['pipeline_seconds'] for r in runs]
    row = dict(label=label, seconds=times, warm_median=statistics.median(times[1:]),
        cues=len(runs[0]['segments']), provider=runs[0]['provider'])
    if label.startswith('baseline'): reference = runs[0]['segments']
    row['exact_baseline_equal'] = all(r['segments'] == reference for r in runs)
    report.append(row)
    (out / 'results.json').write_text(json.dumps(report, indent=2))
    print(row, flush=True)
print(out, flush=True)
