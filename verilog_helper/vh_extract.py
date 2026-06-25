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
import vh_env as ve

# --- OA / Spectre env for oa2verilog on this RHEL8 box (see oa2verilog-rhel8-recipe) ---
DEFAULT_ENV_SH = "/home/yusheng/cadence_work/Test/workarea/LDO_modeling/cadence/env.sh"
OA_ENV = {"OA_UNSUPPORTED_PLAT": "linux_rhel60", "CDS_ENABLE_EXP_PCELL": "1"}

# netlist artifacts to strip (def + every instance of them)
PIN_CELLS = {"ipin", "opin", "iopin"}
# no-connect markers -- pure artifacts, drop them
NOCONN_CELLS = {"noConn", "noConn_"}
# parasitic substrate / well / ESD diode devices (2-terminal, to substrate/supply):
# no functional role in a pure-digital check -> dropped. PDK-specific; extend as needed.
DEVICE_DROP = {"pdio_mac", "ndio_mac", "dnwpsub", "pwdnw", "pnwdio", "pdiode",
               "ndiode", "dnw_psub", "nwdio", "pwdio"}
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


# analogLib 2-terminal passives that sit ON a signal net (not stimulus). A SERIES
# one (neither terminal grounded) is transparent in a pure-digital functional check
# -> SHORT it (merge the two nets). A SHUNT to ground -> OPEN it (drop). Anything
# load-bearing/analog (filter, resonance) can't be done pure-digital -> that's a
# "needs spectre" case; this only removes elements that are functionally transparent.
PASSIVE_CELLS = {"res", "cap", "ind", "resistor", "capacitor", "inductor"}
GROUND_NETS = {"gnd", "gnd!", "0", "vss", "vss!", "agnd", "agnd!", "dgnd", "dgnd!",
               "vgnd", "vgnd!", "gnda", "gndd", "vssa", "vssd", "cds_globals"}


def _is_ground(net):
    n = net.strip().lower()
    return n in GROUND_NETS or n.startswith("gnd") or n.startswith("vss")


