#!/usr/bin/env python3
"""img2svg -- trace a raster image (PNG/JPG/...) into a line-art SVG.

Companion to the note-helper SKILL tool, but completely Cadence-independent:
pure CPython + Pillow + numpy (no potrace/OpenCV). Trace a screenshot, diagram,
or photo to a clean vector SVG of outlines, then import that SVG into a
schematic with note-helper's "Import SVG..." (Feature A).

Two tracing modes:
  * threshold -- binarise the image (Otsu auto level), then trace the outlines
                 of the dark/light regions. Best for clean line art, logos,
                 block diagrams, high-contrast figures.
  * edge      -- Sobel edge magnitude, thresholded, then traced. Use for photos
                 / busy images; lossier and needs threshold tuning.

Both produce *region-boundary contours* via marching squares + Douglas-Peucker
simplification -> SVG <path> outlines (stroke, no fill), in image coordinates
(y-down, standard SVG). note-helper's parser flips Y on import.

Usage
-----
GUI (default):
    python3 img2svg.py

CLI:
    python3 img2svg.py IN.png OUT.svg [--mode threshold|edge] [--threshold T]
            [--invert] [--simplify EPS] [--min-len L] [--stroke W]
            [--max-dim N] [--blur R]

The GUI auto-falls back to CLI usage if Tkinter is unavailable (headless box).
"""

import sys
import argparse


# --------------------------------------------------------------------------
# Core tracing (no GUI dependency).  Needs Pillow + numpy.
# --------------------------------------------------------------------------

def _require_libs():
    try:
        import numpy        # noqa: F401
        from PIL import Image  # noqa: F401
    except Exception as e:
        sys.stderr.write("img2svg needs Pillow and numpy: %s\n" % e)
        raise


def load_gray(path, max_dim=1000, blur=0.0):
    """Load an image as a 2D uint8 grayscale numpy array, optionally downscaled
    to max_dim on its longer side and lightly blurred to denoise."""
    import numpy as np
    from PIL import Image, ImageFilter
    img = Image.open(path).convert("L")
    if max_dim and max(img.size) > max_dim:
        s = max_dim / float(max(img.size))
        img = img.resize((max(1, int(img.size[0] * s)),
                          max(1, int(img.size[1] * s))), Image.LANCZOS)
    if blur and blur > 0:
        img = img.filter(ImageFilter.GaussianBlur(radius=blur))
    return np.asarray(img, dtype=np.uint8)


def otsu(arr):
    """Otsu's threshold (0..255) for a uint8 array."""
    import numpy as np
    hist = np.bincount(arr.ravel(), minlength=256).astype(np.float64)
    total = arr.size
    sum_total = np.dot(np.arange(256), hist)
    wB = 0.0
    sumB = 0.0
    best, thr = -1.0, 127
    for i in range(256):
        wB += hist[i]
        if wB == 0:
            continue
        wF = total - wB
        if wF == 0:
            break
        sumB += i * hist[i]
        mB = sumB / wB
        mF = (sum_total - sumB) / wF
        between = wB * wF * (mB - mF) ** 2
        if between > best:
            best, thr = between, i
    return thr


def sobel_mag(gray):
    """Sobel gradient magnitude, normalised to 0..255 uint8."""
    import numpy as np
    g = gray.astype(np.float64)
    gp = np.pad(g, 1, mode="edge")
    gx = (-gp[:-2, :-2] - 2 * gp[1:-1, :-2] - gp[2:, :-2]
          + gp[:-2, 2:] + 2 * gp[1:-1, 2:] + gp[2:, 2:])
    gy = (-gp[:-2, :-2] - 2 * gp[:-2, 1:-1] - gp[:-2, 2:]
          + gp[2:, :-2] + 2 * gp[2:, 1:-1] + gp[2:, 2:])
    mag = np.hypot(gx, gy)
    m = mag.max()
    if m > 0:
        mag = mag / m * 255.0
    return mag.astype(np.uint8)


