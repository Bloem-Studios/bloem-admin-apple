#!/usr/bin/env python3
"""Generates the Bloem Admin icon from the traced Bloem Studios tulip.

Source drawing: the tulip in reference-bloem-black.png (the Bloem Studios logo, tulip only, no wordmark or
tagline), traced by trace_tulip.py into tulip-trace.json (reference pixel coordinates). The paints below
(gradients sampled from the reference) are applied here.

Outputs (next to this file, or --out DIR):
  bloem-tulip-logo.svg / bloem-tulip-logo-mono.svg   the tulip alone, reference coordinates, transparent
  <app>-icon.svg        full icon: #141417 square + tulip + badge (108x108 units)
  <app>-foreground.svg  tulip + badge on transparent (the Android adaptive foreground)
  <app>-mono.svg        mono tulip + badge ring + glyph, white on transparent (themed / tinted)
  android/<app>/ic_launcher_{foreground,monochrome}.xml   the same two layers as VectorDrawables

Canvas: 108x108 units = the Android adaptive-icon canvas (1 unit = 1dp). The platform mask shows the central
72x72; the guaranteed safe zone is the 66-unit circle (radius 33) around (54, 54). For iOS, render the
central 72x72 (viewBox="18 18 72 72") to the full 1024 square.

The composition is offset on purpose (tulip left of centre, pixel cloud balancing it on the right); the whole
group is placed, the tulip itself is never re-centred. Glyph: Lucide server (ISC licence).

Usage: python3 generate.py [--out DIR] [--min-pixel PX]
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

BG = "#141417"
DISC = "#34343C"        # badge disc: lighter graphite than the plate
DISC_EDGE = "#5A5A64"   # hairline
GLYPH = "#F4F4F6"       # light grey glyph
WHITE = "#FFFFFF"

# ---- badge (108 unit canvas): ~31% of the icon width, glyph 60% of the disc -------------------------
BADGE_R = 15.0                      # 28% of the icon width
BADGE_C = (66.4, 66.4)              # |c| + R = 32.6, inside the 33 unit safe circle
GLYPH_FRAC = 0.60                   # glyph box / disc diameter
GLYPH_STROKE = 2.6                  # in Lucide units (24-box)
KNOCKOUT_GAP = 1.6                  # mono layer: clear space around the badge ring

# ---- tulip placement: scale (canvas units per reference px) and where the anchor lands -------------
# Filled in by fit_layout.py.
LAYOUT = {"scale": 0.0806, "anchor": (679.0, 439.0), "at": (49.0, 49.0)}
MIN_PIXEL = 15.0                    # icons drop dissolve pixels smaller than this many reference px (the 10 tiniest)


def n(v):
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return s if s not in ("-0", "") else "0"


def rrect(x, y, w, h, r):
    return (f"M{x + r} {y}H{x + w - r}A{r} {r} 0 0 1 {x + w} {y + r}V{y + h - r}"
            f"A{r} {r} 0 0 1 {x + w - r} {y + h}H{x + r}A{r} {r} 0 0 1 {x} {y + h - r}"
            f"V{y + r}A{r} {r} 0 0 1 {x + r} {y}Z")


def circle(cx, cy, r):
    """Counter-clockwise (sweep 0), so a rect + this circle makes a hole under the nonzero rule."""
    return f"M{n(cx - r)} {n(cy)}a{n(r)} {n(r)} 0 1 0 {n(2 * r)} 0a{n(r)} {n(r)} 0 1 0 {n(-2 * r)} 0z"


def box(x, y, w, h):
    return f"M{n(x)} {n(y)}h{n(w)}v{n(h)}h{n(-w)}z"


def P(d, fill=None, stroke=None, sw=None, cap="butt", join="round", evenodd=False):
    return {"d": d, "fill": fill, "stroke": stroke, "sw": sw, "cap": cap, "join": join, "evenodd": evenodd}


def G(els, tx=0.0, ty=0.0, s=1.0, clip=None):
    return {"tx": tx, "ty": ty, "s": s, "els": els, "clip": clip}


# ---- paints (reference pixel coordinates); sampled from reference-bloem-black.png --------------------
def linear(y1, y2, stops, x1=0.0, x2=0.0):
    return {"kind": "linear", "x1": x1, "y1": y1, "x2": x2, "y2": y2, "stops": stops}


def radial(cx, cy, r, stops):
    return {"kind": "radial", "cx": cx, "cy": cy, "r": r, "stops": stops}


def vstops(y1, y2, table):
    return [((y - y1) / (y2 - y1), c, 1.0) for y, c in table]


LOWER = [(545, "#FDFDFD"), (576, "#ECECEC"), (604, "#D3D2D3"), (636, "#AFAEAE"), (668, "#8D8C8D"), (694, "#7E7D7E")]
MAIN_Y = [(218, "#FC8313"), (300, "#FD8123"), (325, "#FD9344"), (350, "#FEA460"), (375, "#FDB683"),
          (400, "#FECFB3"), (425, "#FEEBE2"), (450, "#FEFDFD")] + LOWER
ARC_Y = [(402, "#FA9A60"), (414, "#FDA372"), (426, "#FEB38B"), (438, "#FEC4A6"), (455, "#FDDCCB"),
         (470, "#FDEEE9"), (485, "#FEFAF9"), (495, "#FEFEFE")]
RED_HOT = "#F8301F"
PAINTS = {
    1: [linear(182, 263, vstops(182, 263, [(182, "#FD900B"), (215, "#FD8610"), (263, "#FC7211")]))],
    2: [linear(218, 694, vstops(218, 694, MAIN_Y)),
        radial(466, 345, 120, [(0, RED_HOT, .92), (.17, RED_HOT, .87), (.33, RED_HOT, .70), (.5, RED_HOT, .48),
                               (.67, RED_HOT, .26), (.83, RED_HOT, .12), (1, RED_HOT, 0)]),
        radial(508, 268, 70, [(0, "#F83A1E", .55), (1, "#F83A1E", 0)]),
        linear(0, 0, [(0, "#FFB566", 0), (1, "#FFB566", .62)], x1=650, x2=705)],
    17: [linear(402, 495, vstops(402, 495, ARC_Y))],
    24: [linear(476, 694, vstops(476, 694, [(476, "#FDFDFD")] + LOWER))],
}
EVEN_ODD = {2, 17, 24, 1}


def tulip_els(mono=False, min_pixel=None):
    min_pixel = MIN_PIXEL if min_pixel is None else min_pixel
    t = json.load(open(f"{HERE}/tulip-trace.json"))
    els = []
    for p in t["paths"]:
        if mono:
            els.append(P(p["d"], fill=WHITE, evenodd=True))
        else:
            for paint in PAINTS[p["id"]]:
                els.append(P(p["d"], fill=paint, evenodd=True))
    for px in t["pixels"]:
        if max(px["w"], px["h"]) < min_pixel:
            continue
        col = WHITE if mono else "#%02X%02X%02X" % tuple(px["rgb"])
        els.append(P(box(px["x"], px["y"], px["w"], px["h"]), fill=col))
    return els


def tulip_group(mono=False, clip=None):
    s = LAYOUT["scale"]
    tx = LAYOUT["at"][0] - LAYOUT["anchor"][0] * s
    ty = LAYOUT["at"][1] - LAYOUT["anchor"][1] * s
    return G(tulip_els(mono), tx, ty, s, clip=clip)


# Lucide glyph, 24x24 box, stroke only (lucide-react 0.576.0 icon nodes).
GLYPHS = {
    "server": [rrect(2, 2, 20, 8, 2), rrect(2, 14, 20, 8, 2), "M6 6L6.01 6", "M6 18L6.01 18"],
}
APPS = {
    "admin": {"glyph": "server", "label": "Bloem Admin"},
}


def glyph_group(name, colour):
    s = 2 * BADGE_R * GLYPH_FRAC / 24.0
    els = [P(d, stroke=colour, sw=GLYPH_STROKE, cap="round", join="round") for d in GLYPHS[name]]
    return G(els, BADGE_C[0] - 12 * s, BADGE_C[1] - 12 * s, s)


def badge_colour(name):
    ring = P(circle(*BADGE_C, BADGE_R + KNOCKOUT_GAP), fill=BG)      # cuts the leaf cleanly around the badge
    disc = P(circle(*BADGE_C, BADGE_R), fill=DISC, stroke=DISC_EDGE, sw=0.7)
    return [G([ring, disc]), glyph_group(name, GLYPH)]


def badge_mono(name):
    ring = P(circle(*BADGE_C, BADGE_R - 0.6), stroke=WHITE, sw=1.2)
    return [G([ring]), glyph_group(name, WHITE)]


def knockout_clip():
    """Whole canvas minus a disc around the badge: opposite windings, nonzero rule -> a hole."""
    return "M0 0H108V108H0Z" + circle(*BADGE_C, BADGE_R + KNOCKOUT_GAP)


def foreground(name):
    return [tulip_group()] + badge_colour(name)


def mono(name):
    return [tulip_group(mono=True, clip=knockout_clip())] + badge_mono(name)


# ---- emitters -------------------------------------------------------------------------------------
class Defs:
    def __init__(self):
        self.items, self.count = [], 0

    def paint(self, p):
        self.count += 1
        gid = f"g{self.count}"
        if p["kind"] == "linear":
            head = (f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{n(p["x1"])}" y1="{n(p["y1"])}" '
                    f'x2="{n(p["x2"])}" y2="{n(p["y2"])}">')
            tail = "</linearGradient>"
        else:
            head = (f'<radialGradient id="{gid}" gradientUnits="userSpaceOnUse" cx="{n(p["cx"])}" cy="{n(p["cy"])}" '
                    f'r="{n(p["r"])}">')
            tail = "</radialGradient>"
        stops = "".join(f'<stop offset="{n(o)}" stop-color="{c}"' + (f' stop-opacity="{n(a)}"' if a < 1 else "") + "/>"
                        for o, c, a in p["stops"])
        self.items.append(head + stops + tail)
        return f"url(#{gid})"


def svg_path(p, defs=None):
    fill = p["fill"]
    if isinstance(fill, dict):
        fill = defs.paint(fill)
    a = [f'd="{p["d"]}"', f'fill="{fill}"' if fill else 'fill="none"']
    if p["evenodd"]:
        a.append('fill-rule="evenodd"')
    if p["stroke"]:
        a += [f'stroke="{p["stroke"]}"', f'stroke-width="{n(p["sw"])}"',
              f'stroke-linecap="{p["cap"]}"', f'stroke-linejoin="{p["join"]}"']
    return "<path " + " ".join(a) + "/>"


def svg_groups(groups, defs, indent="  "):
    out = []
    for i, g in enumerate(groups):
        if g["clip"]:
            defs.items.append(f'<clipPath id="knockout{i}"><path d="{g["clip"]}" clip-rule="nonzero"/></clipPath>')
            out.append(f'{indent}<g clip-path="url(#knockout{i})">')
        out.append(f'{indent}<g transform="translate({n(g["tx"])} {n(g["ty"])}) scale({n(g["s"])})">')
        out += [f"{indent}  {svg_path(p, defs)}" for p in g["els"]]
        out.append(f"{indent}</g>")
        if g["clip"]:
            out.append(f"{indent}</g>")
    return "\n".join(out)


def svg_doc(groups, title, background=None):
    defs = Defs()
    body = svg_groups(groups, defs)
    bg = f'  <rect width="108" height="108" fill="{background}"/>\n' if background else ""
    d = "  <defs>" + "".join(defs.items) + "</defs>\n" if defs.items else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" width="108" height="108" '
            f'role="img" aria-label="{title}">\n{d}{bg}{body}\n</svg>\n')


def tulip_svg(mono=False, view=(372, 162, 615, 552), bg=None, size=None):
    defs = Defs()
    body = "\n".join("  " + svg_path(p, defs) for p in tulip_els(mono, min_pixel=0))
    w, h = (size, size * view[3] / view[2]) if size else (view[2], view[3])
    back = f'  <rect x="{view[0]}" y="{view[1]}" width="{view[2]}" height="{view[3]}" fill="{bg}"/>\n' if bg else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view[0]} {view[1]} {view[2]} {view[3]}" '
            f'width="{n(w)}" height="{n(h)}" role="img" aria-label="Bloem tulip">\n'
            f'  <defs>{"".join(defs.items)}</defs>\n{back}{body}\n</svg>\n')


def argb(hexcol, alpha=1.0):
    return "#%02X%s" % (round(alpha * 255), hexcol.lstrip("#").upper())


def vd_gradient(p, indent):
    if p["kind"] == "linear":
        head = (f'{indent}<gradient android:type="linear" android:startX="{n(p["x1"])}" android:startY="{n(p["y1"])}" '
                f'android:endX="{n(p["x2"])}" android:endY="{n(p["y2"])}">')
    else:
        head = (f'{indent}<gradient android:type="radial" android:centerX="{n(p["cx"])}" '
                f'android:centerY="{n(p["cy"])}" android:gradientRadius="{n(p["r"])}">')
    items = [f'{indent}    <item android:offset="{n(o)}" android:color="{argb(c, a)}" />' for o, c, a in p["stops"]]
    return "\n".join([head] + items + [f"{indent}</gradient>"])


def vd_path(p, indent):
    a = [f'android:pathData="{p["d"]}"']
    grad = p["fill"] if isinstance(p["fill"], dict) else None
    if p["fill"] and not grad:
        a.insert(0, f'android:fillColor="{argb(p["fill"])}"')
    if p["evenodd"]:
        a.append('android:fillType="evenOdd"')
    if p["stroke"]:
        a.insert(0, f'android:strokeColor="{argb(p["stroke"])}"')
        a += [f'android:strokeWidth="{n(p["sw"])}"', f'android:strokeLineCap="{p["cap"]}"',
              f'android:strokeLineJoin="{p["join"]}"']
    pad = indent + "    "
    head = f"{indent}<path\n" + "\n".join(pad + x for x in a)
    if grad:
        return (head + ">\n" + f'{indent}    <aapt:attr name="android:fillColor">\n' + vd_gradient(grad, indent + "        ")
                + f"\n{indent}    </aapt:attr>\n{indent}</path>")
    return head + " />"


def vd_doc(groups, comment):
    out = ['<?xml version="1.0" encoding="utf-8"?>', f"<!-- {comment} -->",
           '<vector xmlns:android="http://schemas.android.com/apk/res/android"',
           '    xmlns:aapt="http://schemas.android.com/aapt"',
           '    android:width="108dp"', '    android:height="108dp"',
           '    android:viewportWidth="108"', '    android:viewportHeight="108">']
    for g in groups:
        ind = "    "
        if g["clip"]:
            out.append(f"{ind}<group>")
            out.append(f'{ind}    <clip-path android:pathData="{g["clip"]}" />')
            ind += "    "
        if g["tx"] == 0 and g["ty"] == 0 and g["s"] == 1:
            out += [vd_path(p, ind) for p in g["els"]]
        else:
            out.append(f'{ind}<group android:translateX="{n(g["tx"])}" android:translateY="{n(g["ty"])}" '
                       f'android:scaleX="{n(g["s"])}" android:scaleY="{n(g["s"])}">')
            out += [vd_path(p, ind + "    ") for p in g["els"]]
            out.append(f"{ind}</group>")
        if g["clip"]:
            out.append("    </group>")
    out.append("</vector>")
    return "\n".join(out) + "\n"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def main(argv=None):
    global MIN_PIXEL
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=HERE)
    ap.add_argument("--min-pixel", type=float, default=MIN_PIXEL)
    a = ap.parse_args(argv)
    MIN_PIXEL = a.min_pixel
    write(f"{a.out}/bloem-tulip-logo.svg", tulip_svg())
    write(f"{a.out}/bloem-tulip-logo-mono.svg", tulip_svg(mono=True))
    for app, cfg in APPS.items():
        g = cfg["glyph"]
        fg, mo = foreground(g), mono(g)
        write(f"{a.out}/{app}-icon.svg", svg_doc(fg, f"{cfg['label']} icon", background=BG))
        write(f"{a.out}/{app}-foreground.svg", svg_doc(fg, f"{cfg['label']} icon foreground"))
        write(f"{a.out}/{app}-mono.svg", svg_doc(mo, f"{cfg['label']} icon, one colour"))
        note = (f"Bloem Studios tulip (traced from the logo) plus a Lucide {g} badge (ISC licence). "
                f"Generated by docs/design/app-icons/generate.py; edit that, not this file.")
        write(f"{a.out}/android/{app}/ic_launcher_foreground.xml", vd_doc(fg, note))
        write(f"{a.out}/android/{app}/ic_launcher_monochrome.xml",
              vd_doc(mo, "One-colour layer for Android 13+ themed icons, badge knocked out of the tulip: " + note))
    print("ok", a.out)


if __name__ == "__main__":
    sys.exit(main())
