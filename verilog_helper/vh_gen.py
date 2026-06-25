#!/usr/bin/env python3
"""vh_gen -- nested VerilogAMS pure-digital bring-up generator.

Given a set of .va/.vams source files:
  1. parse + build the instance graph (via vh_parse),
  2. pick the TOP DUT,
  3. classify each sub-module: EXISTING (defined in sources) vs EXTERNAL (instantiated
     but undefined -> needs a stub),
  4. infer each EXTERNAL master's port directions from connectivity,
  5. generate: a wreal stub per external, a self-checking testbench for the top,
     run.sh (pure-digital xrun, no spectre), sim.tcl, and a binding manifest.

Usage:
  python3 vh_gen.py --src <dir|file> [--src ...] --out <build_dir>
                    [--top <module>] [--checks <checks.json>]
"""
import sys, os, re, json, argparse, shutil

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vh_parse as vp
import vh_env as ve

XCELIUM_HOME = "/home/yusheng/Program/eda/cadence/XCELIUM1803"
CDS_LIC_FILE = "/home/yusheng/Program/eda/cadence/license/license.dat"


def netkey(net):
    m = re.match(r'\s*(\\?[\w]+)', net or '')
    return m.group(1) if m else (net or '').strip()


def net_bases(net):
    """Set of base net identifiers a connection expression references. Understands bits,
    slices, concatenations and replications so direction/connectivity is tracked per real
    net: '{a, b[3:0]}' -> {'a','b'}; sized literals (2'b0) and numbers contribute none."""
    s = re.sub(r"\b\d*'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_]+", ' ', net or '')   # drop literals
    return set(re.findall(r'\\?[A-Za-z_]\w*', s))


def merge_dir(cur, new):
    if cur is None:
        return new
    if cur == new:
        return cur
    return 'inout'


def conn_width(net, host=None):
    """Width implied by a connection net expression, or None if unknown (-> scalar).
    Handles slices name[hi:lo] (=> hi-lo+1), single bits name[i] (=> 1), and
    concatenations {a, b[3:0], c} (=> sum of element widths). A bare bus name is sized
    from the host's port declaration when available, else treated as unknown (scalar)."""
    s = (net or '').strip()
    if not s:
        return None
    if s.startswith('{'):
        inner = s[1:s.rfind('}')] if '}' in s else s[1:]
        return sum(conn_width(el, host) or 1 for el in vp._split_commas(inner)) or None
    m = re.search(r'\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*$', s)        # slice  name[hi:lo]
    if m:
        return abs(int(m.group(1)) - int(m.group(2))) + 1
    if re.search(r'\[\s*\d+\s*\]\s*$', s):                       # single bit name[i]
        return 1
    if host:                                                     # bare name -> host port width
        r = vp.parse_range(host['dirs'].get(netkey(s), ('', ''))[1])
        if r:
            return abs(r[0] - r[1]) + 1
    return None


LOGIC_NTYPES = {'wire', 'reg', 'logic', 'tri', 'wand', 'wor', 'supply0', 'supply1'}