def to_binary(gray, mode="threshold", threshold=None, invert=False):
    """Return a 0/1 uint8 mask (foreground=1)."""
    import numpy as np
    if mode == "edge":
        m = sobel_mag(gray)
        thr = otsu(m) if threshold is None else threshold
        B = (m > thr).astype(np.uint8)
    else:
        thr = otsu(gray) if threshold is None else threshold
        # default foreground = dark "ink" pixels (Otsu class-0 is values [0..thr],
        # so foreground = gray <= thr); --invert flips to light-on-dark.
        B = (gray <= thr).astype(np.uint8) if not invert else (gray > thr).astype(np.uint8)
    return B


# Marching-squares edge -> segment table. Corners weighted TL=1,TR=2,BR=4,BL=8.
# Edge midpoints: T=top, R=right, B=bottom, L=left.
_MS = {
    1: [("L", "T")], 2: [("T", "R")], 3: [("L", "R")], 4: [("R", "B")],
    5: [("L", "T"), ("R", "B")], 6: [("T", "B")], 7: [("L", "B")],
    8: [("B", "L")], 9: [("T", "B")], 10: [("T", "R"), ("B", "L")],
    11: [("R", "B")], 12: [("L", "R")], 13: [("T", "R")], 14: [("L", "T")],
}


def marching_squares(B):
    """Region-boundary segments of a 0/1 mask via marching squares.
    Returns a list of ((x1,y1),(x2,y2)) at half-integer edge midpoints."""
    import numpy as np
    tl = B[:-1, :-1]; tr = B[:-1, 1:]; br = B[1:, 1:]; bl = B[1:, :-1]
    case = (tl + (tr << 1) + (br << 2) + (bl << 3)).astype(np.int32)
    ys, xs = np.nonzero((case > 0) & (case < 15))
    segs = []
    for r, c in zip(ys.tolist(), xs.tolist()):
        mids = {
            "T": (c + 0.5, r),
            "R": (c + 1.0, r + 0.5),
            "B": (c + 0.5, r + 1.0),
            "L": (c + 0.0, r + 0.5),
        }
        for a, b in _MS[int(case[r, c])]:
            segs.append((mids[a], mids[b]))
    return segs


def stitch(segs):
    """Stitch undirected segments into polylines (closed where possible)."""
    from collections import defaultdict

    def key(p):
        return (int(round(p[0] * 2)), int(round(p[1] * 2)))

    coord = {}
    incident = defaultdict(list)   # key -> list of (segIndex, otherKey)
    for i, (a, b) in enumerate(segs):
        ka, kb = key(a), key(b)
        coord[ka], coord[kb] = a, b
        incident[ka].append((i, kb))
        incident[kb].append((i, ka))

    used = [False] * len(segs)
    polylines = []
    for ka in list(incident.keys()):
        for (i0, _kb0) in incident[ka]:
            if used[i0]:
                continue
            poly = [ka]
            cur = ka
            while True:
                nxt = None
                for (si, ok) in incident[cur]:
                    if not used[si]:
                        used[si] = True
                        nxt = ok
                        break
                if nxt is None:
                    break
                poly.append(nxt)
                cur = nxt
                if cur == poly[0]:
                    break
            if len(poly) >= 2:
                polylines.append([coord[k] for k in poly])
    return polylines


