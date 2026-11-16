#!/usr/bin/env python3
"""Sorts the widget renders into docs/screenshots/bloem-widgets/enhanced/ and puts each widget next to its app page.

    python3 -I scripts/compose-widget-shots.py <renders> <app-screens> <out>

<renders> is the folder `BloemAdminTests/Widgets/WidgetRenderTests` writes when /tmp/bloem-widget-shots exists on the
machine running the simulator (copy it back with `ssh <mac> 'cd /tmp/bloem-widget-shots && tar cf - .' | tar xf - -C <renders>`).
<app-screens> is docs/screenshots/bloem-look/after, the app's own pages from the LookTourUITests fixtures. <out> is
docs/screenshots/bloem-widgets/enhanced.

Every image is reduced to two thirds and palette-reduced to keep the repository small. Nothing here is a real server
or real data: the widgets draw `WidgetSamples`, the pages draw the app's fixtures.
"""
import os
import sys

from PIL import Image

WIDGETS = ["now-playing", "requests", "libraries", "nodes", "server-status"]
# The app page each widget stands for, from the look tour.
PAGES = {
    "now-playing": "now-playing-rows-iphone",
    "requests": "requests-iphone",
    "libraries": "libraries-iphone",
    "nodes": "automation-nodes-iphone",
    "server-status": "dashboard-1-iphone",
}
FAMILIES = ["small", "medium", "large", "extra-large", "circular", "rectangular", "inline"]
STATES = ["loading", "signed-out", "unreachable", "unavailable", "empty", "stale", "action-failed", "down"]
BACKGROUND = {"dark": (20, 20, 23), "light": (236, 236, 240)}
GAP = 16


def reduce(image, scale=2 / 3):
    image = image.convert("RGB")
    return image.resize((max(1, round(image.width * scale)), max(1, round(image.height * scale))), Image.LANCZOS)


def save(image, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.convert("RGB").quantize(colors=256, method=Image.FASTOCTREE, dither=Image.NONE).save(path, optimize=True)


def load(folder, name):
    path = os.path.join(folder, name + ".png")
    return Image.open(path) if os.path.exists(path) else None


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    renders, pages, out = sys.argv[1:]

    # The widgets, by family, dark and light.
    for widget in WIDGETS:
        for family in FAMILIES:
            for scheme in BACKGROUND:
                image = load(renders, f"{widget}-{family}-{scheme}")
                if image:
                    save(reduce(image), os.path.join(out, f"{widget}-{family}-{scheme}.png"))

    # Every state, at the sizes that tell them apart.
    for widget in WIDGETS:
        for state in STATES:
            for family in ["small", "medium", "large", "rectangular", "extra-large", "inline"]:
                for scheme in BACKGROUND:
                    image = load(renders, f"{widget}-{state}-{family}-{scheme}")
                    if image:
                        save(reduce(image), os.path.join(out, "states", f"{widget}-{state}-{family}-{scheme}.png"))

    # The largest text size, the lock screen with details off and on, Now playing with 0, 1 and many streams, and the
    # Live Activity.
    for name in sorted(os.listdir(renders)):
        stem = name[:-4]
        folder = None
        if stem.startswith("now-playing-streams-"):
            folder = "streams"
        elif "-large-text-" in stem:
            folder = "large-text"
        elif "-lock-details-" in stem:
            folder = "lock-screen"
        elif stem.startswith("live-activity"):
            folder = ""
        if folder is not None:
            save(reduce(Image.open(os.path.join(renders, name))), os.path.join(out, folder, name))

    # Each widget beside the app's own page: the page on the left, the widget in its families on the right.
    for widget in WIDGETS:
        for scheme, background in BACKGROUND.items():
            page = load(pages, f"{PAGES[widget]}-{scheme}")
            parts = {family: load(renders, f"{widget}-{family}-{scheme}") for family in FAMILIES}
            if not page or not all(parts[f] for f in ["small", "medium", "large"]):
                continue
            small, medium, large = (reduce(parts[f]) for f in ["small", "medium", "large"])
            lock = [reduce(parts[f], 0.5) for f in ["circular", "rectangular", "inline"] if parts[f]]
            col2 = medium.height + GAP + large.height
            col3 = small.height + sum(GAP + i.height for i in lock)
            height = max(page.height, col2, col3)
            width = page.width + GAP + medium.width + GAP + max(small.width, *(i.width for i in lock)) + GAP
            sheet = Image.new("RGB", (width + GAP, height + 2 * GAP), background)
            x = GAP
            sheet.paste(page.convert("RGB"), (x, GAP))
            x += page.width + GAP
            sheet.paste(medium, (x, GAP))
            sheet.paste(large, (x, GAP + medium.height + GAP))
            x += medium.width + GAP
            y = GAP
            for image in [small] + lock:
                sheet.paste(image, (x, y))
                y += image.height + GAP
            save(sheet, os.path.join(out, "with-app", f"{widget}-{scheme}.png"))

            xl = load(renders, f"{widget}-extra-large-{scheme}")
            if xl:
                xl = reduce(xl)
                wide = Image.new("RGB", (page.width + GAP + xl.width + 2 * GAP, max(page.height, xl.height) + 2 * GAP), background)
                wide.paste(page.convert("RGB"), (GAP, GAP))
                wide.paste(xl, (GAP + page.width + GAP, GAP))
                save(wide, os.path.join(out, "with-app", f"{widget}-extra-large-{scheme}.png"))


if __name__ == "__main__":
    main()
