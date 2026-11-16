#!/usr/bin/env python3
"""Writes the Lucide icon catalog, BloemAdmin/Resources/Icons.xcassets, from the icons listed in BloemIcon.swift.

    python3 -I scripts/lucide-icons.py /path/to/lucide-static/icons

`lucide-static` is the npm package (`npm pack lucide-static`); its `icons/` folder holds one SVG per icon. The
list of icons is the `case name = "kebab-name"` lines of BloemAdmin/Theme/BloemIcon.swift, so that file is the
one place to add an icon. Each icon becomes an image set `lucide.<name>`: the SVG with its colour fixed to black
(a template image takes the colour of its text), its size set to 18 (the row size) and Preserve Vector Data on.
Lucide is ISC licensed; the licence text is LICENSES/Lucide-ISC.txt.
"""
import json
import os
import re
import shutil
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SWIFT = os.path.join(ROOT, "BloemAdmin", "Theme", "BloemIcon.swift")
CATALOG = os.path.join(ROOT, "BloemAdmin", "Resources", "Icons.xcassets")
SIZE = 18
# The widget extension has no access to the app's catalog, so it gets its own, with just what it draws.
WIDGET_CATALOG = os.path.join(ROOT, "BloemAdminWidgets", "Icons.xcassets")
WIDGET_ICONS = [
    "radio", "triangle-alert", "inbox", "library", "cpu", "server", "archive", "rotate-cw", "check", "x", "lock", "wifi-off", "arrow-right",
    "chevron-up", "chevron-down",
]

TEMPLATE = (
    '<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" '
    'stroke="#000000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\n{body}\n</svg>\n'
)


def icon_names():
    text = open(SWIFT, encoding="utf-8").read()
    return re.findall(r'^\s*case \w+ = "([a-z0-9-]+)"', text, re.M)


def body_of(svg):
    inner = re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1)
    lines = [line.strip() for line in inner.strip().splitlines() if line.strip()]
    return "\n".join("  " + line for line in lines)


def write_catalog(catalog, source, names):
    if os.path.isdir(catalog):
        shutil.rmtree(catalog)
    os.makedirs(catalog)
    with open(os.path.join(catalog, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    for name in names:
        folder = os.path.join(catalog, f"lucide.{name}.imageset")
        os.makedirs(folder)
        svg = open(os.path.join(source, name + ".svg"), encoding="utf-8").read()
        with open(os.path.join(folder, name + ".svg"), "w", encoding="utf-8") as f:
            f.write(TEMPLATE.format(size=SIZE, body=body_of(svg)))
        contents = {
            "images": [{"filename": name + ".svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
        }
        with open(os.path.join(folder, "Contents.json"), "w") as f:
            json.dump(contents, f, indent=2)
            f.write("\n")
    print(f"wrote {len(names)} icons to {os.path.relpath(catalog, ROOT)}")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    source = sys.argv[1]
    names = icon_names()
    missing = [n for n in names + WIDGET_ICONS if not os.path.isfile(os.path.join(source, n + ".svg"))]
    if missing:
        sys.exit("not in Lucide: " + ", ".join(missing))
    write_catalog(CATALOG, source, names)
    write_catalog(WIDGET_CATALOG, source, WIDGET_ICONS)


if __name__ == "__main__":
    main()
