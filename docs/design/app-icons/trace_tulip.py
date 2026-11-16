#!/usr/bin/env python3
"""Traces the tulip in reference-bloem-black.png (the Bloem Studios logo, 1254x1254) into clean vector
shapes: sub-pixel contours, corner detection, least-squares cubic Beziers (Schneider), and snapping of the
straight horizontal / vertical edges. Writes tulip-trace.json (paths + pixels in reference pixel
coordinates), which make_tulip.py turns into the SVGs.

Needs numpy, Pillow, scipy and scikit-image:  python3 -m venv v && v/bin/pip install numpy pillow scipy scikit-image
Usage: v/bin/python trace_tulip.py
"""
import json
import os

import numpy as np
from PIL import Image
from scipy import ndimage as ndi
from skimage import measure

HERE = os.path.dirname(os.path.abspath(__file__))
THR = 70.0          # max-channel level of the edge (orange 255 and grey 140 both clear it)
FIT_TOL = 0.9       # px, Bezier fit tolerance
CORNER_DEG = 38.0   # turning angle that makes a corner
LINE_TOL = 0.9      # px, a run this flat is a straight line
SNAP = 1.4          # px, a line within this of vertical / horizontal is snapped


# ---- Schneider cubic Bezier fitting ----------------------------------------------------------------
def bez(c, t):
    t = np.asarray(t)[:, None]
    return ((1 - t) ** 3) * c[0] + 3 * ((1 - t) ** 2) * t * c[1] + 3 * (1 - t) * t * t * c[2] + t ** 3 * c[3]


def bez_d(c, t):
    t = np.asarray(t)[:, None]
    return 3 * ((1 - t) ** 2) * (c[1] - c[0]) + 6 * (1 - t) * t * (c[2] - c[1]) + 3 * t * t * (c[3] - c[2])


def bez_dd(c, t):
    t = np.asarray(t)[:, None]
    return 6 * (1 - t) * (c[2] - 2 * c[1] + c[0]) + 6 * t * (c[3] - 2 * c[2] + c[1])


