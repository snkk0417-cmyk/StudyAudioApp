# StudyAudioApp — Architecture & Pipeline Design

A personal audio-learning system for the Japanese First-Class Architect Examination
(一級建築士試験). PDF study materials are turned into deep Japanese lecture scripts,
those scripts are converted to MP3 via OpenAI TTS, and everything is packaged into a
Flutter Android app for hands-free, background audio study.

This document is the single source of truth for *how the system is built*. It is
updated as phases complete.

---

## 1. End-to-end pipeline

```
 ┌──────────┐   (1) human+AI    ┌───────────┐   (2) generate_tts.py   ┌───────────┐   (3) Flutter
 │  PDF     │ ───────────────▶  │  Script   │ ─────────────────────▶  │   MP3     │ ───────────────▶  App
 │ assets/  │   script writing  │ assets/   │   OpenAI TTS (manual)   │ assets/   │   bundled assets   playback
 │  pdf/    │                   │  text/    │                         │  audio/   │
 └──────────┘                   └───────────┘                         └───────────┘
```

| Stage | Tool | Who runs it | Cost |
|-------|------|-------------|------|
| 1. PDF → Script (`.txt`) | Claude (this session), incremental, one topic at a time | AI | none |
| 2. Script → Audio (`.mp3`) | `tools/tts/generate_tts.py` | **User, manually, with own API key** | OpenAI TTS $ |
| 3. Audio → App | Flutter asset bundling + playlist | build step | none |

**Hard rule:** stage 2 is *never* executed automatically. The pipeline is built and
left ready; the user runs it locally when they choose, with a cost estimate shown first.

---

## 2. Content model (the important design decision)

The previous content was **shallow** — every topic was split into four ~2-minute
fragments (`core` / `practical` / `trap` / `exam`). The legacy 4-section structure is
**dropped**. It is replaced by two *content types* per topic.

### Content types (current)

| Content type (`id`) | Label | Role | Depth |
|---------------------|-------|------|-------|
| `deep` | Deep Lecture | The full lecture for **comprehensive understanding**. Combines core knowledge, practical/field knowledge, engineering reasoning, common mistakes, and exam traps — woven into one continuous spoken lecture. | Per-category (below) |
| `exam` | Exam Review | **Fast memorization** for exam prep: frequently-tested concepts, numerical values, high-priority facts, quick recall. | 1–3 min |

Files are named by the content-type id: `assets/text/<cat>/<topic>/deep.txt` →
`assets/audio/<cat>/<topic>/deep.mp3`, and likewise `exam`.

### Flexible architecture (do NOT hardcode "exactly 2")

The data model is **`topic → content_type → audio_file`**, driven by a declared *list*
of content types — not two hardwired fields. Adding a future type (e.g. `advanced`,
`review`) means appending one entry to the content-type list + dropping in the
`<type>.txt` / `<type>.mp3` files; **no structural code change**. The app discovers
which types exist per topic at runtime (asset-presence check), so topics may legitimately
carry different sets of content types. The UI surfaces only `deep` + `exam` for now.

```
topic ── deep.mp3      (Deep Lecture)   ◀ shown in UI
      ├─ exam.mp3      (Exam Review)    ◀ shown in UI
      └─ advanced.mp3  (future)         ◀ data model already supports it
```

### Per-category depth targets (applies to the `deep` lecture)

| Category (folder) | Japanese | `deep` target | Style |
|-------------------|----------|---------------|-------|
| `architecture` | 計画 (Planning) | **2–5 min** | Concise. Definitions, numbers, classification differences, high-frequency exam points. Memorization-efficient. |
| `construction` | 施工 | **8–15 min** | Deep. Procedures + *why*, quality control, field mistakes, engineering reasoning, exam traps. |
| `structure` | 構造 | **10–20 min** | Deepest. Physical principles, structural behavior, force transmission, design philosophy, why standards exist, calculation-mistake patterns. |

Rough script length guide (natural spoken Japanese ≈ 320–360 chars/min):
- 5 min ≈ 1,700 chars · 10 min ≈ 3,400 chars · 15 min ≈ 5,100 chars · 20 min ≈ 6,800 chars.

> Scripts above ~4,000 chars exceed OpenAI's per-request limit and are auto-chunked
> by the TTS pipeline (§4).

---

## 3. File & folder structure