def infer_external_dirs(index, externals):
    """Infer {master:{port:dir}}, {master:{port:width}} and {master:{port:is_logic}} for
    every external master, from connectivity in every host that instantiates it. is_logic
    decides the stub net type: a port wired to logic nets (wire/reg control buses) must be
    logic, one wired to real nets stays wreal -- a wreal stub on a logic net would need a
    connect module (*E,CUNDCM) and a logic stub on a real net likewise."""
    ext_ports = {e: {} for e in externals}
    ext_widths = {e: {} for e in externals}
    ext_logic = {e: {} for e in externals}            # port -> True(logic)/False(real)
    for host in index.values():
        drv, load = set(), set()           # nets driven / loaded by *known* things
        ext_insts = []
        # host's own ports: an input port drives internal nets; an output port sinks
        for p, (d, w) in host['dirs'].items():
            if d == 'input':
                drv.add(p)
            elif d == 'output':
                load.add(p)
            else:
                drv.add(p); load.add(p)
        for it in host['instances']:
            mas, conns = it['master'], it['conns']
            if mas not in index:
                ext_insts.append(it)
                continue
            mport = index[mas]['dirs']
            order = index[mas]['ports']
            if conns['named']:
                pairs = conns['named'].items()
            elif conns['pos']:
                pairs = zip(order, conns['pos'])
            else:
                pairs = []
            for port, net in pairs:
                bases = net_bases(net)
                d = mport.get(port, (None,))[0]
                if d == 'output':
                    drv |= bases
                elif d == 'input':
                    load |= bases
                else:
                    drv |= bases; load |= bases
        # now infer each external instance's ports against what *else* touches the net
        for it in ext_insts:
            mas, conns = it['master'], it['conns']
            mapping = conns['named']
            if not mapping and conns['pos']:
                mapping = {('p%d' % i): n for i, n in enumerate(conns['pos'])}
            for port, net in (mapping or {}).items():
                bases = net_bases(net)
                isd = bool(bases & drv)
                isl = bool(bases & load)
                if isd and not isl:
                    newd = 'input'      # something else drives it -> external consumes
                elif isl and not isd:
                    newd = 'output'     # something else loads it -> external must drive
                elif isd and isl:
                    newd = 'inout'
                else:
                    newd = 'output'     # nothing else touches it -> assume external drives
                ext_ports[mas][port] = merge_dir(ext_ports[mas].get(port), newd)
                # bus width: from the connection net, divided across an array instance
                w = conn_width(net, host)
                if w:
                    arr_n = len(vp.range_bits(it.get('arr')))
                    if arr_n and w >= arr_n and w % arr_n == 0:
                        w = w // arr_n          # array distributes the net across N instances
                    cur = ext_widths[mas].get(port, 0)
                    ext_widths[mas][port] = max(cur, w)
                # logic vs real: from the connected nets' declared types in the host
                nts = {host['ntype'].get(b) for b in bases}
                if nts & {'wreal', 'electrical'}:
                    ext_logic[mas][port] = False
                elif (nts & LOGIC_NTYPES) and not ext_logic[mas].get(port):
                    ext_logic[mas].setdefault(port, True)
    return ext_ports, ext_widths, ext_logic


def gen_stub(master, ports, widths=None, logic=None):
    """ports:{port:dir}; widths:{port:int} (bit-width, 1/absent=>scalar); logic:{port:bool}
    (True=packed logic net, False=wreal real net). Pure-digital stub, ideal placeholder.
    Each port's net type matches what it's wired to in the Stage-A struct: logic control
    buses -> packed `[w-1:0]` logic; real signals -> wreal (scalar or unpacked array) --
    so no connect module is needed at the stub boundary."""
    widths = widths or {}
    logic = logic or {}
    plist = list(ports.keys())

    def w_of(p):
        return widths.get(p, 1) or 1

    def is_logic(p):
        return logic[p] if p in logic else (w_of(p) > 1)    # unknown bus -> logic control

    def decl(kw, p):
        if is_logic(p) and w_of(p) > 1:                     # packed logic bus
            return '  %s [%d:0] %s;' % (kw, w_of(p) - 1, p)
        return '  %s %s;' % (kw, p)
    ins = [p for p, d in ports.items() if d == 'input']
    outs = [p for p, d in ports.items() if d == 'output']
    inouts = [p for p, d in ports.items() if d == 'inout']
    real_scal = [p for p in plist if not is_logic(p) and w_of(p) == 1]
    real_bus = [p for p in plist if not is_logic(p) and w_of(p) > 1]
    L = ['`include "disciplines.vams"', '`timescale 1s/1fs',
         '// AUTO-GENERATED stub for EXTERNAL master "%s".' % master,
         '// Port dirs/widths/types inferred from connectivity; behavior is an IDEAL',
         '// placeholder. logic control buses -> packed [w-1:0]; real signals -> wreal',
         '// (scalar/unpacked array). EDIT THIS if the block needs real behavior.',
         'module %s(%s);' % (master, ', '.join(plist))]
    for p in outs:
        L.append(decl('output', p))
    for p in ins:
        L.append(decl('input ', p))
    for p in inouts:
        L.append(decl('inout ', p))
    if real_scal:
        L.append('  wreal  %s;' % ', '.join(real_scal))
    for p in real_bus:
        L.append('  wreal  %s[%d:0];' % (p, w_of(p) - 1))
    if len(outs) == 1 and len(ins) == 1 and is_logic(outs[0]) == is_logic(ins[0]) \
            and w_of(outs[0]) == w_of(ins[0]):
        L.append('  // single in / single out, matching width -> ideal unity buffer')
        L.append('  assign %s = %s;' % (outs[0], ins[0]))
    else:
        L.append('  // each output driven by an ideal constant (override as needed)')
        for p in outs:
            if is_logic(p):
                L.append("  assign %s = %d'b0;" % (p, w_of(p)))
            elif w_of(p) > 1:
                for b in range(w_of(p) - 1, -1, -1):
                    L.append('  assign %s[%d] = 0.0;' % (p, b))
            else:
                L.append('  parameter real %s_const = 0.0;' % p)
                L.append('  assign %s = %s_const;' % (p, p))
    L.append('endmodule')
    return '\n'.join(L) + '\n'


