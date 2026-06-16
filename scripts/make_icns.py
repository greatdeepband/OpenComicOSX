#!/usr/bin/env python3
"""Generate AppBundle/DC.icns from AppBundle/dc_icon_1024.png.

One-shot icon-refresh tool. Reads the 1024×1024 PNG source committed at
AppBundle/dc_icon_1024.png, produces a complete .iconset under
AppBundle/DC.iconset/, then runs `iconutil -c icns` to assemble the final
AppBundle/DC.icns that ./build_app.sh copies into Open Comic.app/Contents/Resources/.

Run from the repo root:
    python3 scripts/make_icns.py

Requires Pillow (`pip install Pillow` or `pip3 install Pillow`).
"""
import subprocess
from pathlib import Path
from PIL import Image

# Resolve paths relative to the repo root so the script works from any clone.
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
APP_BUNDLE = REPO_ROOT / "AppBundle"

SRC = APP_BUNDLE / "dc_icon_1024.png"
ICONSET = APP_BUNDLE / "DC.iconset"
OUT_ICNS = APP_BUNDLE / "DC.icns"

if not SRC.exists():
    raise SystemExit(f"Source image not found: {SRC}")

ICONSET.mkdir(exist_ok=True)

sizes = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

img = Image.open(SRC).convert("RGBA")

for size, scale in sizes:
    px = size * scale
    resized = img.resize((px, px), Image.LANCZOS)
    suffix = f"@{scale}x" if scale != 1 else ""
    fname = f"icon_{size}x{size}{suffix}.png"
    resized.save(ICONSET / fname)
    print(f"  {fname} ({px}x{px})")

result = subprocess.run(
    ["iconutil", "-c", "icns", str(ICONSET), "-o", str(OUT_ICNS)],
    capture_output=True, text=True
)
if result.returncode == 0:
    print(f"Created {OUT_ICNS}")
else:
    print("iconutil error:", result.stderr)
    raise SystemExit(result.returncode)
