#!/usr/bin/env python3
"""Overlay comparison of the redrawn tulip (bloem-tulip-logo.svg) against the reference crop.
Writes tulip-overlay-comparison.png: reference | redraw / difference (x3) | 50% blend.
Needs chromium (headless), numpy and Pillow. Usage: python3 compare_tulip.py"""
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import generate as g  # noqa: E402

BOX = (370, 160, 990, 710)


def render_svg(svg, size):
    d = tempfile.mkdtemp()
    sp, hp, op = f"{d}/t.svg", f"{d}/t.html", f"{d}/t.png"
    open(sp, "w").write(svg)
    open(hp, "w").write(f'<html><body style="margin:0;background:#000"><img src="{sp}" style="display:block"></body></html>')
    subprocess.run(["chromium", "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
                    "--default-background-color=000000ff", f"--window-size={size},{size}", f"--screenshot={op}",
                    f"file://{hp}"], capture_output=True, timeout=120)
    return Image.open(op).convert("RGB")


def main():
    ref = Image.open(f"{HERE}/reference-bloem-black.png").convert("RGB")
    mine = render_svg(g.tulip_svg(view=(0, 0, 1254, 1254), bg="#000000", size=1254), 1254)
    a = np.array(ref.crop(BOX)).astype(float)
    b = np.array(mine.crop(BOX)).astype(float)
    diff = np.clip(np.abs(a - b) * 3, 0, 255).astype(np.uint8)
    blend = ((a + b) / 2).astype(np.uint8)
    w, h = BOX[2] - BOX[0], BOX[3] - BOX[1]
    sheet = Image.new("RGB", (2 * w + 30, 2 * h + 70), (24, 24, 28))
    dr = ImageDraw.Draw(sheet)
    panels = [("reference (Bloem Black.png, tulip only)", ref.crop(BOX)), ("redraw (bloem-tulip-logo.svg)", mine.crop(BOX)),
              ("difference x3", Image.fromarray(diff)), ("50% blend", Image.fromarray(blend))]
    for i, (label, im) in enumerate(panels):
        x, y = 10 + (i % 2) * (w + 10), 20 + (i // 2) * (h + 30)
        dr.text((x, y - 14), label, fill=(200, 200, 205))
        sheet.paste(im, (x, y))
    sheet.save(f"{HERE}/tulip-overlay-comparison.png")
    inside = (a.max(axis=2) > 70) | (b.max(axis=2) > 70)
    print("mean abs difference over the tulip (0-255):", round(float(np.abs(a - b)[inside].mean()), 2),
          "| over the whole crop:", round(float(np.abs(a - b).mean()), 2))


if __name__ == "__main__":
    main()
