#!/usr/bin/env python3
"""Render a (possibly huge, scanned) PDF to compressed per-page JPEGs.

Used to read source PDFs that exceed the 20MB inline-read limit. Output goes to
a gitignored folder so it is never committed.

Usage:
  python render_pages.py "assets/pdf/施工/鉄筋工事.pdf"
  python render_pages.py "<pdf>" --width 1600 --quality 80
"""
import argparse
import sys
import unicodedata
from pathlib import Path

import fitz  # PyMuPDF

# Windows consoles default to cp932 and choke on the Japanese filenames we print.
# Force UTF-8 and never let a print() crash the render.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

REPO = Path(__file__).resolve().parent.parent.parent
OUT_ROOT = REPO / "build" / "pdf_pages"  # build/ is gitignored


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--width", type=int, default=1600, help="target px width")
    ap.add_argument("--quality", type=int, default=80, help="JPEG quality")
    args = ap.parse_args()

    pdf_path = Path(args.pdf)
    if not pdf_path.is_absolute():
        pdf_path = REPO / pdf_path
    if not pdf_path.exists():
        # macOS-created filenames are often NFD; the typed arg is usually NFC (or vice versa).
        # Fall back to matching the directory listing by normalized name.
        target = unicodedata.normalize("NFC", pdf_path.name)
        match = next(
            (p for p in pdf_path.parent.glob("*") if unicodedata.normalize("NFC", p.name) == target),
            None,
        )
        if match is None:
            sys.exit(f"Not found: {pdf_path}")
        pdf_path = match

    out_dir = OUT_ROOT / pdf_path.stem
    out_dir.mkdir(parents=True, exist_ok=True)

    doc = fitz.open(pdf_path)
    print(f"{pdf_path.name}: {doc.page_count} page(s) -> {out_dir}")
    for i, page in enumerate(doc, 1):
        zoom = max(0.5, args.width / page.rect.width)
        pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom))
        out = out_dir / f"page_{i:02d}.jpg"
        pix.pil_save(out, format="JPEG", quality=args.quality, optimize=True)
        kb = out.stat().st_size / 1024
        print(f"  page {i:02d}: {pix.width}x{pix.height}  {kb:.0f} KB  {out}")
    doc.close()


if __name__ == "__main__":
    main()
