#!/usr/bin/env python3
"""vh_diag -- one-shot diagnostics for a verilog_helper build (Stage A export + Stage C sim).

Reads the build dir (the Output folder that holds export/ + sim/), parses every gathered
.va/.vams + the generated stubs + TB, and cross-checks the whole netlist the way xrun's
elaborator does -- so the things that blow up at elaboration show up here in ONE file you
can copy/paste instead of running greps by hand:

  * PORT MISMATCH  -- an instance connects `.X(net)` but its master module has no port X
                      (the `*E,CUVPOM "Port name 'X' is invalid"` cause: symbol-pin vs
                      gathered/descended-module-port mismatch, e.g. power pins VPP/VDD).
  * UNRESOLVED     -- a master is instantiated but defined nowhere (not gathered, not in a
                      -v lib, not stubbed): the `*E,CUVMUR ... unresolved` cause. With
                      --cdslib it also reports whether the cell HAS a veriloga/verilogams
                      on disk (=> should be gatherable) or not (=> will be stubbed).
  * manifest highlights (top, #leaves, externals resolved/stubbed, bus warnings) and a
    digest of the xrun.log *E/*F lines (unique code -> count + first example).

Pure stdlib; runs on dev or the red zone. CLI:
  python3 vh_diag.py --build <out>            # <out> holds export/ and sim/
  python3 vh_diag.py --build <out>/sim        # a sim/ dir is fine too (uses its parent)
  options: --cdslib <cds.lib> (enable on-disk veriloga check for UNRESOLVED)
           --out <report.txt>  (default <build>/vh_diag.txt)
"""
import sys, os, re, json, glob, argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vh_parse as vp
import vh_extract as vx


def collect_sources(out_dir):
    """Return (export_dir, sim_dir, [source files]) for a build output dir."""
    export = os.path.join(out_dir, "export")
    sim = os.path.join(out_dir, "sim")
    sim = sim if os.path.isdir(sim) else out_dir
    files = []
    for d in (export, sim):
        if os.path.isdir(d):
            for pat in ("*.vams", "*.va"):
                files += glob.glob(os.path.join(d, pat))
    return export, sim, sorted(set(files))


def module_names_in(path):
    """Cheap module-name scan of a (possibly huge) -v library file."""
    try:
        txt = open(path, errors="replace").read()
    except OSError:
        return set()
    return set(re.findall(r'\bmodule\s+(\\?\w+)', txt))


