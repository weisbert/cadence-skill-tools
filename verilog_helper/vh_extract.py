#!/usr/bin/env python3
"""vh_extract -- Stage A: OA schematic config -> structural top + gathered .va + manifest.

Pipeline position (see HANDOFF.md):
  A  read config (cds.lib + expand.cfg) -> expand DUT hierarchy via oa2verilog ->
     classify each instantiated master -> strip netlist artifacts (OA pins, TB
     stimulus) -> gather veriloga leaf bodies -> emit a CLEAN structural top + a
     manifest that Stage B/C consume.

Two phases, deliberately decoupled so the pure-python part is portable/testable:
  1. NETLIST  (needs OA: IC618 oa2verilog) -> a raw structural .v. Skippable with
     --netlist <file> (reuse a captured netlist; also how the red zone / tests run).
  2. PROCESS  (pure stdlib python) -> classify, clean, gather, manifest.

Master classification (oa2verilog emits an empty interface module for every master
whose schematic it could not descend into -- i.e. leaf cells, externals, and pin
artifacts; structural masters come out with real instance bodies):
  STRUCTURAL    has >=1 surviving instance         -> kept in the clean top
  VERILOGA-LEAF empty + a veriloga view on disk    -> dropped from top, .va gathered
  EXTERNAL      empty + no veriloga found           -> recorded (Stage C stubs it)
  PIN           ipin/opin/iopin                     -> dropped (OA netlist artifact)
  STIMULUS      analogLib source/ground (TB)        -> dropped + warned

A DUT whose schematic is a pin-only stub collapses to an empty clean top -> Stage A
flags "nothing to verify" loudly (this is the real state of PMU_top on the dev box).

CLI:
  python3 vh_extract.py --config <expand.cfg> --out <dir> [--cdslib <cds.lib>]
                        [--lib L --cell C --view V]   # override the config's design
                        [--netlist <file>]            # reuse a netlist, skip oa2verilog
  python3 vh_extract.py --lib L --cell C [--view schematic] --cdslib <cds.lib> --out <dir>
"""
import sys, os, re, json, argparse, subprocess, shutil

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vh_parse as vp

# --- OA / Spectre env for oa2verilog on this RHEL8 box (see oa2verilog-rhel8-recipe) ---
DEFAULT_ENV_SH = "/home/yusheng/cadence_work/Test/workarea/LDO_modeling/cadence/env.sh"
OA_ENV = {"OA_UNSUPPORTED_PLAT": "linux_rhel60", "CDS_ENABLE_EXP_PCELL": "1"}

# netlist artifacts to strip (def + every instance of them)
PIN_CELLS = {"ipin", "opin", "iopin"}
# analogLib stimulus / globals that show up only when you netlist a TESTBENCH
STIMULUS_CELLS = {
    "vdc", "vpulse", "vsin", "vexp", "vpwl", "vpwlf", "vpwlfile", "vsource",
    "idc", "ipulse", "isin", "isource", "vcvs", "vccs", "cccs", "ccvs",
    "vcvs2", "port", "gnd", "vgnd", "vsource2",
}


