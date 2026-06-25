#!/usr/bin/env python3
"""vh_dut -- multi-DUT driver. One folder per DUT, each verified independently.

Layout (a "DUT" is just a folder; everything is auto-detected, dut.json overrides):

  duts/
    DUT1/                      # OA-config driven
      expand.cfg  cds.lib      #   -> Stage A (oa2verilog, or a captured netlist) -> B -> C
      [checks.json | a test file]
    DUT2/                      # hand-dropped sources (your workflow: drag .v in)
      foo.v  bar.va            #   -> straight to Stage C
      mydut_tb.v               #   a test file -> used as the testbench (--tb)
    DUT3/
      dut.json                 # explicit overrides for any of the below

Auto-detection per DUT folder:
  - config   : dut.json.config | expand.cfg | config/expand.cfg          -> Stage A
  - netlist  : dut.json.netlist | *_raw.v | netlist.v | oa_netlist/*.v   -> Stage A --netlist (no OA)
  - test     : dut.json.tb | tb.v* | *_tb.v* | test.v* | *_test.v*       -> vh_gen --tb (your own test)
  - checks   : dut.json.checks | checks.json                             -> generated self-checking TB
  - sources  : every .v/.va/.vams in the folder minus the test/netlist/_vh
  - ext libs : dut.json.ext_lib[]                                        -> vh_gen --ext-lib

Outputs go to <dut>/_vh/{A, build, package}; the DUT folder stays yours.

CLI:
  python3 vh_dut.py run <dutdir> [--package]
  python3 vh_dut.py run-all <root> [--package]
  python3 vh_dut.py list <root>
"""
import sys, os, re, json, glob, argparse, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vh_parse as vp

SRC_EXT = (".v", ".va", ".vams")
TEST_PATS = [r'(?i)^tb\.', r'(?i)^tb_', r'(?i)_tb\.', r'(?i)^test\.', r'(?i)_test\.',
             r'(?i)^testbench\.']
NETLIST_PATS = [r'_raw\.v$', r'(?i)^netlist\.v$']


def _first(globs):
    for g in globs:
        hits = sorted(glob.glob(g))
        if hits:
            return hits[0]
    return None


def detect(dutdir):
    """Inspect a DUT folder; return a spec dict (dut.json overrides auto-detection)."""
    spec = {"name": os.path.basename(os.path.abspath(dutdir.rstrip("/"))),
            "dir": os.path.abspath(dutdir)}
    over = {}
    j = os.path.join(dutdir, "dut.json")
    if os.path.isfile(j):
        try:
            over = json.load(open(j))
        except ValueError as e:
            spec["error"] = "bad dut.json: %s" % e
    spec["name"] = over.get("name", spec["name"])

    def _ov(val):   # a dut.json override is bare/relative-to-dutdir; found paths are already full
        if not val:
            return None
        return os.path.abspath(val if os.path.isabs(val) else os.path.join(dutdir, val))

    def _found(p):
        return os.path.abspath(p) if p else None

    # config
    spec["config"] = _ov(over.get("config")) or _found(_first(
        [os.path.join(dutdir, "expand.cfg"), os.path.join(dutdir, "config", "expand.cfg")]))
    # captured netlist (lets Stage A skip OA)
    nl = None
    if not over.get("netlist"):
        for p in NETLIST_PATS:
            cands = [f for f in glob.glob(os.path.join(dutdir, "**", "*.v"), recursive=True)
                     if re.search(p, os.path.basename(f))]
            if cands:
                nl = sorted(cands)[0]; break
    spec["netlist"] = _ov(over.get("netlist")) or _found(nl)
    # test file
    tb = None
    if not over.get("tb"):
        for f in sorted(glob.glob(os.path.join(dutdir, "*"))):
            b = os.path.basename(f)
            if any(re.search(p, b) for p in TEST_PATS) and b.endswith(SRC_EXT):
                tb = f; break
    spec["tb"] = _ov(over.get("tb")) or _found(tb)
    spec["tb_top"] = over.get("tb_top")
    # checks
    spec["checks"] = _ov(over.get("checks")) or _found(_first([os.path.join(dutdir, "checks.json")]))
    spec["top"] = over.get("top")
    spec["cell"] = over.get("cell")
    spec["cdslib"] = over.get("cdslib")
    spec["ext_lib"] = over.get("ext_lib", [])
    spec["no_convert"] = over.get("no_convert", False)

    # hand-dropped sources = .v/.va/.vams in the dir, minus test/netlist/_vh
    excl = {os.path.abspath(x) for x in (spec["tb"], spec["netlist"]) if x}
    srcs = []
    for ext in SRC_EXT:
        for f in glob.glob(os.path.join(dutdir, "**", "*" + ext), recursive=True):
            ap = os.path.abspath(f)
            if "_vh" + os.sep in ap or ap in excl:
                continue
            srcs.append(ap)
    spec["sources"] = sorted(set(srcs))
    spec["mode"] = "config" if spec["config"] else ("src" if spec["sources"] else None)
    return spec