def _perp(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    L2 = dx * dx + dy * dy
    if L2 == 0:
        return ((p[0] - a[0]) ** 2 + (p[1] - a[1]) ** 2) ** 0.5
    t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / L2
    px, py = a[0] + t * dx, a[1] + t * dy
    return ((p[0] - px) ** 2 + (p[1] - py) ** 2) ** 0.5


def douglas_peucker(pts, eps):
    """Iterative Ramer-Douglas-Peucker polyline simplification."""
    if len(pts) < 3 or eps <= 0:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        dmax, idx = -1.0, -1
        for k in range(i + 1, j):
            d = _perp(pts[k], pts[i], pts[j])
            if d > dmax:
                dmax, idx = d, k
        if dmax > eps:
            keep[idx] = True
            stack.append((i, idx))
            stack.append((idx, j))
    return [p for p, k in zip(pts, keep) if k]


def _poly_len(pts):
    return sum(((pts[i + 1][0] - pts[i][0]) ** 2 + (pts[i + 1][1] - pts[i][1]) ** 2) ** 0.5
               for i in range(len(pts) - 1))


def foreground_mask(gray):
    """Background = the low-gradient region flood-filled inward from the image
    border (it stops at the subject's strong silhouette edge); foreground = its
    complement. Used by --rmbg to drop border-connected background contours
    without touching the subject. Pure numpy morphological reconstruction."""
    import numpy as np
    mag = sobel_mag(gray)
    smooth = mag < max(otsu(mag), 1)
    # erode the smooth mask by one pixel (a pixel stays floodable only if all 4
    # neighbours are smooth too) so the flood can't sneak through thin weak-edge
    # gaps in the subject's silhouette and eat interior detail.
    er = smooth.copy()
    er[1:, :] &= smooth[:-1, :]
    er[:-1, :] &= smooth[1:, :]
    er[:, 1:] &= smooth[:, :-1]
    er[:, :-1] &= smooth[:, 1:]
    smooth = er
    H, W = gray.shape
    bg = np.zeros((H, W), dtype=bool)
    bg[0, :] |= smooth[0, :]; bg[-1, :] |= smooth[-1, :]
    bg[:, 0] |= smooth[:, 0]; bg[:, -1] |= smooth[:, -1]
    for _ in range(H + W):
        g = bg.copy()
        g[1:, :] |= bg[:-1, :]
        g[:-1, :] |= bg[1:, :]
        g[:, 1:] |= bg[:, :-1]
        g[:, :-1] |= bg[:, 1:]
        g &= smooth
        if int(g.sum()) == int(bg.sum()):
            bg = g
            break
        bg = g
    return ~bg


def _mostly_in(poly, fg, frac=0.5):
    H, W = fg.shape
    inside = 0
    for (x, y) in poly:
        xi = min(max(int(x), 0), W - 1)
        yi = min(max(int(y), 0), H - 1)
        if fg[yi, xi]:
            inside += 1
    return inside >= frac * len(poly)


def _binary_masks(gray, mode, threshold, invert, levels):
    """One or more 0/1 masks to trace. levels>1 (threshold mode) posterises the
    tonal range into `levels` bands and returns the level-to-level boundaries,
    which adds interior detail (shading, folds) as nested iso-tone contours."""
    import numpy as np
    if mode == "edge":
        return [to_binary(gray, mode="edge", threshold=threshold)]
    if levels and levels > 1:
        lo = float(np.percentile(gray, 3))
        hi = float(np.percentile(gray, 97))
        if hi <= lo:
            lo, hi = float(gray.min()), float(gray.max()) + 1.0
        masks = []
        for k in range(1, levels):
            t = lo + (hi - lo) * (k / float(levels))
            B = (gray <= t) if not invert else (gray > t)
            masks.append(B.astype(np.uint8))
        return masks
    return [to_binary(gray, mode="threshold", threshold=threshold, invert=invert)]


def trace(gray, mode="threshold", threshold=None, invert=False,
          simplify=1.5, min_len=8.0, levels=1, rmbg=False):
    """Grayscale array -> list of simplified polylines (image coords, y-down).
    levels>1 traces multiple tonal bands for a more detailed line drawing;
    rmbg drops contours lying in the border-connected background."""
    fg = foreground_mask(gray) if rmbg else None
    polys = []
    for B in _binary_masks(gray, mode, threshold, invert, levels):
        polys += stitch(marching_squares(B))
    out = []
    for p in polys:
        sp = douglas_peucker(p, simplify)
        if len(sp) < 2 or _poly_len(sp) < min_len:
            continue
        if fg is not None and not _mostly_in(sp, fg):
            continue
        out.append(sp)
    return out


def to_svg(polylines, W, H, stroke=1.0):
    """Polylines -> a clean line-art SVG string (image coords, y-down)."""
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" '
             'viewBox="0 0 %d %d" width="%d" height="%d">' % (W, H, W, H),
             '<g fill="none" stroke="black" stroke-width="%g" '
             'stroke-linejoin="round" stroke-linecap="round">' % stroke]
    for poly in polylines:
        d = "M " + " L ".join("%.2f %.2f" % (x, y) for (x, y) in poly)
        if poly[0] == poly[-1]:
            d += " Z"
        parts.append('<path d="%s"/>' % d)
    parts.append("</g></svg>")
    return "\n".join(parts) + "\n"


