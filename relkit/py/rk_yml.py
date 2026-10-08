"""rk_yml -- RelStudio upper-level yml builder (plan 4.2) + EMIR input prefill.

Subcommands (docs/CONTRACT.md section 3):
  build-yml    --ctx [--type T] [--yml PATH] [--work-dir DIR]
  emir-inputs  --ctx

The yml mirrors, key by key and in the same order, the files RelStudio's GUI
writes (analog_aging.yml / DEOS.yml / EM.yml):

  Simulation.Corners.<Mode>_<Test>_<CornerGroup>[_0 for EMIR]
  Mode_Name = Corner_Group name = the (sweep-expanded) Maestro corner name,
  Test_Name = the Maestro test; Model_File per section mapped through the
  site's model_file_map; Temperature from the corner; Parameters = netlist
  `parameters` + Maestro global vars + corner overrides, values as !!str in
  one-element lists, keys sorted.

Netlist helpers (parameters, DUT ports, vsources, signature) live here too,
because both emir-inputs and the submit/aged code need them.

Python 3.8+, stdlib only.
"""

import ast
import datetime
import hashlib
import math
import os
import platform
import re
import shutil
import socket

import rk_common
import rk_site
from rk_yaml import Tagged, dump

# relkit type -> (RelStudio -t / type dir, yml file name, Rel_Type, script subdir)
RS_TYPES = {
    "aging": ("analog_aging", "analog_aging.yml", "AnalogAging", "analog_aging"),
    "deos": ("dynamic_eos", "DEOS.yml", "DynamicEOS", "dynamic_eos"),
    "emir": ("emir", "EM.yml", "EMIR", "em"),
}

# RelStudio GUI defaults (plan D7). Site `defaults.<type>` and ctx settings
# override them; a null value never overrides.
BUILTIN_DEFAULTS = {
    "aging": {"life_time": "10", "life_time_unit": "years", "start_time": "0n",
              "stop_time": "20n", "eval_temperatures": None},
    "deos": {"life_time": "10", "life_time_unit": "years", "start_time": "0n",
             "stop_time": "20n", "simulation_time": "20n", "tddb_temperature": None},
    "emir": {"run_type": "DYN SEM", "selfheat": True, "em_temperature": 110,
             "rc_corner": None, "rc_temperature": None, "start_time": "0n",
             "stop_time": "20n", "dynamic_time_step": "20p", "life_time": "10",
             "life_time_unit": "years", "method": "iterated", "dspf_file": None,
             "gds_file": None, "layout_lib": None, "layout_view": "layout",
             "supplies": None, "limits": None, "license_policy": None,
             "license_wait_hours": None},
}

# EM.yml Limits as the RelStudio GUI fills them by default.
DEFAULT_LIMITS = [
    ("Dynamic_IR_Limits", 5), ("IR_AVG_Limits", 5), ("IR_MAX_Limit", 5),
    ("IR_MIN_Limit", 5), ("Power_EM_AVG_Limits", 100), ("Power_EM_Peak_Limits", 100),
    ("Power_EM_RMS_Limits", 100), ("Signal_EM_AVG_Limits", 100),
    ("Signal_EM_Peak_Limits", 100), ("Signal_EM_RMS_Limits", 100),
    ("Static_EM_Limits", 100), ("Static_IR_Limits", 3),
]


def default_totem_flow():
    """EM.yml Advance.Totem_Flow as the GUI writes it (site emir.totem_flow merges over)."""
    return {
        "Is_Multi_Process": True,
        "Is_Gui_Background": True,
        "Switch_Model_Table": {"Flag": False, "Internal_Power_Pin": None,
                               "Internal_Ground_Pin": None},
        "Is_Dyn_Ldo": {"Flag": False, "Regulated_Power_Nets": None},
        "Is_Top_Analysis": {"Flag": False, "Is_Skip_Gen_Model": False},
        "Is_Cmm": {"Flag": False, "Cmm_Export_View": "cell_view", "Lef_File": None,
                   "Cmm_Phy_Model": None, "Cmm_Constraint_File": None},
        "Vp_Pairing": None,
        "Is_Post_Sim": True,
        "Is_Internal_Pin": False,
        "Is_Fem_Calculate": False,
        "Is_Fit_Calculate": False,
        "Is_Heat_Sink": False,
        "Macro_Type": "rf",
        "Is_No_Ace": False,
        "Is_Extract_View_Netlist": False,
        "Probe_Bus_Delimiter_Checked": True,
        "Probe_Bus_Delimiter": '"<" "\\<" ">" "\\>"',
        "Apache_Db_Dir": True,
        "Auto_Ploc_Cmd": None,
        "Files_To_Delete": None,
        "Pad_Location_File": None,
    }


ALPS_FLOW = [("en_level", 7), ("r_bti_core_nmos", 1), ("r_bti_core_pmos", 1),
             ("r_bti_io_nmos", 1), ("r_bti_io_pmos", 1)]