def subst_inputs(expr, inputs):
    """Replace whole-word input port names with their _drv testbench variables."""
    for nm in sorted(inputs, key=len, reverse=True):
        expr = re.sub(r'\b%s\b' % re.escape(nm), nm + '_drv', expr)
    return expr


def port_repr(mi, p):
    """How a top port is represented in the pure-digital flow:
       ('scalar'    , '' )  scalar real      -> real drv / wreal net
       ('logic_bus' , w )  packed logic bus  -> reg/wire [m:l]  (control words: ndiv,pwsel)
       ('wreal_bus' , w )  real-valued bus   -> unpacked wreal array  wreal x[m:l]
    The kind is read from the port's own declaration so the TB ALWAYS matches the DUT:
    a sized port whose net type is `wreal` is an unpacked real array (Stage B emits these);
    any other sized port is a packed logic bus (slices/concats/array-instances inside the
    Stage-A struct are then native Verilog -- no expansion needed)."""
    d, w = mi['dirs'].get(p, ('inout', ''))
    nt = mi['ntype'].get(p)
    if not w:
        # scalar: wreal (real signal) if declared wreal, else a logic scalar (reg/wire).
        # A logic scalar is modeled as a width-'' logic bus so the logic_bus paths handle it.
        return d, '', ('scalar' if nt == 'wreal' else 'logic_bus')
    return d, w, ('wreal_bus' if nt == 'wreal' else 'logic_bus')


def _logic_vec(v, width):
    """Deterministic integer stimulus for a logic bus of `width` bits, vector index v."""
    mask = (1 << width) - 1
    pats = [0, 1, mask, mask >> 1, mask ^ (mask >> 1)]
    return pats[v % len(pats)] & mask


