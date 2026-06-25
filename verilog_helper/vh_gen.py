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
import sys, os, re, json, argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vh_parse as vp

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


def gen_runsh(top, src_files, stub_files, tb_file):
    files = src_files + stub_files + [tb_file]
    flines = ' \\\n  '.join('"%s"' % f for f in files)
    return """#!/usr/bin/env bash
# AUTO-GENERATED. Pure-digital VerilogAMS run via xrun (no spectre).
set -uo pipefail
export XCELIUM_HOME=%s
export CDS_LIC_FILE=%s
export PATH="$XCELIUM_HOME/tools/bin:$PATH"
cd "$(dirname "$0")"
rm -rf xcelium.d INCA_libs .simvision waves.shm xrun.log xrun.key

xrun -64bit -ams -timescale 1s/1fs \\
  -amsvlog_ext .vams,.va \\
  %s \\
  -top tb -access +rwc +libext+.va+.vams \\
  -l xrun.log
rc=$?

echo "================= RESULT ================="
grep -E "=== TB (PASS|FAIL)|^FAIL " xrun.log || echo "(no PASS/FAIL line -- check xrun.log)"
echo "xrun exit code: $rc"
exit $rc
""" % (XCELIUM_HOME, CDS_LIC_FILE, flines)


SIM_TCL = """# Optional waveform dump (batch or GUI). Use:  ./run.sh  then  simvision waves.shm
database -open waves -shm -into waves.shm
probe -create tb -all -depth all -database waves
run
exit
"""


def inst_tree(master, index, indent=1):
    pad = '    ' * indent
    out = []
    if master in index:
        for it in index[master]['instances']:
            m = it['master']
            tag = '' if m in index else '   <-- EXTERNAL (stubbed)'
            kind = ('[%s]' % index[m]['kind']) if m in index else '[external]'
            out.append('%s* %s : %s %s%s' % (pad, it['inst'], m, kind, tag))
            out += inst_tree(m, index, indent + 1)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', action='append', required=True, help='source dir or file (repeatable)')
    ap.add_argument('--out', required=True, help='output/build directory')
    ap.add_argument('--top', help='top DUT module (default: unique top in the graph)')
    ap.add_argument('--checks', help='JSON {output: expected-expr-in-terms-of-inputs}')
    args = ap.parse_args()

    files, mods, index, dups = vp.parse_files(args.src)
    g = vp.build_graph(mods, index)

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

    checks = {}
    if args.checks:
        raw = json.load(open(args.checks))
        checks = {k: v for k, v in raw.items() if not k.startswith('_')}

    os.makedirs(args.out, exist_ok=True)
    src_files = [os.path.abspath(f) for f in files]

    # stubs
    stub_files = []
    for e in externals:
        stub = gen_stub(e, ext_ports[e])
        path = os.path.join(args.out, 'stub_%s.vams' % e)
        open(path, 'w').write(stub)
        stub_files.append(os.path.abspath(path))

    # testbench
    tb_src, tb_warns = gen_tb(top, index, checks)
    tb_path = os.path.join(args.out, 'tb_%s.vams' % top)
    open(tb_path, 'w').write(tb_src)

    # run.sh + sim.tcl
    runsh = os.path.join(args.out, 'run.sh')
    open(runsh, 'w').write(gen_runsh(top, src_files, stub_files, os.path.abspath(tb_path)))
    os.chmod(runsh, 0o755)
    open(os.path.join(args.out, 'sim.tcl'), 'w').write(SIM_TCL)

    # manifest
    existing = sorted(m for m in g['used'] if m in index)
    tree = ['%s : %s [%s]  (TOP)' % (top, index[top]['file'], index[top]['kind'])]
    tree += inst_tree(top, index)
    manifest = {
        'top': top, 'top_file': index[top]['file'],
        'existing_verilogams': [{'module': m, 'file': index[m]['file'], 'kind': index[m]['kind']}
                                for m in existing],
        'external_verilogams': [{'module': e, 'inferred_ports': ext_ports[e],
                                 'stub': 'stub_%s.vams' % e} for e in externals],
        'duplicates': [{'module': n, 'ignored_file': f2, 'kept_file': f1} for n, f2, f1 in dups],
        'tb': os.path.basename(tb_path), 'run': 'run.sh',
        'checks': checks, 'tb_warnings': tb_warns,
        'instance_tree': tree,
    }
    json.dump(manifest, open(os.path.join(args.out, 'manifest.json'), 'w'), indent=2)

    # human-readable summary (stdout + manifest.txt)
    out = []
    out.append("=" * 72)
    out.append("BINDING MANIFEST")
    out.append("=" * 72)
    out.append("TOP DUT          : %s  [%s]" % (top, index[top]['kind']))
    out.append("")
    out.append("INSTANCE TREE:")
    out += ["  " + t for t in tree]
    out.append("")
    out.append("EXISTING verilogams (compiled from source):")
    for m in existing:
        out.append("  - %-14s %s" % (m, index[m]['file']))
    out.append("")
    out.append("EXTERNAL verilogams (undefined -> auto-stubbed):")
    if externals:
        for e in externals:
            pd = ", ".join("%s:%s" % (p, d) for p, d in ext_ports[e].items())
            out.append("  - %-14s ports{ %s }  -> stub_%s.vams" % (e, pd, e))
    else:
        out.append("  (none)")
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
    for f in ['tb_%s.vams' % top] + ['stub_%s.vams' % e for e in externals] + ['run.sh', 'sim.tcl', 'manifest.json']:
        out.append("  - %s" % f)
    out.append("")
    out.append("RUN:  bash %s" % runsh)
    text = '\n'.join(out)
    open(os.path.join(args.out, 'manifest.txt'), 'w').write(text + '\n')
    print(text)


if __name__ == '__main__':
    main()
