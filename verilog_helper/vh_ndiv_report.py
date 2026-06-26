#!/usr/bin/env python3
"""vh_ndiv_report.py -- one-shot verification report for the LPBT_NDIV testbench.

Runs the generated sim (run.sh) WITH waveforms, prints + saves a PASS/FAIL table
(what was checked and the result, grouped by mode), and captures *genuine Cadence
SimVision* waveform screenshots -- fully headless (Xvfb), no interactive GUI session
needed. Built for the air-gapped red zone: pure stdlib + Cadence tools already there.

    python3 vh_ndiv_report.py [--sim DIR] [--no-run] [--display :88]

Writes into <sim>/report/:
    report.md            verification table + result + embedded waveform images
    wave_overview.png    full run -- which paths are live in CAL / TEST / NORM
    wave_cal.png         CAL  zoom -- CLK2CNT = VCO/4
    wave_test.png        TEST zoom -- TESTCLK_300M = VCO/16 + OUT_NDIV running
    wave_norm.png        NORM zoom -- OUT_NDIV + CLK2DSM (50% duty, phase offset)
    layout_*.tcl         SimVision layout scripts (for manual `simvision` use)

Screenshots need: simvision (Cadence, on PATH) + Xvfb + python PIL. If any is missing
the table + layout_*.tcl are still produced and the exact manual command is printed:
    simvision <sim>/ndiv.shm -input <sim>/report/layout_norm.tcl
"""
import argparse, os, re, subprocess, sys, time

# top-level TB signals to show (order = waveform row order)
SIGNALS = ["cal_en", "en_test", "CLK2CNT", "TESTCLK_300M", "OUT_NDIV", "CLK2DSM"]
TB_TOP  = "tb_LPBT_NDIV_TOP"
CROP    = (0, 0, 1010, 600)   # SimVision default window box on a 1100x650 root


