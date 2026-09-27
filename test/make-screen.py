"""Writes a stand-in 'screen' (window, text, colour chart) as PPM for the preview renders."""
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 720
im = Image.new("RGB", (W, H), (36, 40, 48))
d = ImageDraw.Draw(im)
for y in range(H):  # desktop gradient
    d.line([(0, y), (W, y)], fill=(30 + y * 40 // H, 60 + y * 50 // H, 110 + y * 40 // H))
d.rounded_rectangle([60, 50, 1220, 680], 14, fill=(250, 250, 247))
d.rectangle([60, 50, 1220, 92], fill=(232, 232, 236))
for i, c in enumerate([(237, 106, 94), (245, 191, 79), (98, 197, 84)]):
    d.ellipse([80 + i * 26, 64, 96 + i * 26, 80], fill=c)
try:
    font = ImageFont.truetype("DejaVuSans.ttf", 18)
    small = ImageFont.truetype("DejaVuSans.ttf", 13)
    big = ImageFont.truetype("DejaVuSans-Bold.ttf", 34)
except OSError:
    font = small = big = ImageFont.load_default()
d.text((100, 120), "The quick brown fox jumps over the lazy dog", font=big, fill=(30, 30, 36))
text = ("MagniGlass follows your pointer with a real lens: fine print, icons and pixels come up large and "
        "sharp, the edge of the glass bends the page like a real magnifier and the chrome catches the light.")
words, line, y = text.split(), "", 190
for w in words:
    if d.textlength(line + " " + w, font=font) > 640:
        d.text((100, y), line.strip(), font=font, fill=(70, 70, 78)); y += 28; line = ""
    line += " " + w
d.text((100, y), line.strip(), font=font, fill=(70, 70, 78))
for i in range(14):
    d.text((100, 330 + i * 22), f"{i + 1:02d}  ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789 {{}}[]()<>", font=small, fill=(90, 90, 100))
colors = [(230, 57, 70), (244, 162, 97), (233, 196, 106), (42, 157, 143), (38, 70, 83), (69, 123, 157)]
for i, c in enumerate(colors):
    h = 80 + (i * 53) % 190
    d.rectangle([800 + i * 60, 620 - h, 846 + i * 60, 620], fill=c)
d.ellipse([860, 130, 1120, 390], outline=(40, 40, 40), width=6)
for a in range(12):
    import math
    x, y = 990 + 110 * math.sin(a * math.pi / 6), 260 - 110 * math.cos(a * math.pi / 6)
    d.ellipse([x - 5, y - 5, x + 5, y + 5], fill=(40, 40, 40))
im.save(sys.argv[1])
