#!/usr/bin/env python3
"""Generate an .icns file from a 1024x1024 PNG source image."""
import subprocess, os, shutil
from pathlib import Path
from PIL import Image

src = Path("/home/ubuntu/dc_icon_1024.png")
iconset = Path("/home/ubuntu/DC.iconset")
iconset.mkdir(exist_ok=True)

sizes = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

img = Image.open(src).convert("RGBA")

for size, scale in sizes:
    px = size * scale
    resized = img.resize((px, px), Image.LANCZOS)
    if scale == 1:
        fname = f"icon_{size}x{size}.png"
    else:
        fname = f"icon_{size}x{size}@2x.png"
    resized.save(iconset / fname)
    print(f"  {fname} ({px}x{px})")

# Use iconutil to create the .icns (macOS only)
result = subprocess.run(
    ["iconutil", "-c", "icns", str(iconset), "-o", "/home/ubuntu/DC.icns"],
    capture_output=True, text=True
)
if result.returncode == 0:
    print("Created /home/ubuntu/DC.icns")
else:
    print("iconutil error:", result.stderr)
