# App icon sources

The Bloem Admin icon is the Bloem Studios tulip on a dark graphite plate (`#141417`, see `background.txt`), with a small
Lucide `server` badge (ISC licence).

| File | What it is |
| --- | --- |
| `admin-icon.svg` | Full icon: plate, tulip and badge, 108×108 units |
| `admin-foreground.svg` | Tulip and badge on transparent |
| `admin-mono.svg` | White, one-colour drawing with the badge knocked out of the tulip; the source of the tinted icon and of the widget mark |
| `bloem-tulip-logo.svg`, `bloem-tulip-logo-mono.svg` | The tulip alone |
| `reference-bloem-black.png`, `tulip-trace.json`, `tulip-overlay-comparison.png` | The logo the tulip is traced from, the trace, and an overlay of the redraw on the logo |

The Bloem name and tulip logo are trademarks of Bloem Studios and are not licensed under the AGPL. See
[THIRD_PARTY_NOTICES.md](../../../THIRD_PARTY_NOTICES.md).

## The iOS icon

The icon set in `BloemAdmin/Assets.xcassets/AppIcon.appiconset` is rendered from `admin-icon.svg` and `admin-mono.svg`.
The canvas is 108×108 units; the central 72×72 (`viewBox="18 18 72 72"`) is scaled to the 1024 point square, and everything
important sits inside the 66-unit safe circle.

- `icon-1024.png`: default, opaque, with no corner mask (iOS applies it).
- `icon-1024-dark.png`: the same artwork. The plate is already dark graphite, so a transparent background would only let
  the system's lighter fill show through.
- `icon-1024-tinted.png`: the grayscale mono tulip plus badge ring and glyph on a near-black grey plate.

The widget extension has no icon of its own. Change the masters and regenerate rather than editing the generated files.

## Rebuilding

Run these from this folder:

- `python3 generate.py` writes the SVGs (and Android VectorDrawables under `android/`, which this app does not use) from
  `tulip-trace.json`. Pass `--out DIR` to write elsewhere.
- `python3 trace_tulip.py` re-traces the reference into `tulip-trace.json` (needs numpy, Pillow, scipy and scikit-image).
- `python3 fit_layout.py` picks the tulip scale and badge position (needs headless Chromium, numpy and Pillow).
- `python3 compare_tulip.py` rewrites `tulip-overlay-comparison.png` (needs headless Chromium and Pillow).
- `python3 ../../../scripts/render-widget-mark.py` redraws the widget extension's mark from `admin-mono.svg`.