def detect_tb_top(tb_path):
    """Best-effort sim top of a user test: a module named tb/test/testbench, else the
    unique top, else 'tb'."""
    try:
        mods = vp.parse_text(open(tb_path, errors="replace").read(), tb_path)
    except Exception:
        return "tb"
    names = [m["module"] for m in mods]
    for pref in ("tb", "testbench", "test"):
        for n in names:
            if n.lower() == pref:
                return n
    g = vp.build_graph(mods, {m["module"]: m for m in mods})
    return g["tops"][0] if len(g["tops"]) == 1 else (names[0] if names else "tb")


def _run(cmd, log):
    with open(log, "w") as lf:
        p = subprocess.run(cmd, stdout=lf, stderr=subprocess.STDOUT)
    return p.returncode


def run_dut(spec, do_package=False):
    """Run the pipeline for one detected DUT. Returns a result dict."""
    res = {"name": spec["name"], "mode": spec["mode"],
           "test": "user" if spec["tb"] else ("checks" if spec["checks"] else "smoke"),
           "result": "ERROR", "detail": "", "externals": []}
    if spec.get("error"):
        res["detail"] = spec["error"]; return res
    if not spec["mode"]:
        res["detail"] = "no config and no .v/.va sources found"; return res

    vh = os.path.join(spec["dir"], "_vh")
    os.makedirs(vh, exist_ok=True)
    py = sys.executable

    # --- Stage A (+ B) for config-driven DUTs --------------------------------
    if spec["mode"] == "config":
        adir = os.path.join(vh, "A")
        cmd = [py, os.path.join(HERE, "vh_extract.py"), "--config", spec["config"], "--out", adir]
        if spec["netlist"]:
            cmd += ["--netlist", spec["netlist"]]
        if spec["cdslib"]:
            cmd += ["--cdslib", spec["cdslib"]]
        if spec["cell"]:
            cmd += ["--cell", spec["cell"]]
        if _run(cmd, os.path.join(vh, "A.log")):
            res["detail"] = "Stage A failed (see _vh/A.log)"; return res
        # Stage B: convert gathered leaves to digital in export/, don't touch the shared lib
        if not spec["no_convert"]:
            man_a = os.path.join(adir, "manifest_A.json")
            if _run([py, os.path.join(HERE, "vh_convert.py"), "--manifest", man_a, "--no-cell-write"],
                    os.path.join(vh, "B.log")):
                res["detail"] = "Stage B failed (see _vh/B.log)"; return res
            try:
                mb = json.load(open(os.path.join(adir, "manifest_B.json")))
                flagged = [c["module"] for c in mb.get("cells", []) if c["status"] == "flagged"]
                if flagged:
                    res["flagged"] = flagged
            except (OSError, ValueError):
                pass
        src_args = ["--src", os.path.join(adir, "export")]
    else:
        src_args = []
        for s in spec["sources"]:
            src_args += ["--src", s]

    # --- Stage C -------------------------------------------------------------
    build = os.path.join(vh, "build")
    cmd = [py, os.path.join(HERE, "vh_gen.py")] + src_args + ["--out", build]
    if spec["top"]:
        cmd += ["--top", spec["top"]]
    if spec["tb"]:
        tb_top = spec["tb_top"] or detect_tb_top(spec["tb"])
        cmd += ["--tb", spec["tb"], "--tb-top", tb_top]
    elif spec["checks"]:
        cmd += ["--checks", spec["checks"]]
    for lib in spec["ext_lib"]:
        cmd += ["--ext-lib", lib]
    if _run(cmd, os.path.join(vh, "C.log")):
        res["detail"] = "Stage C failed (see _vh/C.log)"; return res
    try:
        mc = json.load(open(os.path.join(build, "manifest.json")))
        res["externals"] = [e["module"] for e in mc.get("external_stubbed", [])] + \
                           ["%s(resolved)" % e["module"] for e in mc.get("external_resolved", [])]
        res["top"] = mc.get("top")
    except (OSError, ValueError):
        pass

    # --- Stage D (optional) --------------------------------------------------
    if do_package:
        if _run([py, os.path.join(HERE, "vh_package.py"), "--build", build,
                 "--out", os.path.join(vh, "package")], os.path.join(vh, "D.log")):
            res["detail"] = "Stage D (package) failed (see _vh/D.log)"; return res
        res["packaged"] = True

    # --- run ----------------------------------------------------------------
    runlog = os.path.join(vh, "run.log")
    rc = _run(["bash", os.path.join(build, "run.sh")], runlog)
    txt = open(runlog, errors="replace").read()
    if re.search(r'=== TB PASS', txt):
        res["result"], res["detail"] = "PASS", ""
    elif re.search(r'=== TB FAIL', txt):
        res["result"], res["detail"] = "FAIL", "mismatch (see _vh/run.log)"
    else:
        res["result"], res["detail"] = "ERROR", "no PASS/FAIL (rc=%d, see _vh/run.log)" % rc
    return res


