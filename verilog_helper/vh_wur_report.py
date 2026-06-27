#!/usr/bin/env python3
"""vh_wur_report.py -- one-shot verification report for the WuR NDIV testbench
(NDIV_TOP_v7_svt_0p5W, module `tb`).

Runs the generated sim (run.sh) WITH waveforms, prints + saves a PASS/FAIL table
(grouped by mode), and captures *genuine Cadence SimVision* waveform screenshots,
fully headless (Xvfb), no interactive GUI needed. Built for the air-gapped red zone:
pure stdlib + Cadence tools already on PATH.

    python3 vh_wur_report.py [--sim DIR] [--no-run] [--display :88]

<sim> must contain run.sh (the auto-generated one is fine -- it uses -top tb and the
real -v COT libs) and the TB must be the committed tb_NDIV_TOP_v7_svt_0p5W.vams
(module `tb`), which emits the RPTINFO + MODEWIN markers this tool reads to auto-zoom.

Writes into <sim>/report/:
    report.md            verification table + path map + embedded waveform images
    wave_overview.png    full run -- 5 mode bands; which paths are live where
    wave_norm.png        WuR-NORMAL : OUT_NDIV/CLK2DSM=VCO/16/(ndiv-1), OUT_ADCDIV=VCO/4/(adcdiv-1)
    wave_lpbt.png        LPBT       : OUT_NDIV=VCO/4/(ndiv-1), ADCDIV frozen
    wave_cal.png         CAL        : CLK2CNT=VCO/4
    wave_test.png        TEST       : TESTCLK_300M=VCO/16
    wave_pdn.png         POWER-DOWN : all outputs clamped to clean 0
    layout_*.tcl         SimVision layout scripts (for manual `simvision` use)

Screenshots need: simvision (Cadence, on PATH) + Xvfb + python PIL. If any is missing,
the table + layout_*.tcl are still produced and the manual command is printed:
    simvision <sim>/ndiv.shm -input <sim>/report/layout_norm.tcl
"""
import argparse, os, re, subprocess, sys, time

TB_TOP  = "tb"
# top-level TB signals to show (waveform row order): controls first, then the 5 outputs.
SIGNALS = ["lpbt_en", "cal_en", "en_test", "ndiv_en",
           "OUT_NDIV", "CLK2DSM", "CLK2CNT", "TESTCLK_300M", "OUT_ADCDIV"]
CROP    = (0, 0, 1010, 600)

# mode-header name (in xrun.log "== <name> ...")  ->  (png key, MODEWIN key)
MODE_KEY = {"WuR-NORMAL": ("norm", "NORM"), "LPBT-mode": ("lpbt", "LPBT"),
            "CAL": ("cal", "CAL"), "TEST": ("test", "TEST"), "POWER-DOWN": ("pdn", "PDN")}


