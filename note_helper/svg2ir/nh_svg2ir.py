#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
nh_svg2ir.py -- note-helper Feature A vector parser (M4).

Reads an SVG file and writes a *SKILL list literal* of note-helper IR elements
(the same IR the table path produces in nhCore.il), so the IL side only has to
`infile` + `read` the file and hand it straight to `nhPlaceIR` -- no IR
translation in SKILL.

    nh_svg2ir.py  IN.svg  OUT.il  [--width W] [--height H]
                  [--font-height FH] [--curve-tol REL] [--max-seg N]

Design constraints (matches the project's zero-dependency philosophy, like
tsv2md): standard library ONLY -- xml.etree for parsing, an in-file path/number
tokenizer, and de Casteljau / arc sampling for curve flattening. No svgpathtools,
no cairosvg, no numpy.

Coordinate handling:
  * SVG user space has +Y pointing DOWN; a Cadence schematic has +Y pointing UP.
    We therefore flip Y so the figure is upright.
  * All geometry is collected in SVG user units (after applying the element/group
    transform chain), then the whole picture is bbox-normalised to the origin and
    uniformly scaled (aspect preserved) to the requested width (or height).

Emitted IR element forms (see nhCore.il header):
  shape:  (nil kind shape stype "line" lstyle "solid" points ((x y) ...) width nil)
  label:  (nil kind label point (x y) text "..." height <n>
               just "lowerLeft" orient "R0" font "fixed" ltype "normalLabel")