def find_duts(root):
    out = []
    for d in sorted(glob.glob(os.path.join(root, "*"))):
        if not os.path.isdir(d) or os.path.basename(d).startswith((".", "_")):
            continue
        s = detect(d)
        if s["mode"]:
            out.append(s)
    return out


def print_summary(results):
    W = max([len(r["name"]) for r in results] + [6])
    print("=" * 78)
    print("MULTI-DUT SUMMARY")
    print("=" * 78)
    print("%-*s  %-6s  %-6s  %-7s  %s" % (W, "DUT", "mode", "test", "result", "detail"))
    print("-" * 78)
    npass = 0
    for r in sorted(results, key=lambda x: x["name"]):
        npass += r["result"] == "PASS"
        extra = r["detail"]
        if r.get("flagged"):
            extra = (extra + "  " if extra else "") + "needs-manual: %s" % ",".join(r["flagged"])
        print("%-*s  %-6s  %-6s  %-7s  %s" % (W, r["name"], r["mode"] or "-",
              r["test"], r["result"], extra))
    print("-" * 78)
    print("%d/%d PASS" % (npass, len(results)))
    return npass == len(results)


def main():
    ap = argparse.ArgumentParser(description="multi-DUT driver (one folder per DUT)")
    ap.add_argument("cmd", choices=["run", "run-all", "list"])
    ap.add_argument("path", help="a DUT dir (run) or a root of DUT dirs (run-all/list)")
    ap.add_argument("--package", action="store_true", help="also build the air-gap package")
    args = ap.parse_args()

    if args.cmd == "list":
        duts = find_duts(args.path)
        for s in duts:
            print("%-20s mode=%-6s config=%s tb=%s checks=%s srcs=%d" % (
                s["name"], s["mode"], os.path.basename(s["config"]) if s["config"] else "-",
                os.path.basename(s["tb"]) if s["tb"] else "-",
                os.path.basename(s["checks"]) if s["checks"] else "-", len(s["sources"])))
        print("\n%d DUT(s)" % len(duts))
        return

    if args.cmd == "run":
        res = run_dut(detect(args.path), do_package=args.package)
        ok = print_summary([res])
        sys.exit(0 if ok else 1)

    duts = find_duts(args.path)
    if not duts:
        sys.exit("no DUT folders found under %s" % args.path)
    results = [run_dut(s, do_package=args.package) for s in duts]
    ok = print_summary(results)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