def unit(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-9 else v


def chord_param(pts):
    d = np.r_[0, np.cumsum(np.linalg.norm(np.diff(pts, axis=0), axis=1))]
    return d / d[-1]


def gen_bezier(pts, u, t1, t2):
    p0, p3 = pts[0], pts[-1]
    b0, b1, b2, b3 = (1 - u) ** 3, 3 * u * (1 - u) ** 2, 3 * u * u * (1 - u), u ** 3
    a1 = t1[None, :] * b1[:, None]
    a2 = t2[None, :] * b2[:, None]
    c = np.array([[np.sum(a1 * a1), np.sum(a1 * a2)], [np.sum(a1 * a2), np.sum(a2 * a2)]])
    tmp = pts - (p0[None, :] * (b0 + b1)[:, None] + p3[None, :] * (b2 + b3)[:, None])
    x = np.array([np.sum(a1 * tmp), np.sum(a2 * tmp)])
    det = c[0, 0] * c[1, 1] - c[0, 1] * c[1, 0]
    seg = np.linalg.norm(p3 - p0)
    if abs(det) > 1e-12:
        al1 = (x[0] * c[1, 1] - x[1] * c[0, 1]) / det
        al2 = (c[0, 0] * x[1] - c[1, 0] * x[0]) / det
    else:
        al1 = al2 = seg / 3
    if al1 < 1e-6 * seg or al2 < 1e-6 * seg:
        al1 = al2 = seg / 3
    return np.array([p0, p0 + t1 * al1, p3 + t2 * al2, p3])


def reparam(c, pts, u):
    d = bez(c, u) - pts
    d1, d2 = bez_d(c, u), bez_dd(c, u)
    num = np.sum(d * d1, axis=1)
    den = np.sum(d1 * d1, axis=1) + np.sum(d * d2, axis=1)
    den[np.abs(den) < 1e-12] = 1e-12
    return np.clip(u - num / den, 0, 1)


def fit_cubic(pts, t1, t2, tol, depth=0):
    if len(pts) == 2:
        d = np.linalg.norm(pts[1] - pts[0]) / 3
        return [np.array([pts[0], pts[0] + t1 * d, pts[1] + t2 * d, pts[1]])]
    u = chord_param(pts)
    c = gen_bezier(pts, u, t1, t2)
    for _ in range(6):
        err = np.linalg.norm(bez(c, u) - pts, axis=1)
        if err.max() < tol:
            return [c]
        u = reparam(c, pts, u)
        c = gen_bezier(pts, u, t1, t2)
    err = np.linalg.norm(bez(c, u) - pts, axis=1)
    if err.max() < tol:
        return [c]
    if depth > 12 or len(pts) < 5:
        return [c]
    i = int(np.argmax(err))
    i = min(max(i, 2), len(pts) - 3)
    tc = unit(pts[i - 2] - pts[i + 2])
    return fit_cubic(pts[:i + 1], t1, tc, tol, depth + 1) + fit_cubic(pts[i:], -tc, t2, tol, depth + 1)


# ---- contour handling ------------------------------------------------------------------------------
def resample(c, step=0.6):
    d = np.r_[0, np.cumsum(np.linalg.norm(np.diff(c, axis=0), axis=1))]
    n = max(int(d[-1] / step), 8)
    s = np.linspace(0, d[-1], n, endpoint=False)
    return np.stack([np.interp(s, d, c[:, 0]), np.interp(s, d, c[:, 1])], 1)


def turning(p, k=7):
    """Turning angle (deg) at each point of a closed polyline, from the directions k steps either side."""
    n = len(p)
    out = np.zeros(n)
    for i in range(n):
        a = p[i] - p[(i - k) % n]
        b = p[(i + k) % n] - p[i]
        ang = np.degrees(np.arctan2(a[0] * b[1] - a[1] * b[0], a @ b))
        out[i] = abs(ang)
    return out


def find_corners(p):
    ang = turning(p)
    n = len(p)
    corners = []
    for i in np.argsort(-ang):
        if ang[i] < CORNER_DEG:
            break
        if all(min((i - j) % n, (j - i) % n) > 14 for j in corners):
            corners.append(int(i))
    return sorted(corners)


def smooth_closed(p, w=2):
    k = np.ones(2 * w + 1) / (2 * w + 1)
    out = np.empty_like(p)
    for d in range(2):
        ext = np.r_[p[-w:, d], p[:, d], p[:w, d]]
        out[:, d] = np.convolve(ext, k, mode="valid")
    return out


def trace_closed(c):
    p = resample(c)
    ps = smooth_closed(p, 1)
    corners = find_corners(ps)
    n = len(p)
    if not corners:
        # a smooth closed outline: cut it at the point furthest from the centroid
        corners = [int(np.argmax(np.linalg.norm(p - p.mean(0), axis=1)))]
    segs = []   # (start_vertex, kind, c1, c2, end_vertex)
    verts = [p[i].copy() for i in corners]
    for ci in range(len(corners)):
        a, b = corners[ci], corners[(ci + 1) % len(corners)]
        idx = list(range(a, b + 1)) if b > a else list(range(a, n)) + list(range(0, b + 1))
        run = p[idx]
        if len(corners) == 1:
            run = np.vstack([run, p[a:a + 1]])
        chord = run[-1] - run[0]
        L = np.linalg.norm(chord)
        rel = run - run[0]
        dev = np.abs(chord[0] * rel[:, 1] - chord[1] * rel[:, 0]) / max(L, 1e-9)
        if L > 6 and dev.max() < LINE_TOL:
            segs.append(["L"])
            continue
        k = min(4, len(run) // 3)
        t1 = unit(run[k] - run[0])
        t2 = unit(run[-1 - k] - run[-1])
        if len(corners) == 1:
            t1 = unit(run[k] - run[-1 - k])
            t2 = -t1
        cs = fit_cubic(run, t1, t2, FIT_TOL)
        segs.append(["C", cs])
    return verts, segs


def snap(verts, segs):
    """Snap near-vertical / near-horizontal straight edges to exact coordinates, moving the vertices
    (and the adjacent Bezier handles with them)."""
    nv = len(verts)
    verts = [v.copy() for v in verts]
    for i, s in enumerate(segs):
        if s[0] != "L":
            continue
        a, b = verts[i], verts[(i + 1) % nv]
        if abs(a[0] - b[0]) < SNAP and abs(a[1] - b[1]) > 4:
            x = round((a[0] + b[0]) / 2 * 2) / 2
            a[0] = b[0] = x
        elif abs(a[1] - b[1]) < SNAP and abs(a[0] - b[0]) > 4:
            y = round((a[1] + b[1]) / 2 * 2) / 2
            a[1] = b[1] = y
    return verts


def path_d(verts, segs):
    f = lambda v: f"{v[0]:.1f} {v[1]:.1f}"
    out = [f"M{f(verts[0])}"]
    nv = len(verts)
    for i, s in enumerate(segs):
        end = verts[(i + 1) % nv]
        if s[0] == "L":
            out.append(f"L{f(end)}")
        else:
            cs = [c.copy() for c in s[1]]
            cs[0][1] = cs[0][1] + (verts[i] - cs[0][0])     # move the first handle with its (snapped) vertex
            cs[-1][2] = cs[-1][2] + (end - cs[-1][3])
            cs[-1][3] = end
            for c in cs:
                out.append(f"C{f(c[1])} {f(c[2])} {f(c[3])}")
    out.append("Z")
    return "".join(out)


def main():
    ref = np.array(Image.open(f"{HERE}/reference-bloem-black.png").convert("RGB")).astype(float)
    lum = ref.max(axis=2)
    mask = lum > THR
    mask[720:, :] = False
    mask[:150, :] = False
    lab, n = ndi.label(mask, structure=np.ones((3, 3)))
    big, pixels = [], []
    for i in range(1, n + 1):
        ys, xs = np.nonzero(lab == i)
        if len(ys) < 20:
            continue
        if len(ys) < 1000 and (xs.min() > 725):          # the dissolve pixels
            pixels.append(i)
        else:
            big.append(i)
    result = {"paths": [], "pixels": []}
    names = {}
    for i in big:
        ys, xs = np.nonzero(lab == i)
        names[i] = (xs.min(), xs.max(), ys.min(), ys.max())
    for i in big:
        x0, x1, y0, y1 = names[i]
        pad = 6
        win = (slice(y0 - pad, y1 + pad + 1), slice(x0 - pad, x1 + pad + 1))
        # half-maximum edge: normalise by the local plateau so orange (255) and grey (140) edges both sit at 50%
        plateau = ndi.maximum_filter(lum, size=9)[win]
        norm = np.clip(lum[win] / np.maximum(plateau, 1.0), 0, 1)
        norm = np.where(ndi.binary_dilation(lab[win] == i, iterations=3), norm, 0.0)
        sub = ndi.gaussian_filter(norm, 0.6)
        contours = measure.find_contours(sub, 0.5)
        ds = []
        for c in contours:
            if len(c) < 20:
                continue
            c = np.stack([c[:, 1] + x0 - pad, c[:, 0] + y0 - pad], 1)   # (x, y) in reference px
            if np.linalg.norm(c[0] - c[-1]) > 1.5:
                continue
            verts, segs = trace_closed(c[:-1] if np.allclose(c[0], c[-1]) else c)
            verts = snap(verts, segs)
            ds.append(path_d(verts, segs))
        result["paths"].append({"id": int(i), "bbox": [int(x0), int(x1), int(y0), int(y1)], "d": "".join(ds)})
    for i in pixels:
        m = lab == i
        ys, xs = np.nonzero(m)
        cy, cx = int(ys.mean()), int(xs.mean())
        # sub-pixel extents: where the centre row / column crosses half of the plateau
        row, col = lum[cy, xs.min() - 3:xs.max() + 4], lum[ys.min() - 3:ys.max() + 4, cx]
        def extent(prof, off):
            half = (prof.max() + 0) / 2
            idx = np.nonzero(prof > half)[0]
            a, b = idx[0], idx[-1]
            fa = a - (prof[a] - half) / (prof[a] - prof[a - 1]) if a > 0 and prof[a] != prof[a - 1] else a
            fb = b + (prof[b] - half) / (prof[b] - prof[b + 1]) if b + 1 < len(prof) and prof[b] != prof[b + 1] else b
            return off + fa + 0.5, off + fb + 0.5
        xa, xb = extent(row, xs.min() - 3)
        ya, yb = extent(col, ys.min() - 3)
        core = ref[cy - 2:cy + 3, cx - 2:cx + 3].reshape(-1, 3).mean(0)
        result["pixels"].append({"x": round(xa, 1), "y": round(ya, 1), "w": round(xb - xa, 1), "h": round(yb - ya, 1),
                                 "rgb": [int(v) for v in core]})
    with open(f"{HERE}/tulip-trace.json", "w") as f:
        json.dump(result, f, indent=1)
    print("paths", [(p["id"], p["bbox"], p["d"].count("C"), p["d"].count("L")) for p in result["paths"]])
    print("pixels", len(result["pixels"]))


if __name__ == "__main__":
    main()