The whole file is ONE top-level list of those elements.
"""

import sys
import re
import math
import argparse
import xml.etree.ElementTree as ET


# ---------------------------------------------------------------------------
# 2x3 affine transforms  (point: x' = a*x + c*y + e ;  y' = b*x + d*y + f)
# ---------------------------------------------------------------------------
IDENTITY = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def mat_mul(p, q):
    """Compose parent p with child q (apply q first, then p)."""
    pa, pb, pc, pd, pe, pf = p
    qa, qb, qc, qd, qe, qf = q
    return (
        pa * qa + pc * qb,
        pb * qa + pd * qb,
        pa * qc + pc * qd,
        pb * qc + pd * qd,
        pa * qe + pc * qf + pe,
        pb * qe + pd * qf + pf,
    )


def mat_apply(m, x, y):
    a, b, c, d, e, f = m
    return (a * x + c * y + e, b * x + d * y + f)


_NUM_RE = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?")


def _nums(s):
    return [float(t) for t in _NUM_RE.findall(s or "")]


_TRANSFORM_RE = re.compile(r"(matrix|translate|scale|rotate|skewX|skewY)\s*\(([^)]*)\)")


def parse_transform(s):
    """Parse an SVG transform attribute into a single 2x3 matrix."""
    m = IDENTITY
    if not s:
        return m
    for name, body in _TRANSFORM_RE.findall(s):
        v = _nums(body)
        if name == "matrix" and len(v) == 6:
            t = tuple(v)
        elif name == "translate":
            tx = v[0] if v else 0.0
            ty = v[1] if len(v) > 1 else 0.0
            t = (1.0, 0.0, 0.0, 1.0, tx, ty)
        elif name == "scale":
            sx = v[0] if v else 1.0
            sy = v[1] if len(v) > 1 else sx
            t = (sx, 0.0, 0.0, sy, 0.0, 0.0)
        elif name == "rotate":
            ang = math.radians(v[0]) if v else 0.0
            ca, sa = math.cos(ang), math.sin(ang)
            t = (ca, sa, -sa, ca, 0.0, 0.0)
            if len(v) >= 3:
                cx, cy = v[1], v[2]
                t = mat_mul((1, 0, 0, 1, cx, cy), mat_mul(t, (1, 0, 0, 1, -cx, -cy)))
        elif name == "skewX":
            t = (1.0, 0.0, math.tan(math.radians(v[0] if v else 0.0)), 1.0, 0.0, 0.0)
        elif name == "skewY":
            t = (1.0, math.tan(math.radians(v[0] if v else 0.0)), 0.0, 1.0, 0.0, 0.0)
        else:
            t = IDENTITY
        m = mat_mul(m, t)
    return m


# ---------------------------------------------------------------------------
# Curve flattening
# ---------------------------------------------------------------------------
def _cubic_pt(p0, p1, p2, p3, t):
    u = 1.0 - t
    a = u * u * u
    b = 3 * u * u * t
    c = 3 * u * t * t
    d = t * t * t
    return (a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
            a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1])


def _quad_pt(p0, p1, p2, t):
    u = 1.0 - t
    a = u * u
    b = 2 * u * t
    c = t * t
    return (a * p0[0] + b * p1[0] + c * p2[0],
            a * p0[1] + b * p1[1] + c * p2[1])


def flatten_cubic(p0, p1, p2, p3, tol, max_seg):
    """Adaptive de Casteljau; returns interior+end points (not p0)."""
    out = []

    def rec(a, b, c, d, depth):
        # flatness = max control-point deviation from the a-d chord
        dev1 = _dist_to_line(b, a, d)
        dev2 = _dist_to_line(c, a, d)
        if (dev1 + dev2) <= tol or depth >= max_seg:
            out.append(d)
            return
        ab = _mid(a, b); bc = _mid(b, c); cd = _mid(c, d)
        abc = _mid(ab, bc); bcd = _mid(bc, cd)
        m = _mid(abc, bcd)
        rec(a, ab, abc, m, depth + 1)
        rec(m, bcd, cd, d, depth + 1)

    rec(p0, p1, p2, p3, 0)
    return out


def flatten_quad(p0, p1, p2, tol, max_seg):
    c1 = (p0[0] + 2.0 / 3.0 * (p1[0] - p0[0]), p0[1] + 2.0 / 3.0 * (p1[1] - p0[1]))
    c2 = (p2[0] + 2.0 / 3.0 * (p1[0] - p2[0]), p2[1] + 2.0 / 3.0 * (p1[1] - p2[1]))
    return flatten_cubic(p0, c1, c2, p2, tol, max_seg)


def _mid(a, b):
    return ((a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5)


def _dist_to_line(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    L = math.hypot(dx, dy)
    if L < 1e-12:
        return math.hypot(p[0] - a[0], p[1] - a[1])
    return abs((p[0] - a[0]) * dy - (p[1] - a[1]) * dx) / L


def arc_to_points(x1, y1, rx, ry, phi_deg, large, sweep, x2, y2, n):
    """SVG elliptical arc -> polyline points (excluding start). SVG spec F.6."""
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [(x2, y2)]
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(phi_deg % 360.0)
    cosp, sinp = math.cos(phi), math.sin(phi)
    dx2, dy2 = (x1 - x2) / 2.0, (y1 - y2) / 2.0
    x1p = cosp * dx2 + sinp * dy2
    y1p = -sinp * dx2 + cosp * dy2
    # correct out-of-range radii
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        s = math.sqrt(lam)
        rx *= s; ry *= s
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    co = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large == sweep:
        co = -co
    cxp = co * rx * y1p / ry
    cyp = -co * ry * x1p / rx
    cx = cosp * cxp - sinp * cyp + (x1 + x2) / 2.0
    cy = sinp * cxp + cosp * cyp + (y1 + y2) / 2.0

    def ang(ux, uy, vx, vy):
        d = math.hypot(ux, uy) * math.hypot(vx, vy)
        c = max(-1.0, min(1.0, (ux * vx + uy * vy) / d)) if d else 1.0
        a = math.acos(c)
        return -a if (ux * vy - uy * vx) < 0 else a

    th1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dth = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dth > 0:
        dth -= 2 * math.pi
    elif sweep and dth < 0:
        dth += 2 * math.pi
    steps = max(2, int(abs(dth) / (math.pi / max(2, n // 2))) + 1)
    pts = []
    for i in range(1, steps + 1):
        th = th1 + dth * (i / steps)
        ex = cosp * rx * math.cos(th) - sinp * ry * math.sin(th) + cx
        ey = sinp * rx * math.cos(th) + cosp * ry * math.sin(th) + cy
        pts.append((ex, ey))
    return pts


# ---------------------------------------------------------------------------
# Path "d" parsing -> list of subpaths (each a list of (x,y) in user space)
# ---------------------------------------------------------------------------
_CMD_RE = re.compile(r"([MmLlHhVvCcSsQqTtAaZz])|([-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?)")


def _tokenize_d(d):
    toks = []
    for cmd, num in _CMD_RE.findall(d or ""):
        toks.append(("cmd", cmd) if cmd else ("num", float(num)))
    return toks


def parse_path(d, tol, max_seg, arc_n):
    """Return a list of subpaths; each subpath = list of (x,y) user-space points."""
    toks = _tokenize_d(d)
    i, n = 0, len(toks)
    subpaths = []
    cur = []
    cx = cy = 0.0          # current point
    sx = sy = 0.0          # subpath start
    pcx = pcy = None       # last cubic control (for S)
    pqx = pqy = None       # last quad control (for T)
    cmd = None
    started = False        # has the initial point been established?

    def num():
        nonlocal i
        v = toks[i][1]; i += 1
        return v

    def have_num():
        return i < n and toks[i][0] == "num"

    while i < n:
        if toks[i][0] == "cmd":
            cmd = toks[i][1]; i += 1
        elif cmd is None:
            i += 1
            continue
        rel = cmd.islower()
        C = cmd.upper()

        if C == "M":
            x = num(); y = num()
            # relative moveto adds the current point UNLESS it's the path's
            # first command (incl. the relative `m` that follows a `z`, whose
            # current point is the just-closed subpath start).
            if rel and started:
                x += cx; y += cy
            if cur:
                subpaths.append(cur)
            cur = [(x, y)]
            cx, cy, sx, sy = x, y, x, y
            pcx = pqx = None
            started = True
            cmd = "l" if rel else "L"   # subsequent pairs are implicit lineto
        elif C == "L":
            x = num(); y = num()
            if rel:
                x += cx; y += cy
            cur.append((x, y)); cx, cy = x, y; pcx = pqx = None
        elif C == "H":
            x = num()
            if rel:
                x += cx
            cur.append((x, cy)); cx = x; pcx = pqx = None
        elif C == "V":
            y = num()
            if rel:
                y += cy
            cur.append((cx, y)); cy = y; pcx = pqx = None
        elif C == "C":
            x1 = num(); y1 = num(); x2 = num(); y2 = num(); x = num(); y = num()
            if rel:
                x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy
            cur.extend(flatten_cubic((cx, cy), (x1, y1), (x2, y2), (x, y), tol, max_seg))
            pcx, pcy = x2, y2; cx, cy = x, y; pqx = None
        elif C == "S":
            x2 = num(); y2 = num(); x = num(); y = num()
            if rel:
                x2 += cx; y2 += cy; x += cx; y += cy
            if pcx is None:
                x1, y1 = cx, cy
            else:
                x1, y1 = 2 * cx - pcx, 2 * cy - pcy
            cur.extend(flatten_cubic((cx, cy), (x1, y1), (x2, y2), (x, y), tol, max_seg))
            pcx, pcy = x2, y2; cx, cy = x, y; pqx = None
        elif C == "Q":
            x1 = num(); y1 = num(); x = num(); y = num()
            if rel:
                x1 += cx; y1 += cy; x += cx; y += cy
            cur.extend(flatten_quad((cx, cy), (x1, y1), (x, y), tol, max_seg))
            pqx, pqy = x1, y1; cx, cy = x, y; pcx = None
        elif C == "T":
            x = num(); y = num()
            if rel:
                x += cx; y += cy
            if pqx is None:
                x1, y1 = cx, cy
            else:
                x1, y1 = 2 * cx - pqx, 2 * cy - pqy
            cur.extend(flatten_quad((cx, cy), (x1, y1), (x, y), tol, max_seg))
            pqx, pqy = x1, y1; cx, cy = x, y; pcx = None
        elif C == "A":
            rx = num(); ry = num(); rot = num()
            large = num() != 0; sweep = num() != 0
            x = num(); y = num()
            if rel:
                x += cx; y += cy
            cur.extend(arc_to_points(cx, cy, rx, ry, rot, large, sweep, x, y, arc_n))
            cx, cy = x, y; pcx = pqx = None
        elif C == "Z":
            if cur:
                cur.append((sx, sy))
                subpaths.append(cur)
            cur = []
            cx, cy = sx, sy
            pcx = pqx = None
        else:
            i += 1
    if cur:
        subpaths.append(cur)
    return [sp for sp in subpaths if len(sp) >= 2]


# ---------------------------------------------------------------------------
# SVG element -> geometry
# ---------------------------------------------------------------------------
def _strip_ns(tag):
    return tag.split("}", 1)[1] if "}" in tag else tag


def _attr_num(el, name, default=0.0):
    v = el.get(name)
    if v is None:
        return default
    m = _NUM_RE.match(v.strip())
    return float(m.group()) if m else default


def ellipse_points(cx, cy, rx, ry, n):
    pts = []
    for i in range(n + 1):
        a = 2 * math.pi * i / n
        pts.append((cx + rx * math.cos(a), cy + ry * math.sin(a)))
    return pts


SKIP_TAGS = {"defs", "symbol", "marker", "clipPath", "mask", "pattern",
             "linearGradient", "radialGradient", "style", "metadata", "title", "desc"}


def walk(el, ctm, tol, max_seg, arc_n, ell_n, polylines, labels):
    tag = _strip_ns(el.tag)
    if tag in SKIP_TAGS:
        return
    ctm = mat_mul(ctm, parse_transform(el.get("transform")))

    def emit(subpaths):
        for sp in subpaths:
            polylines.append([mat_apply(ctm, x, y) for (x, y) in sp])

    if tag == "path":
        emit(parse_path(el.get("d"), tol, max_seg, arc_n))
    elif tag == "line":
        x1 = _attr_num(el, "x1"); y1 = _attr_num(el, "y1")
        x2 = _attr_num(el, "x2"); y2 = _attr_num(el, "y2")
        emit([[(x1, y1), (x2, y2)]])
    elif tag in ("polyline", "polygon"):
        v = _nums(el.get("points"))
        pts = list(zip(v[0::2], v[1::2]))
        if tag == "polygon" and pts:
            pts = pts + [pts[0]]
        emit([pts])
    elif tag == "rect":
        x = _attr_num(el, "x"); y = _attr_num(el, "y")
        w = _attr_num(el, "width"); h = _attr_num(el, "height")
        if w > 0 and h > 0:
            emit([[(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)]])
    elif tag == "circle":
        r = _attr_num(el, "r")
        if r > 0:
            emit([ellipse_points(_attr_num(el, "cx"), _attr_num(el, "cy"), r, r, ell_n)])
    elif tag == "ellipse":
        rx = _attr_num(el, "rx"); ry = _attr_num(el, "ry")
        if rx > 0 and ry > 0:
            emit([ellipse_points(_attr_num(el, "cx"), _attr_num(el, "cy"), rx, ry, ell_n)])
    elif tag == "text":
        txt = "".join(el.itertext()).strip()
        if txt:
            x = _attr_num(el, "x"); y = _attr_num(el, "y")
            fs = _attr_num(el, "font-size", 16.0)
            px, py = mat_apply(ctm, x, y)
            # crude transform of the font size (uniform-ish scale magnitude)
            sm = math.sqrt(abs(ctm[0] * ctm[3] - ctm[1] * ctm[2])) or 1.0
            labels.append((px, py, txt, fs * sm))

    for child in el:
        walk(child, ctm, tol, max_seg, arc_n, ell_n, polylines, labels)


# ---------------------------------------------------------------------------
# IR emit (SKILL list literal)
# ---------------------------------------------------------------------------
def fnum(v):
    if v is None or (isinstance(v, float) and (math.isnan(v) or math.isinf(v))):
        return "0.0"
    if abs(v) < 1e-9:
        return "0.0"
    s = "%.6f" % v
    if "." in s:
        s = s.rstrip("0")
        if s.endswith("."):
            s += "0"
    return s


def esc(s):
    out = s.replace("\\", "\\\\").replace('"', '\\"')
    return "".join(c if 32 <= ord(c) < 127 else " " for c in out)


def emit_shape(points):
    body = " ".join("(%s %s)" % (fnum(x), fnum(y)) for (x, y) in points)
    return '(nil kind shape stype "line" lstyle "solid" points (%s) width nil)' % body


def emit_label(x, y, text, height):
    return ('(nil kind label point (%s %s) text "%s" height %s '
            'just "lowerLeft" orient "R0" font "fixed" ltype "normalLabel")'
            % (fnum(x), fnum(y), esc(text), fnum(height)))


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main(argv):
    ap = argparse.ArgumentParser(description="SVG -> note-helper IR (SKILL literal)")
    ap.add_argument("infile")
    ap.add_argument("outfile")
    ap.add_argument("--width", type=float, default=5.0,
                    help="target width in user units (aspect preserved); default 5.0")
    ap.add_argument("--height", type=float, default=0.0,
                    help="target height instead of width (aspect preserved)")
    ap.add_argument("--font-height", type=float, default=0.0,
                    help="override label height (user units); 0 = derive from SVG font-size")
    ap.add_argument("--curve-tol", type=float, default=0.0015,
                    help="curve flatness tolerance as a fraction of the figure diagonal")
    ap.add_argument("--max-seg", type=int, default=18, help="max recursion depth per Bezier")
    ap.add_argument("--arc-n", type=int, default=24, help="arc sampling hint")
    ap.add_argument("--ellipse-n", type=int, default=48, help="points per circle/ellipse")
    args = ap.parse_args(argv)

    try:
        tree = ET.parse(args.infile)
    except Exception as e:
        sys.stderr.write("nh_svg2ir: cannot parse %s: %s\n" % (args.infile, e))
        return 2
    root = tree.getroot()

    # estimate a flatness tolerance from the rough coordinate extent first, so
    # curve resolution is independent of the SVG's unit scale.
    allnums = _nums(ET.tostring(root, encoding="unicode"))
    span = (max(allnums) - min(allnums)) if allnums else 100.0
    tol = max(span * args.curve_tol, 1e-9)

    polylines, labels = [], []
    walk(root, IDENTITY, tol, args.max_seg, args.arc_n, args.ellipse_n, polylines, labels)
    polylines = [p for p in polylines if len(p) >= 2]

    # global bbox over all geometry + label anchors
    xs, ys = [], []
    for p in polylines:
        for (x, y) in p:
            xs.append(x); ys.append(y)
    for (x, y, _t, _h) in labels:
        xs.append(x); ys.append(y)
    if not xs:
        with open(args.outfile, "w") as f:
            f.write("()\n")
        sys.stderr.write("nh_svg2ir: no drawable geometry found\n")
        return 0
    minx, maxx = min(xs), max(xs)
    miny, maxy = min(ys), max(ys)
    bw = max(maxx - minx, 1e-9)
    bh = max(maxy - miny, 1e-9)

    if args.height > 0:
        sc = args.height / bh
    else:
        sc = args.width / bw

    def tx(x, y):
        # normalise to origin, scale uniformly, flip Y (SVG y-down -> schematic y-up)
        return ((x - minx) * sc, (maxy - y) * sc)

    elems = []
    for p in polylines:
        elems.append(emit_shape([tx(x, y) for (x, y) in p]))
    for (x, y, t, h) in labels:
        gx, gy = tx(x, y)
        gh = args.font_height if args.font_height > 0 else (h * sc)
        if gh <= 0:
            gh = 0.125
        elems.append(emit_label(gx, gy, t, gh))

    with open(args.outfile, "w") as f:
        f.write("(\n" + "\n".join(elems) + "\n)\n")

    sys.stderr.write("nh_svg2ir: %d shapes, %d labels, scale=%.5g, bbox=%.4gx%.4g -> %.4gx%.4g\n"
                     % (len(polylines), len(labels), sc, bw, bh, bw * sc, bh * sc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