# --------------------------------------------------------------------------
# small helpers

def rs_info(run_type):
    if run_type not in RS_TYPES:
        raise rk_common.RkError("unknown run type %r (aging|deos|emir)" % (run_type,))
    return RS_TYPES[run_type]


def num(v):
    """'125' -> 125, '-40' -> -40, '27.5' -> 27.5, 110 -> 110; anything else unchanged."""
    if isinstance(v, bool) or v is None:
        return v
    if isinstance(v, (int, float)):
        if isinstance(v, float) and v.is_integer() and abs(v) < 1e15:
            return int(v)
        return v
    s = str(v).strip()
    if re.match(r"^[-+]?\d+$", s):
        return int(s)
    if re.match(r"^[-+]?(\d+\.\d*|\.\d+|\d+)([eE][-+]?\d+)?$", s):
        f = float(s)
        if f.is_integer() and "e" not in s.lower() and abs(f) < 1e15:
            return int(f)
        return f
    return s


def merge_settings(*layers):
    out = {}
    for layer in layers:
        if not isinstance(layer, dict):
            continue
        for k, v in layer.items():
            if v is not None:
                out[k] = v
    return out


def effective_settings(ctx, site, run_type):
    """settings[run_type] after defaults: builtin < site.defaults.<type> < ctx.settings.<type>."""
    builtin = dict(BUILTIN_DEFAULTS[run_type])
    if run_type == "emir":
        builtin["rc_corner"] = rk_site.get(site, "emir.rc_corner") or "typical"
        builtin["license_policy"] = rk_site.get(site, "emir.license_policy") or "wait_forever"
        builtin["license_wait_hours"] = rk_site.get(site, "emir.license_wait_hours")
        builtin["layout_lib"] = (ctx.get("maestro") or {}).get("lib")
    site_def = rk_site.get(site, "defaults.%s" % run_type) or {}
    ctx_set = ((ctx.get("settings") or {}).get(run_type)) or {}
    eff = merge_settings(builtin, site_def, ctx_set)
    for k in builtin:
        eff.setdefault(k, None)
    return eff


def selected_corners(ctx):
    corners = [c for c in (ctx.get("corners") or []) if c and c.get("selected") is True]
    if not corners:
        raise rk_common.RkError("no corner selected (ctx.corners[].selected)")
    names = [c.get("name") for c in corners]
    dup = sorted(set(n for n in names if names.count(n) > 1))
    if dup:
        raise rk_common.RkError("duplicate corner names: %s" % ", ".join(dup))
    return corners


def corner_temperature(ctx, corner, warnings):
    t = corner.get("temperature")
    if t is None or str(t).strip() == "":
        t = (ctx.get("global_vars") or {}).get("temperature")
        if t is None or str(t).strip() == "":
            warnings.append("corner %s has no temperature; using 27" % corner.get("name"))
            t = "27"
    return str(t).strip()


def corner_key(corner_name, test, run_type):
    key = "%s_%s_%s" % (corner_name, test, corner_name)
    if run_type == "emir":
        key += "_0"
    return key


def map_model_file(path, site):
    for rule in rk_site.get(site, "model_file_map") or []:
        try:
            pat = rule.get("match")
            if pat and re.search(pat, path):
                return re.sub(pat, rule.get("replace") or "", path, count=1)
        except re.error as e:
            raise rk_common.RkError("bad model_file_map regex %r: %s" % (rule.get("match"), e))
    return path


def life_suffix(life_time, unit):
    """'10','years' -> '10y' (RelStudio's <Life>y_point / mapping life_time)."""
    u = (unit or "years").lower()
    letter = {"years": "y", "year": "y", "days": "d", "day": "d", "hours": "h",
              "hour": "h", "months": "m", "month": "m"}.get(u, u[:1] or "y")
    return "%s%s" % (life_time, letter)


# --------------------------------------------------------------------------
# netlist parsing (Spectre syntax as Maestro writes it)

def _logical_lines(text):
    """Yield (lineno, statement) with '\\' continuations joined, comments dropped."""
    buf, start, lang = [], None, "spectre"
    for i, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        s = line.strip()
        if not buf:
            if not s or s.startswith("//") or (lang == "spice" and s.startswith("*")):
                continue
            m = re.match(r"^simulator\s+lang\s*=\s*(\w+)", s)
            if m:
                lang = m.group(1).lower()
                yield i, s
                continue
            start = i
        if s.endswith("\\"):
            buf.append(s[:-1].strip())
            continue
        buf.append(s)
        stmt = " ".join(x for x in buf if x)
        buf = []
        yield start, stmt
    if buf:
        yield start, " ".join(buf)


