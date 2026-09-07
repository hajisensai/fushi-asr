"""Compare Apple's original-file path with the former ffmpeg/WAV preparation.

Both modes invoke the SAME helper and SpeechTranscriber model. Runs alternate
ABBA, fresh helper process per run; warm OS/model caches are not flushed. The
default 300-second input excerpt is packet-copied, not re-encoded. Timed old runs
include ffmpeg's whole-input 16 kHz mono PCM conversion; direct runs do not.

Example (after building the helper with script/build_and_run.sh):
  python3 tool/benchmark_apple_input.py /path/to/book.m4b \
      --helper build/apple_transcribe --duration 300 --offset 120 --rounds 2

Use --duration 0 for the complete input. All audio, transcripts, and reports stay
in a unique local build/benchmark directory. Do not run alongside another ASR
job. Text similarity measures differences, NOT recognition accuracy.
"""

import argparse
import difflib
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]


def compare_segments(before, after):
    before_text = "".join(segment["text"] for segment in before)
    after_text = "".join(segment["text"] for segment in after)
    comparison = {
        "exact_segments": before == after,
        "exact_text": before_text == after_text,
        "text_similarity_not_accuracy": 1.0 if before_text == after_text else
            difflib.SequenceMatcher(None, before_text, after_text, autojunk=False).ratio(),
        "before_segments": len(before),
        "after_segments": len(after),
        "before_characters": len(before_text),
        "after_characters": len(after_text),
    }
    # Index-based timing deltas are meaningful only with equal segment counts;
    # they do not prove that boundaries refer to the same spoken words.
    if len(before) == len(after) and before:
        comparison["max_index_start_delta_ms"] = max(
            abs(left["start"] - right["start"]) * 1000
            for left, right in zip(before, after)
        )
        comparison["max_index_end_delta_ms"] = max(
            abs(left["end"] - right["end"]) * 1000
            for left, right in zip(before, after)
        )
    return comparison


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--ffmpeg", default=os.environ.get("ASR_FFMPEG", "ffmpeg"))
    parser.add_argument("--duration", type=float, default=300,
                        help="Seconds to packet-copy; 0 uses complete input")
    parser.add_argument("--offset", type=float, default=0)
    parser.add_argument("--rounds", type=int, default=2,
                        help="Number of old/direct/direct/old blocks")
    parser.add_argument("--timeout", type=float, default=600,
                        help="Maximum seconds per subprocess")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/benchmark")
    args = parser.parse_args()
    if (not args.audio.is_file() or not args.helper.is_file()
            or not all(math.isfinite(value) for value in
                       (args.duration, args.offset, args.timeout))
            or args.duration < 0 or args.offset < 0 or args.rounds < 1
            or args.timeout <= 0):
        parser.error("Existing audio/helper, nonnegative duration/offset, and positive rounds/timeout required")
    if args.duration == 0 and args.offset != 0:
        parser.error("--duration 0 uses the complete file; --offset must be 0")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="apple-input-", dir=args.output_dir)).resolve()
    audio = args.audio.resolve()
    helper = str(args.helper.resolve())
    sample = audio
    if args.duration > 0:
        sample = work / ("sample" + audio.suffix)
        subprocess.run([
            args.ffmpeg, "-v", "error", "-nostdin", "-ss", str(args.offset),
            "-i", str(audio), "-t", str(args.duration), "-map", "0:a:0",
            "-c:a", "copy", str(sample),
        ], check=True, timeout=args.timeout)
    digest = hashlib.sha256()
    with sample.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    report = {
        "source": str(audio), "sample": str(sample), "helper": helper,
        "sample_sha256": digest.hexdigest(), "platform": platform.platform(),
        "offset_seconds": args.offset, "requested_seconds": args.duration,
        "method": "Same helper/model; fresh process per run; old/direct/direct/old blocks; old includes ffmpeg PCM preparation; sample extraction excluded; no cache flush; sequential, not parallel.",
        "runs": [], "quality_against_first_old_run": [],
    }
    reference = None

    def save():
        (work / "results.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"Local evidence: {work}", flush=True)
    for index, mode in enumerate(["old", "direct", "direct", "old"] * args.rounds):
        prepared = sample
        decode_seconds = 0.0
        started = time.perf_counter()
        if mode == "old":
            prepared = work / f"{index:02}-pcm.wav"
            subprocess.run([
                args.ffmpeg, "-v", "error", "-nostdin", "-i", str(sample),
                "-map", "0:a:0", "-ac", "1", "-ar", "16000",
                "-c:a", "pcm_s16le", str(prepared),
            ], check=True, timeout=args.timeout)
            decode_seconds = time.perf_counter() - started
        result = subprocess.run([helper, str(prepared)], capture_output=True,
                                text=True, timeout=args.timeout)
        wall_seconds = time.perf_counter() - started
        stem = f"{index:02}-{mode}"
        (work / f"{stem}.stderr.log").write_text(result.stderr, encoding="utf-8")
        (work / f"{stem}.json").write_text(result.stdout, encoding="utf-8")
        if result.returncode:
            report["error"] = {"run": stem, "exit_code": result.returncode}
            save()
            raise RuntimeError(f"{stem} failed; see {work / (stem + '.stderr.log')}")
        data = json.loads(result.stdout)
        if not data.get("segments"):
            raise RuntimeError(f"{stem} produced no segments")
        if reference is None:
            reference = data["segments"]
        row = {
            "index": index, "mode": mode, "wall_seconds": wall_seconds,
            "decode_seconds": decode_seconds,
            "helper_wall_seconds": wall_seconds - decode_seconds,
            "pipeline_seconds": data["pipeline_seconds"],
            "audio_seconds": data["audio_seconds"],
            "speed_factor": data["audio_seconds"] / wall_seconds,
            "segments": len(data["segments"]),
        }
        report["runs"].append(row)
        report["quality_against_first_old_run"].append({
            "index": index, "mode": mode,
            **compare_segments(reference, data["segments"]),
        })
        save()
        print(json.dumps(row), flush=True)
        # Each old conversion was timed in full. Remove only our known scratch
        # WAV after storing results, avoiding multiple full-book PCM copies.
        if mode == "old":
            prepared.unlink()

    report["median_wall_seconds"] = {
        mode: statistics.median(row["wall_seconds"] for row in report["runs"]
                                if row["mode"] == mode)
        for mode in ("old", "direct")
    }
    report["old_over_direct_speedup"] = (
        report["median_wall_seconds"]["old"] / report["median_wall_seconds"]["direct"]
    )
    save()
    print(json.dumps({key: report[key] for key in
                      ("median_wall_seconds", "old_over_direct_speedup")}), flush=True)


if __name__ == "__main__":
    main()
