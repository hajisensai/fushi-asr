"""Fresh CoreML vs a resident worker, using unique jobs and identical PCM bytes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('audio', type=Path, nargs='+', help='Already extracted PCM WAV samples')
    parser.add_argument('--runs', type=int, default=4, help='First + warm requests per worker')
    args = parser.parse_args()
    if args.runs < 2 or any(not p.is_file() for p in args.audio):
        parser.error('At least two runs and existing PCM samples required')
    out = ROOT / 'build/benchmark' / (time.strftime('%Y%m%d-%H%M%S') + '-reuse-' + uuid.uuid4().hex[:8])
    out.mkdir(parents=True)
    report = {'os': platform.platform(), 'runs': [], 'method':
              'Same PCM bytes, unique basename for every job. Fresh baseline disables session reuse. '
              'Resident first request includes initialization; warm median excludes first. '
              'No forced disk cache flush. Request latency excludes final worker shutdown. '
              'Exact subtitle equality is a regression check, not accuracy against ground truth.'}
    for source in args.audio:
        duration = float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries',
            'format=duration', '-of', 'default=nw=1:nk=1', str(source)], text=True))
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        groups = {}
        for mode in ['fresh', 'resident']:
            paths = []
            for i in range(args.runs):
                path = out / f'{out.name}-{source.stem}-{mode}-{i}.wav'
                shutil.copyfile(source, path)
                assert hashlib.sha256(path.read_bytes()).hexdigest() == digest
                paths.append(path)
            commands = [[p] for p in paths] if mode == 'fresh' else [paths]
            rows = []
            for i, files in enumerate(commands):
                command = [str(ROOT / 'build/reazon_benchmark'), '--coreml']
                if mode == 'fresh':
                    command.append('--no-reuse')
                print(f'{duration}s {mode} group {i + 1}', flush=True)
                started = time.perf_counter()
                process = subprocess.run(command + [str(p) for p in files],
                    capture_output=True, text=True, timeout=600)
                wall = time.perf_counter() - started
                stem = f'{source.stem}-{mode}-{i}'
                (out / f'{stem}.log').write_text(process.stderr)
                (out / f'{stem}.json').write_text(process.stdout)
                if process.returncode:
                    raise RuntimeError(f'Benchmark failed: {out / (stem + ".log")}')
                data = json.loads(process.stdout)
                batch = data.get('runs', [data])
                for row in batch:
                    assert row['segments'], 'No subtitles returned'
                    assert abs(row['audio_seconds'] - duration) < .1
                    assert 'coreml' in row['provider'], 'Provider fallback'
                rows.extend(batch)
                print(f'  wall {wall:.3f}s; requests {[round(r["pipeline_seconds"], 3) for r in batch]}', flush=True)
            groups[mode] = rows
        reference = groups['fresh'][0]['segments']
        identical = all(r['segments'] == reference for rows in groups.values() for r in rows)
        row = {'audio_seconds': duration, 'sha256': digest,
               'fresh_seconds': [r['pipeline_seconds'] for r in groups['fresh']],
               'resident_seconds': [r['pipeline_seconds'] for r in groups['resident']],
               'exact_subtitles_equal': identical, 'segments': len(reference)}
        row['fresh_median'] = statistics.median(row['fresh_seconds'])
        row['warm_median'] = statistics.median(row['resident_seconds'][1:])
        row['speedup'] = row['fresh_median'] / row['warm_median']
        report['runs'].append(row)
        (out / 'results.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(f'Results: {out}', flush=True)


if __name__ == '__main__':
    main()