def split_tokens(s):
    """Whitespace split that keeps (..), [..], "..." together and re-joins 'a = b'."""
    toks, cur, depth, q = [], [], 0, None
    for c in s:
        if q:
            cur.append(c)
            if c == q:
                q = None
            continue
        if c == '"':
            q = c
            cur.append(c)
        elif c in "([":
            depth += 1
            cur.append(c)
        elif c in ")]":
            depth -= 1
            cur.append(c)
        elif c.isspace() and depth <= 0:
            if cur:
                toks.append("".join(cur))
                cur = []
        else:
            cur.append(c)
    if cur:
        toks.append("".join(cur))
    out = []
    for t in toks:
        if out and (t.startswith("=") or out[-1].endswith("=")):
            out[-1] += t
        else:
            out.append(t)
    return out


def parse_assignments(tokens):
    d = {}
    for t in tokens:
        if "=" in t:
            k, _, v = t.partition("=")
            if k:
                d[k.strip()] = v.strip()
    return d


def parse_netlist(path=None, text=None):
    """Parse a Spectre netlist into the pieces relkit needs.

    Returns {"parameters": {name: expr} (top level, file order),
             "subckts": {name: [ports]},
             "instances": [{"name", "nodes", "master", "params", "subckt"}],
             "top_instances": [... with subckt None]}
    """
    if text is None:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    params = {}
    subckts = {}
    instances = []
    stack = []
    lang = "spectre"
    for _ln, stmt in _logical_lines(text):
        m = re.match(r"^simulator\s+lang\s*=\s*(\w+)", stmt)
        if m:
            lang = m.group(1).lower()
            continue
        if lang != "spectre":
            continue
        toks = split_tokens(stmt)
        if not toks:
            continue
        head = toks[0]
        if head in ("subckt", "inline") and len(toks) >= 2:
            if head == "inline":
                toks = toks[1:]
            if len(toks) < 2:
                continue
            name = toks[1]
            ports = []
            rest = toks[2:]
            if rest and rest[0].startswith("("):
                ports = rest[0].strip("()").split()
            else:
                ports = [t for t in rest if "=" not in t]
            subckts[name] = ports
            stack.append(name)
            continue
        if head == "ends":
            if stack:
                stack.pop()
            continue
        if head == "parameters":
            if not stack:
                for k, v in parse_assignments(toks[1:]).items():
                    params[k] = v
            continue
        if head in ("include", "ahdl_include", "global", "save", "simulatorOptions",
                    "statistics", "library", "endlibrary", "section", "endsection",
                    "model", "real", "ic", "nodeset") or head.startswith("//"):
            continue
        # instance: NAME (nodes) MASTER params...
        if len(toks) >= 3 and toks[1].startswith("(") and toks[1].endswith(")"):
            nodes = toks[1][1:-1].split()
            instances.append({"name": head, "nodes": nodes, "master": toks[2],
                              "params": parse_assignments(toks[3:]),
                              "subckt": stack[-1] if stack else None})
    return {"parameters": params, "subckts": subckts, "instances": instances,
            "top_instances": [i for i in instances if i["subckt"] is None]}


def netlist_signature(path):
    """sha1 over the sorted set of subckt names and (subckt/instance) names.

    Insensitive to parameter values / sizes; changes when instances are added,
    removed or renamed -- what matters for HRMI aging data (plan 4.6)."""
    nl = parse_netlist(path)
    keys = ["S:" + s for s in nl["subckts"]]
    keys += ["I:%s/%s" % (i["subckt"] or "", i["name"]) for i in nl["instances"]]
    h = hashlib.sha1()
    for k in sorted(set(keys)):
        h.update(k.encode("utf-8"))
        h.update(b"\n")
    return h.hexdigest()


def file_sha1(path, chunk=1 << 20):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


# --- expression evaluation (supply prefill) --------------------------------

_SI = {"T": 1e12, "G": 1e9, "M": 1e6, "K": 1e3, "k": 1e3, "m": 1e-3, "u": 1e-6,
       "n": 1e-9, "p": 1e-12, "f": 1e-15, "a": 1e-18}
_NUM_RE = re.compile(r"(?<![A-Za-z0-9_.])(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?(meg|[TGMKkmunpfa])?(?![A-Za-z0-9_])")
_FUNCS = {"min": min, "max": max, "abs": abs, "sqrt": math.sqrt, "exp": math.exp,
          "log": math.log, "log10": math.log10, "pow": pow, "int": int}


def _si_to_float(expr):
    def repl(m):
        v = float(m.group(1) + (m.group(2) or ""))
        suf = m.group(3)
        if suf == "meg":
            v *= 1e6
        elif suf:
            v *= _SI[suf]
        return repr(v)
    return _NUM_RE.sub(repl, expr)