def gen_tb(top, index, checks):
    mi = index[top]
    ports = mi['ports']
    rep = {p: port_repr(mi, p) for p in ports}
    ins = [p for p in ports if rep[p][0] == 'input']
    outs = [p for p in ports if rep[p][0] == 'output']
    inouts = [p for p in ports if rep[p][0] == 'inout']
    scal_ins = [p for p in ins if rep[p][2] == 'scalar']     # drive the golden-expr subst
    warns = []

    L = ['`include "disciplines.vams"', '`timescale 1s/1fs',
         '// AUTO-GENERATED self-checking testbench for top DUT "%s".' % top,
         '// Bus-aware: logic control buses -> reg/wire[m:l]; real buses -> unpacked wreal',
         '// arrays; scalars -> wreal. Golden checks are scalar-output only (bus outputs are',
         '// displayed). Bus bits may be referenced in checks.json as name[i] (e.g. sel[0]).',
         'module tb;', '  integer err;', '  real diff, adiff;',
         '  localparam real TOL = 1e-9;']

    # ---- input drivers ----
    for p in ins:
        d, w, k = rep[p]
        if k == 'scalar':
            L.append('  real  %s_drv;' % p)
        elif k == 'logic_bus':
            L.append('  reg %s %s;' % (w, p))
            warns.append("input '%s' is a logic %s -> reg%s, integer-vector stimulus"
                         % (p, ("control bus" if w else "scalar"), (" " + w) if w else ""))
        else:  # wreal_bus
            L.append('  real  %s_drv%s;' % (p, w))          # unpacked real driver array
            warns.append("input '%s' is a real bus -> unpacked wreal array %s%s, "
                         "per-bit drive" % (p, p, w))

    # ---- nets ----
    scal_nets = [p for p in ports if rep[p][2] == 'scalar']
    if scal_nets:
        L.append('  wreal %s;' % ', '.join(scal_nets))
    for p in ports:                                          # real buses: unpacked wreal array
        if rep[p][2] == 'wreal_bus':
            L.append('  wreal %s%s;' % (p, rep[p][1]))
    for p in outs + inouts:                                  # logic bus sinks: wire
        if rep[p][2] == 'logic_bus':
            L.append('  wire %s %s;' % (rep[p][1], p))

    for p in ins:                                            # hook drivers to nets
        if rep[p][2] == 'scalar':
            L.append('  assign %s = %s_drv;' % (p, p))
        elif rep[p][2] == 'wreal_bus':
            for b in vp.range_bits(rep[p][1]):
                L.append('  assign %s[%d] = %s_drv[%d];' % (p, b, p, b))
    for o in outs:
        if rep[o][2] == 'scalar' and o in checks:
            L.append('  real  exp_%s;' % o)

    conn = ', '.join('.%s(%s)' % (p, p) for p in ports)
    L.append('  %s dut (%s);' % (top, conn))
    L.append('')
    L.append('  initial begin')
    L.append('    err = 0;')

    # per-vector context shown in every line: scalars as %g, logic buses as %0d
    ctx_fmt, ctx_val = [], []
    for p in ins:
        if rep[p][2] == 'scalar':
            ctx_fmt.append('%s=%%g' % p); ctx_val.append('%s_drv' % p)
        elif rep[p][2] == 'logic_bus':
            ctx_fmt.append('%s=%%0d' % p); ctx_val.append(p)
    cfmt = "  ".join(ctx_fmt)
    cval = ", ".join(ctx_val)
    ctx = (", " + cval) if cval else ''

    palette = [1.0, 2.0, 0.5, -1.0, 3.5]
    nvec = 5
    for v in range(nvec):
        L.append('    // ---- vector %d ----' % (v + 1))
        for j, p in enumerate(scal_ins):
            L.append('    %s_drv = %s;' % (p, palette[(v + j) % len(palette)]))
        for p in ins:
            d, w, k = rep[p]
            if k == 'logic_bus':
                L.append('    %s = %d;' % (p, _logic_vec(v, len(vp.range_bits(w)) or 1)))
            elif k == 'wreal_bus':
                for bi, b in enumerate(vp.range_bits(w)):
                    L.append('    %s_drv[%d] = %s;' % (p, b, palette[(v + bi) % len(palette)]))
        L.append('    #1;')
        for o in outs:
            d, w, k = rep[o]
            if k == 'scalar' and o in checks:
                expr = subst_inputs(checks[o], set(scal_ins))
                L.append('    exp_%s = %s;' % (o, expr))
                L.append('    diff = %s - exp_%s; adiff = (diff > 0.0) ? diff : -diff;' % (o, o))
                L.append('    if (adiff > TOL) begin')
                L.append('      err = err + 1;')
                L.append('      $display("FAIL %s: got %%g  exp %%g   [%s]", %s, exp_%s%s);'
                         % (o, cfmt, o, o, ctx))
                L.append('    end else')
                L.append('      $display("ok   %s=%%g   [%s]", %s%s);' % (o, cfmt, o, ctx))
            elif k == 'scalar':
                L.append('    $display("     %s=%%g   [%s]", %s%s);' % (o, cfmt, o, ctx))
            elif k == 'logic_bus':
                L.append('    $display("     %s=%%0d (0x%%0h)   [%s]", %s, %s%s);'
                         % (o, cfmt, o, o, ctx))
            else:  # wreal_bus
                for b in vp.range_bits(w):
                    L.append('    $display("     %s[%d]=%%g   [%s]", %s[%d]%s);'
                             % (o, b, cfmt, o, b, ctx))
    L.append('')
    L.append('    if (err == 0) $display("=== TB PASS  (top=%s) ===");' % top)
    L.append('    else          $display("=== TB FAIL  (%0d mismatches) ===", err);')
    L.append('    $finish;')
    L.append('  end')
    L.append('endmodule')
    return '\n'.join(L) + '\n', warns