def sh(cmd, cwd=None, env=None, timeout=None):
    return subprocess.run(cmd, cwd=cwd, env=env, timeout=timeout,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def _which(x, env=None):
    path = (env or os.environ).get("PATH", "")
    return any(os.access(os.path.join(p, x), os.X_OK)
               for p in path.split(os.pathsep) if p)


# ---------------------------------------------------------------- run + parse
def run_sim(simdir):
    print("[1/3] running: bash run.sh +define+WAVES")
    r = sh(["bash", "run.sh", "+define+WAVES"], cwd=simdir, timeout=3600)
    sys.stdout.write(r.stdout[-600:] if r.stdout else "")
    return os.path.join(simdir, "xrun.log")


def parse_log(logpath):
    """-> (rows, finish_ps, info, mwin).
       rows = [(mode,label,status,detail)]; info = {fvco,D_WUR,D_LPBT,D_ADC};
       mwin = {MODEWIN_KEY: (start_ps, end_ps)}."""
    rows, mode, finish = [], "?", None
    info = {"fvco": 4.8, "D_WUR": 800, "D_LPBT": 200, "D_ADC": 656}
    mwin = {}
    mre = re.compile(r"^==\s*(.+?)\s*(?:\(|:|==)")
    cre = re.compile(r"^\s+(PASS|FAIL|WARN|INFO)\s+(.*)$")
    fre = re.compile(r"(?:\$finish|complete).*?at time\s+([0-9.]+)\s*([fnum]?s)", re.I)
    ire = re.compile(r"RPTINFO\s+fvco_ghz=([0-9.]+)\s+D_WUR=(\d+)\s+D_LPBT=(\d+)\s+D_ADC=(\d+)")
    wre = re.compile(r"MODEWIN\s+(\S+)\s+([0-9.]+)\s+([0-9.]+)")
    for ln in open(logpath, errors="replace"):
        i = ire.search(ln)
        if i:
            info = {"fvco": float(i.group(1)), "D_WUR": int(i.group(2)),
                    "D_LPBT": int(i.group(3)), "D_ADC": int(i.group(4))}; continue
        w = wre.search(ln)
        if w:
            mwin[w.group(1)] = (float(w.group(2)), float(w.group(3))); continue
        m = mre.search(ln)
        if m and m.group(1) in MODE_KEY:
            mode = m.group(1); continue
        c = cre.match(ln.rstrip("\n"))
        if c:
            stat, rest = c.group(1), c.group(2).strip()
            label, _, detail = rest.partition(":")
            rows.append((mode, label.strip() or rest, stat, detail.strip()))
        f = fre.search(ln)
        if f:
            v = float(f.group(1)); u = (f.group(2) or "ps").lower()
            finish = v * {"s": 1e12, "ms": 1e9, "us": 1e6, "ns": 1e3, "ps": 1.0, "fs": 1e-3}.get(u, 1.0)
    return rows, (finish or 0.0), info, mwin


# ---------------------------------------------------------------- SimVision capture
def write_layout(path, shm, mn_ns, mx_ns):
    sigs = " \\\n  ".join("ndiv::%s.%s" % (TB_TOP, s) for s in SIGNALS)
    open(path, "w").write(
        "database require ndiv -open %s\n"
        "set w [waveform new -name NDIV]\n"
        "waveform using $w\n"
        "waveform add -signals [list \\\n  %s ]\n"
        "waveform xview limits %gns %gns\n" % (shm, sigs, mn_ns, mx_ns))


def _grab(disp, out):
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


def sim_env(simdir):
    env = dict(os.environ)
    if os.path.exists(os.path.join(simdir, "setup_env.sh")):
        r = sh(["bash", "-c", ". ./setup_env.sh >/dev/null 2>&1; env"], cwd=simdir)
        for ln in (r.stdout or "").splitlines():
            if "=" in ln and not ln.startswith(("BASH_FUNC", "}")):
                k, v = ln.split("=", 1); env[k] = v
    return env


def capture(simdir, repdir, name, mn_ns, mx_ns, disp, env):
    shm = os.path.join(simdir, "ndiv.shm")
    tcl = os.path.join(repdir, "layout_%s.tcl" % name)
    png = os.path.join(repdir, "wave_%s.png" % name)
    write_layout(tcl, shm, mn_ns, mx_ns)
    if not _which("simvision", env):
        return png, False
    xv = None
    if _which("Xvfb", env):
        lock = "/tmp/.X%s-lock" % disp.lstrip(":")
        try: os.remove(lock)
        except OSError: pass
        xv = subprocess.Popen(["Xvfb", disp, "-screen", "0", "1100x650x24"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(3)
    elif os.environ.get("DISPLAY"):
        disp = os.environ["DISPLAY"]
    else:
        return png, False
    svenv = dict(env, DISPLAY=disp)
    sv = subprocess.Popen(["simvision", shm, "-input", tcl], cwd=simdir, env=svenv,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(24)
    ok = _grab(disp, png)
    for p in (sv, xv):
        try: p.terminate()
        except Exception: pass
    time.sleep(1)
    return png, ok


# ---------------------------------------------------------------- windows
def windows(T_ps, info, mwin):
    """Per-mode zoom windows (ns) ending at each mode's measured window end (settled).
    Width = a few cycles of the signal of interest in that mode."""
    tv = 1.0 / info["fvco"]                       # VCO period [ns]
    width_ns = {"norm": 5.0 * info["D_WUR"]  * tv,    # ~5 OUT_NDIV periods
                "lpbt": 5.0 * info["D_LPBT"] * tv,
                "cal":  16.0 * 4  * tv,               # ~16 CLK2CNT (VCO/4) cycles
                "test": 16.0 * 16 * tv,               # ~16 TESTCLK (VCO/16) cycles
                "pdn":  300.0 * tv}                   # a flat slab, proves "no clock"
    out = [("overview", 0.0, T_ps / 1000.0)]
    for hdr, (png, mk) in MODE_KEY.items():
        if mk in mwin:
            start, end = mwin[mk][0] / 1000.0, mwin[mk][1] / 1000.0   # ps -> ns
            w = width_ns.get(png, 200.0)
            out.append((png, max(start, end - w), end))
    return out


# ---------------------------------------------------------------- report
def report_md(rows, T_ps, info, pngs, fails):
    verdict = "TB PASS" if fails == 0 else "TB FAIL"
    L = ["# NDIV_TOP_v7_svt_0p5W (WuR NDIV) -- verification report", "",
         "Pure-digital VerilogAMS run via xrun (no spectre), VCO = %g GHz. "
         "Verdict: **%s** (%d fail).  sim end = %g ns." % (info["fvco"], verdict, fails, T_ps / 1000.0),
         "", "Operating point: ndiv=51,pwsel=28 (OUT_NDIV=VCO/%d); adcdiv=165,adcpwsel=20 "
         "(OUT_ADCDIV=VCO/%d)." % (info["D_WUR"], info["D_ADC"]), "",
         "## Checks (what is verified, per mode)", "",
         "| Mode | Check | Result | Measured |", "|---|---|---|---|"]
    for mode, label, stat, detail in rows:
        L.append("| %s | %s | **%s** | %s |" % (mode, label, stat, detail.replace("|", "/")))
    L += ["", "## Path map (which clocks are live per mode)", "",
          "| Signal | WuR-NORMAL (lpbt=0) | LPBT (lpbt=1) | CAL (cal=1) | TEST (test=1) | POWER-DOWN |",
          "|---|---|---|---|---|---|",
          "| OUT_NDIV | **VCO/16/(ndiv-1)** | **VCO/4/(ndiv-1)** | VCO/16/(ndiv-1) | VCO/16/(ndiv-1) | 0 (clamp) |",
          "| CLK2DSM | = OUT_NDIV | = OUT_NDIV | = OUT_NDIV | = OUT_NDIV | 0 |",
          "| CLK2CNT | static-hi | static-hi | **VCO/4** | static-hi | 0 |",
          "| TESTCLK_300M | low | low | low | **VCO/16** | 0 |",
          "| OUT_ADCDIV | **VCO/4/(adcdiv-1)** | frozen | = NORM | = NORM | 0 |",
          "",
          "## Laws (sim-confirmed)",
          "- Prescaler select: `lpbt_en=1`->NDIVCKIN=VCO/4 ; `lpbt_en=0`->VCO/16.",
          "- Divide: OUT_NDIV=NDIVCKIN/(ndiv-1) ; OUT_ADCDIV=VCO/4/(adcdiv-1).",
          "- NDIV pulse-width: low=2*floor(pwsel/2)-3 (NDIVCKIN); 50% @ pwsel=(ndiv+5)/2, exact ndiv%4==3.",
          "- ADCDIV pulse-width: low=2*floor(adcpwsel/2)+62 (q6>=1 needs adcdiv>=adcpwsel+64); 50% @ adcpwsel=(adcdiv-1)/2-62.",
          "", "## Waveforms (SimVision)", ""]
    cap = {"overview": "Full run -- the 5 mode bands (lpbt_en/cal_en/en_test/ndiv_en); which outputs toggle where.",
           "norm": "WuR-NORMAL: OUT_NDIV & CLK2DSM = VCO/16/(ndiv-1) (50% duty); OUT_ADCDIV = VCO/4/(adcdiv-1).",
           "lpbt": "LPBT mode (lpbt_en=1): OUT_NDIV & CLK2DSM = VCO/4/(ndiv-1); ADCDIV frozen.",
           "cal":  "CAL (cal_en=1): CLK2CNT = VCO/4 monitor; NDIV keeps dividing.",
           "test": "TEST (en_test=1): TESTCLK_300M = VCO/16 (=300 MHz @ 4.8 GHz).",
           "pdn":  "POWER-DOWN (ndiv_en=0): all five outputs clamped to a clean 0 (no toggling, no X)."}
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
    rows, T, info, mwin = parse_log(log)
    fails = sum(1 for _, _, s, _ in rows if s == "FAIL")

    print("[2/3] verification table")
    print("  %-11s %-38s %-5s %s" % ("MODE", "CHECK", "STAT", "MEASURED"))
    for mode, label, stat, detail in rows:
        print("  %-11s %-38s %-5s %s" % (mode[:11], label[:38], stat, detail[:30]))
    print("  --> %s (%d fail)" % ("TB PASS" if fails == 0 else "TB FAIL", fails))

    print("[3/3] capturing SimVision waveforms (headless)")
    env = sim_env(simdir)
    pngs = []
    for name, mn, mx in windows(T, info, mwin):
        png, ok = capture(simdir, repdir, name, mn, mx, args.display, env)
        print("  %-9s %8.1f..%-9.1f ns  %s" % (name, mn, mx, "OK" if ok else "(layout only)"))
        pngs.append((name, png, ok))

    md = os.path.join(repdir, "report.md")
    open(md, "w").write(report_md(rows, T, info, pngs, fails))
    print("\nwrote %s" % md)
    if not all(ok for _, _, ok in pngs):
        print("NOTE: some screenshots not auto-captured (need simvision+Xvfb+PIL). The layout .tcl are\n"
              "      in report/; capture manually:  simvision ndiv.shm -input report/layout_norm.tcl")


if __name__ == "__main__":
    main()