def eval_expr(expr, params, _seen=None):
    """Evaluate a Spectre parameter expression; None if not resolvable."""
    if expr is None:
        return None
    seen = set() if _seen is None else _seen
    s = str(expr).strip().strip('"')
    if not s:
        return None
    try:
        tree = ast.parse(_si_to_float(s).replace("^", "**"), mode="eval")
    except SyntaxError:
        return None

    def ev(n):
        if isinstance(n, ast.Expression):
            return ev(n.body)
        if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)):
            return float(n.value)
        if isinstance(n, ast.BinOp):
            a, b = ev(n.left), ev(n.right)
            if isinstance(n.op, ast.Add):
                return a + b
            if isinstance(n.op, ast.Sub):
                return a - b
            if isinstance(n.op, ast.Mult):
                return a * b
            if isinstance(n.op, ast.Div):
                return a / b
            if isinstance(n.op, ast.Pow):
                return a ** b
            raise ValueError("operator")
        if isinstance(n, ast.UnaryOp):
            v = ev(n.operand)
            if isinstance(n.op, ast.USub):
                return -v
            if isinstance(n.op, ast.UAdd):
                return v
            raise ValueError("unary")
        if isinstance(n, ast.Name):
            if n.id in seen or n.id not in params:
                raise ValueError("unknown %s" % n.id)
            seen.add(n.id)
            v = eval_expr(params[n.id], params, seen)
            seen.discard(n.id)
            if v is None:
                raise ValueError("unresolved %s" % n.id)
            return v
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id in _FUNCS:
            return float(_FUNCS[n.func.id](*[ev(a) for a in n.args]))
        raise ValueError("unsupported")

    try:
        return ev(tree)
    except (ValueError, ZeroDivisionError, OverflowError, TypeError, RecursionError):
        return None


def fmt_volt(v):
    if v is None:
        return None
    s = "%.6g" % v
    if s in ("-0",):
        s = "0"
    return s


GROUND_RE = re.compile(r"^(0|gnd!?|.*gnd.*|.*vss.*|vsub.*|.*_gnd)$", re.I)
POWER_RE = re.compile(r"^(.*vdd.*|.*vcc.*|vpp.*|vbat.*|.*pwr.*|.*avdd.*|.*dvdd.*|vio.*|vdda?\d*.*)$", re.I)


def classify_port(name, site):
    pw = [n.lower() for n in (rk_site.get(site, "extract.power_nets") or [])]
    gn = [n.lower() for n in (rk_site.get(site, "extract.ground_nets") or [])]
    low = name.lower()
    if low in gn:
        return "ground"
    if low in pw:
        return "power"
    if GROUND_RE.match(name):
        return "ground"
    if POWER_RE.match(name):
        return "power"
    return "signal"


def node_voltages(nl, params):
    """Solve DC node voltages from top-level ideal vsources (only dc=, chained)."""
    volts = {"0": 0.0, "gnd!": 0.0}
    srcs = []
    for inst in nl["top_instances"]:
        if inst["master"] == "vsource" and len(inst["nodes"]) >= 2:
            dc = inst["params"].get("dc")
            if dc is None and inst["params"].get("type", "dc") == "dc":
                dc = "0"
            srcs.append((inst["nodes"][0], inst["nodes"][1], eval_expr(dc, params)))
    changed = True
    while changed:
        changed = False
        for p, n, v in srcs:
            if v is None:
                continue
            if n in volts and p not in volts:
                volts[p] = volts[n] + v
                changed = True
            elif p in volts and n not in volts:
                volts[n] = volts[p] - v
                changed = True
    return volts


def emir_inputs(ctx, site):
    dut = ctx.get("dut") or {}
    netlist_path = ((ctx.get("netlist") or {}).get("path")
                    or (ctx.get("netlist") or {}).get("source"))
    warnings = []
    ports_out, power, ground, unresolved = [], {}, {}, []
    nl = None
    if netlist_path and os.path.isfile(netlist_path):
        nl = parse_netlist(netlist_path)
    else:
        warnings.append("netlist not available (%s); ports from ctx.dut.terms only" % netlist_path)
    params = dict((nl or {}).get("parameters") or {})
    for k, v in (ctx.get("global_vars") or {}).items():
        params.setdefault(k, v)
    ports = list(dut.get("terms") or [])
    port_net = {}
    if nl is not None:
        sub_ports = nl["subckts"].get(dut.get("cell") or "")
        inst = None
        for i in nl["top_instances"]:
            if i["name"] == dut.get("inst"):
                inst = i
                break
        if sub_ports is not None:
            ports = list(sub_ports)
        elif inst is None:
            warnings.append("DUT subckt %s not found in the netlist" % dut.get("cell"))
        if inst is not None and sub_ports is not None and len(inst["nodes"]) == len(sub_ports):
            port_net = dict(zip(sub_ports, inst["nodes"]))
        elif inst is None:
            warnings.append("DUT instance %s not found at the netlist top level" % dut.get("inst"))
    volts = node_voltages(nl, params) if nl is not None else {"0": 0.0}
    for p in ports:
        kind = classify_port(p, site)
        net = port_net.get(p)
        v = None
        if net is not None:
            v = volts.get(net)
            if v is None and GROUND_RE.match(net or ""):
                v = 0.0
        entry = {"name": p, "net": net, "kind": kind, "voltage": fmt_volt(v)}
        ports_out.append(entry)
        if kind == "ground":
            ground[p] = fmt_volt(v) if v is not None else "0"
        elif kind == "power":
            if v is None:
                unresolved.append(p)
                power[p] = None
            else:
                power[p] = fmt_volt(v)
    dspf, gds = artifact_candidates(ctx, site)
    return {"dut_ports": ports_out, "supplies": {"power": power, "ground": ground},
            "unresolved": unresolved, "dspf_candidates": dspf, "gds_candidates": gds,
            "warnings": warnings}