# setup_env.sh -- env-agnostic xrun resolution, sourced by run.sh / verify.sh.
# Red zone: xrun is already on PATH -> use it as-is. Dev: fall back to the local
# Xcelium. Either: set VH_SITE_ENV=/path/site_env.sh to source your own.
SETUP_ENV = """# AUTO-GENERATED. Source this to make `xrun` available, env-agnostically.
if ! command -v xrun >/dev/null 2>&1; then
  if [ -n "${VH_SITE_ENV:-}" ] && [ -f "${VH_SITE_ENV}" ]; then
    . "${VH_SITE_ENV}"
  elif [ -d "%s" ]; then                 # dev-box fallback
    export XCELIUM_HOME="%s"
    export CDS_LIC_FILE="%s"
    export PATH="$XCELIUM_HOME/tools/bin:$PATH"
  fi
fi
if ! command -v xrun >/dev/null 2>&1; then
  echo "ERROR: xrun not on PATH. On the red zone it should be ambient; otherwise set" >&2
  echo "       VH_SITE_ENV=/path/to/your_cadence_env.sh and re-run." >&2
  return 127 2>/dev/null || exit 127
fi
""" % (XCELIUM_HOME, XCELIUM_HOME, CDS_LIC_FILE)


def _bake_ext(ext_flags):
    """Render ext_flags as a bash array body, quoting bare path args."""
    q = []
    for tok in (ext_flags or []):
        q.append(tok if tok.startswith(('-', '+')) else '"%s"' % tok)
    return ' '.join(q)