def convert_file(in_path, out_path, mode="threshold", threshold=None, invert=False,
                 simplify=1.5, min_len=8.0, stroke=1.0, max_dim=1000, blur=0.0,
                 levels=1, rmbg=False):
    """Full pipeline: image file -> SVG file. Returns (n_contours, W, H)."""
    _require_libs()
    gray = load_gray(in_path, max_dim=max_dim, blur=blur)
    H, W = gray.shape
    polys = trace(gray, mode=mode, threshold=threshold, invert=invert,
                  simplify=simplify, min_len=min_len, levels=levels, rmbg=rmbg)
    svg = to_svg(polys, W, H, stroke=stroke)
    with open(out_path, "w") as f:
        f.write(svg)
    return len(polys), W, H


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def run_cli(argv):
    ap = argparse.ArgumentParser(prog="img2svg",
                                 description="Trace a raster image into a line-art SVG.")
    ap.add_argument("infile")
    ap.add_argument("outfile")
    ap.add_argument("--mode", choices=["threshold", "edge"], default="threshold")
    ap.add_argument("--threshold", type=int, default=None,
                    help="0..255 cut (default: Otsu auto)")
    ap.add_argument("--levels", type=int, default=1,
                    help="threshold mode: trace this many tonal bands for more "
                         "detail (1 = single Otsu split; try 4-6)")
    ap.add_argument("--invert", action="store_true",
                    help="threshold mode: treat light pixels as foreground")
    ap.add_argument("--rmbg", action="store_true",
                    help="drop the border-connected background (keep the subject)")
    ap.add_argument("--simplify", type=float, default=1.5,
                    help="Douglas-Peucker epsilon in pixels (default 1.5)")
    ap.add_argument("--min-len", type=float, default=8.0,
                    help="drop contours shorter than this perimeter (px)")
    ap.add_argument("--stroke", type=float, default=1.0, help="SVG stroke width")
    ap.add_argument("--max-dim", type=int, default=1000,
                    help="downscale longer side to this before tracing")
    ap.add_argument("--blur", type=float, default=0.0,
                    help="Gaussian denoise radius before tracing")
    args = ap.parse_args(argv)
    n, W, H = convert_file(args.infile, args.outfile, mode=args.mode,
                           threshold=args.threshold, invert=args.invert,
                           simplify=args.simplify, min_len=args.min_len,
                           stroke=args.stroke, max_dim=args.max_dim, blur=args.blur,
                           levels=args.levels, rmbg=args.rmbg)
    sys.stderr.write("img2svg: %s -> %s  (%d contours, %dx%d, mode=%s)\n"
                     % (args.infile, args.outfile, n, W, H, args.mode))
    return 0


# --------------------------------------------------------------------------
# GUI
# --------------------------------------------------------------------------

