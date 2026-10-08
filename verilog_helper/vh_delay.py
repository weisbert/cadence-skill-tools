#!/usr/bin/env python3
"""vh_delay -- inject realistic gate/FF delays into Verilog-AMS leaf models.

The red-zone `verilogams` cellviews of a divider block are typically written with
NO timing (`Q <= D;`) or with ad-hoc `#10`s.  A zero-delay model hides every
hold race and every ripple-accumulation problem, so a "PASS" proves less than it
looks.  This tool takes a **delay table** (JSON: class -> ps + module -> class)
and mechanically rewrites the models so every functional assignment carries a
named, overridable delay parameter.

  parameter real VH_TPD_DFF = 50.0 * VH_TPD_SCALE_P;   // ps, file timescale aware
  always @(posedge clk ...) Q <= #(VH_TPD_DFF) D;

Properties
  * NON-DESTRUCTIVE by default: `--src DIR --out DIR2` writes copies.  `--in-place`
    is opt-in and always leaves a `<file>.orig` backup.
  * IDEMPOTENT: every injected module carries a `// ---- VH_DELAY <ver> BEGIN`
    marker plus a `// VH_ORIG [...]` record of the delays that were there before.
    Re-applying reverts first, then re-injects -- it never double-injects, and
    `revert` restores the file byte-for-byte.
  * TIMESCALE AWARE: a `1ps/1ps` file gets `50.0`, a `1s/1fs` file gets `50.0e-12`.
  * OVERRIDABLE FROM THE COMMAND LINE, no re-injection and no file edit:
        xrun ... +define+VH_TPD_SCALE=2.0            # scale every class
        xrun ... +define+VH_TPD_DFF_PS=75            # one class, absolute ps
    (`+define+` was chosen over `-defparam` because these leaves are instantiated
    hundreds of times -- a macro hits every instance, a defparam would need a path
    per instance.  Verified on xrun 18.03; `+define+` is core Verilog-2001, so it
    carries to 19.04.)
  * POLICY: the power-fail / async-clear branch (`if (!powerOK) ...`) is NEVER
    delayed.  A supply collapse must clamp immediately; delaying it would inject
    phantom edges after power removal.  Only the functional branch is delayed.

CLI
  vh_delay.py apply  --table T --src DIR [--out DIR | --in-place] [--scale S] [--dry-run]
  vh_delay.py report --src DIR [--table T]
  vh_delay.py revert --src DIR [--out DIR | --in-place] [--dry-run]
  vh_delay.py flags  --table T [--scale S]        # print the xrun +define+ line
  vh_delay.py apply  --table T --in-place --cdslib cds.lib --lib MYLIB   # OA cellviews
"""
import os
import re
import sys
import json
import shutil
import difflib
import argparse

VERSION = "v1"
MARK_BEGIN = "// ---- VH_DELAY %s BEGIN" % VERSION
MARK_END = "// ---- VH_DELAY %s END ----" % VERSION
SCALE_PARAM = "VH_TPD_SCALE_P"
SCALE_MACRO = "VH_TPD_SCALE"

TIME_UNITS = {"s": 1.0, "ms": 1e-3, "us": 1e-6, "ns": 1e-9, "ps": 1e-12, "fs": 1e-15}

SRC_EXT = (".vams", ".va", ".v")


