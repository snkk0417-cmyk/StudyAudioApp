#!/usr/bin/env python3
"""
StudyAudioApp — batch OpenAI TTS generator.

Converts the Japanese lecture scripts under  assets/text/<category>/<topic>/<sec>.txt
into MP3 files mirrored under              assets/audio/<category>/<topic>/<sec>.mp3

DESIGN PRINCIPLES (see docs/ARCHITECTURE.md §4):
  * The API key lives ONLY in tools/tts/.env  (never hardcoded, never committed).
  * Nothing is sent to OpenAI until you confirm. A cost estimate is always shown first.
  * --dry-run makes ZERO API calls and needs no key.
  * Work is incremental: --file / --folder / --all. Existing outputs are skipped
    (resume-safe) unless --force.
  * Long scripts are chunked under OpenAI's 4096-char limit and concatenated.

USAGE
  python generate_tts.py --dry-run --all                       # estimate everything
  python generate_tts.py --file architecture/urban_planning/core.txt
  python generate_tts.py --file urban_planning                 # fuzzy match in text tree
  python generate_tts.py --folder construction
  python generate_tts.py --all
  python generate_tts.py --all --yes                           # skip the confirm prompt
  python generate_tts.py --folder structure --force            # re-generate existing mp3s

Run  python generate_tts.py --help  for all options.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# Console output is UTF-8 — paths and scripts are Japanese, and the plan uses box
# characters. Windows terminals default to cp932/cp1252 and would crash otherwise.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

# ---------------------------------------------------------------------------
# Paths. This script lives in  <repo>/tools/tts/ , so the repo root is two up.
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
TEXT_ROOT = REPO_ROOT / "assets" / "text"
AUDIO_ROOT = REPO_ROOT / "assets" / "audio"

# OpenAI hard limit on TTS input length, per request. We stay safely under it.
MAX_CHARS_PER_REQUEST = 4000

# ---------------------------------------------------------------------------
# Config loaded from .env (with built-in defaults).
# ---------------------------------------------------------------------------


def load_config() -> dict:
    """Read tools/tts/.env into os.environ (if present), return resolved config."""
    env_path = SCRIPT_DIR / ".env"
    try:
        from dotenv import load_dotenv

        if env_path.exists():
            load_dotenv(env_path)
    except ImportError:
        # python-dotenv not installed: fall back to whatever is already in the env.
        if env_path.exists():
            _load_env_manually(env_path)

    return {
        "api_key": os.environ.get("OPENAI_API_KEY", "").strip(),
        "model": os.environ.get("TTS_MODEL", "gpt-4o-mini-tts").strip(),
        "voice": os.environ.get("TTS_VOICE", "nova").strip(),
        "format": os.environ.get("TTS_FORMAT", "mp3").strip(),
        "speed": float(os.environ.get("TTS_SPEED", "1.0") or "1.0"),
        "instructions": os.environ.get("TTS_INSTRUCTIONS", "").strip(),
        "price_per_1m": float(os.environ.get("TTS_PRICE_PER_1M_CHARS", "12.00") or "12.00"),
    }


def _load_env_manually(env_path: Path) -> None:
    """Tiny .env parser used only if python-dotenv is missing."""
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


# ---------------------------------------------------------------------------
# Selecting which scripts to process.
# ---------------------------------------------------------------------------


def all_text_files() -> list[Path]:
    if not TEXT_ROOT.exists():
        return []
    return sorted(TEXT_ROOT.rglob("*.txt"))


def resolve_selection(args) -> list[Path]:
    """Return the list of .txt scripts to process, based on the CLI flags."""
    every = all_text_files()
    if not every:
        sys.exit(f"No scripts found under {TEXT_ROOT}. Generate scripts first.")

    if args.all:
        return every

    if args.folder:
        folder = args.folder.strip().strip("/\\")
        base = TEXT_ROOT / folder
        if not base.exists():
            cats = sorted({p.relative_to(TEXT_ROOT).parts[0] for p in every})
            sys.exit(
                f"Folder '{folder}' not found under assets/text/.\n"
                f"Available categories: {', '.join(cats)}"
            )
        return sorted(base.rglob("*.txt"))

    if args.file:
        return _match_file(args.file, every)

    sys.exit("Choose one of: --file <name>, --folder <category>, or --all. "
             "(Add --dry-run to only estimate cost.)")


def _match_file(needle: str, every: list[Path]) -> list[Path]:
    """Match --file either as an exact relative path or a fuzzy substring."""
    needle = needle.strip()
    norm = needle.replace("\\", "/")

    # 1) exact relative path under assets/text/
    exact = TEXT_ROOT / norm
    if exact.suffix != ".txt":
        exact = exact.with_suffix(".txt")
    if exact.exists():
        return [exact]

    # 2) fuzzy: substring match against the relative path (without extension)
    stem = norm[:-4] if norm.endswith(".txt") else norm
    matches = [p for p in every
               if stem.lower() in str(p.relative_to(TEXT_ROOT)).replace("\\", "/").lower()]
    if not matches:
        sys.exit(f"No script matched '{needle}' under assets/text/.")
    if len(matches) > 1:
        listing = "\n  ".join(str(p.relative_to(TEXT_ROOT)) for p in matches)
        sys.exit(f"'{needle}' matched {len(matches)} scripts — be more specific:\n  {listing}")
    return matches


def audio_path_for(text_file: Path) -> Path:
    """Mirror a text path to its audio path: text/<...>.txt -> audio/<...>.mp3"""
    rel = text_file.relative_to(TEXT_ROOT)
    return (AUDIO_ROOT / rel).with_suffix(".mp3")


# ---------------------------------------------------------------------------
# Cost estimation.
# ---------------------------------------------------------------------------


def count_chars(path: Path) -> int:
    try:
        return len(path.read_text(encoding="utf-8"))
    except Exception:
        return 0


def print_plan(selection: list[Path], cfg: dict, force: bool) -> list[Path]:
    """Print the work plan + cost estimate. Returns the files that will actually run."""
    print("=" * 72)
    print("StudyAudioApp — TTS generation plan")
    print("=" * 72)
    print(f"  model : {cfg['model']}    voice : {cfg['voice']}    format : {cfg['format']}")
    print(f"  text  : {TEXT_ROOT}")
    print(f"  audio : {AUDIO_ROOT}")
    print("-" * 72)

    to_run: list[Path] = []
    skipped = 0
    total_chars = 0

    print(f"  {'STATUS':8}  {'CHARS':>7}  {'~MIN':>5}  SCRIPT")
    for text_file in selection:
        out = audio_path_for(text_file)
        rel = text_file.relative_to(TEXT_ROOT)
        chars = count_chars(text_file)
        minutes = chars / 340.0  # ~340 Japanese chars per spoken minute

        if out.exists() and not force:
            print(f"  {'skip':8}  {chars:>7}  {minutes:>5.1f}  {rel}  (mp3 exists)")
            skipped += 1
            continue

        print(f"  {'GEN':8}  {chars:>7}  {minutes:>5.1f}  {rel}")
        to_run.append(text_file)
        total_chars += chars

    print("-" * 72)
    est_cost = total_chars / 1_000_000.0 * cfg["price_per_1m"]
    n_requests = sum(_chunk_count(count_chars(f)) for f in to_run)
    print(f"  to generate : {len(to_run)} file(s)   skipped : {skipped}")
    print(f"  characters  : {total_chars:,}  ->  ~{total_chars/340.0:.0f} min of audio")
    print(f"  api requests: {n_requests} (long scripts are chunked under "
          f"{MAX_CHARS_PER_REQUEST} chars)")
    print(f"  EST. COST   : ${est_cost:,.4f}  "
          f"(@ ${cfg['price_per_1m']:.2f}/1M chars — verify against OpenAI pricing)")
    print("=" * 72)
    return to_run


def _chunk_count(chars: int) -> int:
    if chars == 0:
        return 0
    return max(1, -(-chars // MAX_CHARS_PER_REQUEST))  # ceil division


# ---------------------------------------------------------------------------
# Chunking long scripts on sentence boundaries.
# ---------------------------------------------------------------------------


def chunk_text(text: str, limit: int = MAX_CHARS_PER_REQUEST) -> list[str]:
    """Split text into <= limit-char chunks, preferring Japanese sentence/line breaks."""
    text = text.strip()
    if len(text) <= limit:
        return [text] if text else []

    chunks: list[str] = []
    buf = ""
    # Split on sentence enders and newlines, keeping the delimiter attached.
    segments = _split_keep(text, ("。", "！", "？", "\n"))
    for seg in segments:
        if len(buf) + len(seg) <= limit:
            buf += seg
        else:
            if buf:
                chunks.append(buf)
            # A single segment longer than the limit (rare) is hard-split.
            while len(seg) > limit:
                chunks.append(seg[:limit])
                seg = seg[limit:]
            buf = seg
    if buf.strip():
        chunks.append(buf)
    return [c for c in chunks if c.strip()]


def _split_keep(text: str, delimiters: tuple[str, ...]) -> list[str]:
    """Split text into pieces, each ending with one of the delimiters (kept)."""
    out: list[str] = []
    start = 0
    for i, ch in enumerate(text):
        if ch in delimiters:
            out.append(text[start:i + 1])
            start = i + 1
    if start < len(text):
        out.append(text[start:])
    return out


# ---------------------------------------------------------------------------
# Generation.
# ---------------------------------------------------------------------------


def generate_one(client, text_file: Path, cfg: dict) -> None:
    out = audio_path_for(text_file)
    out.parent.mkdir(parents=True, exist_ok=True)
    text = text_file.read_text(encoding="utf-8").strip()
    chunks = chunk_text(text)
    rel = text_file.relative_to(TEXT_ROOT)

    if not chunks:
        print(f"  [skip] {rel} is empty.")
        return

    print(f"  [gen ] {rel}  ({len(text):,} chars, {len(chunks)} chunk(s)) -> "
          f"{out.relative_to(AUDIO_ROOT)}")

    audio_bytes = bytearray()
    for idx, chunk in enumerate(chunks, 1):
        if len(chunks) > 1:
            print(f"         chunk {idx}/{len(chunks)} ({len(chunk):,} chars)...")
        audio_bytes += _synthesize(client, chunk, cfg)

    # Write atomically: temp file then replace, so an interrupted write never
    # leaves a half-written mp3 that the resume logic would treat as "done".
    tmp = out.with_suffix(".mp3.partial")
    tmp.write_bytes(bytes(audio_bytes))
    tmp.replace(out)
    print(f"         done -> {out.relative_to(REPO_ROOT)} ({len(audio_bytes):,} bytes)")


def _synthesize(client, text: str, cfg: dict) -> bytes:
    """One TTS request. Tolerates models that don't accept speed/instructions."""
    kwargs = dict(
        model=cfg["model"],
        voice=cfg["voice"],
        input=text,
        response_format=cfg["format"],
    )
    if cfg["instructions"] and cfg["model"].startswith("gpt-4o"):
        kwargs["instructions"] = cfg["instructions"]
    if abs(cfg["speed"] - 1.0) > 1e-6:
        kwargs["speed"] = cfg["speed"]

    try:
        resp = client.audio.speech.create(**kwargs)
    except TypeError:
        # Older SDK / param mismatch: retry with the minimal supported set.
        resp = client.audio.speech.create(
            model=cfg["model"], voice=cfg["voice"], input=text,
            response_format=cfg["format"],
        )
    return resp.content


# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Batch-generate MP3 audio from lecture scripts via OpenAI TTS.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sel = parser.add_mutually_exclusive_group()
    sel.add_argument("--file", help="One script: relative path or fuzzy name.")
    sel.add_argument("--folder", help="One category folder, e.g. construction.")
    sel.add_argument("--all", action="store_true", help="Every script under assets/text/.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Only show the cost estimate; make NO API calls.")
    parser.add_argument("--force", action="store_true",
                        help="Regenerate even if the .mp3 already exists.")
    parser.add_argument("--yes", "-y", action="store_true",
                        help="Skip the confirmation prompt (for scripted runs).")
    args = parser.parse_args()

    cfg = load_config()
    selection = resolve_selection(args)
    to_run = print_plan(selection, cfg, args.force)

    if args.dry_run:
        print("\n[dry-run] No audio generated. Remove --dry-run to proceed.")
        return

    if not to_run:
        print("\nNothing to generate (all outputs exist — use --force to overwrite).")
        return

    if not cfg["api_key"]:
        sys.exit(
            "\nERROR: OPENAI_API_KEY is not set.\n"
            f"Copy {SCRIPT_DIR / '.env.example'} to .env and add your key, "
            "then run again.\n(Use --dry-run to estimate cost without a key.)"
        )

    if not args.yes:
        reply = input(f"\nGenerate {len(to_run)} file(s) now? This calls the paid "
                      "OpenAI API. [y/N] ").strip().lower()
        if reply not in ("y", "yes"):
            print("Aborted. No API calls made.")
            return

    try:
        from openai import OpenAI
    except ImportError:
        sys.exit("ERROR: the 'openai' package is not installed. "
                 "Run: pip install -r requirements.txt")

    client = OpenAI(api_key=cfg["api_key"])

    print("\nGenerating...")
    ok, failed = 0, []
    for text_file in to_run:
        try:
            generate_one(client, text_file, cfg)
            ok += 1
        except KeyboardInterrupt:
            print("\nInterrupted. Already-finished files are kept; rerun to resume.")
            break
        except Exception as exc:  # keep going; report at the end
            print(f"  [FAIL] {text_file.relative_to(TEXT_ROOT)}: {exc}")
            failed.append((text_file, exc))

    print("\n" + "=" * 72)
    print(f"Done. Generated {ok} file(s).", end="")
    if failed:
        print(f"  {len(failed)} failed:")
        for f, exc in failed:
            print(f"  - {f.relative_to(TEXT_ROOT)}: {exc}")
    else:
        print(" No failures.")


if __name__ == "__main__":
    main()
