#!/usr/bin/env python3
"""
sdm_psd.py -- noise-shaping check for the WuR NDIV MASH 1-1-1 period sequence.

Input : perr_<tag>.txt written by tb_wur_sdm (one integer per line = one OUT_NDIV period,
        in NDIVCKIN cycles; '#' lines are a header).
Model : period_k = N_int - 1 + y_k  and  y_k = F + (1-z^-1)^3 * E3_k  (MASH 1-1-1), so the
        period-error sequence e_k = period_k - mean(period) carries a PURE 3rd-order-shaped
        quantization noise.  |(1-z^-1)^3|^2 ~ f^6  =>  the PSD rises at +60 dB/decade.
Check : fit the PSD slope over one decade in the low-frequency region and compare with
        20*order dB/dec (order = 3 -> +60 dB/dec).

numpy is used when present.  Without it (an air-gapped box with a bare python3) the SAME
maths runs on a pure-stdlib backend: a Bluestein chirp-z DFT (arbitrary N, e.g. the prime
N=8191 record) on top of an iterative radix-2 FFT, a stdlib Kaiser/Blackman-Harris window
and a closed-form least-squares fit.  Both backends give the same slope (verified: +59.2
dB/dec on perr_w300_f7373.txt); the pure-python one just takes a few seconds instead of
a few milliseconds.  `--backend py` forces it, `--backend numpy` fails if numpy is absent.

Usage:
    python3 sdm_psd.py perr_w300.txt [more files ...] [--fmin 1e-3] [--fmax 1e-2]
                                     [--order 3] [--tol 12] [--csv out.csv]
                                     [--backend auto|numpy|py]
"""
import sys, argparse, math

try:
    import numpy as np
    HAVE_NUMPY = True
except ImportError:                      # red zone may ship a bare python3
    np = None
    HAVE_NUMPY = False

USE_NUMPY = HAVE_NUMPY      # --backend may turn this off


def load(path):
    v = []
    with open(path) as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            v.append(float(ln.split()[0]))
    return np.asarray(v, dtype=float) if USE_NUMPY else v


def bh4(n):
    """4-term minimum Blackman-Harris window, sidelobes -92 dB."""
    a = (0.35875, 0.48829, 0.14128, 0.01168)
    k = np.arange(n)
    return (a[0] - a[1]*np.cos(2*np.pi*k/n) + a[2]*np.cos(4*np.pi*k/n)
            - a[3]*np.cos(6*np.pi*k/n))


# WINDOW LEAKAGE IS THE TRAP HERE.  A 3rd-order-shaped spectrum rises 60 dB/decade, so over
# the ~2.6 decades from f/fs=1e-3 to Nyquist it spans ~160 dB.  A Blackman-Harris window
# (-92 dB sidelobes) lets the high-frequency energy leak into the low-frequency bins and
# flattens the measured slope to ~+39 dB/dec -- a false "2nd order" reading.  A Kaiser
# window with beta=24 (sidelobes ~ -230 dB) removes it; its main lobe is ~9 bins wide, so
# the fit band must start at least ~16 bins up.  Short records (< 2048) cannot afford the
# wide main lobe and are fitted with Blackman-Harris at higher frequencies instead.
def window(n, kind):
    return bh4(n) if kind == "bh4" else np.kaiser(n, 24.0)


def _psd_np(e, wkind):
    """single-sided periodogram of e (normalised sample rate fs = 1 -> f in cycles/sample)"""
    n = len(e)
    w = window(n, wkind)
    x = (e - e.mean()) * w
    X = np.fft.rfft(x)
    p = (np.abs(X) ** 2) / (np.sum(w ** 2))
    f = np.fft.rfftfreq(n, d=1.0)
    return f[1:], p[1:]          # drop DC


def _slope_fit_np(f, p, fmin, fmax):
    m = (f >= fmin) & (f <= fmax) & (p > 0)
    if m.sum() < 8:
        return None, m.sum()
    x = np.log10(f[m])
    y = 10.0 * np.log10(p[m])
    A = np.vstack([x, np.ones_like(x)]).T
    sol, *_ = np.linalg.lstsq(A, y, rcond=None)
    return float(sol[0]), int(m.sum())     # dB per decade