# --------------------------------------------------------------------------
# lexical helpers
# --------------------------------------------------------------------------
def mask_comments(text):
    """Return a same-length copy with comments/strings blanked (newlines kept).

    All structural scanning runs on this mask so a `//` comment can never be
    mistaken for code; edits are applied to the original text by offset.
    """
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            for k in range(i, min(j + 1, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = min(j + 1, n)
        else:
            i += 1
    return "".join(out)


_BLOCKWORD = re.compile(r"\b(begin|end|case|casex|casez|endcase|fork|join)\b")


def _skip_ws(scan, i):
    n = len(scan)
    while i < n and scan[i].isspace():
        i += 1
    return i


def _match_paren(scan, i):
    """i must point at '('; return index just past the matching ')'."""
    depth, n = 0, len(scan)
    while i < n:
        if scan[i] == "(":
            depth += 1
        elif scan[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def stmt_end(scan, i):
    """i = start of a statement (ws ok); return index just past that statement."""
    n = len(scan)
    i = _skip_ws(scan, i)
    if i >= n:
        return n
    opener = None
    for w in ("begin", "fork", "case", "casex", "casez"):
        if scan.startswith(w, i) and (i + len(w) >= n or not (scan[i + len(w)].isalnum() or scan[i + len(w)] == "_")):
            opener = w
            break
    if opener is None:
        j = scan.find(";", i)
        return n if j < 0 else j + 1
    depth = 0
    for m in _BLOCKWORD.finditer(scan, i):
        w = m.group(1)
        if w in ("begin", "fork", "case", "casex", "casez"):
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                return m.end()
    return n


def find_modules(text):
    """[(name, start, end)] -- start at 'module', end just past 'endmodule'."""
    scan = mask_comments(text)
    out = []
    for m in re.finditer(r"\bmodule\s+([A-Za-z_]\w*)", scan):
        e = scan.find("endmodule", m.end())
        e = len(scan) if e < 0 else e + len("endmodule")
        out.append((m.group(1), m.start(), e))
    return out


def module_timescale(text, mod_start, default=(1.0, 1e-15)):
    """(unit_sec, prec_sec) of the last `timescale before mod_start."""
    last = None
    for m in re.finditer(r"`timescale\s*(\d+)\s*(fs|ps|ns|us|ms|s)\s*/\s*(\d+)\s*(fs|ps|ns|us|ms|s)",
                         text[:mod_start]):
        last = m
    if not last:
        return default
    return (int(last.group(1)) * TIME_UNITS[last.group(2)],
            int(last.group(3)) * TIME_UNITS[last.group(4)])


def header_end(scan, mod_start):
    """Index just past the `);` that closes the module header."""
    i = scan.find("(", mod_start)
    semi = scan.find(";", mod_start)
    if i < 0 or (0 <= semi < i):          # module foo;  (no port list)
        return semi + 1 if semi >= 0 else mod_start
    j = _match_paren(scan, i)
    k = scan.find(";", j)
    return (k + 1) if k >= 0 else j


# --------------------------------------------------------------------------
# site discovery
# --------------------------------------------------------------------------
ASSIGN_RE = re.compile(
    r"(?P<lhs>[A-Za-z_]\w*)\s*(?P<idx>\[[^\]\n]*\]\s*)?"
    r"(?P<op><=|=)(?![=<>])\s*"
    r"(?P<dly>#\s*(?:\([^()]*\)|[0-9][0-9_.eE]*(?:[+-]\d+)?)\s*)?")

PREV_OK = (";", ")", "begin", "end", "else", "do")
CONST_RHS = re.compile(r"^(?:\d+\s*'\s*[bodhBODH][0-9a-fA-FxXzZ_?]+|[0-9][0-9_]*|1'[bB][01xXzZ])$")


def _prev_token(scan, i):
    j = i - 1
    while j >= 0 and scan[j].isspace():
        j -= 1
    if j < 0:
        return ""
    if scan[j].isalnum() or scan[j] == "_":
        k = j
        while k >= 0 and (scan[k].isalnum() or scan[k] == "_"):
            k -= 1
        return scan[k + 1:j + 1]
    return scan[j]


def _regions(scan, mod_start, mod_end, kw):
    """Extents of `always`/`initial` statements inside the module."""
    out = []
    for m in re.finditer(r"\b%s\b" % kw, scan[mod_start:mod_end]):
        i = mod_start + m.end()
        i = _skip_ws(scan, i)
        if kw == "always" and i < len(scan) and scan[i] == "@":
            i = _skip_ws(scan, i + 1)
            if i < len(scan) and scan[i] == "(":
                i = _match_paren(scan, i)
            elif i < len(scan) and scan[i] == "*":
                i += 1
        out.append((mod_start + m.start(), stmt_end(scan, i)))
    return out


def _guard_regions(scan, lo, hi):
    """Extents of the `if (!powerOK) <stmt>` power-fail branches in [lo,hi)."""
    out = []
    for m in re.finditer(r"\bif\s*\(\s*!\s*\(?\s*(?:powerOK|powerok|power_on|power_ok)\b",
                         scan[lo:hi]):
        i = lo + m.start()
        p = scan.find("(", i)
        j = _match_paren(scan, p)
        out.append((i, stmt_end(scan, j)))
    return out


def _in(spans, pos):
    return any(a <= pos < b for a, b in spans)


def module_sites(text, scan, mod_start, mod_end, delay_const_rhs=False):
    """Delay sites in one module: [{'lhs','op','dly','dly_span','rhs','line'}]."""
    always = _regions(scan, mod_start, mod_end, "always")
    initial = _regions(scan, mod_start, mod_end, "initial")
    guards = []
    for a, b in always:
        guards += _guard_regions(scan, a, b)
    sites = []
    for a, b in always:
        for m in ASSIGN_RE.finditer(scan, a, b):
            pos = m.start()
            if _in(initial, pos) or _in(guards, pos):
                continue
            if _prev_token(scan, pos) not in PREV_OK:
                continue
            semi = scan.find(";", m.end())
            if semi < 0 or semi > b:
                continue
            rhs = text[m.end():semi].strip()
            if not delay_const_rhs and CONST_RHS.match(rhs.replace(" ", "")):
                continue
            sites.append({
                "lhs": m.group("lhs"), "op": m.group("op"),
                "dly": (m.group("dly") or "").strip(),
                # span starts AT the operator: delayed sites are normalised to a
                # NON-blocking assignment (a blocking `= #d` would suspend the
                # always block for d and can swallow an input event).
                "dly_span": (m.start("op"), m.end()),
                "rhs": rhs, "line": text.count("\n", 0, pos) + 1,
            })
    sites.sort(key=lambda s: s["dly_span"][0])
    return sites


ASSIGN_STMT_RE = re.compile(
    r"\bassign\s+(?P<dly>#\s*(?:\([^()]*\)|[0-9][0-9_.eE]*)\s*)?(?P<lhs>[A-Za-z_]\w*)\s*=")


def module_assign_sites(text, scan, mod_start, mod_end, names):
    """Continuous-assign sites whose target is in `names` (explicit opt-in)."""
    out = []
    for m in ASSIGN_STMT_RE.finditer(scan, mod_start, mod_end):
        if m.group("lhs") not in names:
            continue
        # span to replace = everything between the `assign` keyword and the target
        a = m.start() + len("assign")
        b = m.start("lhs")
        out.append({"lhs": m.group("lhs"), "op": "assign",
                    "dly": (m.group("dly") or "").strip(), "dly_span": (a, b),
                    "rhs": "", "line": text.count("\n", 0, m.start()) + 1})
    return out


# --------------------------------------------------------------------------
# table
# --------------------------------------------------------------------------
class Table(object):
    def __init__(self, data, scale=None):
        self.d = data
        self.classes = data.get("classes", {})
        self.modules = data.get("modules", {})
        self.version = data.get("version", VERSION)
        self.prefix = data.get("param_prefix", "VH_TPD_")
        self.scale = float(scale) if scale is not None else float(data.get("scale", 1.0))

    @staticmethod
    def load(path, scale=None):
        with open(path) as f:
            return Table(json.load(f), scale)

    def entry(self, module):
        return self.modules.get(module)

    def ps(self, cls):
        return float(self.classes[cls]["ps"])

    def param(self, cls):
        return self.prefix + re.sub(r"\W", "_", cls).upper()

    def macro_ps(self, cls):
        return self.param(cls) + "_PS"


def _num(v):
    """Format a float compactly but unambiguously for Verilog."""
    s = ("%.6g" % v)
    return s if ("." in s or "e" in s or "E" in s) else s + ".0"


def make_header(tab, cls, unit_sec, orig):
    per_ps = 1e-12 / unit_sec
    ps = tab.ps(cls)
    val = ps * tab.scale * per_ps
    p, mp = tab.param(cls), tab.macro_ps(cls)
    unit_txt = "1s" if unit_sec == 1.0 else ("%g" % (unit_sec / 1e-12)) + "ps"
    return (
        "%s  class=%s  tpd=%sps  scale=%s  unit=%s ----\n"
        "// VH_ORIG %s\n"
        "`ifdef %s\n"
        "parameter real %s = `%s;\n"
        "`else\n"
        "parameter real %s = 1.0;\n"
        "`endif\n"
        "`ifdef %s\n"
        "parameter real %s = (`%s) * %s * %s;\n"
        "`else\n"
        "parameter real %s = %s * %s;\n"
        "`endif\n"
        "%s\n" % (
            MARK_BEGIN, cls, _num(ps), _num(tab.scale), unit_txt,
            json.dumps(orig, separators=(",", ":")),
            SCALE_MACRO, SCALE_PARAM, SCALE_MACRO, SCALE_PARAM,
            mp, p, mp, _num(per_ps), SCALE_PARAM,
            p, _num(val), SCALE_PARAM,
            MARK_END))


BLOCK_RE = re.compile(r"\n?" + re.escape(MARK_BEGIN) + r".*?" + re.escape(MARK_END) + r"\n?",
                      re.S)
ORIG_RE = re.compile(r"// VH_ORIG (\[.*?\])\n")
# the injected delay INCLUDING the whitespace around it, so revert is byte-exact
INJECTED_DLY_RE = re.compile(r"(?:<=[ \t]*#|[ \t]*#)\s*\(\s*VH_TPD_\w+\s*\)[ \t]*")


# --------------------------------------------------------------------------
# transform
# --------------------------------------------------------------------------
def revert_text(text):
    """Undo every VH_DELAY injection in `text`. Returns (new_text, n_modules)."""
    n = 0
    while True:
        bm = BLOCK_RE.search(text)
        if not bm:
            break
        n += 1
        block = bm.group(0)
        om = ORIG_RE.search(block)
        orig = json.loads(om.group(1)) if om else []
        # scope: from the end of the block to the end of this module
        scan = mask_comments(text)
        mend = scan.find("endmodule", bm.end())
        mend = len(text) if mend < 0 else mend
        body = text[bm.end():mend]
        parts, last, i = [], 0, 0
        for dm in INJECTED_DLY_RE.finditer(body):
            # orig[i] is the RAW span vh_delay replaced (operator + whitespace +
            # any pre-existing delay), so putting it back is byte-exact.
            rep = orig[i] if i < len(orig) else " "
            i += 1
            parts.append(body[last:dm.start()])
            parts.append(rep)
            last = dm.end()
        parts.append(body[last:])
        text = text[:bm.start()] + "".join(parts) + text[mend:]
    return text, n


def apply_text(text, tab, only=None, default_unit=1.0):
    """Inject delays. Returns (new_text, [(module, class, n_sites)])."""
    text, _ = revert_text(text)
    done = []
    # process modules back-to-front so earlier offsets stay valid
    for name, mstart, mend in reversed(find_modules(text)):
        ent = tab.entry(name)
        if not ent or (only and name not in only):
            continue
        cls = ent.get("class")
        if cls not in tab.classes:
            continue
        scan = mask_comments(text)
        sites = module_sites(text, scan, mstart, mend,
                             delay_const_rhs=bool(ent.get("delay_const_rhs")))
        anames = ent.get("assign_sites") or []
        if anames:
            sites += module_assign_sites(text, scan, mstart, mend, set(anames))
            sites.sort(key=lambda s: s["dly_span"][0])
        if not sites:
            continue
        unit_sec, _prec = module_timescale(text, mstart, default=(default_unit, 1e-15))
        param = tab.param(cls)
        # record the RAW replaced span (whitespace included) so revert is byte-exact
        orig = [text[s["dly_span"][0]:s["dly_span"][1]] for s in sites]
        for s in reversed(sites):
            a, b = s["dly_span"]
            rep = (" #(%s) " % param) if s["op"] == "assign" else ("<= #(%s) " % param)
            text = text[:a] + rep + text[b:]
        hend = header_end(mask_comments(text), mstart)
        text = text[:hend] + "\n" + make_header(tab, cls, unit_sec, orig) + text[hend:]
        done.append((name, cls, len(sites)))
    done.reverse()
    return text, done


# --------------------------------------------------------------------------
# file walking / IO
# --------------------------------------------------------------------------
def src_files(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            for f in sorted(os.listdir(p)):
                if f.endswith(SRC_EXT):
                    out.append(os.path.join(p, f))
        elif os.path.isfile(p):
            out.append(p)
    return out


def udiff(old, new, name):
    return "".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                                        "a/" + name, "b/" + name))


def resolve_cdslib(cdslib, lib, cells, view="verilogams", fname="verilog.vams"):
    """[(cell, path)] for OA `verilogams` cellview texts of `cells` in `lib`."""
    libs = None
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        if here not in sys.path:
            sys.path.insert(0, here)
        import vh_extract
        libs = vh_extract.parse_cdslib(cdslib)
    except Exception:
        libs = {}
        base = os.path.dirname(os.path.abspath(cdslib))
        for ln in open(cdslib):
            t = ln.split("#", 1)[0].split()
            if len(t) >= 3 and t[0].upper() == "DEFINE":
                libs[t[1]] = t[2] if os.path.isabs(t[2]) else os.path.join(base, t[2])
    if lib not in libs:
        raise SystemExit("ERROR: library %r not in %s (have: %s)"
                         % (lib, cdslib, ", ".join(sorted(libs))))
    root = libs[lib]
    out = []
    for c in cells:
        p = os.path.join(root, c, view, fname)
        if os.path.isfile(p):
            out.append((c, p))
    return out


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------
def cmd_report(args):
    tab = Table.load(args.table) if args.table else None
    files = src_files(args.src)
    print("%-52s %-12s %-5s %-26s %s" % ("MODULE", "CLASS", "SITES", "CURRENT DELAY(S)", "LINE(S)"))
    print("-" * 118)
    tot = marked = nodelay = 0
    for f in files:
        text = open(f).read()
        scan = mask_comments(text)
        for name, a, b in find_modules(text):
            ent = tab.entry(name) if tab else None
            cls = (ent or {}).get("class", "-")
            sites = module_sites(text, scan, a, b,
                                 delay_const_rhs=bool((ent or {}).get("delay_const_rhs")))
            if not sites:
                continue
            tot += 1
            has_mark = MARK_BEGIN in text[a:b]
            dl = ",".join(s["dly"] or "(none)" for s in sites)
            if has_mark:
                marked += 1
            if all(not s["dly"] for s in sites):
                nodelay += 1
            print("%-52s %-12s %-5d %-26s %s%s"
                  % (name, cls, len(sites), dl[:26],
                     ",".join(str(s["line"]) for s in sites),
                     "   [VH_DELAY]" if has_mark else ""))
    print("-" * 118)
    print("%d module(s) with delay sites; %d already injected; %d carry NO delay at all"
          % (tot, marked, nodelay))
    if tab:
        missing = [n for n in tab.modules
                   if not any(n == m[0] for f in files for m in find_modules(open(f).read()))]
        if missing:
            print("table modules not found under --src: %s" % ", ".join(sorted(missing)))
    return 0


def _write_out(args, f, text, old, changed_note):
    name = os.path.basename(f)
    if args.dry_run:
        d = udiff(old, text, name)
        if d:
            sys.stdout.write(d)
        return
    if args.in_place:
        if text == old:
            return
        bak = f + ".orig"
        if not os.path.exists(bak):
            shutil.copy2(f, bak)
        open(f, "w").write(text)
    else:
        os.makedirs(args.out, exist_ok=True)
        open(os.path.join(args.out, name), "w").write(text)


def cmd_apply(args):
    tab = Table.load(args.table, args.scale)
    if args.cdslib:
        if not args.in_place:
            raise SystemExit("ERROR: --cdslib/--lib patches OA cellviews in place; "
                             "it requires --in-place (and writes a .orig backup).")
        cells = [(v.get("cell") or k) for k, v in tab.modules.items()]
        pairs = resolve_cdslib(args.cdslib, args.lib, cells, args.view)
        files = [p for _c, p in pairs]
        if not files:
            raise SystemExit("ERROR: no <lib>/<cell>/%s/verilog.vams found for the table cells."
                             % args.view)
    else:
        if not args.src:
            raise SystemExit("ERROR: apply needs --src DIR (or --cdslib/--lib)")
        if not args.in_place and not args.out and not args.dry_run:
            raise SystemExit("ERROR: apply needs --out DIR (non-destructive) or --in-place")
        files = src_files(args.src)
    only = set(args.only) if args.only else None
    total = []
    for f in files:
        old = open(f).read()
        text, done = apply_text(old, tab, only=only)
        if not done and not args.in_place and args.out and not args.dry_run:
            open(os.path.join(_ensure(args.out), os.path.basename(f)), "w").write(old)
            continue
        _write_out(args, f, text, old, done)
        total += [(os.path.basename(f), m, c, n) for m, c, n in done]
    if not args.dry_run:
        print("vh_delay %s apply -- table=%s scale=%s" % (VERSION, os.path.basename(args.table), _num(tab.scale)))
        for fn, m, c, n in total:
            print("  %-42s %-12s %d site(s)   %s" % (m, c, n, fn))
        print("  %d module(s) injected -> %s" % (len(total), args.out if args.out else "(in place)"))
        if total:
            print("  tune at xrun time without touching these files:")
            print("    +define+%s=<x>            # scale every class (baked values are 1.0)"
                  % SCALE_MACRO)
            print("    +define+%s=<ps>       # one class, absolute ps"
                  % tab.macro_ps(sorted(tab.classes)[0]))
    return 0


def _ensure(d):
    os.makedirs(d, exist_ok=True)
    return d


def cmd_revert(args):
    files = src_files(args.src)
    n = 0
    for f in files:
        old = open(f).read()
        bak = f + ".orig"
        if args.in_place and os.path.exists(bak):
            text = open(bak).read()
        else:
            text, _k = revert_text(old)
        if text != old:
            n += 1
        _write_out(args, f, text, old, None)
        if args.in_place and os.path.exists(bak) and not args.dry_run:
            os.remove(bak)
    if not args.dry_run:
        print("vh_delay %s revert -- %d file(s) restored" % (VERSION, n))
    return 0


def xrun_flags(tab, scale=None):
    s = tab.scale if scale is None else scale
    return "+define+%s=%s" % (SCALE_MACRO, _num(s))


def cmd_flags(args):
    tab = Table.load(args.table, args.scale)
    print(xrun_flags(tab, args.scale if args.scale is not None else 1.0))
    print("# the baked-in values already include the table's scale=%s;" % _num(tab.scale))
    print("# +define+%s multiplies ON TOP of them (1.0 = as injected)." % SCALE_MACRO)
    print("# per-class absolute override (ps), e.g.:")
    for c in sorted(tab.classes)[:4]:
        print("#   +define+%s=%s" % (tab.macro_ps(c), _num(tab.ps(c))))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="vh_delay.py",
                                 description="inject/report/revert Verilog-AMS leaf delays")
    sub = ap.add_subparsers(dest="cmd")

    a = sub.add_parser("apply", help="inject the delay table into the models")
    a.add_argument("--table", required=True, help="delay table JSON")
    a.add_argument("--src", action="append", default=[], help="source dir or file (repeatable)")
    a.add_argument("--out", help="output dir (non-destructive; required unless --in-place)")
    a.add_argument("--in-place", action="store_true", help="edit in place, keeping <file>.orig")
    a.add_argument("--scale", type=float, help="override the table's global scale")
    a.add_argument("--only", action="append", help="only this module (repeatable)")
    a.add_argument("--dry-run", action="store_true", help="print a unified diff, write nothing")
    a.add_argument("--cdslib", help="cds.lib -- patch OA verilogams cellviews (needs --in-place)")
    a.add_argument("--lib", help="OA library name for --cdslib")
    a.add_argument("--view", default="verilogams", help="OA view name (default: verilogams)")
    a.set_defaults(func=cmd_apply)

    r = sub.add_parser("report", help="list every module: class / has-delay / value / line")
    r.add_argument("--src", action="append", required=True)
    r.add_argument("--table", help="delay table JSON (adds the class column)")
    r.set_defaults(func=cmd_report)

    v = sub.add_parser("revert", help="undo injection (from the marker, or from <file>.orig)")
    v.add_argument("--src", action="append", required=True)
    v.add_argument("--out", help="output dir (non-destructive)")
    v.add_argument("--in-place", action="store_true")
    v.add_argument("--dry-run", action="store_true")
    v.set_defaults(func=cmd_revert)

    f = sub.add_parser("flags", help="print the xrun command-line override flags")
    f.add_argument("--table", required=True)
    f.add_argument("--scale", type=float)
    f.set_defaults(func=cmd_flags)

    args = ap.parse_args(argv)
    if not getattr(args, "cmd", None):
        ap.print_help()
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
