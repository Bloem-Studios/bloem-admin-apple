#!/usr/bin/env python3
"""Renders the widgets' app mark: the Bloem tulip with the admin app's server badge, as a template image.

    python3 -I scripts/render-widget-mark.py

Reads docs/design/app-icons/admin-mono.svg (the icon's one-colour drawing, white on transparent) and writes
BloemAdmin/Shared/Widgets/Marks.xcassets/bloem.admin-mark.imageset: a square, cropped to the artwork, at 16 points
(32 and 48 pixels), black with the drawing as its alpha, so SwiftUI draws it in whatever colour the widget gives it
(`muted`, and the system's tint on a tinted Home Screen or the Lock Screen). The asset lives under BloemAdmin/Shared
so the app and the widget extension both ship it: the widgets are drawn in both.

Rendering is headless chromium at a large size, on black: the drawing is white, so each pixel's luminance is its coverage.
Needs chromium and Pillow.
"""
import base64
import json
import os
import shutil
import subprocess
import tempfile

from PIL import Image

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SVG = os.path.join(ROOT, "docs", "design", "app-icons", "admin-mono.svg")
SET = os.path.join(ROOT, "BloemAdmin", "Shared", "Widgets", "Marks.xcassets", "bloem.admin-mark.imageset")
POINTS = 16
BIG = 2160  # 20 px per unit of the 108-unit canvas


def chromium():
    for name in ("chromium", "chromium-browser", "google-chrome"):
        path = shutil.which(name)
        if path:
            return path
    raise SystemExit("chromium not found")


def render():
    svg = open(SVG, "rb").read()
    html = (
        '<html><body style="margin:0;background:#000"><img style="display:block;width:%dpx;height:%dpx" '
        'src="data:image/svg+xml;base64,%s"></body></html>' % (BIG, BIG, base64.b64encode(svg).decode())
    )
    with tempfile.TemporaryDirectory() as tmp:
        page = os.path.join(tmp, "mark.html")
        shot = os.path.join(tmp, "mark.png")
        open(page, "w").write(html)
        subprocess.run(
            [chromium(), "--headless=new", "--no-sandbox", "--hide-scrollbars", "--force-device-scale-factor=1",
             "--default-background-color=000000FF", "--window-size=%d,%d" % (BIG, BIG), "--screenshot=" + shot,
             "file://" + page],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return Image.open(shot).convert("L").copy()


def main():
    coverage = render()
    box = coverage.point(lambda v: 255 if v > 6 else 0).getbbox()
    if not box:
        raise SystemExit("nothing was drawn")
    art = coverage.crop(box)
    side = max(art.size)
    square = Image.new("L", (side, side), 0)
    square.paste(art, ((side - art.width) // 2, (side - art.height) // 2))
    if os.path.isdir(SET):
        shutil.rmtree(SET)
    os.makedirs(SET)
    files = []
    for scale in (2, 3):
        size = POINTS * scale
        alpha = square.resize((size, size), Image.LANCZOS)
        image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        image.putalpha(alpha)
        name = "mark@%dx.png" % scale
        image.save(os.path.join(SET, name), optimize=True)
        files.append({"filename": name, "idiom": "universal", "scale": "%dx" % scale})
    contents = {"images": files, "info": {"author": "xcode", "version": 1}, "properties": {"template-rendering-intent": "template"}}
    with open(os.path.join(SET, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")
    with open(os.path.join(os.path.dirname(SET), "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    print("wrote", os.path.relpath(SET, ROOT), "from a %dx%d drawing" % art.size)


if __name__ == "__main__":
    main()