def run_gui():
    import tkinter as tk
    from tkinter import ttk, filedialog
    _require_libs()

    root = tk.Tk()
    root.title("img2svg  --  trace a raster image to SVG")
    root.geometry("900x640")
    main = ttk.Frame(root, padding=8)
    main.pack(fill="both", expand=True)

    state = {"in": None, "polys": None, "W": 0, "H": 0}

    # --- controls row ---
    ctl = ttk.Frame(main)
    ctl.pack(fill="x", pady=(0, 6))
    in_var = tk.StringVar(value="")
    ttk.Button(ctl, text="Open image...",
               command=lambda: pick_in()).pack(side="left")
    ttk.Label(ctl, textvariable=in_var, width=36).pack(side="left", padx=6)

    mode_var = tk.StringVar(value="threshold")
    ttk.Label(ctl, text="Mode:").pack(side="left", padx=(10, 2))
    ttk.Radiobutton(ctl, text="line-art", variable=mode_var, value="threshold").pack(side="left")
    ttk.Radiobutton(ctl, text="edge (photo)", variable=mode_var, value="edge").pack(side="left")

    # --- sliders row ---
    sl = ttk.Frame(main)
    sl.pack(fill="x", pady=(0, 6))
    thr_var = tk.IntVar(value=0)       # 0 = auto (Otsu)
    simp_var = tk.DoubleVar(value=1.5)
    minlen_var = tk.DoubleVar(value=8.0)
    invert_var = tk.BooleanVar(value=False)
    rmbg_var = tk.BooleanVar(value=False)
    maxdim_var = tk.IntVar(value=1000)
    levels_var = tk.IntVar(value=1)    # threshold-mode tonal bands (detail)

    def labeled(parent, text, var, frm, to, width=120):
        f = ttk.Frame(parent)
        ttk.Label(f, text=text).pack(anchor="w")
        ttk.Scale(f, from_=frm, to=to, variable=var, orient="horizontal",
                  length=width).pack()
        f.pack(side="left", padx=6)

    labeled(sl, "Threshold (0=auto)", thr_var, 0, 255)
    labeled(sl, "Levels (detail)", levels_var, 1, 8)
    labeled(sl, "Simplify (px)", simp_var, 0, 8)
    labeled(sl, "Min length (px)", minlen_var, 0, 60)
    labeled(sl, "Max dim", maxdim_var, 200, 2000)
    ttk.Checkbutton(sl, text="invert", variable=invert_var).pack(side="left", padx=8)
    ttk.Checkbutton(sl, text="rm bg", variable=rmbg_var).pack(side="left")

    # --- buttons + status ---
    btns = ttk.Frame(main)
    btns.pack(fill="x", pady=4)
    status = ttk.Label(btns, text="Open an image, then Trace.")
    ttk.Button(btns, text="Trace", command=lambda: do_trace()).pack(side="left")
    ttk.Button(btns, text="Save SVG...", command=lambda: do_save()).pack(side="left", padx=6)
    status.pack(side="left", padx=12)

    # --- preview canvas ---
    canvas = tk.Canvas(main, bg="white", highlightthickness=1,
                       highlightbackground="#999")
    canvas.pack(fill="both", expand=True, pady=(6, 0))

    def pick_in():
        p = filedialog.askopenfilename(
            filetypes=[("Images", "*.png *.jpg *.jpeg *.bmp *.gif *.tif *.tiff"),
                       ("All files", "*.*")])
        if p:
            state["in"] = p
            in_var.set(p.split("/")[-1])
            status.config(text="Loaded %s" % in_var.get())

    def do_trace():
        if not state["in"]:
            status.config(text="Open an image first.")
            return
        try:
            gray = load_gray(state["in"], max_dim=int(maxdim_var.get()))
            H, W = gray.shape
            thr = int(thr_var.get()) or None
            polys = trace(gray, mode=mode_var.get(), threshold=thr,
                          invert=invert_var.get(), simplify=float(simp_var.get()),
                          min_len=float(minlen_var.get()), levels=int(levels_var.get()),
                          rmbg=rmbg_var.get())
            state.update(polys=polys, W=W, H=H)
            status.config(text="%d contours (%dx%d). Save SVG when happy." % (len(polys), W, H))
            draw_preview()
        except Exception as e:
            status.config(text="Trace failed: %s" % e)

    def draw_preview():
        canvas.delete("all")
        polys, W, H = state["polys"], state["W"], state["H"]
        if not polys:
            return
        cw = canvas.winfo_width() or 880
        ch = canvas.winfo_height() or 360
        s = min((cw - 20) / float(W), (ch - 20) / float(H))
        ox, oy = 10, 10
        for poly in polys:
            flat = []
            for (x, y) in poly:
                flat += [ox + x * s, oy + y * s]
            if len(flat) >= 4:
                canvas.create_line(*flat, fill="black")

    def do_save():
        if not state["polys"]:
            status.config(text="Trace first.")
            return
        p = filedialog.asksaveasfilename(defaultextension=".svg",
                                         filetypes=[("SVG", "*.svg")])
        if not p:
            return
        with open(p, "w") as f:
            f.write(to_svg(state["polys"], state["W"], state["H"]))
        status.config(text="Saved %s  (import it with note-helper)" % p.split("/")[-1])

    root.mainloop()
    return 0


# --------------------------------------------------------------------------

def main():
    argv = sys.argv[1:]
    if argv:
        # any argument -> CLI (argparse handles --help and missing positionals)
        return run_cli([a for a in argv if a != "--cli"])
    # no args -> GUI, falling back to a CLI hint on a headless box
    try:
        import tkinter  # noqa: F401
    except Exception:
        sys.stderr.write("tkinter unavailable. Use the CLI:\n"
                         "  python3 img2svg.py IN.png OUT.svg "
                         "[--mode threshold|edge] [--threshold T] ...\n")
        return 2
    return run_gui()


if __name__ == "__main__":
    raise SystemExit(main())