def short_passives(text, warns=None, report=None):
    """In ONE structural module's text, remove analogLib 2-terminal passives that
    are functionally transparent:
      - SERIES (neither terminal grounded): MERGE the two nets (signal passes
        straight through) by renaming one net to the other and dropping the
        merged net's declaration; then delete the passive instance.
      - SHUNT to ground (one terminal grounded): delete the instance (OPEN).
    A module PORT involved in a merge is kept as the representative so the port
    survives. Non-2-terminal / bus-bit passives are left in place + warned (they
    fall through to the normal external-stub path). Returns the modified text."""
    warns = warns if warns is not None else []
    report = report if report is not None else []
    mods = vp.parse_text(text)
    if not mods:
        return text
    mi = mods[0]
    ports = set(mi["ports"])

    parent = {}
    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    def union(a, b):
        ra, rb = find(a), find(b)
        if ra == rb:
            return
        # keep a PORT as the root so the port name survives the merge
        if rb in ports and ra not in ports:
            ra, rb = rb, ra
        parent[rb] = ra

    drop_masters, handled = set(), False
    for it in mi["instances"]:
        if it["master"] not in PASSIVE_CELLS:
            continue
        nets = (list(it["conns"]["named"].values()) if it["conns"]["named"]
                else (it["conns"]["pos"] or []))
        nets = [n.strip() for n in nets]
        if len(nets) != 2:
            warns.append("module '%s': %s '%s' is not 2-terminal (nets=%s) -> left "
                         "in place (stubbed)" % (mi["module"], it["master"], it["inst"], nets))
            continue
        a, b = nets
        if "[" in a or "[" in b:
            warns.append("module '%s': %s '%s' on a bus bit -> left in place (stubbed)"
                         % (mi["module"], it["master"], it["inst"]))
            continue
        ga, gb = _is_ground(a), _is_ground(b)
        if ga and gb:
            report.append((mi["module"], it["inst"], it["master"], "both grounded -> dropped"))
        elif ga or gb:
            report.append((mi["module"], it["inst"], it["master"],
                           "shunt to %s -> opened" % (a if ga else b)))
        else:
            union(a, b)
            report.append((mi["module"], it["inst"], it["master"],
                           "series -> shorted (%s = %s)" % (a, b)))
        drop_masters.add(it["master"])
        handled = True

    if not handled:
        return text
    rename = {n: find(n) for n in list(parent) if find(n) != n}

    # statement-level surgery on the module body (keeps the header/port list intact)
    m = re.search(r'(.*?\)\s*;)(.*)(\bendmodule\b.*)', text, re.S)
    if not m:
        return strip_instances(text, drop_masters)   # fallback: at least drop them
    header, body, tail = m.group(1), m.group(2), m.group(3)
    body = vp.strip_comments(body)   # avoid stray ';' in comments breaking the split
    NETKW = re.compile(r'^\s*(wire|wreal|electrical|tri|reg|logic)\b\s*(\[[^\]]*\])?\s*(.*)$', re.S)
    DIR = re.compile(r'^\s*(input|output|inout)\b')
    out_stmts = []
    for raw in vp.split_statements(body):
        stmt = raw
        it = vp.parse_instance(vp.strip_comments(stmt))
        if it and it["master"] in drop_masters:
            continue                                  # drop the passive instance
        dm = NETKW.match(stmt)
        if dm and not DIR.match(stmt):                # a plain net decl -> drop merged-away names
            kw, rng, names = dm.group(1), dm.group(2) or "", dm.group(3)
            keep = [nm.strip() for nm in names.split(",")
                    if nm.strip() and nm.strip() not in rename]
            if not keep:
                continue                              # whole decl was merged away
            out_stmts.append("  %s %s%s" % (kw, (rng + " ") if rng else "", ", ".join(keep)))
            continue
        for src, dst in rename.items():               # remap nets used in instance conns
            stmt = re.sub(r'\b%s\b' % re.escape(src), dst, stmt)
        if stmt.strip():
            out_stmts.append(stmt.rstrip())
    new_body = "\n" + ";\n".join(s.strip() for s in out_stmts) + ";\n"
    return header + new_body + tail


def drop_instance_ports(text, drops):
    """drops: {(master, inst): set(ports)}. Remove the named connections `.port(...)` for
    those ports from each matching instance's connection list, in place (balanced)."""
    if not drops:
        return text
    masters = sorted({m for (m, _) in drops})
    hdr = re.compile(r'(\b(?:%s)\b)\s*(\\?\w+)(\s*\[[^\]]*\])?\s*\(' %
                     "|".join(re.escape(m) for m in masters))
    out, i, n = [], 0, len(text)
    while i < n:
        m = hdr.match(text, i)
        if m:
            master, inst = m.group(1), m.group(2)
            close = vp.find_matching(text, m.end() - 1)
            if close >= 0 and (master, inst) in drops:
                conn = text[m.end():close]
                for p in drops[(master, inst)]:
                    conn = re.sub(r'\.%s\s*\([^()]*(?:\([^()]*\)[^()]*)*\)\s*,?' % re.escape(p),
                                  '', conn)
                conn = re.sub(r',\s*$', ' ', conn)        # tidy a dangling comma
                out.append(text[i:m.end()]); out.append(conn); out.append(text[close])
                i = close + 1
                continue
        out.append(text[i]); i += 1
    return "".join(out)


