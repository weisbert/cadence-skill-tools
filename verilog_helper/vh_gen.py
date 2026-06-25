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


def merge_dir(cur, new):
    if cur is None:
        return new
    if cur == new:
        return cur
    return 'inout'


def infer_external_dirs(index, externals):
    """Infer {master: {port: dir}} for every external master, from connectivity in
    every host module that instantiates it."""
    ext_ports = {e: {} for e in externals}
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
                nk = netkey(net)
                d = mport.get(port, (None,))[0]
                if d == 'output':
                    drv.add(nk)
                elif d == 'input':
                    load.add(nk)
                else:
                    drv.add(nk); load.add(nk)
        # now infer each external instance's ports against what *else* touches the net
        for it in ext_insts:
            mas, conns = it['master'], it['conns']
            mapping = conns['named']
            if not mapping and conns['pos']:
                mapping = {('p%d' % i): n for i, n in enumerate(conns['pos'])}
            for port, net in (mapping or {}).items():
                nk = netkey(net)
                isd, isl = nk in drv, nk in load
                if isd and not isl:
                    newd = 'input'      # something else drives it -> external consumes
                elif isl and not isd:
                    newd = 'output'     # something else loads it -> external must drive
                elif isd and isl:
                    newd = 'inout'
                else:
                    newd = 'output'     # nothing else touches it -> assume external drives
                ext_ports[mas][port] = merge_dir(ext_ports[mas].get(port), newd)
    return ext_ports


def gen_stub(master, ports):
    """ports: {port: dir}. Pure-digital wreal stub, ideal placeholder behavior."""
    plist = list(ports.keys())
    ins = [p for p, d in ports.items() if d == 'input']
    outs = [p for p, d in ports.items() if d == 'output']
    inouts = [p for p, d in ports.items() if d == 'inout']
    L = ['`include "disciplines.vams"', '`timescale 1s/1fs',
         '// AUTO-GENERATED wreal stub for EXTERNAL master "%s".' % master,
         '// Port directions inferred from connectivity; behavior is an IDEAL placeholder.',
         '// EDIT THIS if the external block needs real behavior for your verification.',
         'module %s(%s);' % (master, ', '.join(plist))]
    for p in outs:
        L.append('  output %s;' % p)
    for p in ins:
        L.append('  input  %s;' % p)
    for p in inouts:
        L.append('  inout  %s;' % p)
    L.append('  wreal  %s;' % ', '.join(plist))
    if len(outs) == 1 and len(ins) == 1:
        L.append('  // single in / single out -> ideal unity buffer')
        L.append('  assign %s = %s;' % (outs[0], ins[0]))
    else:
        L.append('  // multi-port -> each output driven by a constant parameter (override as needed)')
        for p in outs:
            L.append('  parameter real %s_const = 0.0;' % p)
            L.append('  assign %s = %s_const;' % (p, p))
    L.append('endmodule')
    return '\n'.join(L) + '\n'


def subst_inputs(expr, inputs):
    """Replace whole-word input port names with their _drv testbench variables."""
    for nm in sorted(inputs, key=len, reverse=True):
        expr = re.sub(r'\b%s\b' % re.escape(nm), nm + '_drv', expr)
    return expr


def gen_tb(top, index, checks):
    mi = index[top]
    ins = [p for p in mi['ports'] if mi['dirs'].get(p, ('inout',))[0] == 'input']
    outs = [p for p in mi['ports'] if mi['dirs'].get(p, ('inout',))[0] == 'output']
    inouts = [p for p in mi['ports'] if mi['dirs'].get(p, ('inout',))[0] == 'inout']
    warns = []
    for p in mi['ports']:
        if mi['dirs'].get(p, ('', ''))[1]:
            warns.append("port '%s' is a bus (%s) -- TB emits scalar wreal; widen by hand if needed"
                         % (p, mi['dirs'][p][1]))

    L = ['`include "disciplines.vams"', '`timescale 1s/1fs',
         '// AUTO-GENERATED self-checking testbench for top DUT "%s".' % top,
         'module tb;', '  integer err;', '  real diff, adiff;',
         '  localparam real TOL = 1e-9;']
    for p in ins:
        L.append('  real  %s_drv;' % p)
    allnets = ins + outs + inouts
    if allnets:
        L.append('  wreal %s;' % ', '.join(allnets))
    for p in ins:
        L.append('  assign %s = %s_drv;' % (p, p))
    for o in outs:
        if o in checks:
            L.append('  real  exp_%s;' % o)
    conn = ', '.join('.%s(%s)' % (p, p) for p in mi['ports'])
    L.append('  %s dut (%s);' % (top, conn))
    L.append('')
    L.append('  initial begin')
    L.append('    err = 0;')

    # deterministic stimulus palette
    palette = [1.0, 2.0, 0.5, -1.0, 3.5]
    nvec = 5
    for v in range(nvec):
        L.append('    // ---- vector %d ----' % (v + 1))
        for j, p in enumerate(ins):
            L.append('    %s_drv = %s;' % (p, palette[(v + j) % len(palette)]))
        L.append('    #1;')
        argfmt = "  ".join("%s=%%g" % p for p in ins)
        argval = ", ".join("%s_drv" % p for p in ins)
        for o in outs:
            if o in checks:
                expr = subst_inputs(checks[o], set(ins))
                L.append('    exp_%s = %s;' % (o, expr))
                L.append('    diff = %s - exp_%s; adiff = (diff > 0.0) ? diff : -diff;' % (o, o))
                L.append('    if (adiff > TOL) begin')
                L.append('      err = err + 1;')
                L.append('      $display("FAIL %s: got %%g  exp %%g   [%s]", %s, exp_%s%s);'
                         % (o, argfmt, o, o, (", " + argval) if argval else ''))
                L.append('    end else')
                L.append('      $display("ok   %s=%%g   [%s]", %s%s);'
                         % (o, argfmt, o, (", " + argval) if argval else ''))
            else:
                L.append('    $display("     %s=%%g   [%s]", %s%s);'
                         % (o, argfmt, o, (", " + argval) if argval else ''))
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
    ext_ports = infer_external_dirs(index, externals)
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
        stub = gen_stub(e, ext_ports[e])
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
            pd = ", ".join("%s:%s" % (p, d) for p, d in ext_ports[e].items())
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
