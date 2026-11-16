#!/usr/bin/env python3
"""Finds the largest placement of the traced tulip group (tulip + pixel cloud) for generate.py's LAYOUT:
  - all ink inside the safe circle (radius SAFE_R around 54,54);
  - the badge (and its knock-out ring) covers the right leaf only, never the stem, petals, bud or left leaf,
    and touches no dissolve pixel.
The group is placed as a whole (the composition's left-of-centre offset is kept).

Needs chromium (headless), numpy and Pillow. Usage: python3 fit_layout.py [--min-pixel 14]
"""
import argparse
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import generate as g  # noqa: E402

SAFE_R = 32.6
MAX_REST_OVERLAP = 0.01   # the badge may cover the right leaf only
RING = 1.6                # knock-out ring around the badge
ANCHOR = (679.5, 438.0)     # centre of the group's bounding box (reference px), set in main()


def ink(min_pixel):
    """(rest of the tulip, right leaf, pixels) as ink points in reference px, from a render of the traced shapes."""
    g.MIN_PIXEL = min_pixel
    els = g.tulip_els(mono=True)
    # trace order: bud, main piece (stem, petals, left leaf), right petal arc, right leaf; then the boxes
    outlines = [e for e in els if e["d"].count("C") + e["d"].count("L") > 3]
    boxes = [e for e in els if e not in outlines]
    groups = [outlines[:3], outlines[3:], boxes]
    out = []
    for group in groups:
        svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1254 1254" width="1254" height="1254">'
               + "".join(g.svg_path(e) for e in group).replace("#FFFFFF", "#000") + "</svg>")
        d = tempfile.mkdtemp()
        sp, hp, op = f"{d}/m.svg", f"{d}/m.html", f"{d}/m.png"
        open(sp, "w").write(svg)
        open(hp, "w").write(f'<html><body style="margin:0"><img src="{sp}" style="display:block"></body></html>')
        subprocess.run(["chromium", "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
                        "--default-background-color=00000000", "--window-size=1254,1254", f"--screenshot={op}",
                        f"file://{hp}"], capture_output=True, timeout=120)
        a = np.array(Image.open(op).convert("RGBA"))[:, :, 3] > 40
        ys, xs = np.nonzero(a)
        out.append(np.stack([xs + .5, ys + .5], 1))
    return out


def badge_at(theta_deg):
    """Badge centre on the line from the canvas centre at this angle (0 = right, 90 = down), flush to the safe circle."""
    d = SAFE_R - g.BADGE_R
    t = np.radians(theta_deg)
    return (54 + d * np.cos(t), 54 + d * np.sin(t))


def check(rest, leaf, px, s, at, bc):
    allp = np.vstack([rest, leaf, px])
    pos = (allp - ANCHOR) * s + np.array(at)
    r = np.hypot(pos[:, 0] - 54, pos[:, 1] - 54)
    bd = np.hypot(pos[:, 0] - bc[0], pos[:, 1] - bc[1])
    n1, n2 = len(rest), len(rest) + len(leaf)
    # the badge (with its knock-out ring) may cover the right leaf only; keep clear of the pixels by 1.2 units
    rest_ov = float((bd[:n1] < g.BADGE_R + RING).mean())
    px_hit = bool((bd[n2:] < g.BADGE_R + RING + 1.2).any()) if len(px) else False
    leaf_ov = float((bd[n1:n2] < g.BADGE_R).mean())
    return r.max(), rest_ov, leaf_ov, px_hit, pos


def main():
    global ANCHOR
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-pixel", type=float, default=15.0)
    ap.add_argument("--badge-r", type=float, default=g.BADGE_R)
    ap.add_argument("--leaf-cap", type=float, default=0.35, help="max share of the right leaf the badge may cover")
    a = ap.parse_args()
    g.BADGE_R = a.badge_r
    rest, leaf, px = ink(a.min_pixel)
    allp = np.vstack([rest, leaf, px])
    anchor = ((allp[:, 0].min() + allp[:, 0].max()) / 2, (allp[:, 1].min() + allp[:, 1].max()) / 2)
    ANCHOR = anchor
    full = (rest, leaf, px)
    rest, leaf, px = rest[::7], leaf[::7], px[::3]          # coarse search on subsampled ink
    best = None
    for theta in range(20, 81, 5):
        bc = badge_at(theta)
        for ax in np.arange(44, 62.1, 1.0):
            for ay in np.arange(42, 62.1, 1.0):
                lo, hi = 0.03, 0.2
                for _ in range(16):
                    mid = (lo + hi) / 2
                    rmax, rov, lov, hit, _ = check(rest, leaf, px, mid, (ax, ay), bc)
                    if rmax <= SAFE_R and rov <= MAX_REST_OVERLAP and lov <= a.leaf_cap and not hit:
                        lo = mid
                    else:
                        hi = mid
                if best is None or lo > best[0]:
                    best = (lo, (ax, ay), theta)
    s, at, theta = best
    bc = badge_at(theta)
    rmax, rov, lov, hit, pos = check(*full, s, at, bc)
    w = pos[:, 0].max() - pos[:, 0].min()
    h = pos[:, 1].max() - pos[:, 1].min()
    print(f'LAYOUT = {{"scale": {s:.4f}, "anchor": ({anchor[0]:.1f}, {anchor[1]:.1f}), "at": ({at[0]:.1f}, {at[1]:.1f})}}')
    print(f"BADGE_R = {g.BADGE_R}  BADGE_C = ({bc[0]:.1f}, {bc[1]:.1f})  (angle {theta})")
    print(f"max r {rmax:.2f}  badge over rest {rov * 100:.1f}%  over right leaf {lov * 100:.0f}%  pixel clash {hit}  "
          f"group {w:.1f} x {h:.1f} units = {w / 108 * 100:.0f}% x {h / 108 * 100:.0f}% of the icon; "
          f"x {pos[:, 0].min():.1f}..{pos[:, 0].max():.1f} y {pos[:, 1].min():.1f}..{pos[:, 1].max():.1f}")


if __name__ == "__main__":
    main()