def gen_runsh(top, src_files, stub_files, tb_file, ext_flags=None, sim_top='tb'):
    files = src_files + stub_files + [tb_file]
    flines = ' \\\n  '.join('"%s"' % f for f in files)
    # SMOKE vs FUNCTIONAL: a run with any STUBBED external verifies wiring/logic
    # against ideal buffers, NOT the real models -- that is a smoke proxy (the
    # authoritative run resolves every external via -v). Echo the kind so both
    # CLI and GUI users can tell a smoke pass from a real one, on dev or red.
    if stub_files:
        snames = ', '.join(os.path.basename(s)[5:].rsplit('.', 1)[0]
                           if os.path.basename(s).startswith('stub_')
                           else os.path.basename(s) for s in stub_files)
        runkind = ("SMOKE -- %d external(s) STUBBED (ideal buffers, NOT real "
                   "models): %s" % (len(stub_files), snames))
    else:
        runkind = "FUNCTIONAL -- all externals resolved (no stubs)"
    return """#!/usr/bin/env bash
# AUTO-GENERATED. Pure-digital VerilogAMS run via xrun (no spectre). Env-agnostic:
# uses xrun if already on PATH (red zone), else falls back to a site/dev env.
set -uo pipefail
cd "$(dirname "$0")"
. ./setup_env.sh || exit 127

# external -v/-y/+incdir libs: VH_EXT_LIBS (space-sep files) or an ext_libs.list
# file (one path per line) OVERRIDE the baked-in set below -- use these on the red
# zone where the library paths differ.
EXT=(%s)
if [ -n "${VH_EXT_LIBS:-}" ]; then
  EXT=(); for f in ${VH_EXT_LIBS}; do EXT+=(-v "$f"); done
elif [ -f ext_libs.list ]; then
  EXT=(); while read -r f; do case "$f" in ''|\\#*) ;; -*) EXT+=($f) ;; +*) EXT+=("$f") ;; *) EXT+=(-v "$f") ;; esac; done < ext_libs.list
fi

rm -rf xcelium.d INCA_libs .simvision waves.shm xrun.log xrun.key
xrun -64bit -ams -timescale 1s/1fs \\
  -amsvlog_ext .vams,.va \\
  ${EXT[@]+"${EXT[@]}"} \\
  %s \\
  -top %s -access +rwc +libext+.v+.va+.vams \\
  -l xrun.log
rc=$?

echo "================= RESULT ================="
grep -E "=== TB (PASS|FAIL)|^FAIL " xrun.log || echo "(no PASS/FAIL line -- check xrun.log)"
echo "xrun exit code: $rc"
echo "RUN-KIND: %s"
echo "xrun-bin: $(command -v xrun)"
exit $rc
""" % (_bake_ext(ext_flags), flines, sim_top, runkind)


SIM_TCL = """# Optional waveform dump (batch or GUI). Use:  ./run.sh  then  simvision waves.shm
database -open waves -shm -into waves.shm
probe -create tb -all -depth all -database waves
run
exit
"""


