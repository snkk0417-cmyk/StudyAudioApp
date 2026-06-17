# TTS pipeline — `tools/tts/`

Batch-converts the Japanese lecture scripts in `assets/text/` into MP3 files in
`assets/audio/`, using the OpenAI TTS API. **You run this manually on your machine** —
it is never executed automatically, and it always shows a cost estimate before calling
the API.

## One-time setup

```bash
cd tools/tts
pip install -r requirements.txt
cp .env.example .env          # then edit .env and paste your OpenAI API key
```

`.env` is gitignored. Your key never enters the repo or the code.

## Everyday use

```bash
# Estimate cost for everything, WITHOUT calling the API or needing a key:
python generate_tts.py --dry-run --all

# Generate a single script:
python generate_tts.py --file structure/rc_beam/core.txt
python generate_tts.py --file rc_beam            # fuzzy match also works

# Generate one whole category:
python generate_tts.py --folder construction

# Generate everything (sequentially, one request at a time):
python generate_tts.py --all

# Re-generate files that already exist:
python generate_tts.py --folder structure --force

# Non-interactive (skip the y/N prompt):
python generate_tts.py --all --yes
```

## How it behaves

- **Cost first.** Every run prints a per-file + total character count and an estimated
  USD cost, then asks for confirmation before any paid call. `--dry-run` stops there.
- **Resume-safe.** Files whose `.mp3` already exists are skipped (use `--force` to
  overwrite). An interrupted run is cheap to resume — just run the same command again.
- **Long scripts.** OpenAI caps input at ~4096 chars/request. Long lectures are split on
  Japanese sentence boundaries and the MP3 chunks are concatenated automatically.
- **Mirrored output.** `assets/text/<cat>/<topic>/<sec>.txt` → `assets/audio/<cat>/<topic>/<sec>.mp3`.

## Configuration (`.env`)

| Var | Default | Notes |
|-----|---------|-------|
| `OPENAI_API_KEY` | — | required for real runs; not needed for `--dry-run` |
| `TTS_MODEL` | `gpt-4o-mini-tts` | or `tts-1`, `tts-1-hd` |
| `TTS_VOICE` | `nova` | `nova`/`shimmer`/`alloy`/`fable`/`onyx`/`echo` |
| `TTS_FORMAT` | `mp3` | |
| `TTS_SPEED` | `1.0` | the app also has its own speed control |
| `TTS_INSTRUCTIONS` | (lecturer tone) | steering for `gpt-4o-mini-tts` |
| `TTS_PRICE_PER_1M_CHARS` | `12.00` | **estimate only** — verify current OpenAI pricing |

> The cost figure is an estimate for budgeting, not a billing source. Always check your
> OpenAI usage dashboard for actual charges.