def artifact_candidates(ctx, site):
    dut_cell = (ctx.get("dut") or {}).get("cell")
    root = rk_site.get(site, "artifact_root")
    found_d, found_g = [], []
    if root and dut_cell:
        base = os.path.join(root, dut_cell)
        if os.path.isdir(base):
            for dirpath, dirnames, filenames in os.walk(base):
                depth = os.path.relpath(dirpath, base).count(os.sep)
                if depth >= 2:
                    dirnames[:] = []
                for fn in filenames:
                    low = fn.lower()
                    full = os.path.join(dirpath, fn).replace("\\", "/")
                    if low.endswith((".dspf", ".spf", ".spef.dspf")):
                        found_d.append(full)
                    elif low.endswith((".gds", ".gds2", ".gdsii", ".gds.gz")):
                        found_g.append(full)

    def by_mtime(lst):
        return sorted(set(lst), key=lambda p: -os.path.getmtime(p))
    em = ((ctx.get("settings") or {}).get("emir")) or {}
    d, g = by_mtime(found_d), by_mtime(found_g)
    for key, lst in (("dspf_file", d), ("gds_file", g)):
        v = em.get(key)
        if v and v not in lst and os.path.isfile(v):
            lst.insert(0, v)
    return d, g


# --------------------------------------------------------------------------
# yml document

def tool_versions(site, warnings):
    out = {}
    missing = []
    for name in rk_site.get(site, "tool_version_names") or []:
        p = shutil.which(name)
        if p:
            out[name] = p.replace("\\", "/")
        else:
            missing.append(name)
    if missing:
        warnings.append("ToolVersion: not on PATH (omitted): %s" % ", ".join(missing))
    return out