def inst_tree(master, index, indent=1, resolved=None):
    resolved = resolved or {}
    pad = '    ' * indent
    out = []
    if master in index:
        for it in index[master]['instances']:
            m = it['master']
            if m in index:
                tag, kind = '', '[%s]' % index[m]['kind']
            elif m in resolved:
                tag = '   <-- EXTERNAL (resolved via %s)' % os.path.basename(resolved[m]['file'])
                kind = '[external:%s]' % resolved[m]['kind']
            else:
                tag, kind = '   <-- EXTERNAL (stubbed)', '[external]'
            out.append('%s* %s : %s %s%s' % (pad, it['inst'], m, kind, tag))
            out += inst_tree(m, index, indent + 1, resolved)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', action='append', required=True, help='source dir or file (repeatable)')
    ap.add_argument('--out', required=True, help='output/build directory')
    ap.add_argument('--top', help='top DUT module (default: unique top in the graph)')
    ap.add_argument('--checks', help='JSON {output: expected-expr-in-terms-of-inputs}')
    ap.add_argument('--tb', help='use this user-supplied testbench file instead of generating one')
    ap.add_argument('--tb-top', default='tb', help='top module of --tb (default: tb)')
    ap.add_argument('--manifest', help='Stage-A manifest_A.json (default: auto-find near --src)')
    ap.add_argument('--ext-lib', action='append', default=[], help='external -v file (per-run)')
    ap.add_argument('--ext-dir', action='append', default=[], help='external -y dir (per-run)')
    ap.add_argument('--ext-inc', action='append', default=[], help='external +incdir dir (per-run)')
    args = ap.parse_args()

    files, mods, index, dups = vp.parse_files(args.src)
    g = vp.build_graph(mods, index)

    # external HDL env: explicit --ext-* > Stage-A manifest ext_env > remembered store
    env = {k: [] for k in ('lib_files', 'lib_dirs', 'inc_dirs')}
    mpath = args.manifest
    if not mpath:
        for s in args.src:
            cand = os.path.join(s if os.path.isdir(s) else os.path.dirname(s),
                                os.pardir, 'manifest_A.json')
            if os.path.isfile(cand):
                mpath = cand
                break
    if args.ext_lib or args.ext_dir or args.ext_inc:
        ve.merge(env, lib_files=args.ext_lib, lib_dirs=args.ext_dir, inc_dirs=args.ext_inc)
    elif mpath and os.path.isfile(mpath):
        try:
            me = json.load(open(mpath)).get('ext_env', {})
            for k in env:
                env[k] = list(me.get(k, []))
        except (ValueError, OSError):
            pass
    if ve.is_empty(env):
        env = ve.load_env()
    ext_index = ve.index_modules(env)

    # pick top
    if args.top:
        top = args.top
        if top not in index:
            sys.exit("ERROR: --top %s not found among parsed modules" % top)
    else:
        if len(g['tops']) != 1:
            sys.exit("ERROR: need --top; graph tops = %s" % g['tops'])
        top = g['tops'][0]

    externals = g['externals']
    ext_ports, ext_widths, ext_logic = infer_external_dirs(index, externals)
    # externals provided by the remembered env are RESOLVED (xrun -v compiles them);
    # only the rest get an auto-stub.
    resolved = {e: ext_index[e] for e in externals if e in ext_index}
    to_stub = [e for e in externals if e not in resolved]
    ext_warns = ["external '%s' resolves to an ANALOG model (%s) -> needs spectre; "
                 "pure-digital xrun cannot solve it" % (e, resolved[e]['file'])
                 for e in resolved if resolved[e]['kind'] == 'analog']

    checks = {}
    if args.checks and not args.tb:
        raw = json.load(open(args.checks))
        checks = {k: v for k, v in raw.items() if not k.startswith('_')}
    if args.checks and args.tb:
        print("note: --tb given -> ignoring --checks (your test does its own checking)")

    os.makedirs(args.out, exist_ok=True)
    src_files = [os.path.abspath(f) for f in files]

    # stubs (only for externals NOT provided by the env)
    stub_files = []
    for e in to_stub:
        stub = gen_stub(e, ext_ports[e], ext_widths[e], ext_logic[e])
        path = os.path.join(args.out, 'stub_%s.vams' % e)
        open(path, 'w').write(stub)
        stub_files.append(os.path.abspath(path))

    # testbench: user-supplied (--tb) or generated. sim_top = the module xrun runs.
    if args.tb:
        if not os.path.isfile(args.tb):
            sys.exit("ERROR: --tb file not found: %s" % args.tb)
        tb_path = os.path.join(args.out, os.path.basename(args.tb))   # copy in -> self-contained build
        if os.path.abspath(args.tb) != os.path.abspath(tb_path):
            shutil.copyfile(args.tb, tb_path)
        tb_path = os.path.abspath(tb_path)
        sim_top = args.tb_top
        tb_warns = []
        user_tb = True
    else:
        tb_src, tb_warns = gen_tb(top, index, checks)
        tb_path = os.path.abspath(os.path.join(args.out, 'tb_%s.vams' % top))
        open(tb_path, 'w').write(tb_src)
        sim_top = 'tb'
        user_tb = False

    # setup_env.sh (sourced) + run.sh + sim.tcl
    ext_flags = ve.xrun_flags(env)
    open(os.path.join(args.out, 'setup_env.sh'), 'w').write(SETUP_ENV)
    runsh = os.path.join(args.out, 'run.sh')
    open(runsh, 'w').write(gen_runsh(top, src_files, stub_files, tb_path,
                                     ext_flags=ext_flags, sim_top=sim_top))
    os.chmod(runsh, 0o755)
    open(os.path.join(args.out, 'sim.tcl'), 'w').write(SIM_TCL)

    # manifest
    existing = sorted(m for m in g['used'] if m in index)
    tree = ['%s : %s [%s]  (TOP)' % (top, index[top]['file'], index[top]['kind'])]
    tree += inst_tree(top, index, resolved=resolved)
    manifest = {
        'top': top, 'top_file': index[top]['file'],
        'existing_verilogams': [{'module': m, 'file': index[m]['file'], 'kind': index[m]['kind']}
                                for m in existing],
        'external_resolved': [{'module': e, 'file': resolved[e]['file'],
                               'kind': resolved[e]['kind']} for e in sorted(resolved)],
        'external_stubbed': [{'module': e, 'inferred_ports': ext_ports[e],
                              'inferred_widths': ext_widths[e],
                              'stub': 'stub_%s.vams' % e} for e in to_stub],
        'ext_flags': ext_flags,
        'duplicates': [{'module': n, 'ignored_file': f2, 'kept_file': f1} for n, f2, f1 in dups],
        'tb': os.path.basename(tb_path), 'sim_top': sim_top, 'user_tb': user_tb, 'run': 'run.sh',
        'checks': checks, 'tb_warnings': tb_warns + ext_warns,
        'instance_tree': tree,
    }
    json.dump(manifest, open(os.path.join(args.out, 'manifest.json'), 'w'), indent=2)

    # human-readable summary (stdout + manifest.txt)
    out = []
    out.append("=" * 72)
    out.append("BINDING MANIFEST")
    out.append("=" * 72)
    out.append("TOP DUT          : %s  [%s]" % (top, index[top]['kind']))
    out.append("TESTBENCH        : %s  (sim top=%s)"
               % (os.path.basename(tb_path) + (" [user-supplied]" if user_tb else " [generated]"),
                  sim_top))
    out.append("")
    out.append("INSTANCE TREE:")
    out += ["  " + t for t in tree]
    out.append("")
    out.append("EXISTING verilogams (compiled from source):")
    for m in existing:
        out.append("  - %-14s %s" % (m, index[m]['file']))
    out.append("")
    out.append("EXTERNAL resolved via env (-v, real def used by xrun):")
    if resolved:
        for e in sorted(resolved):
            out.append("  - %-14s %s [%s]" % (e, os.path.basename(resolved[e]['file']),
                                              resolved[e]['kind']))
    else:
        out.append("  (none)")
    out.append("")
    out.append("EXTERNAL undefined -> auto-stubbed:")
    if to_stub:
        for e in to_stub:
            pd = ", ".join("%s:%s%s" % (p, d, ("[%d:0]" % (ext_widths[e][p] - 1))
                                        if ext_widths[e].get(p, 1) > 1 else '')
                           for p, d in ext_ports[e].items())
            out.append("  - %-14s ports{ %s }  -> stub_%s.vams" % (e, pd, e))
    else:
        out.append("  (none)")
    if ext_flags:
        out.append("")
        out.append("EXTERNAL ENV baked into run.sh:  %s" % " ".join(ext_flags))
    for w in ext_warns:
        tb_warns.append(w)
    if dups:
        out.append("")
        out.append("DUPLICATE module defs (first kept):")
        for n, f2, f1 in dups:
            out.append("  - %s: ignored %s" % (n, f2))
    if tb_warns:
        out.append("")
        out.append("TB WARNINGS:")
        for w in tb_warns:
            out.append("  ! " + w)
    out.append("")
    out.append("GENERATED in %s :" % args.out)
    for f in [os.path.basename(tb_path)] + ['stub_%s.vams' % e for e in to_stub] + ['run.sh', 'setup_env.sh', 'sim.tcl', 'manifest.json']:
        out.append("  - %s" % f)
    out.append("")
    out.append("RUN:  bash %s" % runsh)
    text = '\n'.join(out)
    open(os.path.join(args.out, 'manifest.txt'), 'w').write(text + '\n')
    print(text)


if __name__ == '__main__':
    main()