# --------------------------------------------------------------------------- #
# cds.lib                                                                      #
# --------------------------------------------------------------------------- #
def parse_cdslib(path, _seen=None):
    """Recursively resolve a cds.lib into {libName: absLibPath}.

    Honors DEFINE / INCLUDE / SOFTINCLUDE (SOFT* relative to the including file's
    dir; a missing SOFT* include is skipped, a missing hard INCLUDE warns).
    """
    libs = {}
    if _seen is None:
        _seen = set()
    path = os.path.abspath(path)
    if path in _seen or not os.path.isfile(path):
        return libs
    _seen.add(path)
    base = os.path.dirname(path)
    for raw in open(path, errors="replace"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        toks = line.split()
        kw = toks[0].upper()
        if kw == "DEFINE" and len(toks) >= 3:
            libs[toks[1]] = os.path.abspath(os.path.join(base, toks[2]))
        elif kw in ("INCLUDE", "SOFTINCLUDE") and len(toks) >= 2:
            inc = toks[1]
            inc = inc if os.path.isabs(inc) else os.path.join(base, inc)
            if os.path.isfile(inc):
                child = parse_cdslib(inc, _seen)
                for k, v in child.items():
                    libs.setdefault(k, v)
            elif kw == "INCLUDE":
                sys.stderr.write("  [cds.lib] WARNING: INCLUDE not found: %s\n" % inc)
    return libs


def find_cdslib(start):
    """Walk up from a config file/dir to the nearest cds.lib."""
    d = os.path.abspath(start)
    if os.path.isfile(d):
        d = os.path.dirname(d)
    while True:
        cand = os.path.join(d, "cds.lib")
        if os.path.isfile(cand):
            return cand
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


# --------------------------------------------------------------------------- #
# expand.cfg  (Cadence Hierarchy-Editor config)                               #
# --------------------------------------------------------------------------- #
def _strip_cfg_comments(s):
    return re.sub(r'//[^\n]*', ' ', s)


def parse_expandcfg(path):
    """Parse a hierarchy-editor expand.cfg.

    Returns {name, design:(lib,cell,view), liblist:[...], viewlist:[...],
             stoplist:[...], cell_bindings:{(lib,cell):view},
             inst_bindings:{path:view}}.
    """
    txt = _strip_cfg_comments(open(path, errors="replace").read())
    cfg = {"name": None, "design": None, "liblist": [], "viewlist": [],
           "stoplist": [], "cell_bindings": {}, "inst_bindings": {}}

    m = re.search(r'\bconfig\s+([A-Za-z_]\w*)\s*;', txt)
    if m:
        cfg["name"] = m.group(1)

    m = re.search(r'\bdesign\s+([\w\\.]+)\.([\w\\.]+)\s*:\s*([\w\\.]+)\s*;', txt)
    if m:
        cfg["design"] = (m.group(1), m.group(2), m.group(3))

    def _words(stmt):
        # split a viewlist/liblist body on commas/space, drop escaped-id backslashes
        return [w.replace("\\", "").strip()
                for w in re.split(r'[,\s]+', stmt.strip()) if w.strip()]

    m = re.search(r'\bliblist\s+([^;]*);', txt)
    if m:
        cfg["liblist"] = _words(m.group(1))
    m = re.search(r'\bviewlist\s+([^;]*);', txt)
    if m:
        cfg["viewlist"] = _words(m.group(1))
    m = re.search(r'\bstoplist\s+([^;]*);', txt)
    if m:
        cfg["stoplist"] = _words(m.group(1))

    # cell <lib>.<cell> binding :<view>;
    for mm in re.finditer(r'\bcell\s+([\w\\.]+)\.([\w\\.]+)\s+binding\s*:\s*([\w\\.]+)\s*;', txt):
        lib, cell, view = (g.replace("\\", "") for g in mm.groups())
        cfg["cell_bindings"][(lib, cell)] = view
    # instance <path> binding :<view>;
    for mm in re.finditer(r'\binstance\s+([\w\\./]+)\s+binding\s*:\s*([\w\\.]+)\s*;', txt):
        cfg["inst_bindings"][mm.group(1)] = mm.group(2).replace("\\", "")
    return cfg


# --------------------------------------------------------------------------- #
# oa2verilog driver                                                           #
# --------------------------------------------------------------------------- #
def run_oa2verilog(lib, cell, view, libdef, out_v, env_sh=DEFAULT_ENV_SH, log=None):
    """Run IC618 oa2verilog -recursive -noStopping. Returns (ok, message)."""
    oa = shutil.which("oa2verilog")
    if not oa:
        # try to locate via env.sh's CDSHOME without sourcing
        oa = None
    log = log or (out_v + ".log")
    # build a child env: inherit, source env.sh, add OA_* knobs, then exec oa2verilog
    cmd = (
        '. "%s" >/dev/null 2>&1; ' % env_sh +
        " ".join('export %s=%s;' % (k, v) for k, v in OA_ENV.items()) +
        ' oa2verilog -lib %s -cell %s -view %s -verilog "%s"'
        ' -libDefFile "%s" -recursive -noStopping -logFile "%s"'
        % (lib, cell, view, out_v, libdef, log)
    )
    p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
    ok = (p.returncode == 0 and os.path.isfile(out_v))
    msg = (p.stdout + p.stderr).strip()
    return ok, msg


# --------------------------------------------------------------------------- #
# netlist splitting / surgery                                                 #
# --------------------------------------------------------------------------- #
MOD_RE = re.compile(r'\bmodule\b.*?\bendmodule\b(?:\s*//[^\n]*)?', re.S)
MODNAME_RE = re.compile(r'\bmodule\s+(\\?\S+|\w+)')


def split_modules(src):
    """Return (preamble, [(name, text), ...]) preserving each module verbatim."""
    blocks, last = [], 0
    preamble = ""
    for m in MOD_RE.finditer(src):
        if not blocks:
            preamble = src[:m.start()]
        nm = MODNAME_RE.search(m.group(0))
        name = (nm.group(1).lstrip("\\") if nm else "?")
        blocks.append((name, m.group(0)))
        last = m.end()
    return preamble, blocks


def module_body(text):
    """The text between the port-list ');' and 'endmodule'."""
    m = re.search(r'\)\s*;(.*)\bendmodule\b', text, re.S)
    if m:
        return m.group(1)
    # port-less module:  module foo (); ... endmodule   or  module foo; ...
    m = re.search(r';(.*)\bendmodule\b', text, re.S)
    return m.group(1) if m else ""


def instances_of(text):
    """[(master, inst)] in this module's body (uses vh_parse's statement splitter)."""
    body = vp.strip_comments(module_body(text))
    body = re.sub(r'\banalog\b.*?\bend\b', ' ', body, flags=re.S)
    out = []
    for stmt in vp.split_statements(body):
        it = vp.parse_instance(stmt)
        if it:
            out.append((it["master"], it["inst"]))
    return out


def wrealize(text, warns):
    """Normalize a structural module's nets to wreal (the pure-digital AMS flow is
    wreal/voltage-only). Scalar `wire`->`wreal`, and add a `wreal <ports>;` decl so
    the top's ports carry real values too. Buses are left as-is and warned about."""
    mods = vp.parse_text(text)
    mname = mods[0]["module"] if mods else "?"
    # internal nets:  scalar `wire X;` -> `wreal X;`   (vectored `wire [..]` left alone)
    text = re.sub(r'\bwire\b(\s+\w)', lambda m: "wreal" + m.group(1), text)
    # ports: merge the net type into the direction decl -> `input wreal in1;`
    scalar_ports, bus_ports = [], []
    if mods:
        mi = mods[0]
        for p in mi["ports"]:
            _, w = mi["dirs"].get(p, ("inout", ""))
            (bus_ports if w else scalar_ports).append(p)
    for p in scalar_ports:
        text = re.sub(r'\b(input|output|inout)\b(\s+)(%s)\s*;' % re.escape(p),
                      r'\1\2wreal \3;', text, count=1)
    for p in bus_ports:
        warns.append("module '%s': port '%s' is a bus -> left as-is; the pure-digital "
                     "flow is scalar-wreal, widen/split by hand if it must be verified"
                     % (mname, p))
    return text


def strip_instances(text, drop_masters):
    """Remove every instance statement whose master is in drop_masters (balanced)."""
    if not drop_masters:
        return text
    out, i, n = [], 0, len(text)
    while i < n:
        m = re.compile(r'(\b(%s)\b)\s*\\?\w+\s*\(' %
                       "|".join(re.escape(d) for d in drop_masters)).match(text, i)
        if m:
            close = vp.find_matching(text, m.end() - 1)
            if close >= 0:
                j = close + 1
                while j < n and text[j] in " \t":
                    j += 1
                if j < n and text[j] == ';':
                    j += 1
                # swallow trailing newline, and drop the removed line's indentation
                if j < n and text[j] == '\n':
                    j += 1
                while out and out[-1] in " \t":
                    out.pop()
                i = j
                continue
        out.append(text[i])
        i += 1
    return "".join(out)


# --------------------------------------------------------------------------- #
# leaf resolution                                                             #
# --------------------------------------------------------------------------- #
def find_veriloga(cell, libs, prefer_lib=None):
    """Locate <libpath>/<cell>/veriloga/veriloga.va (or any .va in a veriloga view).

    Search prefer_lib first, then all libs. Returns (libname, abspath) or (None, None).
    """
    order = ([prefer_lib] if prefer_lib in libs else []) + \
            [L for L in libs if L != prefer_lib]
    for L in order:
        vdir = os.path.join(libs[L], cell, "veriloga")
        if os.path.isdir(vdir):
            cand = os.path.join(vdir, "veriloga.va")
            if os.path.isfile(cand):
                return L, cand
            vas = [f for f in os.listdir(vdir) if f.endswith((".va", ".vams"))]
            if vas:
                return L, os.path.join(vdir, vas[0])
    return None, None


def has_schematic(cell, libs):
    for L in libs:
        if os.path.isfile(os.path.join(libs[L], cell, "schematic", "sch.oa")):
            return L
    return None


# --------------------------------------------------------------------------- #
# main extraction                                                             #
# --------------------------------------------------------------------------- #
def extract(lib, cell, view, libs, raw_netlist, out_dir, cfg=None, warnings=None):
    """Process a raw oa2verilog netlist into clean top + gathered leaves + manifest dict."""
    warnings = warnings if warnings is not None else []
    cfg = cfg or {}
    preamble, blocks = split_modules(raw_netlist)
    by_name = {nm: tx for nm, tx in blocks}

    # config-driven veriloga bindings: cell explicitly bound to veriloga -> force leaf
    forced_va = {c for (lb, c), v in cfg.get("cell_bindings", {}).items()
                 if v == "veriloga"}

    # first pass: who has real instances (ignoring pin/stimulus artifacts)?
    structural = {}
    for nm, tx in blocks:
        insts = instances_of(tx)
        real = [(mas, ins) for mas, ins in insts
                if mas not in PIN_CELLS and mas not in STIMULUS_CELLS]
        structural[nm] = real

    drop_arti = PIN_CELLS | STIMULUS_CELLS
    stim_seen = sorted({mas for nm, tx in blocks for mas, _ in instances_of(tx)
                        if mas in STIMULUS_CELLS})
    pin_seen = sorted({mas for nm, tx in blocks for mas, _ in instances_of(tx)
                       if mas in PIN_CELLS})

    # classify every defined module
    classes, leaves, externals = {}, [], []
    for nm, tx in blocks:
        if nm in drop_arti:
            classes[nm] = "pin" if nm in PIN_CELLS else "stimulus"
            continue
        forced = nm in forced_va
        if structural[nm] and not forced:
            classes[nm] = "structural"
            continue
        # empty interface (or forced-to-veriloga): leaf or external
        vlib, vpath = find_veriloga(nm, libs, prefer_lib=lib)
        if vpath:
            classes[nm] = "veriloga"
            leaves.append({"module": nm, "lib": vlib, "src": vpath,
                           "forced_binding": forced})
        elif nm == cell:
            # the targeted top itself is empty -> a pin-only stub, flagged below;
            # it is the DUT, not a neighbor to stub, so keep it out of externals.
            classes[nm] = "stub_top"
        else:
            # interface ports/dirs come straight from oa2verilog (symbol-accurate)
            classes[nm] = "external"
            externals.append({"module": nm, "interface": tx.strip()})

    # which masters are actually instantiated somewhere?
    used = set()
    for nm, tx in blocks:
        for mas, _ in instances_of(tx):
            used.add(mas)

    # build clean top: keep STRUCTURAL module defs, drop artifact instances inside
    # them, and normalize nets to wreal for the pure-digital AMS flow.
    kept = []
    for nm, tx in blocks:
        if classes.get(nm) != "structural":
            continue
        kept.append(wrealize(strip_instances(tx, drop_arti), warnings))

    # is the targeted top a pin-only stub?  (its def survives but has no real instances)
    top_is_stub = (cell in by_name and not structural.get(cell))
    top_empty_interface = (cell in by_name and not instances_of(by_name[cell]))

    os.makedirs(out_dir, exist_ok=True)
    export = os.path.join(out_dir, "export")
    os.makedirs(export, exist_ok=True)

    # gather leaf .va bodies
    gathered = []
    for lf in leaves:
        dst = os.path.join(export, "%s.va" % lf["module"])
        shutil.copyfile(lf["src"], dst)
        gathered.append({"module": lf["module"], "lib": lf["lib"],
                         "src": lf["src"], "gathered": os.path.relpath(dst, out_dir),
                         "forced_binding": lf["forced_binding"]})

    # emit clean structural top
    clean_name = "%s_struct.vams" % cell
    clean_path = os.path.join(export, clean_name)
    header = ("// AUTO-GENERATED by vh_extract (Stage A) -- structural hierarchy of\n"
              "// %s.%s:%s, with OA pin artifacts and TB stimulus stripped.\n"
              "// Veriloga leaves live as sibling .va files (gathered). Externals are\n"
              "// left undefined on purpose so Stage C (vh_gen) stubs them.\n\n"
              % (lib, cell, view))
    open(clean_path, "w").write(header + "\n\n".join(kept) + ("\n" if kept else ""))

    # classify external port dirs from their oa2verilog interface (symbol-accurate)
    ext_records = []
    for e in externals:
        mods = vp.parse_text(e["interface"])
        ports = {}
        if mods:
            mi = mods[0]
            for p in mi["ports"]:
                ports[p] = mi["dirs"].get(p, ("inout", ""))[0]
        ext_records.append({"module": e["module"], "ports": ports})

    manifest = {
        "stage": "A",
        "design": {"lib": lib, "cell": cell, "view": view},
        "config": {"name": cfg.get("name"), "viewlist": cfg.get("viewlist"),
                   "stoplist": cfg.get("stoplist"),
                   "cell_bindings": {"%s.%s" % k: v
                                     for k, v in cfg.get("cell_bindings", {}).items()}},
        "clean_top": os.path.relpath(clean_path, out_dir),
        "veriloga_leaves": gathered,
        "external_modules": ext_records,
        "stripped": {"pins": pin_seen, "stimulus": stim_seen},
        "top_is_pin_only_stub": bool(top_is_stub),
        "warnings": warnings,
    }

    # warnings
    if stim_seen:
        cand = sorted({mas for mas, _ in structural.get(cell, [])})
        warnings.append(
            "TB stimulus %s found -> you are likely netlisting a TESTBENCH, not the DUT. "
            "Re-run with --cell <DUT> (candidates from this top: %s)."
            % (stim_seen, cand or "(none -- top is a stub)"))
    if top_is_stub:
        warnings.append(
            "Target '%s' has no real sub-instances (pin-only stub) -> NOTHING TO VERIFY. "
            "Point --cell at the cell that actually instantiates the design." % cell)
    if not leaves and not kept:
        warnings.append("No structural hierarchy and no veriloga leaves were extracted.")
    manifest["warnings"] = warnings
    return manifest, clean_path


def render_summary(manifest):
    L = ["=" * 72, "STAGE A  -- EXTRACTION MANIFEST", "=" * 72]
    d = manifest["design"]
    L.append("DESIGN        : %s.%s:%s" % (d["lib"], d["cell"], d["view"]))
    if manifest["config"].get("name"):
        L.append("CONFIG        : %s   viewlist=%s  stoplist=%s"
                 % (manifest["config"]["name"], manifest["config"]["viewlist"],
                    manifest["config"]["stoplist"]))
    L.append("")
    L.append("CLEAN TOP     : %s" % manifest["clean_top"])
    L.append("")
    L.append("VERILOGA LEAVES (gathered as .va):")
    if manifest["veriloga_leaves"]:
        for g in manifest["veriloga_leaves"]:
            tag = "  [forced :veriloga]" if g["forced_binding"] else ""
            L.append("  - %-16s %s.%s%s" % (g["module"], g["lib"], g["module"], tag))
            L.append("        from %s" % g["src"])
    else:
        L.append("  (none)")
    L.append("")
    L.append("EXTERNAL MODULES (undefined -> Stage C will stub):")
    if manifest["external_modules"]:
        for e in manifest["external_modules"]:
            pd = ", ".join("%s:%s" % (p, dr) for p, dr in e["ports"].items()) or "(no ports)"
            L.append("  - %-16s { %s }" % (e["module"], pd))
    else:
        L.append("  (none)")
    st = manifest["stripped"]
    if st["pins"] or st["stimulus"]:
        L.append("")
        L.append("STRIPPED      : pins=%s  stimulus=%s" % (st["pins"] or "-", st["stimulus"] or "-"))
    if manifest["warnings"]:
        L.append("")
        L.append("WARNINGS:")
        for w in manifest["warnings"]:
            L.append("  ! " + w)
    L.append("")
    L.append("NEXT: Stage C ->  python3 vh_gen.py --src %s --out <build>"
             % os.path.dirname(manifest["clean_top"]))
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description="Stage A: OA config -> structural top + .va + manifest")
    ap.add_argument("--config", help="expand.cfg (hierarchy-editor config)")
    ap.add_argument("--cdslib", help="cds.lib (default: nearest above --config / --out)")
    ap.add_argument("--lib", help="override/standalone: top library")
    ap.add_argument("--cell", help="override/standalone: top cell (DUT)")
    ap.add_argument("--view", default="schematic", help="top view (default schematic)")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--netlist", help="reuse a pre-made oa2verilog .v (skip OA)")
    ap.add_argument("--env-sh", default=DEFAULT_ENV_SH, help="Cadence env.sh to source for oa2verilog")
    args = ap.parse_args()

    warnings = []
    cfg = {}
    if args.config:
        cfg = parse_expandcfg(args.config)
        if not cfg.get("design") and not (args.lib and args.cell):
            sys.exit("ERROR: could not read 'design' from %s and no --lib/--cell given" % args.config)

    # resolve target design (CLI overrides config)
    if args.lib and args.cell:
        lib, cell, view = args.lib, args.cell, args.view
    elif cfg.get("design"):
        lib, cell, dview = cfg["design"]
        view = args.view if args.view != "schematic" else dview
        if args.cell:
            cell = args.cell
        if args.lib:
            lib = args.lib
    else:
        sys.exit("ERROR: need --config (with a design) or --lib/--cell")

    # resolve cds.lib
    cdslib = args.cdslib or (find_cdslib(args.config) if args.config else None) \
        or find_cdslib(args.out) or find_cdslib(os.getcwd())
    if not cdslib:
        sys.exit("ERROR: no cds.lib found; pass --cdslib")
    libs = parse_cdslib(cdslib)
    if lib not in libs:
        warnings.append("design lib '%s' not in cds.lib (%s); leaf lookup may miss it"
                        % (lib, cdslib))

    os.makedirs(args.out, exist_ok=True)

    # phase 1: get a netlist
    if args.netlist:
        raw = open(args.netlist, errors="replace").read()
    else:
        raw_v = os.path.join(args.out, "%s_raw.v" % cell)
        ok, msg = run_oa2verilog(lib, cell, view, cdslib, raw_v, env_sh=args.env_sh)
        if not ok:
            sys.exit("ERROR: oa2verilog failed:\n" + msg)
        raw = open(raw_v, errors="replace").read()

    manifest, clean = extract(lib, cell, view, libs, raw, args.out, cfg=cfg, warnings=warnings)
    json.dump(manifest, open(os.path.join(args.out, "manifest_A.json"), "w"), indent=2)
    text = render_summary(manifest)
    open(os.path.join(args.out, "manifest_A.txt"), "w").write(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
