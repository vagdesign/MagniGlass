#!/bin/sh
# Regenerates the app icons from the lens renderer (needs clang/cc and Python + Pillow).
#   win/MagniGlass/MagniGlass.ico  and  mac/AppIcon.png (1024 px, turned into .icns at build time)
set -eu
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/magniglass-icon"
mkdir -p "$T"
${CC:-cc} -O2 -o "$T/icon" tools/icon.c core/lenscore.c -lm
"$T/icon" "$T/icon.rgba" 560
python3 - "$T/icon.rgba" <<'PY'
import sys
from PIL import Image
data = open(sys.argv[1], "rb").read()
nl = data.index(b"\n")
n = int(data[:nl])
im = Image.frombytes("RGBA", (n, n), data[nl + 1:])
bbox = im.getbbox()
side = max(bbox[2] - bbox[0], bbox[3] - bbox[1])
cx, cy = (bbox[0] + bbox[2]) // 2, (bbox[1] + bbox[3]) // 2
pad = int(side * 0.04)
half = side // 2 + pad
sq = Image.new("RGBA", (2 * half, 2 * half))
sq.paste(im.crop((cx - half, cy - half, cx + half, cy + half)), (0, 0))
sq.resize((1024, 1024), Image.LANCZOS).save("mac/AppIcon.png")
sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
sq.resize((256, 256), Image.LANCZOS).save("win/MagniGlass/MagniGlass.ico", sizes=[(s, s) for s in sizes])
sq.resize((512, 512), Image.LANCZOS).save("docs/icon.png")
PY
echo "icons written"