# =============================================================================
# PURE-STDLIB BACKEND  (no numpy -- for an air-gapped box with a bare python3)
# Same maths, same windows, same fit; only the arithmetic engine differs.
# =============================================================================
def _i0(x):
    """modified Bessel I0 via its power series -- matches numpy's i0 to ~1e-15."""
    s, t, k = 1.0, 1.0, 0
    while True:
        k += 1
        t *= (x / (2.0 * k)) ** 2
        s += t
        if t < 1e-18 * s or k > 400:
            return s


def _kaiser_py(n, beta):
    """np.kaiser(n, beta), in stdlib."""
    if n == 1:
        return [1.0]
    alpha = (n - 1) / 2.0
    den = _i0(beta)
    return [_i0(beta * math.sqrt(max(0.0, 1.0 - ((k - alpha) / alpha) ** 2))) / den
            for k in range(n)]


def _bh4_py(n):
    a = (0.35875, 0.48829, 0.14128, 0.01168)
    return [a[0] - a[1]*math.cos(2*math.pi*k/n) + a[2]*math.cos(4*math.pi*k/n)
            - a[3]*math.cos(6*math.pi*k/n) for k in range(n)]


def _window_py(n, kind):
    return _bh4_py(n) if kind == "bh4" else _kaiser_py(n, 24.0)


def _fft_pow2(a, tw, inverse=False):
    """in-place iterative radix-2 FFT; tw = exact exp(-2j*pi*k/n) table, len n//2."""
    n = len(a)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    length = 2
    while length <= n:
        half = length >> 1
        step = n // length
        for i in range(0, n, length):
            for k in range(half):
                w = tw[k * step]
                if inverse:
                    w = w.conjugate()
                u = a[i + k]
                v = a[i + k + half] * w
                a[i + k] = u + v
                a[i + k + half] = u - v
        length <<= 1
    if inverse:
        inv = 1.0 / n
        for i in range(n):
            a[i] *= inv
    return a


