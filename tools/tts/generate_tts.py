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
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
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

# Run records live here. progress.jsonl = one line per finished file (resume audit
# trail); failures.log = one line per failed file, kept separate so a long run's
# errors are easy to find. Both are gitignored and append-only.
LOG_DIR = SCRIPT_DIR / "logs"
PROGRESS_LOG = LOG_DIR / "progress.jsonl"
FAILURE_LOG = LOG_DIR / "failures.log"

# Per-request input cap. The gpt-4o-*-tts models limit input to 2000 TOKENS (not
# characters). Japanese runs high — ~0.84 tokens/char observed — so a 2,955-char
# script is ~2,468 tokens, over the limit. We chunk on a conservative CHARACTER
# budget that stays under 2000 tokens even for dense kanji (~1.0 tok/char worst case):
# 1,800 chars -> <=1,800 tokens. (tts-1/tts-1-hd allow 4096 chars; this is safe there too.)
MAX_CHARS_PER_REQUEST = 1800

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
        "voice": os.environ.get("TTS_VOICE", "shimmer").strip(),
        "format": os.environ.get("TTS_FORMAT", "mp3").strip(),
        "speed": float(os.environ.get("TTS_SPEED", "1.0") or "1.0"),
        "instructions": os.environ.get("TTS_INSTRUCTIONS", "").strip(),
        "price_per_1m": float(os.environ.get("TTS_PRICE_PER_1M_CHARS", "12.00") or "12.00"),
        "max_retries": int(os.environ.get("TTS_MAX_RETRIES", "5") or "5"),
        "retry_base_delay": float(os.environ.get("TTS_RETRY_BASE_DELAY", "2.0") or "2.0"),
        # Throttle: seconds to wait before each API request (rate-limit safety).
        "request_delay": float(os.environ.get("TTS_REQUEST_DELAY", "0") or "0"),
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
# Progress + failure logging (incremental, resume-friendly).
# ---------------------------------------------------------------------------


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log_success(text_file: Path, out: Path, info: dict) -> None:
    """Append one JSON line per finished file — an audit trail for resumed runs."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    record = {
        "ts": _now_iso(),
        "script": str(text_file.relative_to(TEXT_ROOT)).replace("\\", "/"),
        "audio": str(out.relative_to(AUDIO_ROOT)).replace("\\", "/"),
        **info,
    }
    with PROGRESS_LOG.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def log_failure(text_file: Path, exc: Exception) -> None:
    """Append one line per failure to a dedicated log, separate from progress."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    rel = str(text_file.relative_to(TEXT_ROOT)).replace("\\", "/")
    with FAILURE_LOG.open("a", encoding="utf-8") as fh:
        fh.write(f"{_now_iso()}\t{rel}\t{type(exc).__name__}: {exc}\n")


def mp3_duration_seconds(path: Path, char_count: int) -> tuple[float, bool]:
    """Best-effort audio duration in seconds.

    Returns (seconds, exact). Uses mutagen if installed for a real measurement;
    otherwise estimates from character count (~340 JA chars/min) and flags it.
    """
    try:
        from mutagen.mp3 import MP3

        return float(MP3(str(path)).info.length), True
    except Exception:
        return char_count / 340.0 * 60.0, False


# ---------------------------------------------------------------------------
# Generation.
# ---------------------------------------------------------------------------


def _find_ffmpeg() -> str | None:
    """Locate an ffmpeg binary: system PATH first, else the imageio-ffmpeg bundle.

    imageio-ffmpeg ships a self-contained ffmpeg, so chunk stitching works with no
    system install. Returns the executable path, or None if neither is available.
    """
    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    try:
        import imageio_ffmpeg

        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return None


def _concat_audio(chunk_bytes: list[bytes], dest: Path, cfg: dict) -> None:
    """Stitch multiple audio chunks into `dest` using ffmpeg — never a raw byte join.

    A raw byte concatenation splices two independently-encoded MP3 streams mid-frame,
    which can leave a click/pop and corrupts seeking. Instead we hand the chunks to
    ffmpeg's concat demuxer:
      * primary  : -c copy  -> lossless, frame-accurate stream copy (no re-encode).
      * fallback : decode + re-encode with libmp3lame, used only if -c copy errors
        (e.g. mismatched stream params), per the 'decode and re-encode' alternative.
    Either path produces a single, valid, continuous file with clean frame boundaries.
    """
    ffmpeg = _find_ffmpeg()
    if not ffmpeg:
        raise RuntimeError(
            "ffmpeg not found — required to stitch multi-chunk audio losslessly. "
            "Install it with:  pip install imageio-ffmpeg  (bundled binary, no system "
            "install) or add system ffmpeg to PATH."
        )

    ext = cfg["format"]
    with tempfile.TemporaryDirectory(prefix="tts_concat_") as td:
        tdp = Path(td)
        parts = []
        for i, b in enumerate(chunk_bytes):
            part = tdp / f"part{i:03d}.{ext}"
            part.write_bytes(b)
            parts.append(part)

        # concat-demuxer list file. Forward slashes + single quotes per its syntax.
        listfile = tdp / "list.txt"
        listfile.write_text(
            "\n".join(f"file '{p.as_posix()}'" for p in parts) + "\n",
            encoding="utf-8",
        )
        staged = tdp / f"out.{ext}"

        base = [ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
                "-f", "concat", "-safe", "0", "-i", str(listfile)]
        copy_cmd = base + ["-c", "copy", str(staged)]
        res = subprocess.run(copy_cmd, capture_output=True, text=True)

        if res.returncode != 0 or not staged.exists() or staged.stat().st_size == 0:
            # Lossless copy failed — fall back to a clean decode + re-encode.
            reencode_cmd = base + ["-c:a", "libmp3lame", "-b:a", "128k", str(staged)]
            res = subprocess.run(reencode_cmd, capture_output=True, text=True)
            if res.returncode != 0:
                raise RuntimeError(f"ffmpeg concat failed: {res.stderr.strip()}")

        dest.write_bytes(staged.read_bytes())


