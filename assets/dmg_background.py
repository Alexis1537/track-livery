#!/usr/bin/env python3
"""Generates the DMG background image (1280x840, 2x of a 640x420 window).

Usage: python3 assets/dmg_background.py <output.png>
Reads assets/icon_1024.png for the app icon shown on the left.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 1280, 840
NIGHT_VIOLET = (29, 16, 93)
DEEP_VIOLET = (66, 55, 198)

FONT_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FONT_REG = "/System/Library/Fonts/Supplemental/Arial.ttf"


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def main(out_path):
    img = Image.new("RGB", (W, H))
    for y in range(H):
        img.putpixel((0, y), lerp(NIGHT_VIOLET, DEEP_VIOLET, y / (H - 1)))
    # the loop above is slow at 1280x840; do it properly with a 1px column
    col = Image.new("RGB", (1, H))
    for y in range(H):
        col.putpixel((0, y), lerp(NIGHT_VIOLET, DEEP_VIOLET, y / (H - 1)))
    img = col.resize((W, H))

    d = ImageDraw.Draw(img)

    icon = Image.open(os.path.join(HERE, "icon_1024.png")).resize((300, 300), Image.LANCZOS)
    img.paste(icon, (150, 270), icon.convert("RGBA"))

    title_font = ImageFont.truetype(FONT_BOLD, 96)
    sub_font = ImageFont.truetype(FONT_REG, 44)
    d.text((520, 300), "Track Livery", font=title_font, fill=(248, 246, 245))
    d.text((524, 430), "Drag the app into your", font=sub_font, fill=(232, 219, 224))
    d.text((524, 490), "Applications folder", font=sub_font, fill=(232, 219, 224))

    img.save(out_path)
    print("wrote", out_path)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "dmg_background.png"))