```
StudyAudioApp/
├── assets/
│   ├── pdf/                         # SOURCE material (read-only input)
│   │   ├── 意匠/   (→ architecture, 12 PDFs)
│   │   ├── 施工/   (→ construction, 22 PDFs)
│   │   └── 構造/   (→ structure,    18 PDFs)
│   ├── text/                        # GENERATED scripts  assets/text/<category>/<topic>/<type>.txt
│   │   ├── architecture/<topic>/{deep,exam}.txt
│   │   ├── construction/<topic>/{deep,exam}.txt
│   │   └── structure/<topic>/{deep,exam}.txt
│   └── audio/                       # GENERATED mp3  assets/audio/<category>/<topic>/<type>.mp3
│       ├── architecture/<topic>/{deep,exam}.mp3
│       ├── construction/<topic>/{deep,exam}.mp3
│       └── structure/<topic>/{deep,exam}.mp3     # legacy typo "sturucture/" renamed in Phase 3
├── tools/
│   └── tts/
│       ├── generate_tts.py          # batch TTS generator (manual run)
│       ├── requirements.txt
│       ├── .env.example             # copy to .env, add OPENAI_API_KEY (gitignored)
│       └── README.md
├── lib/
│   └── main.dart                    # Flutter app (being refactored for background audio)
├── android/                         # Android host project (APK build target)
├── docs/
│   └── ARCHITECTURE.md              # this file
└── pubspec.yaml                     # asset manifest + dependencies
```

**Invariant:** `assets/text/<cat>/<topic>/<sec>.txt` and
`assets/audio/<cat>/<topic>/<sec>.mp3` mirror each other 1:1. The TTS pipeline and the
app both rely on this. Audio uses the correctly-spelled `structure/`; the legacy
`sturucture/` folder was renamed (files preserved) in Phase 3.

---

## 4. TTS pipeline design (`tools/tts/generate_tts.py`)

- **Input:** walks `assets/text/`. **Output:** mirrored `.mp3` under `assets/audio/`.
- **Key handling:** `OPENAI_API_KEY` read from `tools/tts/.env` (via `python-dotenv`).
  Never hardcoded, never committed (`.env` is gitignored). Missing key → clear error,
  except in `--dry-run` which needs no key.
- **Selection (incremental, never "all at once" by accident):**
  - `--file <name>`   one script, e.g. `--file architecture/urban_planning/core.txt`
    or just `--file 鉄筋工事` style matching is resolved against the text tree.
  - `--folder <cat>`  one category folder, e.g. `--folder construction`.
  - `--all`           every script (still processed sequentially, one request at a time).
- **Cost estimation FIRST:** before any API call, count characters across the selected
  scripts, multiply by the configured per-character price for the chosen model, print a
  per-file + total estimate, and **require an interactive confirmation** to proceed
  (`--yes` to skip the prompt for scripted runs).
- **`--dry-run`:** prints the cost estimate and the work plan, makes **zero** API calls.
- **Chunking:** OpenAI TTS caps input at 4096 chars/request. Long scripts are split on
  Japanese sentence boundaries (`。`/`\n`) into ≤4000-char chunks; each chunk is
  synthesized and the resulting MP3 chunks are concatenated into the final file.
- **Resume-safe:** existing `.mp3` outputs are skipped unless `--force`, so an
  interrupted run is cheap to resume.
- **Config (in `.env`):** model (`gpt-4o-mini-tts` default), voice, speed, and the
  price-per-1M-chars used for estimation (user verifies against current OpenAI pricing).
- **Dependencies:** `openai`, `python-dotenv` only. MP3 concatenation is done by byte
  append (works for same-codec chunks); `ffmpeg` is optional for gapless joins.

Example:
```
python generate_tts.py --dry-run --all                 # estimate everything, no calls
python generate_tts.py --file structure/rc_beam/core.txt
python generate_tts.py --folder construction
python generate_tts.py --all --yes
```

---

## 5. App audio-engine upgrade

The current app uses `audioplayers` and **fails three hard requirements**: background
playback when the screen is off, continued playback when minimized, and resume-position
after reopening. Plan:

- Migrate playback to **`just_audio`** + **`audio_service`** (or `just_audio_background`)
  for true background audio + lock-screen/notification controls on Android.
- Persist last position, track, scope, and study-mode via **`shared_preferences`**;
  restore on launch (resume).
- Keep the existing UI/UX and Cupertino styling — *no unnecessary UI changes* per the
  brief. Only the playback layer and persistence are rewritten.
- Update `AndroidManifest.xml` (foreground-service + media permissions) and `pubspec.yaml`.
- ✅ Fixed the `sturucture` → `structure` folder typo and removed the in-app workaround.
- Audio remains **bundled as assets** ("stored locally"). "Update library later" =
  rebuild + reinstall APK for now; a future option is downloadable content packs.

This phase happens **before** mass content regeneration so we test the engine against
the existing 12 topics first.

---

## 6. Work sequencing

1. ✅ **Design** — this document.
2. ⏳ **TTS pipeline** — build `tools/tts/` (no API calls, no key needed yet).
3. ⏳ **App engine upgrade** — background/lock-screen/resume, typo fix. Test on existing audio.
4. ⏳ **Content regeneration** — incremental, one topic at a time:
   - First, upgrade the 12 existing shallow topics to the deep hybrid model.
   - Then expand to the remaining 40 PDFs.
   - After each script batch, the user runs the TTS pipeline locally.