def generate_one(client, text_file: Path, cfg: dict) -> dict:
    out = audio_path_for(text_file)
    out.parent.mkdir(parents=True, exist_ok=True)
    text = text_file.read_text(encoding="utf-8").strip()
    chunks = chunk_text(text)
    rel = text_file.relative_to(TEXT_ROOT)

    if not chunks:
        print(f"  [skip] {rel} is empty.")
        return {}

    print(f"  [gen ] {rel}  ({len(text):,} chars, {len(chunks)} chunk(s)) -> "
          f"{out.relative_to(AUDIO_ROOT)}")

    chunk_audio: list[bytes] = []
    for idx, chunk in enumerate(chunks, 1):
        if len(chunks) > 1:
            print(f"         chunk {idx}/{len(chunks)} ({len(chunk):,} chars)...")
        # Throttle before every API request (incl. across files) to dodge rate limits.
        if cfg.get("request_delay", 0) > 0:
            time.sleep(cfg["request_delay"])
        chunk_audio.append(_synthesize(client, chunk, cfg))

    # Write atomically: build into a temp file then replace, so an interrupted write
    # never leaves a half-written mp3 that the resume logic would treat as "done".
    tmp = out.with_suffix(".mp3.partial")
    if len(chunk_audio) == 1:
        # Single chunk: already one clean stream from the API — no stitching needed.
        tmp.write_bytes(chunk_audio[0])
    else:
        # Multiple chunks: stitch with ffmpeg (lossless concat), never a byte join.
        print(f"         stitching {len(chunk_audio)} chunks via ffmpeg...")
        _concat_audio(chunk_audio, tmp, cfg)
    tmp.replace(out)

    out_bytes = out.stat().st_size
    seconds, exact = mp3_duration_seconds(out, len(text))
    info = {
        "chars": len(text),
        "chunks": len(chunks),
        "bytes": out_bytes,
        "duration_sec": round(seconds, 1),
        "duration_exact": exact,
        "stitched": len(chunk_audio) > 1,
    }
    log_success(text_file, out, info)
    dur_note = f"{seconds:.1f}s" + ("" if exact else " (est.)")
    print(f"         done -> {out.relative_to(REPO_ROOT)} "
          f"({out_bytes:,} bytes, {dur_note})")
    return info


def _is_retryable(exc: Exception) -> bool:
    """True only for transient failures: rate limits, timeouts, conn drops, 5xx.

    A 4xx client error (bad input, auth, not-found) is deterministic — retrying it
    just wastes time and money, so those return False and fail fast.
    """
    try:
        import openai
    except ImportError:
        return True  # can't introspect SDK types; be lenient and allow a retry
    if isinstance(exc, (openai.APIConnectionError, openai.APITimeoutError,
                        openai.RateLimitError, openai.InternalServerError)):
        return True
    status = getattr(exc, "status_code", None)
    if isinstance(status, int):
        return status == 429 or 500 <= status < 600
    # Unknown/non-API exception (e.g. network lib): treat as transient.
    return not isinstance(exc, openai.APIStatusError)


def _synthesize(client, text: str, cfg: dict) -> bytes:
    """One TTS request, with retry/backoff on transient API failures.

    Network blips, rate limits (429) and server errors (5xx) are retried with
    exponential backoff. A TypeError means the SDK rejected a kwarg (not transient),
    so we drop the optional params and retry once with the minimal set instead.
    """
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

    max_retries = cfg["max_retries"]
    base_delay = cfg["retry_base_delay"]
    last_exc: Exception | None = None

    for attempt in range(1, max_retries + 1):
        try:
            resp = client.audio.speech.create(**kwargs)
            return resp.content
        except TypeError:
            # Param/SDK mismatch — not transient. Strip optional kwargs and retry once.
            resp = client.audio.speech.create(
                model=cfg["model"], voice=cfg["voice"], input=text,
                response_format=cfg["format"],
            )
            return resp.content
        except Exception as exc:
            last_exc = exc
            # Only retry transient failures. A 4xx like 400 (bad input) or 401
            # (auth) will fail identically every time — fail fast, don't burn retries.
            if not _is_retryable(exc):
                raise
            if attempt == max_retries:
                break
            delay = base_delay * (2 ** (attempt - 1))  # 2, 4, 8, 16, ...
            print(f"         API error (attempt {attempt}/{max_retries}): {exc} "
                  f"-> retrying in {delay:.0f}s")
            time.sleep(delay)

    raise RuntimeError(
        f"TTS request failed after {max_retries} attempts: {last_exc}"
    ) from last_exc


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
            log_failure(text_file, exc)
            failed.append((text_file, exc))

    print("\n" + "=" * 72)
    print(f"Done. Generated {ok} file(s).", end="")
    if failed:
        print(f"  {len(failed)} failed (see {FAILURE_LOG.relative_to(REPO_ROOT)}):")
        for f, exc in failed:
            print(f"  - {f.relative_to(TEXT_ROOT)}: {exc}")
    else:
        print(" No failures.")
    if ok:
        print(f"Progress log: {PROGRESS_LOG.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
