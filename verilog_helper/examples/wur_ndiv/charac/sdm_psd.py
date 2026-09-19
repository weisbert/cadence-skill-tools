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

Only numpy is required.  Usage:
    python3 sdm_psd.py perr_w300.txt [more files ...] [--fmin 1e-3] [--fmax 1e-2]
                                     [--order 3] [--tol 12] [--csv out.csv]
"""
import sys, argparse
import numpy as np


def load(path):
    v = []
    with open(path) as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            v.append(float(ln.split()[0]))
    return np.asarray(v, dtype=float)


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


def psd(e, wkind):
    """single-sided periodogram of e (normalised sample rate fs = 1 -> f in cycles/sample)"""
    n = len(e)
    w = window(n, wkind)
    x = (e - e.mean()) * w
    X = np.fft.rfft(x)
    p = (np.abs(X) ** 2) / (np.sum(w ** 2))
    f = np.fft.rfftfreq(n, d=1.0)
    return f[1:], p[1:]          # drop DC


def slope_fit(f, p, fmin, fmax):
    m = (f >= fmin) & (f <= fmax) & (p > 0)
    if m.sum() < 8:
        return None, m.sum()
    x = np.log10(f[m])
    y = 10.0 * np.log10(p[m])
    A = np.vstack([x, np.ones_like(x)]).T
    sol, *_ = np.linalg.lstsq(A, y, rcond=None)
    return float(sol[0]), int(m.sum())     # dB per decade


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--fmin", type=float, default=1e-3, help="low edge of the fit band, in f/fs")
    ap.add_argument("--fmax", type=float, default=1e-2, help="high edge (one decade above fmin)")
    ap.add_argument("--order", type=float, default=3.0, help="expected modulator order")
    ap.add_argument("--tol", type=float, default=12.0, help="slope tolerance [dB/dec]")
    ap.add_argument("--window", choices=["auto", "bh4", "kaiser"], default="auto")
    ap.add_argument("--csv", default=None, help="write the averaged PSD of the LAST file here")
    args = ap.parse_args()

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
              % (path.split("/")[-1], n, e.mean(), e.std(), wkind, nb, s, s/20.0,
                 "PASS" if ok else "FAIL", fmin, fmax, np.log10(fmax/fmin), want, args.tol))
        if args.csv:
            np.savetxt(args.csv, np.column_stack([f, p]), header="f_over_fs  psd", comments="# ")
    print("=== PSD PASS ===" if nfail == 0 else "=== PSD FAIL (%d) ===" % nfail)
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