5. **APK build** — on the user's machine (Flutter is not installed in the dev
   environment here).

**Discipline:** scripts are written and reviewed one topic at a time. PDFs are never
bulk-summarized. Quality (exam mastery) is prioritized over speed.

---

## 7. PDF → topic-slug manifest

Source PDFs (Japanese) map to English topic slugs used by `text/`, `audio/`, and the
app. This table is filled in as topics are processed (slugs are provisional until then).

### architecture (意匠 / 計画) — 12 PDFs
| PDF | topic slug | status |
|-----|-----------|--------|
| 公共建築1 - 教育施設 | educational_facilities | exists (shallow → regenerate) |
| 公共建築2 - 高齢者・医療施設 | elderly_and_medical_facilities | exists (shallow → regenerate) |
| 公共建築3 - 図書館・競技場等 | library_museum_sports | exists (shallow → regenerate) |
| 都市計画 | urban_planning | exists (shallow → regenerate) |
| 各部計画1 寸法設計 | dimensional_design | pending |
| 各部計画2 高齢者対応 | barrier_free_design | pending |
| 各部計画3 窓、建具金具 | windows_and_fittings | pending |
| 各部計画4 窓ガラス、屋根 | glazing_and_roofing | pending |
| 商業建築1 事務所、劇場 | offices_and_theaters | pending |
| 商業建築2 物品販売店 | retail_facilities | pending |
| 日本建築史 | japanese_architecture_history | pending |
| 西洋、東洋建築史 | western_eastern_architecture_history | pending |

### construction (施工) — 22 PDFs
| PDF | topic slug | status |
|-----|-----------|--------|
| 仮説工事 (仮設工事) | temporary_work | exists (shallow → regenerate) |
| 土工事・山留め | earthwork_and_shoring | exists (shallow → regenerate) |
| 基礎・地業工事 | foundation_work | exists (shallow → regenerate) |
| 鉄骨工事3 現場施工 ↔ foundation_and_piling? | (review mapping) | exists — verify slug |
| 敷地・地盤調査 | site_and_ground_survey | pending |
| 鉄筋工事 | reinforcement_work | pending |
| 型枠工事 | formwork | pending |
| コンクリート工事1 調合、品質 | concrete_mix_and_quality | pending |
| コンクリート工事2 打込み | concrete_placing | pending |
| コンクリート工事3 各種コンクリート | special_concrete | pending |
| 鉄骨工事1 材料 | steelwork_materials | pending |
| 鉄骨工事2 高力ボルト | high_strength_bolts | pending |
| 鉄骨工事3 現場施工 | steelwork_site_erection | pending |
| PCa工事 | precast_concrete | pending |
| 防水工事 | waterproofing | pending |
| 左官、タイル | plastering_and_tiling | pending |
| 内外装工事 | interior_exterior_finishing | pending |
| ガラス、建具 | glass_and_fittings | pending |
| 木工事 | wood_work | pending |
| 設備工事 | building_services | pending |
| 改修工事1 耐震改修 | seismic_retrofit | pending |
| 改修工事2 各種工事 | renovation_work | pending |
| 用語 | terminology | pending |

### structure (構造) — 18 PDFs
| PDF | topic slug | status |
|-----|-----------|--------|
| 鉄骨構造1 - 鋼材の性質 | steel_material_properties | exists (shallow → regenerate) |
| 鉄骨構造2 - 座屈・変形 | buckling_and_beam_deflection | exists (shallow → regenerate) |
| 鉄骨構造3 - 接合部 | steel_connection | exists (shallow → regenerate) |
| 鉄骨構造4 - 柱脚・耐震設計 | column_base_and_seismic_design | exists (shallow → regenerate) |
| 鉄筋コンクリート1 梁 | rc_beam | pending |
| 鉄筋コンクリート2 柱 | rc_column | pending |
| 鉄筋コンクリート3 耐震壁 | rc_shear_wall | pending |
| 鉄筋コンクリート4 耐震設計 | rc_seismic_design | pending |
| 鉄筋コンクリート5 その他 | rc_other | pending |
| 鉄骨鉄筋コンクリート | src_structure | pending |
| コンクリート | concrete_material | pending |
| 金属材料 | metal_materials | pending |
| 木材 | timber_material | pending |
| 木構造 | timber_structure | pending |
| 地盤基礎1 地盤 | ground_and_soil | pending |
| 地盤基礎2 基礎構造設計 | foundation_structural_design | pending |
| その他構造 | other_structures | pending |

> The existing `construction` slugs `foundation_and_piling` and `foundation_work` need a
> quick reconciliation against their source PDFs during the content phase — flagged above.