def reconcile_ports(text, port_index, warns=None, report=None):
    """Drop instance connections to ports their (known) master does NOT have -- the cause
    of `*E,CUVPOM "Port name 'X' is invalid"` (e.g. power pins VPP/VDD on the symbol but
    not in the cell's verilogams, or an enable the model omits). Only reconciled when the
    instance still shares >=1 port with the master (it IS the right cell, just extra pins);
    if there is ZERO overlap the wrong view was descended -> leave it + warn loudly (don't
    silently gut the instance)."""
    warns = warns if warns is not None else []
    report = report if report is not None else []
    mods = vp.parse_text(text)
    if not mods:
        return text
    host = mods[0]["module"]
    drops = {}
    for it in mods[0]["instances"]:
        mas, named = it["master"], it["conns"]["named"]
        if mas not in port_index or not named:
            continue
        connected, mports = set(named), port_index[mas]
        absent = connected - mports
        if not absent:
            continue
        if not (connected & mports):
            warns.append("module '%s': instance '%s' of '%s' connects %s but its extracted "
                         "interface is %s -- ZERO overlap (the wrong view was likely descended "
                         "for '%s'); NOT reconciled, will not elaborate -- fix that cell's view."
                         % (host, it["inst"], mas, sorted(connected)[:10], sorted(mports), mas))
            continue
        drops[(mas, it["inst"])] = absent
        for p in sorted(absent):
            report.append({"module": host, "inst": it["inst"], "master": mas, "dropped_port": p})
        warns.append("module '%s': dropped %s on '%s' (%s has no such port) -> reconciled "
                     "to the cell's actual interface" % (host, sorted(absent), it["inst"], mas))
    return drop_instance_ports(text, drops)