def system_version():
    for p in ("/etc/redhat-release", "/etc/centos-release", "/etc/system-release"):
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                s = f.read().strip()
                if s:
                    return s.splitlines()[0]
        except OSError:
            pass
    try:
        with open("/etc/os-release", "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return platform.platform()


def simulation_cmd(site, run_type):
    sim = rk_site.get(site, "simulator") or {}
    custom = sim.get("Simulation_Cmd")
    if isinstance(custom, dict):
        custom = custom.get(run_type)
    if custom:
        return custom
    acc = sim.get("Simulator_Accuracy") or "moderate"
    mt = sim.get("Sim_Mt") or 8
    if run_type == "emir":
        return "alps input.scs -format fsdb -ade -o SIM_DIR/psf -p %s -errpreset %s " % (mt, acc)
    return "alps -errpreset %s +mt %s -lqtimeout -closelink -d" % (acc, mt)


def simulator_block(site, run_type):
    sim = rk_site.get(site, "simulator") or {}
    return {
        "Name": sim.get("Name") or "alps",
        "Simulator_Accuracy": sim.get("Simulator_Accuracy") or "moderate",
        "Sim_Mt": sim.get("Sim_Mt") if sim.get("Sim_Mt") is not None else 8,
        "Simulation_Options": sim.get("Simulation_Options"),
        "Simulation_Cmd": simulation_cmd(site, run_type),
        "Flag_Is_Delete_Simulation_Data": bool(sim.get("Flag_Is_Delete_Simulation_Data") or False),
        "Flag_Is_Save_Final_Result": bool(sim.get("Flag_Is_Save_Final_Result") or False),
    }


def cluster_block(site):
    c = rk_site.get(site, "cluster") or {}
    keys = ["Using_Cluster", "Cluster_Type", "Group", "Queue", "CPU", "Memory", "GPU",
            "Machine_Arch"]
    out = {}
    for k in keys:
        v = c.get(k)
        out[k] = v
    if out["Using_Cluster"] is None:
        out["Using_Cluster"] = True
    return out


def corner_group(corner, site, warnings):
    models, sections = [], []
    for s in corner.get("sections") or []:
        mf = s.get("model_file") or ""
        sec = s.get("section")
        if not sec:
            warnings.append("corner %s: model file %s has no section" % (corner.get("name"), mf))
            sec = ""
        models.append(map_model_file(mf, site))
        sections.append(sec)
    if not models:
        warnings.append("corner %s has no model sections" % corner.get("name"))
    return {corner["name"]: {"Model_File": models, "Sections": sections}}


def corner_parameters(ctx, corner, netlist_params):
    params = dict(netlist_params or {})
    for k, v in (ctx.get("global_vars") or {}).items():
        if v is not None:
            params[k] = v
    for k, v in (corner.get("vars") or {}).items():
        if v is not None:
            params[k] = v
    params.pop("temperature", None)
    out = {}
    for k in sorted(params):
        out[k] = [Tagged(str(params[k]))]
    return out


def netlist_params_for(ctx, warnings):
    nl = ctx.get("netlist") or {}
    path = nl.get("path") or nl.get("source")
    if path and os.path.isfile(path):
        try:
            return parse_netlist(path)["parameters"]
        except (OSError, UnicodeError) as e:
            warnings.append("cannot read netlist %s: %s" % (path, e))
    if isinstance(nl.get("parameters"), dict):   # rkMae's copy of the netlist parameters
        return dict(nl["parameters"])
    warnings.append("netlist %s not readable; Parameters from Maestro variables only" % path)
    return {}


def build_doc(ctx, site, run_type, work_dir, history, now=None, host=None,
              tools=None, sysver=None):
    """Build the yml document (an ordered dict tree).

    Returns (doc, info) with info = {"corner_keys", "corner_map", "warnings",
    "settings"}. `now` / `host` / `tools` / `sysver` are injectable for tests."""
    rs_type, _yml_name, rel_type, script_sub = rs_info(run_type)
    warnings = []
    settings = effective_settings(ctx, site, run_type)
    corners = selected_corners(ctx)
    test = ctx.get("test")
    if not test:
        raise rk_common.RkError("ctx.test is empty")
    dut = ctx.get("dut") or {}
    cell_name = dut.get("cell")
    if not cell_name:
        raise rk_common.RkError("ctx.dut.cell is empty (choose the DUT first)")
    netlist = (ctx.get("netlist") or {}).get("path")
    if not netlist:
        raise rk_common.RkError("ctx.netlist.path is empty (export the netlist first)")
    rel_tool_dir = (site.get("relstudio_home") or ctx.get("relstudio_home") or "").rstrip("/")
    if not rel_tool_dir:
        warnings.append("relstudio_home unknown: Rel_Tool_Dir / Script_Dir left empty")
    nparams = netlist_params_for(ctx, warnings)
    tech = rk_site.get(site, "tech") or {}
    for k in ("Foundry", "Technology", "Tech_Voltage", "Tech_Layout", "Rel_Tech_Dir"):
        if tech.get(k) is None:
            warnings.append("site tech.%s is not set" % k)
    sim_block = simulator_block(site, run_type)
    clu_block = cluster_block(site)

    corner_docs = {}
    corner_keys = []
    corner_map = []
    for idx, c in enumerate(corners, 1):
        key = corner_key(c["name"], test, run_type)
        temp = corner_temperature(ctx, c, warnings)
        cg = corner_group(c, site, warnings)
        params = corner_parameters(ctx, c, nparams)
        if run_type == "aging":
            entry, evals = _aging_corner(ctx, site, settings, c, test, netlist, temp,
                                         sim_block, clu_block, cg, params)
            corner_map.append({"key": key, "corner": c["name"], "sim": "sim%d" % idx,
                               "temperature": temp, "mode": "Stress_1",
                               "eval_temperatures": evals})
        elif run_type == "deos":
            entry = _deos_corner(settings, c, test, netlist, temp, sim_block, clu_block,
                                 cg, params)
            corner_map.append({"key": key, "corner": c["name"], "sim": "sim%d" % idx,
                               "temperature": temp, "mode": "Stress"})
        else:
            entry = _emir_corner(ctx, site, settings, c, test, netlist, temp, sim_block,
                                 clu_block, cg, params, warnings)
            corner_map.append({"key": key, "corner": c["name"], "sim": "sim%d" % idx,
                               "temperature": temp, "mode": "State_1"})
        corner_docs[key] = entry
        corner_keys.append(key)

    if run_type == "aging":
        simulation = {"Flow_Type": "Native", "Agemos_Flag": False, "Selfheat_Bsim": False,
                      "Corners": corner_docs,
                      "Advance": {"Tmi_Option": None, "Alps_Flow": dict(ALPS_FLOW)},
                      "Rel_Type": rel_type, "History": int(history)}
    elif run_type == "deos":
        simulation = {"Flow_Type": "Native", "Is_Alps_Boost": False, "Aps": "+aps",
                      "Waveform_Debug": False, "Cell_Counts": 1, "Corners": corner_docs,
                      "Rel_Type": rel_type, "History": int(history)}
    else:
        simulation = {"Corners": corner_docs, "Rel_Type": rel_type, "History": int(history)}

    now = now or datetime.datetime.now()
    common = {
        "Project_Name": Tagged(ctx.get("project_name") or site.get("project_name") or "relsim1"),
        "Cell_Name": Tagged(cell_name),
        "IP_Name": Tagged(ctx.get("ip_name") or (ctx.get("maestro") or {}).get("cell") or cell_name),
        "Technology": num(tech.get("Technology")),
        "Tech_Voltage": tech.get("Tech_Voltage"),
        "Tech_Layout": tech.get("Tech_Layout"),
        "Rel_Tool_Dir": rel_tool_dir,
        "Rel_Tech_Dir": tech.get("Rel_Tech_Dir"),
        "Configuration_Dir": ctx.get("workarea"),
        "Script_Dir": ("%s/script/%s" % (rel_tool_dir, script_sub)) if rel_tool_dir else "",
        "Work_Dir": work_dir,
        "Sim_Start_Time": now.strftime("%Y-%m-%d %H:%M:%S"),
        "Sim_Machine": host or ctx.get("host") or socket.gethostname(),
        "User_Name": ctx.get("user") or rk_site.default_user(),
    }
    tv = tools if tools is not None else tool_versions(site, warnings)
    if tv:
        common["ToolVersion"] = tv
    common["SystemVersion"] = sysver if sysver is not None else system_version()
    common["rerunDir"] = ""
    common["jobUniqueIdentifier"] = ""
    common["Foundry"] = tech.get("Foundry")
    doc = {"Simulation": simulation, "Common": common}
    return doc, {"corner_keys": corner_keys, "corner_map": corner_map,
                 "warnings": warnings, "settings": settings}


def _base_entry(mode_type, netlist):
    return {"Mode_Type": mode_type, "Netlist_File": netlist}


def _aging_corner(ctx, site, st, c, test, netlist, temp, sim_block, clu_block, cg, params):
    am = rk_site.get(site, "aging_model") or {}
    evals = st.get("eval_temperatures")
    if evals in (None, [], ""):
        evals = [temp]
    elif not isinstance(evals, list):
        evals = [x for x in re.split(r"[\s,]+", str(evals)) if x]
    evals = [str(x).strip() for x in evals]
    windows = [{"State_1": {"Start_Time": st["start_time"], "Stop_Time": st["stop_time"],
                            "Life_Time": [Tagged(str(st["life_time"]))],
                            "Life_Time_Unit": st["life_time_unit"]}}]

    def entry(mode_type, temps):
        e = _base_entry(mode_type, netlist)
        e.update({
            "Analysis_Type": "multi_age_points",
            "Netlist_Format": "spectre",
            "Model_File": am.get("Model_File"),
            "Relxpert_Uri_Libs": am.get("Relxpert_Uri_Libs"),
            "Mode_Name": Tagged(c["name"]),
            "Test_Name": Tagged(test),
            "Simulator": dict(sim_block),
            "Cluster": dict(clu_block),
            "Skip_Simulation": {"Flag": False},
            "Corner_Group": _copy_cg(cg),
            "Temperature": [num(t) for t in temps],
            "Time_Windows": _copy_windows(windows),
            "Parameter_Groups": None,
            "Parameters": dict(params),
        })
        return e

    layout = (site.get("aging_eval_layout") or "entries")
    items = []
    if layout == "temperature_list":
        items.append({"Aged_1": entry("Aged", evals)})
    else:
        for k, t in enumerate(evals, 1):
            items.append({"Aged_%d" % k: entry("Aged", [t])})
    items.append({"Stress_1": entry("Stress", [temp])})
    return items, evals


def _copy_cg(cg):
    return {k: {"Model_File": list(v["Model_File"]), "Sections": list(v["Sections"])}
            for k, v in cg.items()}


def _copy_windows(w):
    out = []
    for item in w:
        out.append({k: dict(v) for k, v in item.items()})
    return out


def _deos_corner(st, c, test, netlist, temp, sim_block, clu_block, cg, params):
    tddb = st.get("tddb_temperature")
    e = _base_entry("Stress", netlist)
    e.update({
        "Mode_Name": Tagged(c["name"]),
        "Test_Name": Tagged(test),
        "Simulator": dict(sim_block),
        "Cluster": dict(clu_block),
        "Skip_Simulation": {"Flag": False},
        "Corner_Group": _copy_cg(cg),
        "Temperature": [num(temp)],
        "Time_Windows": [{"State_1": {
            "Start_Time": st["start_time"], "Stop_Time": st["stop_time"],
            "Life_Time": num(st["life_time"]), "Simulation_Time": st["simulation_time"],
            "Life_Time_Unit": st["life_time_unit"],
            "Tddb_Temperature": num(tddb if tddb is not None else temp)}}],
        "Parameter_Groups": None,
        "Parameters": dict(params),
    })
    return e


def _emir_corner(ctx, site, st, c, test, netlist, temp, sim_block, clu_block, cg, params,
                 warnings):
    dut = ctx.get("dut") or {}
    for k in ("dspf_file", "gds_file"):
        if not st.get(k):
            warnings.append("EMIR setting %s is empty" % k)
    totem = default_totem_flow()
    over = rk_site.get(site, "emir.totem_flow")
    if isinstance(over, dict):
        totem = rk_site.deep_merge(totem, over)
    supplies = st.get("supplies") or {}
    power = {k: num(v) for k, v in ((supplies.get("power") or {}).items()) if v is not None}
    ground = {k: num(v if v is not None else 0) for k, v in (supplies.get("ground") or {}).items()}
    if not power:
        warnings.append("EMIR: no power supply net given")
    if not ground:
        warnings.append("EMIR: no ground net given")
    limits = dict(DEFAULT_LIMITS)
    for k, v in (st.get("limits") or {}).items():
        if v is not None:
            limits[k] = num(v)
    rc_t = st.get("rc_temperature")
    e = _base_entry("Stress", netlist)
    e.update({
        "Flow_Type": "Totem",
        "isNewPredictFlow": False,
        "Run_Type": st["run_type"],
        "Is_Run_Selfheat": bool(st.get("selfheat")),
        "Is_Calibre_Flow": False,
        "Sim_Cell": dut.get("cell"),
        "Instance_Name": dut.get("inst"),
        "Gds_File": st.get("gds_file"),
        "Dspf_File": st.get("dspf_file"),
        "Gds_Map_File": rk_site.get(site, "emir.gds_map_file"),
        "Method": st.get("method") or "iterated",
        "Sim_Temperature": [num(temp)],
        "Rc_Temperature": num(rc_t if rc_t is not None else temp),
        "Rc_Corner": st.get("rc_corner"),
        "Advance": {"Totem_Flow": totem, "Patron_Flow": "", "Predict_Flow": ""},
        "Supplies": {"Power": power, "Ground": ground},
        "Limits": limits,
        "Mode_Name": Tagged(c["name"]),
        "Test_Name": Tagged(test),
        "Simulator": dict(sim_block),
        "Cluster": dict(clu_block),
        "Skip_Simulation": {"Flag": False, "Start_Step": 0, "Is_Run_Through": True},
        "Corner_Group": _copy_cg(cg),
        "Time_State": {"Is_Multi_State": False, "States": [{"State_1": {
            "Start_Time": st["start_time"], "Stop_Time": st["stop_time"],
            "Dynamic_Time_Step": st["dynamic_time_step"],
            "Em_Temperature": num(st["em_temperature"]),
            "Life_Time": num(st["life_time"]), "Life_Time_Unit": st["life_time_unit"]}}]},
        "Parameter_Groups": None,
        "Parameters": dict(params),
    })
    return e


def write_yml(path, doc):
    d = os.path.dirname(os.path.abspath(path))
    if d and not os.path.isdir(d):
        os.makedirs(d)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(dump(doc))
    os.replace(tmp, path)
    return path


# --------------------------------------------------------------------------
# subcommand handlers

def _cmd_build_yml(args, ctx):
    run_type = args.type or ctx.get("run_type")
    if not run_type:
        raise rk_common.RkError("no run type (--type or ctx.run_type)")
    rs_type, yml_name, _rel, _sub = rs_info(run_type)
    site, _p, site_warn = rk_site.site_from_ctx(ctx)
    if args.work_dir:
        work_dir = args.work_dir.rstrip("/")
        base = os.path.basename(work_dir)
        history = int(base) if base.isdigit() else 1
    else:
        import rk_submit  # lazy: rk_submit imports this module
        work_dir, history = rk_submit.preview_work_dir(ctx, site)
    doc, info = build_doc(ctx, site, run_type, work_dir, history)
    yml_path = args.yml
    if not yml_path:
        stem = args.out[:-5] if args.out.endswith(".json") else args.out
        yml_path = stem + ".yml"
    write_yml(yml_path, doc)
    return {"yml_path": os.path.abspath(yml_path).replace("\\", "/"), "rs_type": rs_type,
            "yml_name": yml_name, "work_dir": work_dir, "rs_history": history,
            "corner_keys": info["corner_keys"], "corner_map": info["corner_map"],
            "warnings": site_warn + info["warnings"]}


def _cmd_emir_inputs(args, ctx):
    site, _p, site_warn = rk_site.site_from_ctx(ctx)
    out = emir_inputs(ctx, site)
    out["warnings"] = site_warn + out["warnings"]
    return out


def register(subparsers):
    p = rk_common.add_command(subparsers, "build-yml", _cmd_build_yml,
                              "build the RelStudio yml for ctx (preview / golden tests)",
                              ctx_required=True)
    p.add_argument("--type", choices=["aging", "deos", "emir"], help="default: ctx.run_type")
    p.add_argument("--yml", help="where to write the yml (default: <out without .json>.yml)")
    p.add_argument("--work-dir", help="Common.Work_Dir to write (default: computed, not created)")
    p = rk_common.add_command(subparsers, "emir-inputs", _cmd_emir_inputs,
                              "DUT ports, supply prefill and DSPF/GDS candidates for the EMIR page",
                              ctx_required=True)
