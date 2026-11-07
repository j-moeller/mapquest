"""Renders the MapQuest app icon (1024x1024 PNG): a dark fog with a revealed,
map-like clearing around a position marker. Usage: python3 make_app_icon.py OUT.png"""
import math
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
S = 4  # supersampling factor


def main(out_path: str) -> None:
    w = SIZE * S
    base = Image.new("RGB", (w, w), (226, 221, 208))  # map paper
    d = ImageDraw.Draw(base)
    # Blocks and streets
    for i in range(-2, 12):
        x = int(i * w / 9 + w * 0.03)
        d.line([(x, 0), (x + w * 0.12, w)], fill=(250, 248, 242), width=int(w * 0.022))
    for j in range(-2, 12):
        y = int(j * w / 8)
        d.line([(0, y), (w, y - w * 0.08)], fill=(250, 248, 242), width=int(w * 0.03))
    # A river and a park
    river = [(0, w * 0.70), (w * 0.3, w * 0.62), (w * 0.55, w * 0.72), (w, w * 0.58)]
    d.line(river, fill=(120, 175, 220), width=int(w * 0.06), joint="curve")
    d.ellipse([w * 0.58, w * 0.18, w * 0.80, w * 0.36], fill=(150, 200, 130))

    # Fog: dark overlay with a soft-edged clearing (two overlapping circles = a walked path).
    fog_alpha = Image.new("L", (w, w), 215)
    fd = ImageDraw.Draw(fog_alpha)
    for cx, cy, r in [(0.42, 0.52, 0.27), (0.62, 0.40, 0.20), (0.30, 0.66, 0.15)]:
        fd.ellipse([w * (cx - r), w * (cy - r), w * (cx + r), w * (cy + r)], fill=0)
    fog_alpha = fog_alpha.filter(ImageFilter.GaussianBlur(w * 0.012))
    fog = Image.new("RGB", (w, w), (18, 24, 42))
    base = Image.composite(fog, base, fog_alpha)

    # Position marker
    d = ImageDraw.Draw(base)
    cx, cy, r = w * 0.45, w * 0.50, w * 0.075
    d.ellipse([cx - r * 1.35, cy - r * 1.35, cx + r * 1.35, cy + r * 1.35], fill=(255, 255, 255))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(245, 153, 46))
    tip = [(cx, cy - r * 3.2), (cx - r * 0.9, cy - r * 1.1), (cx + r * 0.9, cy - r * 1.1)]
    d.polygon(tip, fill=(245, 153, 46))

    base.resize((SIZE, SIZE), Image.LANCZOS).save(out_path, "PNG", optimize=True)


if __name__ == "__main__":
    main(sys.argv[1])
