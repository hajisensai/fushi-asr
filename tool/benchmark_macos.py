"""Compare fresh-process end-to-end latency on identical local PCM files.

Build and install model assets via script/benchmark_macos.sh first.
Audio and transcripts remain under the ignored build/benchmark directory.
"""
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
    parser.add_argument("audio", type=Path)
    parser.add_argument("--offset", type=float, default=120)
    parser.add_argument("--durations", type=int, nargs="+", default=[60, 300])
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--engines", nargs="+", choices=["apple", "reazon", "coreml"],
                        default=["apple", "reazon"])
    args = parser.parse_args()
    if not args.audio.is_file() or args.runs < 1 or args.offset < 0 or min(args.durations) < 1:
        parser.error("valid audio, nonnegative offset, positive durations and runs required")
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    output = ROOT / "build" / "benchmark" / run_id
    output.mkdir(parents=True)
    available = {
        "apple": [str(ROOT / "build/apple_transcribe")],
        "reazon": [str(ROOT / "build/reazon_benchmark")],
        "coreml": [str(ROOT / "build/reazon_benchmark"), "--coreml"],
    }
    engines = {name: available[name] for name in dict.fromkeys(args.engines)}
    metadata = {
        "source": str(args.audio.resolve()), "offset_seconds": args.offset,
        "os": platform.platform(),
        "cpu": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "memory_bytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "method": "Fresh process each run; sequential alternating engine order; downloads and PCM extraction excluded; no forced cache flush. First run is not guaranteed cold. Reazon CPU uses INT8; CoreML uses FP32. Unique basename per engine/repetition prevents completed-job cache reuse; all engines read identical bytes. CoreML compilation/cache loading is included.",
        "runs": [],
    }
    for duration in args.durations:
        wav = output / f"sample-{duration}s.wav"
        subprocess.run([os.environ.get("ASR_FFMPEG", "ffmpeg"), "-v", "error", "-nostdin",
                        "-ss", str(args.offset), "-i", str(args.audio), "-t", str(duration),
                        "-map", "0:a:0", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                        str(wav)], check=True)
        actual = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries",
                        "format=duration", "-of", "default=nw=1:nk=1", str(wav)], text=True))
        if abs(actual - duration) > 0.1:
            raise RuntimeError(f"Requested {duration}s but got {actual}s")
        digest = hashlib.sha256(wav.read_bytes()).hexdigest()
        for repeat in range(args.runs):
            # Reazon keys completed jobs by basename + file size, not full path.
            order = list(engines) if repeat % 2 == 0 else list(reversed(engines))
            for engine in order:
                run_wav = output / f"{output.name}-{duration}s-run{repeat + 1}-{engine}.wav"
                shutil.copyfile(wav, run_wav)
                assert hashlib.sha256(run_wav.read_bytes()).hexdigest() == digest
                stem = f"{duration}s-{repeat + 1}-{engine}"
                print(f"Running {stem}...", flush=True)
                started = time.perf_counter()
                result = subprocess.run([*engines[engine], str(run_wav)], capture_output=True,
                                        text=True, timeout=max(600, duration * 3))
                wall = time.perf_counter() - started
                (output / f"{stem}.stderr.log").write_text(result.stderr)
                (output / f"{stem}.json").write_text(result.stdout)
                if result.returncode:
                    raise RuntimeError(f"{stem} failed: {result.stderr[-3000:]}")
                data = json.loads(result.stdout)
                if not data.get("segments"):
                    raise RuntimeError(f"{stem} returned no segments")
                row = {"engine": engine, "repeat": repeat + 1, "audio_seconds": actual,
                       "wall_seconds": wall, "speed_factor": actual / wall,
                       "pipeline_seconds": data["pipeline_seconds"], "sha256": digest,
                       "segments": len(data["segments"])}
                metadata["runs"].append(row)
                (output / "results.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
                print(f"  {wall:.3f}s, {actual / wall:.1f}x real time, {row['segments']} segments", flush=True)
    lines = ["# macOS ASR speed benchmark", "", metadata["method"], "",
             f"CPU: {metadata['cpu']}; RAM: {metadata['memory_bytes'] / 2**30:.0f} GiB", "",
             "| Audio | Engine | First run | Median all runs | Speed |",
             "|---|---|---:|---:|---:|"]
    for duration in args.durations:
        for engine in engines:
            rows = [r for r in metadata["runs"] if r["engine"] == engine and r["audio_seconds"] == duration]
            median = statistics.median(r["wall_seconds"] for r in rows)
            lines.append(f"| {duration}s | {engine} | {rows[0]['wall_seconds']:.3f}s | {median:.3f}s | {duration / median:.1f}x |")
    (output / "REPORT.md").write_text("\n".join(lines) + "\n")
    print(f"Results: {output}", flush=True)


if __name__ == "__main__":
    main()