def strip_instances(text, drop_masters):
    """Remove every instance statement whose master is in drop_masters (balanced)."""
    if not drop_masters:
        return text
    out, i, n = [], 0, len(text)
    while i < n:
        m = re.compile(r'(\b(%s)\b)\s*\\?\w+(?:\s*\[[^\]]*\])?\s*\(' %
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
# behavioral view-dir names to gather a leaf from. Cadence names the Verilog-A
# view "veriloga" and the Verilog-AMS view "verilogams" (the user's leaf cells use
# verilogams); "ahdl" is the older analog-HDL view. Checked in this order.
VA_VIEW_DIRS = ("veriloga", "verilogams", "ahdl")


def find_veriloga(cell, libs, prefer_lib=None):
    """Locate a cell's behavioral source: <libpath>/<cell>/<view>/*.va|*.vams for
    view in veriloga / verilogams / ahdl. Search prefer_lib first, then all libs.
    Returns (libname, abspath) or (None, None)."""
    order = ([prefer_lib] if prefer_lib in libs else []) + \
            [L for L in libs if L != prefer_lib]
    for L in order:
        cdir = os.path.join(libs[L], cell)
        for vname in VA_VIEW_DIRS:
            vdir = os.path.join(cdir, vname)
            if not os.path.isdir(vdir):
                continue
            # prefer the conventional filenames, else any .va/.vams in the view
            for pref in ("veriloga.va", "verilogams.vams", vname + ".va", vname + ".vams"):
                cand = os.path.join(vdir, pref)
                if os.path.isfile(cand):
                    return L, cand
            vas = sorted(f for f in os.listdir(vdir) if f.endswith((".va", ".vams")))
            if vas:
                return L, os.path.join(vdir, vas[0])
    return None, None


def has_schematic(cell, libs):
    for L in libs:
        if os.path.isfile(os.path.join(libs[L], cell, "schematic", "sch.oa")):
            return L
    return None


# schematic-like view-dir names (the hierarchy lives here). A design's config
# viewlist often names the real schematic "cmos_sch", not "schematic" -- which is
# exactly why `oa2verilog -view schematic` stops at such a sub-block.
SCHEM_VIEW_DIRS = ("schematic", "cmos_sch", "cmos.sch", "sch")


def _schem_view_order(viewlist):
    """Order the schematic-like view names by the config viewlist (so cmos_sch is
    tried before schematic when the config prefers it), then any remaining."""
    sset = set(SCHEM_VIEW_DIRS)
    order = [v for v in (viewlist or []) if v in sset]
    for v in SCHEM_VIEW_DIRS:
        if v not in order:
            order.append(v)
    return order


def find_schematic_view(cell, libs, prefer_lib=None, order=None):
    """Locate a cell's schematic-like view: (lib, viewname) or (None, None)."""
    names = order or list(SCHEM_VIEW_DIRS)
    liborder = ([prefer_lib] if prefer_lib in libs else []) + \
               [L for L in libs if L != prefer_lib]
    for L in liborder:
        for v in names:
            vdir = os.path.join(libs[L], cell, v)
            if os.path.isdir(vdir) and os.listdir(vdir):
                return L, v
    return None, None


def _has_view_dir(cell, libs, vname):
    for L in libs:
        d = os.path.join(libs[L], cell, vname)
        if os.path.isdir(d) and os.listdir(d):
            return True
    return False


# config viewlist entries that mean "behavioral leaf" (map to the on-disk VA_VIEW_DIRS)
BEHAV_VIEWS = ("veriloga", "verilogams", "ahdl", "spice", "ams")


def config_use_schematic(cell, libs, viewlist, stoplist=None):
    """Honor the config_ams viewlist: should `cell` be DESCENDED as a schematic
    (structural) or GATHERED as a behavioral leaf? Decided by viewlist RANK -- the first
    schematic-like view the cell actually has vs the first behavioral view it has (a cell
    can have BOTH; the config picks the higher-ranked one). e.g. with viewlist
    [spectre, cmos_sch, schematic, veriloga, ...] a cell that has BOTH schematic and
    verilogams resolves to SCHEMATIC -> descend (its veriloga/verilogams is NOT used).
    Returns None when there is no viewlist (caller falls back to the verilogams=leaf rule)."""
    if not viewlist:
        return None
    stop = set(stoplist or [])
    sch_rank = beh_rank = None
    for idx, v in enumerate(viewlist):
        if v in stop:
            continue
        if sch_rank is None and v in SCHEM_VIEW_DIRS and _has_view_dir(cell, libs, v):
            sch_rank = idx
        if beh_rank is None and v in BEHAV_VIEWS \
                and any(_has_view_dir(cell, libs, d) for d in VA_VIEW_DIRS):
            beh_rank = idx
    if sch_rank is None:
        return False if beh_rank is not None else None
    if beh_rank is None:
        return True
    return sch_rank < beh_rank


def dedup_netlist(raw):
    """Collapse duplicate module defs (across merged oa2verilog runs), keeping the
    RICHEST block per name -- a real body (has instances) wins over an empty
    interface emitted by a parent run."""
    pre, blocks = split_modules(raw)
    best, order = {}, []
    for nm, tx in blocks:
        if nm not in best:
            best[nm] = tx
            order.append(nm)
        elif instances_of(tx) and not instances_of(best[nm]):
            best[nm] = tx                      # full body replaces empty interface
    return pre + "\n\n".join(best[nm] for nm in order) + "\n"


def expand_hierarchy(raw, top_cell, libs, ext_index, cdslib, env_sh, out_dir,
                     warnings, viewlist=None, stoplist=None):
    """Recursively descend hierarchy sub-blocks that the top oa2verilog run did NOT
    follow (their schematic is a cmos_sch view, or they sit under a nested config).

    A sub-block is descended when it is undefined or an empty interface, the config
    viewlist resolves it to a SCHEMATIC-like view (so a cell that has BOTH a schematic
    and a verilogams is descended when the viewlist ranks schematic higher -- its
    verilogams is NOT used), it is not a -v-resolved std cell, and not a pin/stimulus/
    device/passive. Without a viewlist we fall back to the verilogams=>leaf rule. Each
    descent runs oa2verilog on the cell's own schematic view; merged + dedup'd
    (full body beats empty interface). Repeats to a fixpoint."""
    schem_order = _schem_view_order(viewlist)
    skip = PIN_CELLS | STIMULUS_CELLS | NOCONN_CELLS | DEVICE_DROP | PASSIVE_CELLS
    combined = raw
    descended = {top_cell}
    for _ in range(64):                        # depth guard
        _, blocks = split_modules(combined)
        defined = {nm for nm, _ in blocks}
        empty_defs = {nm for nm, tx in blocks if not instances_of(tx)}
        used = set()
        for nm, tx in blocks:
            for mas, _ in instances_of(tx):
                used.add(mas)
        cand = (used - defined) | (empty_defs - {top_cell})
        todo = []
        for mas in sorted(cand):
            if mas in descended or mas in skip or mas in ext_index:
                continue
            use_sch = config_use_schematic(mas, libs, viewlist, stoplist)
            if use_sch is None:                # no config: verilogams => leaf, don't descend
                if find_veriloga(mas, libs)[1]:
                    continue
            elif not use_sch:                  # config resolves it to a behavioral leaf
                continue
            # else: config resolves it to a schematic -> descend (even if it has verilogams)
            sl, sv = find_schematic_view(mas, libs, order=schem_order)
            if sv:
                todo.append((mas, sl, sv))
        if not todo:
            break
        for mas, mlib, mview in todo:
            descended.add(mas)
            sub_v = os.path.join(out_dir, "_sub_%s.v" % re.sub(r"\W", "_", mas))
            ok, msg = run_oa2verilog(mlib, mas, mview, cdslib, sub_v, env_sh=env_sh)
            if ok and os.path.isfile(sub_v):
                combined += "\n" + open(sub_v, errors="replace").read()
                print("[vh_extract] descended sub-block %s:%s" % (mas, mview))
            else:
                warnings.append("could not descend sub-block '%s:%s' -> left external "
                                "(%s)" % (mas, mview, (msg or "").strip()[:160]))
    return dedup_netlist(combined)


# --------------------------------------------------------------------------- #
# main extraction                                                             #
# --------------------------------------------------------------------------- #
def extract(lib, cell, view, libs, raw_netlist, out_dir, cfg=None, warnings=None,
            env=None, ext_index=None):
    """Process a raw oa2verilog netlist into clean top + gathered leaves + manifest dict.

    env/ext_index (optional): the remembered external HDL environment and its
    {module: {file,kind}} index. Externals found in it are RESOLVED (left for xrun
    to compile via -v, not stubbed); the rest are recorded for Stage C to stub."""
    warnings = warnings if warnings is not None else []
    cfg = cfg or {}
    env = env or {k: [] for k in ("lib_files", "lib_dirs", "inc_dirs")}
    ext_index = ext_index or {}
    preamble, blocks = split_modules(raw_netlist)
    by_name = {nm: tx for nm, tx in blocks}

    # config-driven veriloga bindings: cell explicitly bound to veriloga -> force leaf
    forced_va = {c for (lb, c), v in cfg.get("cell_bindings", {}).items()
                 if v == "veriloga"}

    passive_report = []   # (module, inst, master, action) from short_passives

    drop_arti = PIN_CELLS | STIMULUS_CELLS | NOCONN_CELLS | DEVICE_DROP

    # first pass: who has real instances (ignoring pin/stimulus/passive/noconn/device)?
    structural = {}
    for nm, tx in blocks:
        insts = instances_of(tx)
        real = [(mas, ins) for mas, ins in insts
                if mas not in drop_arti and mas not in PASSIVE_CELLS]
        structural[nm] = real

    stim_seen = sorted({mas for nm, tx in blocks for mas, _ in instances_of(tx)
                        if mas in STIMULUS_CELLS})
    pin_seen = sorted({mas for nm, tx in blocks for mas, _ in instances_of(tx)
                       if mas in PIN_CELLS})
    dropped_seen = sorted({mas for nm, tx in blocks for mas, _ in instances_of(tx)
                           if mas in (NOCONN_CELLS | DEVICE_DROP)})

    # classify every defined module (dedup by name -- oa2verilog can emit a leaf's
    # interface more than once)
    classes, leaves, externals, seen_leaf, seen_ext = {}, [], [], set(), set()
    for nm, tx in blocks:
        if nm in classes:
            continue
        if nm in drop_arti:
            classes[nm] = ("pin" if nm in PIN_CELLS else
                           "stimulus" if nm in STIMULUS_CELLS else
                           "noconn" if nm in NOCONN_CELLS else "device")
            continue
        if nm in PASSIVE_CELLS:
            # a 2-terminal passive primitive's own (empty) interface -> not a
            # neighbor to verify; short_passives removes its instances, so its
            # def is simply dropped (never stubbed, never gathered).
            classes[nm] = "passive"
            continue
        forced = nm in forced_va
        if structural[nm] and not forced:
            classes[nm] = "structural"
            continue
        # empty interface (or forced-to-veriloga): leaf or external. Honor the config
        # viewlist: if it resolves this cell to a SCHEMATIC (and it wasn't an explicit
        # `binding :veriloga`), its verilogams must NOT be gathered -- it should have been
        # descended (its verilogams may be a stale netlist bound to another library).
        vlib, vpath = find_veriloga(nm, libs, prefer_lib=lib)
        use_sch = config_use_schematic(nm, libs, cfg.get("viewlist"), cfg.get("stoplist"))
        if vpath and not (use_sch and not forced):
            classes[nm] = "veriloga"
            if nm not in seen_leaf:
                seen_leaf.add(nm)
                leaves.append({"module": nm, "lib": vlib, "src": vpath,
                               "forced_binding": forced})
        elif use_sch:
            # config says schematic but we have only an empty interface here -> the
            # schematic descent did not run/succeed; do NOT fall back to the (unused)
            # verilogams. Record as external so it's visible, and warn.
            classes[nm] = "external"
            if nm not in seen_ext:
                seen_ext.add(nm)
                externals.append({"module": nm, "interface": tx.strip()})
            warnings.append(
                "cell '%s' resolves to a SCHEMATIC per the config viewlist but no descended "
                "body was produced (oa2verilog did not follow it); its verilogams is NOT "
                "used. Check the cell's schematic view / that OA is available for descent."
                % nm)
        elif nm == cell:
            # the targeted top itself is empty -> a pin-only stub, flagged below;
            # it is the DUT, not a neighbor to stub, so keep it out of externals.
            classes[nm] = "stub_top"
        else:
            # interface ports/dirs come straight from oa2verilog (symbol-accurate)
            classes[nm] = "external"
            if nm not in seen_ext:
                seen_ext.add(nm)
                externals.append({"module": nm, "interface": tx.strip()})

    # which masters are actually instantiated somewhere?
    used = set()
    for nm, tx in blocks:
        for mas, _ in instances_of(tx):
            used.add(mas)

    # is the targeted top a pin-only stub?  (its def survives but has no real instances)
    top_is_stub = (cell in by_name and not structural.get(cell))
    top_empty_interface = (cell in by_name and not instances_of(by_name[cell]))

    os.makedirs(out_dir, exist_ok=True)
    export = os.path.join(out_dir, "export")
    os.makedirs(export, exist_ok=True)

    # gather leaf .va bodies
    gathered = []
    for lf in leaves:
        ext = ".vams" if lf["src"].endswith(".vams") else ".va"
        dst = os.path.join(export, lf["module"] + ext)
        shutil.copyfile(lf["src"], dst)
        gathered.append({"module": lf["module"], "lib": lf["lib"],
                         "src": lf["src"], "gathered": os.path.relpath(dst, out_dir),
                         "forced_binding": lf["forced_binding"]})

    # A gathered verilogams can itself be STRUCTURAL -- instantiating further cells
    # (e.g. a delay cell built from inverter/nor cells). The oa2verilog schematic
    # descent never sees those (they live in the .vams text, not a schematic), so
    # descend the gathered files here: parse each, and for every sub-master it uses
    # that is not already defined/gathered/-v/pin/device/passive, gather its own
    # veriloga/verilogams (recursively, to a fixpoint). Anything still undefined is
    # left for Stage C to -v-resolve or stub.
    gathered_names = {g["module"] for g in gathered}
    defined_names = set(classes)                       # modules defined in the struct
    skip_sub = drop_arti | PASSIVE_CELLS
    sub_records = []                                   # (parent, sub) for the manifest
    queue, guard = list(gathered), 0
    while queue and guard < 4096:
        guard += 1
        lf = queue.pop(0)
        try:
            text = open(os.path.join(out_dir, lf["gathered"]), errors="replace").read()
        except OSError:
            continue
        sub_mods = vp.parse_text(text)
        for mi in sub_mods:                            # helper modules in the same file
            defined_names.add(mi["module"])
        for mi in sub_mods:
            for it in mi["instances"]:
                mas = it["master"]
                if (mas in gathered_names or mas in defined_names
                        or mas in skip_sub or mas in ext_index):
                    continue
                vlib, vpath = find_veriloga(mas, libs, prefer_lib=lf.get("lib") or lib)
                if not vpath:
                    continue                           # undefined -> Stage C stubs/-v's it
                ext2 = ".vams" if vpath.endswith(".vams") else ".va"
                dst = os.path.join(export, mas + ext2)
                shutil.copyfile(vpath, dst)
                newlf = {"module": mas, "lib": vlib, "src": vpath,
                         "gathered": os.path.relpath(dst, out_dir),
                         "forced_binding": False}
                gathered.append(newlf)
                gathered_names.add(mas)
                queue.append(newlf)
                sub_records.append({"sub": mas, "parent": mi["module"], "lib": vlib})
                print("[vh_extract] gathered structural-verilogams sub-cell %s "
                      "(used by %s)" % (mas, mi["module"]))

    # port index of every now-known module (struct defs + all gathered leaves), used to
    # reconcile parent instance connections to each child's ACTUAL interface.
    port_index = {}
    for nm, tx in blocks:
        pm = vp.parse_text(tx)
        if pm:
            port_index[nm] = set(pm[0]["ports"])
    for g in gathered:
        try:
            gm = vp.parse_text(open(os.path.join(out_dir, g["gathered"]), errors="replace").read())
        except OSError:
            gm = None
        if gm:
            port_index[g["module"]] = set(gm[0]["ports"])

    # build clean top: keep STRUCTURAL module defs; short passives, RECONCILE instance
    # connections to each child's real ports (drops symbol-only pins like VPP -> avoids
    # *E,CUVPOM), drop artifact instances, normalize nets to wreal.
    recon_report = []
    kept = []
    for nm, tx in blocks:
        if classes.get(nm) != "structural":
            continue
        tx = short_passives(tx, warnings, passive_report)
        tx = reconcile_ports(tx, port_index, warnings, recon_report)
        kept.append(wrealize(strip_instances(tx, drop_arti), warnings))

    # emit clean structural top
    clean_name = "%s_struct.vams" % cell
    clean_path = os.path.join(export, clean_name)
    header = ("// AUTO-GENERATED by vh_extract (Stage A) -- structural hierarchy of\n"
              "// %s.%s:%s, with OA pin artifacts and TB stimulus stripped.\n"
              "// Veriloga leaves live as sibling .va files (gathered). Externals are\n"
              "// left undefined on purpose so Stage C (vh_gen) stubs them.\n\n"
              % (lib, cell, view))
    open(clean_path, "w").write(header + "\n\n".join(kept) + ("\n" if kept else ""))

    # classify external port dirs from their oa2verilog interface (symbol-accurate),
    # and resolve each against the remembered external HDL env (-v library files).
    ext_records = []
    for e in externals:
        mods = vp.parse_text(e["interface"])
        ports = {}
        if mods:
            mi = mods[0]
            for p in mi["ports"]:
                ports[p] = mi["dirs"].get(p, ("inout", ""))[0]
        hit = ext_index.get(e["module"])
        resolved = ({"file": hit["file"], "kind": hit["kind"]} if hit else None)
        ext_records.append({"module": e["module"], "ports": ports, "resolved": resolved})
        if resolved and resolved["kind"] == "analog":
            warnings.append(
                "external '%s' resolves to an ANALOG model (%s) -> pure-digital xrun "
                "cannot solve its electrical nodes (needs spectre); provide a wreal "
                "model or let Stage C stub it." % (e["module"], resolved["file"]))

    manifest = {
        "stage": "A",
        "design": {"lib": lib, "cell": cell, "view": view},
        "config": {"name": cfg.get("name"), "viewlist": cfg.get("viewlist"),
                   "stoplist": cfg.get("stoplist"),
                   "cell_bindings": {"%s.%s" % k: v
                                     for k, v in cfg.get("cell_bindings", {}).items()}},
        "clean_top": os.path.relpath(clean_path, out_dir),
        "veriloga_leaves": gathered,
        "gathered_subcells": sub_records,
        "reconciled_ports": recon_report,
        "external_modules": ext_records,
        "ext_env": {k: env.get(k, []) for k in ("lib_files", "lib_dirs", "inc_dirs")},
        "stripped": {"pins": pin_seen, "stimulus": stim_seen, "devices": dropped_seen},
        "passives": [{"module": m, "inst": i, "master": ms, "action": ac}
                     for (m, i, ms, ac) in passive_report],
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
    L.append("EXTERNAL MODULES:")
    if manifest["external_modules"]:
        for e in manifest["external_modules"]:
            pd = ", ".join("%s:%s" % (p, dr) for p, dr in e["ports"].items()) or "(no ports)"
            r = e.get("resolved")
            if r:
                tag = "-> RESOLVED via %s [%s]" % (os.path.basename(r["file"]), r["kind"])
            else:
                tag = "-> (no -v match) Stage C will STUB"
            L.append("  - %-16s { %s }  %s" % (e["module"], pd, tag))
    else:
        L.append("  (none)")
    env = manifest.get("ext_env", {})
    if env.get("lib_files") or env.get("lib_dirs") or env.get("inc_dirs"):
        L.append("")
        L.append("EXTERNAL ENV (remembered; baked into Stage C run.sh):")
        for f in env.get("lib_files", []):
            L.append("  -v %s" % f)
        for d in env.get("lib_dirs", []):
            L.append("  -y %s" % d)
        for d in env.get("inc_dirs", []):
            L.append("  +incdir+%s" % d)
    if manifest.get("passives"):
        L.append("")
        L.append("PASSIVES (analogLib 2-terminal, removed from the signal path):")
        for p in manifest["passives"]:
            L.append("  - %-12s in %-14s %s" % (p["inst"], p["module"], p["action"]))
    st = manifest["stripped"]
    if st["pins"] or st["stimulus"] or st.get("devices"):
        L.append("")
        L.append("STRIPPED      : pins=%s  stimulus=%s  devices=%s"
                 % (st["pins"] or "-", st["stimulus"] or "-", st.get("devices") or "-"))
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
    ap.add_argument("--ext-lib", action="append", default=[],
                    help="external HDL library file (xrun -v); repeatable, remembered")
    ap.add_argument("--ext-dir", action="append", default=[],
                    help="external HDL library dir (xrun -y); repeatable, remembered")
    ap.add_argument("--ext-inc", action="append", default=[],
                    help="external +incdir dir; repeatable, remembered")
    ap.add_argument("--ext-clear", action="store_true",
                    help="start from an empty external env (ignore the remembered one)")
    ap.add_argument("--no-remember", action="store_true",
                    help="use --ext-* for this run only; do not persist them")
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

    # remembered external HDL env (+ per-run --ext-* overrides)
    env = {k: [] for k in ("lib_files", "lib_dirs", "inc_dirs")} if args.ext_clear \
        else ve.load_env()
    if args.ext_lib or args.ext_dir or args.ext_inc:
        ve.merge(env, lib_files=args.ext_lib, lib_dirs=args.ext_dir, inc_dirs=args.ext_inc)
        if not args.no_remember:
            ve.save_env(env)
    ext_index = ve.index_modules(env, warn=warnings)

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
        # `-view schematic` stops at sub-blocks whose hierarchy is a cmos_sch view
        # or a nested config -> recursively descend those so the whole tree is dug.
        raw = expand_hierarchy(raw, cell, libs, ext_index, cdslib, args.env_sh,
                               args.out, warnings, viewlist=cfg.get("viewlist"),
                               stoplist=cfg.get("stoplist"))

    manifest, clean = extract(lib, cell, view, libs, raw, args.out, cfg=cfg,
                              warnings=warnings, env=env, ext_index=ext_index)
    json.dump(manifest, open(os.path.join(args.out, "manifest_A.json"), "w"), indent=2)
    text = render_summary(manifest)
    open(os.path.join(args.out, "manifest_A.txt"), "w").write(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