def _twiddle(n):
    return [complex(math.cos(-2.0*math.pi*k/n), math.sin(-2.0*math.pi*k/n))
            for k in range(n // 2)]


def _dft_py(x):
    """DFT of ARBITRARY length n.  Power of two -> radix-2; otherwise Bluestein's
    chirp-z transform (the 8191-point record is a Mersenne PRIME, so a plain radix-2
    is not an option and an O(n^2) DFT would take minutes)."""
    n = len(x)
    if n & (n - 1) == 0:
        return _fft_pow2([complex(v) for v in x], _twiddle(n))
    m = 1
    while m < 2 * n - 1:
        m <<= 1
    # chirp w_k = exp(-i*pi*k^2/n); k^2 is reduced mod 2n to keep full precision
    w = []
    for k in range(n):
        ang = -math.pi * ((k * k) % (2 * n)) / n
        w.append(complex(math.cos(ang), math.sin(ang)))
    a = [x[k] * w[k] for k in range(n)] + [0j] * (m - n)
    b = [0j] * m
    for k in range(n):
        c = w[k].conjugate()
        b[k] = c
        if k:
            b[m - k] = c
    tw = _twiddle(m)
    fa = _fft_pow2(a, tw)
    fb = _fft_pow2(b, tw)
    fc = [fa[i] * fb[i] for i in range(m)]
    cc = _fft_pow2(fc, tw, inverse=True)
    return [cc[k] * w[k] for k in range(n)]


def _psd_py(e, wkind):
    n = len(e)
    w = _window_py(n, wkind)
    mu = sum(e) / n
    x = [(e[i] - mu) * w[i] for i in range(n)]
    X = _dft_py(x)
    norm = sum(v * v for v in w)
    nf = n // 2 + 1
    p = [(X[k].real ** 2 + X[k].imag ** 2) / norm for k in range(nf)]
    f = [k / float(n) for k in range(nf)]
    return f[1:], p[1:]          # drop DC


def _slope_fit_py(f, p, fmin, fmax):
    xs, ys = [], []
    for i in range(len(f)):
        if fmin <= f[i] <= fmax and p[i] > 0:
            xs.append(math.log10(f[i]))
            ys.append(10.0 * math.log10(p[i]))
    nb = len(xs)
    if nb < 8:
        return None, nb
    sx = sum(xs); sy = sum(ys)
    sxx = sum(v * v for v in xs); sxy = sum(xs[i] * ys[i] for i in range(nb))
    den = nb * sxx - sx * sx
    if den == 0.0:
        return None, nb
    return (nb * sxy - sx * sy) / den, nb   # dB per decade


# ------------------------------------------------------------------ dispatch
def psd(e, wkind):
    return _psd_np(e, wkind) if USE_NUMPY else _psd_py(e, wkind)


def slope_fit(f, p, fmin, fmax):
    return _slope_fit_np(f, p, fmin, fmax) if USE_NUMPY else _slope_fit_py(f, p, fmin, fmax)


def stats(e):
    """mean, std -- numpy's own when available (keeps that path bit-identical)."""
    if USE_NUMPY:
        return float(e.mean()), float(e.std())
    n = len(e)
    mu = sum(e) / n
    return mu, math.sqrt(sum((v - mu) ** 2 for v in e) / n)


def write_csv(path, f, p):
    if USE_NUMPY:
        np.savetxt(path, np.column_stack([f, p]), header="f_over_fs  psd", comments="# ")
    else:
        with open(path, "w") as fh:
            fh.write("# f_over_fs  psd\n")
            for i in range(len(f)):
                fh.write("%.18e %.18e\n" % (f[i], p[i]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--fmin", type=float, default=1e-3, help="low edge of the fit band, in f/fs")
    ap.add_argument("--fmax", type=float, default=1e-2, help="high edge (one decade above fmin)")
    ap.add_argument("--order", type=float, default=3.0, help="expected modulator order")
    ap.add_argument("--tol", type=float, default=12.0, help="slope tolerance [dB/dec]")
    ap.add_argument("--window", choices=["auto", "bh4", "kaiser"], default="auto")
    ap.add_argument("--csv", default=None, help="write the averaged PSD of the LAST file here")
    ap.add_argument("--backend", choices=["auto", "numpy", "py"], default="auto",
                    help="auto = numpy when importable, else the pure-stdlib backend")
    args = ap.parse_args()

    global USE_NUMPY
    if args.backend == "numpy":
        if not HAVE_NUMPY:
            print("PSD    ERROR --backend numpy but numpy is not importable on this python3")
            return 2
        USE_NUMPY = True
    elif args.backend == "py":
        USE_NUMPY = False
    else:
        USE_NUMPY = HAVE_NUMPY
    if not USE_NUMPY:
        print("PSDNOTE numpy not in use -- pure-stdlib Bluestein FFT backend "
              "(same result, a few seconds per record)")

    want = 20.0 * args.order
    nfail = 0
    print("PSDHDR %-24s %6s %8s %7s %6s %5s %8s %7s %s" %
          ("file", "N", "mean", "std", "win", "bins", "slope", "order", "verdict"))
    for path in args.files:
        e = load(path)
        if len(e) < 64:
            print("PSD    %-28s N=%d too short for a PSD fit -- SKIP" % (path, len(e)))
            continue
        n = len(e)
        wkind = args.window
        if wkind == "auto":
            wkind = "kaiser" if n >= 2048 else "bh4"
        emean, estd = stats(e)
        f, p = psd(e, wkind)
        # keep the fit band clear of the window main lobe, and below Nyquist
        fmin = max(args.fmin, (16.0 if wkind == "kaiser" else 6.0) / n)
        fmax = min(max(args.fmax, 10.0 * fmin), 0.4)
        if fmax / fmin < 3.0:
            print("PSD    %-24s N=%d too short for a slope fit (band [%.1e,%.1e]) -- SKIP"
                  % (path, n, fmin, fmax))
            continue
        s, nb = slope_fit(f, p, fmin, fmax)
        if s is None:
            print("PSD    %-28s not enough bins in [%.1e,%.1e] (%d)" % (path, fmin, fmax, nb))
            nfail += 1
            continue
        ok = abs(s - want) <= args.tol
        nfail += 0 if ok else 1
        print("PSD    %-24s %6d %8.3f %7.4f %6s %5d %+8.1f %7.2f %s  (band f/fs=[%.1e,%.1e], %.2f dec, want %+0.0f+/-%0.0f dB/dec)"
              % (path.split("/")[-1], n, emean, estd, wkind, nb, s, s/20.0,
                 "PASS" if ok else "FAIL", fmin, fmax, math.log10(fmax/fmin), want, args.tol))
        if args.csv:
            write_csv(args.csv, f, p)
    print("=== PSD PASS ===" if nfail == 0 else "=== PSD FAIL (%d) ===" % nfail)
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