def main():
    ap = argparse.ArgumentParser(description="one-shot diagnostics for a verilog_helper build")
    ap.add_argument("--build", required=True, help="build Output dir (holds export/ + sim/), or a sim/ dir")
    ap.add_argument("--cdslib", help="cds.lib -> enables on-disk veriloga/verilogams check for unresolved masters")
    ap.add_argument("--out", help="report path (default <build>/vh_diag.txt)")
    args = ap.parse_args()

    out_dir = os.path.abspath(args.build)
    if not os.path.isdir(os.path.join(out_dir, "export")) \
            and os.path.isdir(os.path.join(os.path.dirname(out_dir), "export")):
        out_dir = os.path.dirname(out_dir)          # a sim/ dir was passed
    export, sim, files = collect_sources(out_dir)

    L = []
    def p(*a): L.append(" ".join(str(x) for x in a))

    p("=" * 78)
    p("vh_diag -- build diagnostics")
    p("build dir :", out_dir)
    p("export    :", export if os.path.isdir(export) else "(missing)")
    p("sim       :", sim if os.path.isdir(sim) else "(missing)")
    p("=" * 78)

    if not files:
        p("\nERROR: no .va/.vams sources under export/ or sim/. Did Stage A/C run?")
        report = "\n".join(L)
        print(report)
        return

    # ---- parse every source into a module index -------------------------------------
    index, dup = {}, []
    by_file = {}
    for f in files:
        mods = vp.parse_text(open(f, errors="replace").read(), f)
        by_file[f] = [m["module"] for m in mods]
        for mi in mods:
            if mi["module"] in index:
                dup.append((mi["module"], f, index[mi["module"]]["file"]))
            else:
                index[mi["module"]] = mi

    # ---- manifests ------------------------------------------------------------------
    manA = {}
    for cand in (os.path.join(out_dir, "manifest_A.json"),):
        if os.path.isfile(cand):
            try:
                manA = json.load(open(cand))
            except ValueError:
                pass
    manC = {}
    for cand in (os.path.join(sim, "manifest.json"), os.path.join(out_dir, "manifest.json")):
        if os.path.isfile(cand):
            try:
                manC = json.load(open(cand))
                break
            except ValueError:
                pass

    # ---- defined-elsewhere names: -v libraries + dropped primitives ------------------
    ext_env = manA.get("ext_env", {}) or {}
    v_names = set()
    for lf in ext_env.get("lib_files", []):
        v_names |= module_names_in(lf)
    primitives = (vx.PIN_CELLS | vx.STIMULUS_CELLS | vx.NOCONN_CELLS
                  | vx.DEVICE_DROP | vx.PASSIVE_CELLS)
    defined = set(index) | v_names | primitives

    # ---- cds.lib for on-disk veriloga check (optional) ------------------------------
    libs = None
    if args.cdslib and os.path.isfile(args.cdslib):
        try:
            libs = vx.parse_cdslib(args.cdslib)
        except Exception:
            libs = None

    # ---- walk every instance --------------------------------------------------------
    unresolved = {}        # master -> [host.inst, ...]
    mismatches = {}        # master -> {port: [host.inst, ...]}
    for host, mi in sorted(index.items()):
        for it in mi["instances"]:
            mas = it["master"]
            inst = "%s.%s" % (host, it["inst"])
            if mas not in defined:
                unresolved.setdefault(mas, []).append(inst)
                continue
            tgt = index.get(mas)
            if not tgt:
                continue                       # defined in a -v lib: ports not checked here
            tports = set(tgt["ports"])
            named = (it.get("conns") or {}).get("named") or {}
            for port in named:                 # named connection .port(net)
                if port not in tports:
                    mismatches.setdefault(mas, {}).setdefault(port, []).append(inst)

    # ---- SUMMARY --------------------------------------------------------------------
    p("\n## SUMMARY")
    if manA:
        d = manA.get("design", {})
        p("  Stage A design : %s.%s:%s" % (d.get("lib"), d.get("cell"), d.get("view")))
        p("  gathered leaves: %d   (incl. %d structural-verilogams sub-cells)"
          % (len(manA.get("veriloga_leaves", [])), len(manA.get("gathered_subcells", []))))
    if manC:
        res = [e["module"] for e in manC.get("external_resolved", [])]
        stub = [e["module"] for e in manC.get("external_stubbed", [])]
        p("  Stage C top    : %s   (sim top=%s)" % (manC.get("top"), manC.get("sim_top")))
        p("  externals -v   : %d  %s" % (len(res), res or ""))
        p("  externals stub : %d  %s" % (len(stub), stub or ""))
    p("  parsed modules : %d  (from %d files)" % (len(index), len(files)))
    p("  >>> %d UNRESOLVED master(s), %d master(s) with PORT MISMATCHES <<<"
      % (len(unresolved), len(mismatches)))

    # ---- UNRESOLVED -----------------------------------------------------------------
    p("\n## UNRESOLVED MASTERS  (instantiated but defined nowhere -> *E,CUVMUR)")
    if not unresolved:
        p("  (none)")
    for mas in sorted(unresolved):
        hits = unresolved[mas]
        note = ""
        if libs is not None:
            vlib, vpath = vx.find_veriloga(mas, libs)
            if vpath:
                note = "  -> HAS %s on disk in lib '%s' (should be gathered: %s)" % (
                    os.path.basename(os.path.dirname(vpath)), vlib, vpath)
            else:
                sl, sv = vx.find_schematic_view(mas, libs)
                note = ("  -> no veriloga/verilogams; schematic '%s' in '%s' (descend or stub)"
                        % (sv, sl)) if sv else "  -> not found on disk (give it a -v lib, or it gets stubbed)"
        p("  %-34s x%d   e.g. %s%s" % (mas, len(hits), hits[0], note))

    # ---- PORT MISMATCHES ------------------------------------------------------------
    p("\n## PORT MISMATCHES  (instance connects .X but master has no port X -> *E,CUVPOM)")
    if not mismatches:
        p("  (none)")
    for mas in sorted(mismatches):
        tgt = index[mas]
        bad = mismatches[mas]
        p("  master '%s'  (defined in %s)" % (mas, os.path.relpath(tgt["file"], out_dir)))
        p("    actual ports (%d): %s" % (len(tgt["ports"]), ", ".join(tgt["ports"]) or "(none)"))
        p("    connected-but-absent ports: %s" % ", ".join(sorted(bad)))
        for port in sorted(bad):
            p("      .%-16s  <- e.g. %s  (x%d)" % (port, bad[port][0], len(bad[port])))

    # ---- duplicate defs -------------------------------------------------------------
    if dup:
        p("\n## DUPLICATE MODULE DEFINITIONS  (same name in >1 file -> xrun may error)")
        for nm, f2, f1 in dup:
            p("  %-28s %s  (also %s)" % (nm, os.path.relpath(f2, out_dir),
                                         os.path.relpath(f1, out_dir)))

    # ---- xrun.log digest ------------------------------------------------------------
    xlog = os.path.join(sim, "xrun.log")
    if os.path.isfile(xlog):
        codes = {}
        for line in open(xlog, errors="replace"):
            m = re.search(r'\*[EWF],([A-Z0-9]+)', line)
            if m:
                codes.setdefault(m.group(1), []).append(line.strip())
        p("\n## xrun.log MESSAGE DIGEST  (%s)" % xlog)
        if not codes:
            ok = any("=== TB PASS" in l for l in open(xlog, errors="replace"))
            p("  (no *E/*W/*F codes)%s" % ("   TB PASS" if ok else ""))
        for code in sorted(codes, key=lambda c: -len(codes[c])):
            p("  *?,%-8s x%-4d  e.g. %s" % (code, len(codes[code]), codes[code][0][:140]))

    p("\n" + "=" * 78)
    p("Copy this whole file back. Report: %s" % (args.out or os.path.join(out_dir, "vh_diag.txt")))
    p("=" * 78)

    report = "\n".join(L)
    rpath = args.out or os.path.join(out_dir, "vh_diag.txt")
    try:
        open(rpath, "w").write(report + "\n")
    except OSError:
        pass
    print(report)


if __name__ == "__main__":
    main()
