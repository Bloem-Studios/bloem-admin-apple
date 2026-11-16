#!/usr/bin/env python3
"""Writes the theme color sets in BloemAdmin/Assets.xcassets and checks their contrast.

The palette lives here, once: each token has a value for Light, Dark, Light + increased contrast and
Dark + increased contrast. Run `python3 -I scripts/theme-colors.py` to rewrite the sets, and
`python3 -I scripts/theme-colors.py --check` to only measure (exit 1 if a pair is under its minimum).

Neutrals are the web admin's graphite (web app.css 508-571: bg #141417, card #1C1C20, raised and border
#28282E, fg #E8E8EC, muted #A4A4AE) for Dark, and a matching light graphite for Light. Bloem orange
#FA6400 is the only accent; Light uses a darker orange so orange text, and white text on an orange
fill, both reach 4.5:1.
"""
import json
import os
import sys

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "BloemAdmin", "Assets.xcassets")

# name: (light, dark, light-high-contrast, dark-high-contrast); a value is "#RRGGBB" or ("#RRGGBB", alpha)
TOKENS = {
    "BloemBackground": ("#F6F6F8", "#141417", "#FFFFFF", "#000000"),
    "BloemSidebar": ("#EEEEF2", "#0F0F12", "#F2F2F6", "#000000"),
    "BloemSurface": ("#FFFFFF", "#1C1C20", "#FFFFFF", "#101012"),
    "BloemRaised": ("#E9E9EE", "#28282E", "#F2F2F6", "#1E1E23"),
    "BloemSelected": ("#DDDDE1", "#202023", "#D4D4DA", "#26262B"),
    "BloemText": ("#1A1A1F", "#E8E8EC", "#000000", "#FFFFFF"),
    "BloemTextMuted": ("#5A5A65", "#A4A4AE", "#3A3A42", "#D2D2DA"),
    "BloemOutline": ("#85858F", "#787882", "#4A4A52", "#A4A4AE"),
    "BloemHairline": (("#1A1A1F", 0.12), ("#E8E8EC", 0.10), ("#000000", 0.40), ("#FFFFFF", 0.40)),
    "AccentColor": ("#A04000", "#FA6400", "#7A3000", "#FF8A3D"),
    "BloemTally": ("#E85D00", "#FA6400", "#C24E00", "#FF8A3D"),
    "BloemOnAccent": ("#FFFFFF", "#141417", "#FFFFFF", "#000000"),
    "BloemOK": ("#1A6A2B", "#57CB60", "#0D5226", "#7FE08A"),
    "BloemWarn": ("#7F4E00", "#EAB532", "#5E3A00", "#FFD35C"),
    "BloemDanger": ("#B42626", "#F46666", "#921810", "#FF8F8F"),
    # The web's chart tokens (web app.css 549), in the order both apps draw them. Fills, lines and dots, never text.
    "BloemChartDirectPlay": ("#5F74EE", "#5F74EE", "#4659D6", "#8A9BFF"),
    "BloemChartDirectStream": ("#169E88", "#169E88", "#0F7D6B", "#3CC8B0"),
    "BloemChartTranscode": ("#BF7F22", "#BF7F22", "#9A6212", "#E0A04A"),
    "BloemChart4": ("#C2578F", "#C2578F", "#A03F72", "#E27BB1"),
    "BloemChart5": ("#3F97CF", "#3F97CF", "#2478AF", "#6BB5E4"),
}

# (foreground, background) pairs each appearance must keep: minimum ratio normal, increased contrast.
SURFACES = ["BloemBackground", "BloemSurface", "BloemRaised"]
# The selected menu row only carries the page name and an accent icon: text and accent must hold on it.
SELECTED_TEXT = ["BloemText", "BloemTextMuted"]
TEXT_ON_SURFACES = ["BloemText", "BloemTextMuted", "AccentColor", "BloemOK", "BloemWarn", "BloemDanger"]
GRAPHICS = ["BloemChartDirectPlay", "BloemChartDirectStream", "BloemChartTranscode", "BloemChart4", "BloemChart5", "BloemTally", "BloemOutline"]


def parse(value):
    if isinstance(value, tuple):
        return value[0], value[1]
    return value, 1.0


def rgb(hex_):
    h = hex_.lstrip("#")
    return [int(h[i:i + 2], 16) for i in (0, 2, 4)]


def lin(c):
    c /= 255
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4


def luminance(hex_):
    r, g, b = rgb(hex_)
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def ratio(a, b):
    x, y = luminance(a), luminance(b)
    if x < y:
        x, y = y, x
    return (x + 0.05) / (y + 0.05)


def component(n):
    return "0x%02X" % n


def entry(value, appearances):
    hex_, alpha = parse(value)
    r, g, b = rgb(hex_)
    item = {
        "color": {
            "color-space": "srgb",
            "components": {"alpha": "%.3f" % alpha, "blue": component(b), "green": component(g), "red": component(r)},
        },
        "idiom": "universal",
    }
    if appearances:
        item["appearances"] = appearances
    return item


def write_sets():
    for name, (light, dark, light_hc, dark_hc) in TOKENS.items():
        contents = {
            "colors": [
                entry(light, None),
                entry(dark, [{"appearance": "luminosity", "value": "dark"}]),
                entry(light_hc, [{"appearance": "contrast", "value": "high"}]),
                entry(dark_hc, [{"appearance": "luminosity", "value": "dark"}, {"appearance": "contrast", "value": "high"}]),
            ],
            "info": {"author": "xcode", "version": 1},
        }
        folder = os.path.join(ASSETS, name + ".colorset")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "Contents.json"), "w") as f:
            json.dump(contents, f, indent=2, sort_keys=True)
            f.write("\n")


def check():
    failures = 0
    names = ["Light", "Dark", "Light +contrast", "Dark +contrast"]
    for index, label in enumerate(names):
        high = index >= 2
        text_min = 7.0 if high else 4.5
        graphic_min = 3.0
        print(f"== {label} (text >= {text_min}:1, graphics >= {graphic_min}:1)")
        for fg in TEXT_ON_SURFACES:
            row = []
            for bg in SURFACES + (["BloemSelected"] if fg in SELECTED_TEXT else []):
                value = ratio(parse(TOKENS[fg][index])[0], parse(TOKENS[bg][index])[0])
                # Muted text only has to hold on the page and card; on raised it is a caption of a control.
                need = text_min
                ok = value >= need
                failures += 0 if ok else 1
                row.append(f"{bg[5:]} {value:5.2f}{'' if ok else ' FAIL'}")
            print(f"  {fg:16s}", " | ".join(row))
        for g in GRAPHICS:
            row = []
            # Charts sit on cards; the tally dot and outlines on the page too.
            for bg in (["BloemSurface"] if g.startswith("BloemChart") else ["BloemBackground", "BloemSurface"]):
                value = ratio(parse(TOKENS[g][index])[0], parse(TOKENS[bg][index])[0])
                ok = value >= graphic_min
                failures += 0 if ok else 1
                row.append(f"{bg[5:]} {value:5.2f}{'' if ok else ' FAIL'}")
            print(f"  {g:22s}", " | ".join(row))
        on_accent = ratio(parse(TOKENS["BloemOnAccent"][index])[0], parse(TOKENS["AccentColor"][index])[0])
        ok = on_accent >= text_min
        failures += 0 if ok else 1
        print(f"  on-accent label on accent fill {on_accent:5.2f}{'' if ok else ' FAIL'}")
    print("failures:", failures)
    return failures


if __name__ == "__main__":
    if "--check" not in sys.argv:
        write_sets()
    sys.exit(1 if check() else 0)