def sh(cmd, cwd=None, env=None, timeout=None):
    return subprocess.run(cmd, cwd=cwd, env=env, timeout=timeout,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


# ---------------------------------------------------------------- run + parse
def run_sim(simdir):
    print("[1/3] running: bash run.sh +define+WAVES")
    r = sh(["bash", "run.sh", "+define+WAVES"], cwd=simdir, timeout=1800)
    sys.stdout.write(r.stdout[-400:] if r.stdout else "")
    return os.path.join(simdir, "xrun.log")


def parse_log(logpath):
    """-> (rows, finish_ns, fvco_ghz, D). rows = [(mode,label,status,detail)]."""
    rows, mode, finish, fvco, D = [], "?", None, None, None
    mre = re.compile(r"^==\s*(CAL|TEST|NORM)\b")
    cre = re.compile(r"^\s+(PASS|FAIL|WARN|INFO)\s+(.*)$")
    fre = re.compile(r"(?:\$finish|complete).*?at time\s+([0-9.]+)\s*([fnum]?s)", re.I)
    qre = re.compile(r"VCO\s*=\s*([0-9.]+)\s*GHz")
    dre = re.compile(r"OUT_NDIV\s*=\s*VCO/4/\(ndiv-1\).*?VCO/([0-9]+)")
    for ln in open(logpath, errors="replace"):
        m = mre.search(ln)
        if m:
            mode = m.group(1); continue
        c = cre.match(ln.rstrip("\n"))
        if c:
            stat, rest = c.group(1), c.group(2).strip()
            label, _, detail = rest.partition(":")
            rows.append((mode, label.strip() or rest, stat, detail.strip()))
        q = qre.search(ln)
        if q: fvco = float(q.group(1))
        d = dre.search(ln)
        if d: D = int(d.group(1))
        f = fre.search(ln)
        if f:
            v = float(f.group(1)); u = (f.group(2) or "ns").lower()
            finish = v * {"s": 1e9, "ms": 1e6, "us": 1e3, "ns": 1.0, "fs": 1e-6}.get(u, 1.0)
    return rows, (finish or 2440.0), fvco, D


# ---------------------------------------------------------------- SimVision capture
def write_layout(path, shm, mn, mx):
    sigs = " \\\n  ".join("ndiv::%s.%s" % (TB_TOP, s) for s in SIGNALS)
    open(path, "w").write(
        "database require ndiv -open %s\n"
        "set w [waveform new -name NDIV]\n"
        "waveform using $w\n"
        "waveform add -signals [list \\\n  %s ]\n"
        "waveform xview limits %s %s\n" % (shm, sigs, mn, mx))


def _grab(disp, out):
    """Grab the X display to a cropped PNG. PIL first, then import/xwd."""
    try:
        from PIL import ImageGrab
        ImageGrab.grab(xdisplay=disp).crop(CROP).save(out)
        return True
    except Exception:
        pass
    if _which("import"):
        if sh(["import", "-display", disp, "-window", "root", out]).returncode == 0:
            return os.path.exists(out)
    return False


def _which(x, env=None):
    path = (env or os.environ).get("PATH", "")
    return any(os.access(os.path.join(p, x), os.X_OK)
               for p in path.split(os.pathsep) if p)


def sim_env(simdir):
    """Source the sim's setup_env.sh so simvision/xrun land on PATH (like run.sh does)."""
    env = dict(os.environ)
    if os.path.exists(os.path.join(simdir, "setup_env.sh")):
        r = sh(["bash", "-c", ". ./setup_env.sh >/dev/null 2>&1; env"], cwd=simdir)
        for ln in (r.stdout or "").splitlines():
            if "=" in ln and not ln.startswith(("BASH_FUNC", "}")):
                k, v = ln.split("=", 1); env[k] = v
    return env


def capture(simdir, repdir, name, mn, mx, disp, env):
    shm = os.path.join(simdir, "ndiv.shm")
    tcl = os.path.join(repdir, "layout_%s.tcl" % name)
    png = os.path.join(repdir, "wave_%s.png" % name)
    write_layout(tcl, shm, mn, mx)
    if not _which("simvision", env):
        return png, False
    xv = None
    if _which("Xvfb", env):                       # headless: own virtual display
        lock = "/tmp/.X%s-lock" % disp.lstrip(":")
        try: os.remove(lock)
        except OSError: pass
        xv = subprocess.Popen(["Xvfb", disp, "-screen", "0", "1100x650x24"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(3)
    elif os.environ.get("DISPLAY"):               # fall back to a live X session
        disp = os.environ["DISPLAY"]
    else:
        return png, False                         # no way to render -> layout only
    svenv = dict(env, DISPLAY=disp)
    sv = subprocess.Popen(["simvision", shm, "-input", tcl], cwd=simdir, env=svenv,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(24)                       # SimVision load + render
    ok = _grab(disp, png)
    for p in (sv, xv):
        try: p.terminate()
        except Exception: pass
    time.sleep(1)
    return png, ok


# ---------------------------------------------------------------- report
def windows(T, fvco, D):
    """Per-mode zoom windows (ns), each ending near its mode's end (settled).
    Widths scale to the signal shown: a few cycles of CLK2CNT(VCO/4) / TESTCLK(VCO/16)
    / OUT_NDIV(VCO/D). Falls back to fixed widths if fvco/D weren't parsed."""
    third = T / 3.0
    tv = (1.0 / fvco) if fvco else 0.2                 # VCO period [ns]
    dd = D or 40
    wcal  = max(8.0,  12 * 4  * tv)                    # ~12 CLK2CNT cycles
    wtest = max(40.0, 1.6 * dd * tv)                   # ~1.6 OUT periods (TESTCLK is fast)
    wnorm = max(60.0, 4.0 * dd * tv)                   # ~4 OUT periods
    def win(k, w):
        end = (k + 1) * third * 0.985                  # near mode end, settled
        return "%gns" % max(0.0, end - w), "%gns" % end
    return [("overview", "0", "%gns" % T),
            ("cal",  *win(0, wcal)),
            ("test", *win(1, wtest)),
            ("norm", *win(2, wnorm))]


def report_md(rows, T, pngs, fails):
    L = ["# LPBT_NDIV_TOP -- verification report", "",
         "Pure-digital VerilogAMS run via xrun (no spectre). Verdict: **%s** (%d fail).  sim end = %g ns." %
         ("TB PASS" if fails == 0 else "TB FAIL", fails, T), "",
         "## Checks (what is verified, per mode)", "",
         "| Mode | Check | Result | Measured |", "|---|---|---|---|"]
    for mode, label, stat, detail in rows:
        L.append("| %s | %s | **%s** | %s |" % (mode, label, stat, detail.replace("|", "/")))
    L += ["", "## Path map (which clocks are live per mode)", "",
          "| Signal | CAL (cal_en=1) | TEST (en_test=1) | NORM |", "|---|---|---|---|",
          "| CLK2CNT | **VCO/4** (on) | static-hi (off) | static-hi (off) |",
          "| TESTCLK_300M | low (off) | **VCO/16** (on) | low (off) |",
          "| OUT_NDIV | quiet (off) | **VCO/4/(ndiv-1)** (on) | **VCO/4/(ndiv-1)** (on) |",
          "| CLK2DSM (SDMOUT) | quiet (off) | **VCO/4/(ndiv-1)** (on) | **VCO/4/(ndiv-1)** (on) |",
          "", "## Waveforms (SimVision)", ""]
    cap = {"overview": "Full run -- mode structure (cal_en/en_test bands; which outputs toggle).",
           "cal": "CAL: CLK2CNT = VCO/4; OUT_NDIV/CLK2DSM/TESTCLK quiet.",
           "test": "TEST: TESTCLK_300M = VCO/16; OUT_NDIV/CLK2DSM running.",
           "norm": "NORM: OUT_NDIV + CLK2DSM = VCO/4/(ndiv-1); OUT_NDIV 50% duty; SDMOUT lags 8.5 VCO."}
    for name, png, ok in pngs:
        L += ["**%s** %s" % (name, cap.get(name, "")),
              ("![%s](%s)" % (name, os.path.basename(png))) if ok else
              ("_(screenshot not captured -- run: `simvision ndiv.shm -input report/layout_%s.tcl`)_" % name),
              ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", default=".", help="sim dir (has run.sh); default cwd")
    ap.add_argument("--no-run", action="store_true", help="reuse existing xrun.log + ndiv.shm")
    ap.add_argument("--display", default=":88", help="headless X display for Xvfb")
    args = ap.parse_args()
    simdir = os.path.abspath(args.sim)
    repdir = os.path.join(simdir, "report"); os.makedirs(repdir, exist_ok=True)

    log = os.path.join(simdir, "xrun.log")
    if not args.no_run:
        log = run_sim(simdir)
    rows, T, fvco, D = parse_log(log)
    fails = sum(1 for _, _, s, _ in rows if s == "FAIL")

    print("[2/3] verification table")
    print("  %-5s %-34s %-5s %s" % ("MODE", "CHECK", "STAT", "MEASURED"))
    for mode, label, stat, detail in rows:
        print("  %-5s %-34s %-5s %s" % (mode, label[:34], stat, detail[:34]))
    print("  --> %s (%d fail)" % ("TB PASS" if fails == 0 else "TB FAIL", fails))

    print("[3/3] capturing SimVision waveforms (headless)")
    env = sim_env(simdir)
    pngs = []
    for name, mn, mx in windows(T, fvco, D):
        png, ok = capture(simdir, repdir, name, mn, mx, args.display, env)
        print("  %-9s %s  %s" % (name, "%s..%s" % (mn, mx), "OK" if ok else "(layout only)"))
        pngs.append((name, png, ok))

    md = os.path.join(repdir, "report.md")
    open(md, "w").write(report_md(rows, T, pngs, fails))
    print("\nwrote %s" % md)
    if not all(ok for _, _, ok in pngs):
        print("NOTE: some screenshots not auto-captured (need simvision+Xvfb+PIL). Layout .tcl are\n"
              "      in report/; capture manually with:  simvision ndiv.shm -input report/layout_norm.tcl")


if __name__ == "__main__":
    main()
