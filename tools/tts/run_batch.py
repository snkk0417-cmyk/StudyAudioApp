#!/usr/bin/env python3
"""
StudyAudioApp — full-batch deep.txt -> deep.mp3 production runner.

Thin orchestrator over generate_tts.py. It targets ONLY the per-topic deep.txt
scripts (assets/text/<cat>/<topic>/deep.txt), mirrors each to its canonical
assets/audio/<cat>/<topic>/deep.mp3, and:

  * skips topics whose deep.mp3 already exists and is non-empty (resume-safe),
  * runs the unchanged production pipeline (1800-char chunking, ffmpeg concat,
    transient-only retry, atomic writes, progress/failure logs),
  * throttles via TTS_REQUEST_DELAY (set to 2.0 for this run),
  * prints a progress block every 10 completed files (count, cumulative cost
    estimate, failures so far),
  * keeps going if a file fails, recording it for later retry,
  * prints a final report: total time, cost estimate, audio duration, failures.

USAGE
  TTS_REQUEST_DELAY=2.0 python run_batch.py            # run (asks once)
  TTS_REQUEST_DELAY=2.0 python run_batch.py --yes      # no prompt
  python run_batch.py --dry-run                        # plan + cost, no API calls
"""

from __future__ import annotations

import argparse
import sys
import time

import generate_tts as g

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass


def deep_scripts() -> list:
    """Every per-topic deep.txt, sorted — the 51 batch targets."""
    return sorted(g.TEXT_ROOT.rglob("deep.txt"))


def is_done(text_file) -> bool:
    out = g.audio_path_for(text_file)
    return out.exists() and out.stat().st_size > 0


def main() -> None:
    ap = argparse.ArgumentParser(description="Full batch generation for all deep.txt.")
    ap.add_argument("--dry-run", action="store_true", help="Plan + cost only; no API.")
    ap.add_argument("--yes", "-y", action="store_true", help="Skip confirm prompt.")
    args = ap.parse_args()

    cfg = g.load_config()
    every = deep_scripts()
    if not every:
        sys.exit("No deep.txt files found under assets/text/.")

    todo = [f for f in every if not is_done(f)]
    skipped = len(every) - len(todo)
    price = cfg["price_per_1m"]

    # Cost/chunk estimate for the work that will actually run.
    est_chars = sum(g.count_chars(f) for f in todo)
    est_requests = sum(g._chunk_count(g.count_chars(f)) for f in todo)
    est_cost = est_chars / 1_000_000.0 * price

    print("=" * 72)
    print("StudyAudioApp — FULL BATCH (deep.txt -> deep.mp3)")
    print("=" * 72)
    print(f"  model {cfg['model']}   voice {cfg['voice']}   "
          f"chunk<= {g.MAX_CHARS_PER_REQUEST} chars   throttle {cfg['request_delay']}s/req")
    print(f"  total topics : {len(every)}")
    print(f"  already done : {skipped}  (valid deep.mp3 exists -> skipped)")
    print(f"  to generate  : {len(todo)}")
    print(f"  characters   : {est_chars:,}   api requests : {est_requests}")
    print(f"  EST. COST    : ${est_cost:,.4f}  (@ ${price:.2f}/1M chars, estimate only)")
    print("=" * 72)

    if args.dry_run:
        print("\n[dry-run] No audio generated.")
        return
    if not todo:
        print("\nNothing to generate — all deep.mp3 exist.")
        return
    if not cfg["api_key"]:
        sys.exit("\nERROR: OPENAI_API_KEY not set in tools/tts/.env.")
    if not args.yes:
        reply = input(f"\nGenerate {len(todo)} files now (paid API)? [y/N] ").strip().lower()
        if reply not in ("y", "yes"):
            print("Aborted. No API calls made.")
            return

    from openai import OpenAI
    client = OpenAI(api_key=cfg["api_key"])

    print(f"\nStarting batch of {len(todo)} files at throttle {cfg['request_delay']}s/req...\n")
    t0 = time.time()
    done = 0
    done_chars = 0
    done_seconds = 0.0
    failures: list[tuple] = []

    for i, text_file in enumerate(todo, 1):
        rel = text_file.relative_to(g.TEXT_ROOT)
        print(f"[{i}/{len(todo)}] {rel}")
        try:
            info = g.generate_one(client, text_file, cfg)
            done += 1
            done_chars += info.get("chars", 0)
            done_seconds += info.get("duration_sec", 0.0)
        except KeyboardInterrupt:
            print("\nInterrupted by user. Completed files kept; rerun to resume.")
            break
        except Exception as exc:  # tolerate & continue
            print(f"  [FAIL] {rel}: {exc}")
            g.log_failure(text_file, exc)
            failures.append((rel, exc))

        # Progress block every 10 completed files.
        if done and done % 10 == 0:
            _progress(done, len(todo), done_chars, done_seconds, failures, price, t0)

    # ---- final report ----
    elapsed = time.time() - t0
    print("\n" + "=" * 72)
    print("BATCH COMPLETE")
    print("=" * 72)
    print(f"  files generated   : {done}/{len(todo)}   (skipped pre-existing: {skipped})")
    print(f"  total time        : {_hms(elapsed)}")
    print(f"  total audio        : {_hms(done_seconds)}  ({done_seconds/60:.1f} min)")
    print(f"  characters spoken : {done_chars:,}")
    print(f"  EST. total cost   : ${done_chars/1_000_000.0*price:,.4f}  "
          f"(@ ${price:.2f}/1M chars, estimate only)")
    if failures:
        print(f"  FAILED ({len(failures)}) — logged to {g.FAILURE_LOG.relative_to(g.REPO_ROOT)} "
              f"(rerun this script to retry them):")
        for rel, exc in failures:
            print(f"    - {rel}: {exc}")
    else:
        print("  failures          : none")
    print(f"  progress log      : {g.PROGRESS_LOG.relative_to(g.REPO_ROOT)}")
    print("=" * 72)


def _progress(done, total, chars, seconds, failures, price, t0) -> None:
    print("-" * 72)
    print(f"  >> PROGRESS: {done}/{total} completed | "
          f"cumulative est. cost ${chars/1_000_000.0*price:,.4f} | "
          f"audio {seconds/60:.1f} min | "
          f"failures {len(failures)} | elapsed {_hms(time.time()-t0)}")
    print("-" * 72)


def _hms(sec: float) -> str:
    sec = int(round(sec))
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return f"{h:d}:{m:02d}:{s:02d}"


if __name__ == "__main__":
    main()
