#!/usr/bin/env python3
"""vh_convert -- Stage B: analog VerilogA cell -> pure-digital wreal (assisted, bounded).

Why this exists (user-stated, 2026-06-25):
  - The ORIGINAL cell `<lib>/<cell>/veriloga/veriloga.va` is what ships to the real top;
    it MAY contain analog quantities (electrical / `analog begin` / V()/I() contributions).
  - The thing we verify pure-digital MUST be wreal/digital.
  So verifying the digital copy isn't enough: the analog originals eventually have to be
  REPLACED by digital versions. Stage B therefore (a) gives a DETECTION LIST of which
  cells are already digital / auto-convertible / need manual work, and (b) writes a
  candidate digital `veriloga_wreal.va` NEXT TO each original cell (non-destructive) for
  you to review and then overwrite `veriloga.va` yourself. It never overwrites originals.

What it converts (bounded, voltage-only -- see HANDOFF Sec 3):
  Modules whose `analog` block is ONLY voltage contributions `V(node[,ref]) <+ expr`,
  with expr free of current/dynamics/noise. Each `V(o,r) <+ e` becomes `assign o = e + r`
  (`assign o = e` when single-ended); `V(a,b)` in expr maps to `(a - b)`, `V(a)` to `a`.
  Bus contributions `V(bus[i]) <+ ...` are supported via UNPACKED wreal arrays
  (`wreal bus[msb:lsb];` -- packed `wreal [msb:lsb]` is rejected by xrun).

What it FLAGS (writes a TODO skeleton instead): anything with `I(...) <+`, `ddt/idt/
ddx`, `white_noise/flicker_noise`, laplace/zi filters, transition/slew, `@`/if/case/for,
or temp-variable assignments in the analog block (e.g. the LDO-style models).

CLI:
  python3 vh_convert.py --manifest <out>/manifest_A.json [--out <out>]   # convert the
                              # veriloga leaves Stage A gathered; update export/ to digital
  python3 vh_convert.py --src <dir|file> ... --out <dir>                  # standalone
  options: --no-cell-write (don't write veriloga_wreal.va beside originals)
"""
import re, sys, os, json, argparse, shutil

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vh_parse as vp

# analog constructs we cannot mechanically map to pure wreal
FORBIDDEN = re.compile(
    r'\b(ddt|idt|idtmod|ddx|absdelay|transition|slew|last_crossing|'
    r'laplace_zd|laplace_zp|laplace_np|laplace_nd|zi_zp|zi_nd|zi_np|zi_zd|'
    r'white_noise|flicker_noise|noise_table)\b')
NODE = r'[A-Za-z_]\w*(?:\[\s*\w+\s*\])?'          # foo  or  foo[3]
CONTRIB = re.compile(r'^\s*([VI])\s*\(\s*(%s)\s*(?:,\s*(%s)\s*)?\)\s*<\+\s*(.+)$'
                     % (NODE, NODE), re.S)
V_ACCESS = re.compile(r'\bV\s*\(\s*(%s)\s*(?:,\s*(%s)\s*)?\)' % (NODE, NODE))

# supply/ground pins (their threshold checks are "is the rail nominal" -> assumed OK in a
# pure-digital check). Kept in sync with vh_extract.SUPPLY_RE.
SUPPLY_RE = re.compile(r'(?i)^(vdd|vss|vpp|vbb|vnw|vpw|vcc|vee|vgnd|gnd|agnd|dgnd|avdd|avss|'
                       r'dvdd|dvss|vdda|vssa|vddd|vssd|psub|nwell|pwell|sub)(_.*|[0-9].*)?$')
# a wreal net compared to a threshold: `(net >= k)` / `(net < k)` (no nested parens in rhs)
_CMP = r'(>=|<=|>(?!>)|<(?!<))'


def base(node):
    return node.split('[')[0].strip()


def extract_analog(body):
    """Inner text of the `analog begin ... end` block, or a single `analog <stmt>;`."""
    m = re.search(r'\banalog\s+begin\b', body)
    if m:
        depth = 1
        for t in re.finditer(r'\b(begin|end)\b', body[m.end():]):
            depth += 1 if t.group(1) == 'begin' else -1
            if depth == 0:
                return body[m.end():m.end() + t.start()]
        return body[m.end():]
    m = re.search(r'\banalog\b\s*([^;]+;)', body)
    return m.group(1) if m else None


def _wreal_nets(body):
    """Names declared `wreal a, b[3:0];` in a module body."""
    nets = set()
    for m in re.finditer(r'(?m)^[ \t]*wreal\b([^;]*);', body):
        for tok in m.group(1).split(','):
            t = tok.strip().split('[')[0].strip()
            if re.match(r'^[A-Za-z_]\w*$', t):
                nets.add(t)
    return nets


def analyze_wreal_monitor(mi, src, body):
    """A wreal cell with NO analog block but whose wreal ports are read as analog LEVELS in
    THRESHOLD comparisons -- a supply/enable monitor, e.g.
        assign ok = (VDD > k) && (VSS < j) && (en > k);  assign OUT = ok ? IN : 1'b0;
    On a logic design this wreal `en` meets a logic net -> *E,CUNDCM. The pure-digital intent:
    supplies are ideal (their checks -> 1), a signal check `(en > k)` -> the logic enable `en`.
    Returns a status dict, or None when this is not the pattern (leave it 'digital')."""
    nets = _wreal_nets(body)
    if not nets or FORBIDDEN.search(body) or re.search(r'\banalog\b', body):
        return None
    work = body
    for pat in (r'(?m)^[ \t]*wreal\b[^;]*;', r'(?m)^[ \t]*(input|output|inout)\b[^;]*;',
                r'(?m)^[ \t]*(parameter|localparam)\b[^;]*;'):
        work = re.sub(pat, '', work)
    used_cmp, bad = 0, set()
    for net in nets:
        for m in re.finditer(r'\b' + re.escape(net) + r'\b', work):
            if re.match(r'\s*' + _CMP, work[m.end():m.end() + 4]):
                used_cmp += 1
            else:
                bad.add(net)                      # used as a value, not just a threshold
    if used_cmp == 0:
        return None                               # wreal nets not used as thresholds -> not this
    base = {'contribs': [], 'outputs': set(), 'inputs': set(), 'wreal_nets': nets}
    if bad:
        return dict(base, status='flagged',
                    reason="wreal net(s) %s used outside a threshold comparison "
                           "(not a clean supply/enable monitor)" % sorted(bad))
    return dict(base, status='wreal_logic', reason='wreal supply/enable threshold monitor')


def analyze(mi, src):
    """Classify a parsed module. Returns dict(status, reason, contribs, outputs, inputs)."""
    body = vp.strip_comments(re.search(r'\)\s*;(.*)\bendmodule\b', src, re.S).group(1)
                             if re.search(r'\)\s*;(.*)\bendmodule\b', src, re.S) else '')
    inner = extract_analog(body)
    if inner is None and mi['kind'] != 'analog':
        wl = analyze_wreal_monitor(mi, src, body)
        if wl:
            return wl
        return {'status': 'digital', 'reason': 'no analog content', 'contribs': [],
                'outputs': set(), 'inputs': set()}
    if inner is None:
        return {'status': 'flagged', 'reason': 'analog/electrical but no analog block found',
                'contribs': [], 'outputs': set(), 'inputs': set()}

    contribs, blockers, out_nodes = [], [], []
    for stmt in vp.split_statements(inner):
        if not stmt.strip():
            continue
        m = CONTRIB.match(stmt)
        if not m:
            blockers.append("non-contribution statement: '%s'" % " ".join(stmt.split())[:60])
            continue
        acc, node, ref, rhs = m.group(1), m.group(2).strip(), m.group(3), m.group(4).strip()
        out_nodes.append(base(node))
        if acc == 'I':
            blockers.append("current contribution I(%s)" % node)
        if FORBIDDEN.search(rhs):
            blockers.append("uses %s" % FORBIDDEN.search(rhs).group(1))
        contribs.append((acc, node, (ref.strip() if ref else None), rhs))

    outputs = set(out_nodes)
    inputs = set()
    for _, _, ref, rhs in contribs:
        for vm in V_ACCESS.finditer(rhs):
            inputs.add(base(vm.group(1)))
            if vm.group(2):
                inputs.add(base(vm.group(2)))
        if ref:
            inputs.add(base(ref))
    inputs -= outputs

    if not contribs:
        blockers.append('no V() contributions found')
    if blockers:
        seen, uniq = set(), []
        for b in blockers:
            if b not in seen:
                seen.add(b); uniq.append(b)
        return {'status': 'flagged', 'reason': '; '.join(uniq[:4]),
                'contribs': contribs, 'outputs': outputs, 'inputs': inputs}
    return {'status': 'convertible', 'reason': 'voltage-transfer', 'contribs': contribs,
            'outputs': outputs, 'inputs': inputs}


def translate_rhs(expr):
    """V(a,b)->(a - b); V(a)->a. Leaves params / numeric / bit ops / ternary intact."""
    def repl(m):
        return '(%s - %s)' % (m.group(1), m.group(2)) if m.group(2) else m.group(1)
    return V_ACCESS.sub(repl, expr).strip()


def param_lines(src):
    body = re.search(r'\)\s*;(.*)\bendmodule\b', src, re.S)
    body = body.group(1) if body else src
    return [m.group(0).strip()
            for m in re.finditer(r'(?m)^[ \t]*(?:parameter|localparam)\b[^;]*;', body)]


def _dir_for(mi, p, outputs):
    if p in outputs:
        return 'output'
    if mi['dirs'].get(p, ('', ''))[0] == 'output':
        return 'output'
    return 'input'


def _decl(p, width, kw):
    return '  %s %s%s;' % (kw, p, ('[%s]' % width.strip('[]')) if width else '')


def _net_block(mi, outputs):
    """Emit output/input direction decls + wreal net decls (scalar & unpacked-array bus)."""
    L, warns = [], []
    for p in mi['ports']:
        d = _dir_for(mi, p, outputs)
        w = mi['dirs'].get(p, ('', ''))[1]
        L.append(_decl(p, w, d))
        if w:
            warns.append("port '%s' is a bus -> emitted as unpacked wreal array '%s[%s]'; "
                         "verify the bus connection in your hierarchy" % (p, p, w.strip('[]')))
    for p in mi['ports']:
        w = mi['dirs'].get(p, ('', ''))[1]
        L.append(_decl(p, w, 'wreal'))
    return L, warns


def gen_converted(mi, src, an):
    L = ['`include "disciplines.vams"', '`timescale 1s/1fs',
         '// AUTO-GENERATED wreal conversion of cell "%s" (vh_convert / Stage B).' % mi['module'],
         '// Voltage contributions mapped to continuous assigns (voltage-only). REVIEW,',
         '// then overwrite veriloga.va with this file.',
         'module %s(%s);' % (mi['module'], ', '.join(mi['ports']))]
    nets, warns = _net_block(mi, an['outputs'])
    L += nets
    for pl in param_lines(src):
        L.append('  ' + pl)
    # accumulate contributions per output node (multiple <+ to a node sum)
    acc = {}
    for _, node, ref, rhs in an['contribs']:
        acc.setdefault(node, {'terms': [], 'ref': ref})
        acc[node]['terms'].append(translate_rhs(rhs))
        acc[node]['ref'] = acc[node]['ref'] or ref
    for node, d in acc.items():
        expr = ' + '.join('(%s)' % t for t in d['terms'])
        if d['ref']:
            expr = '%s + %s' % (expr, d['ref'])
        L.append('  assign %s = %s;' % (node, expr))
    L.append('endmodule')
    return '\n'.join(L) + '\n', warns


def gen_skeleton(mi, src, an):
    outs = sorted(an['outputs'] & set(mi['ports'])) or \
        [p for p in mi['ports'] if mi['dirs'].get(p, ('', ''))[0] == 'output']
    L = ['`include "disciplines.vams"', '`timescale 1s/1fs',
         '// AUTO-GENERATED wreal SKELETON for cell "%s" (vh_convert / Stage B).' % mi['module'],
         '// Stage B could NOT auto-convert this cell.',
         '//   reason: %s' % an['reason'],
         '// Fill in the intended digital behavior, REVIEW, then overwrite veriloga.va.',
         'module %s(%s);' % (mi['module'], ', '.join(mi['ports']))]
    nets, _ = _net_block(mi, an['outputs'])
    L += nets
    for pl in param_lines(src):
        L.append('  ' + pl)
    L.append('  // TODO: implement digital behavior. For each output, drive a wreal value, e.g.:')
    for o in outs:
        L.append('  // assign %s = /* function of inputs */ ;' % o)
    L.append('endmodule')
    return '\n'.join(L) + '\n'


def gen_wreal_logic(mi, src, an):
    """Convert a wreal supply/enable monitor to logic: drop the `wreal` decls (the nets
    become logic), and rewrite each `(net <op> threshold)` -> 1'b1 for a SUPPLY net (rail
    assumed nominal), -> the net for a SIGNAL `>`/`>=` (active-high), -> !net for `<`/`<=`.
    Everything else (muxes, assigns, params) is kept. Result is pure logic -> no boundary."""
    nets = an['wreal_nets']
    text = re.sub(r'(?m)^[ \t]*wreal\b[^;]*;[ \t]*\n?', '', src)   # nets -> logic
    cmp_pat = re.compile(r'\(\s*(' + '|'.join(re.escape(n) for n in nets) + r')\s*'
                         + _CMP + r'\s*[^()]*?\)')

    def repl(m):
        net, op = m.group(1), m.group(2)
        if SUPPLY_RE.match(net):
            return "1'b1"                          # supply rail assumed nominal in pure-digital
        return net if op[0] == '>' else ('!' + net)   # signal: active-high / active-low

    text = cmp_pat.sub(repl, text)
    header = ('`include "disciplines.vams"\n`timescale 1s/1fs\n'
              '// AUTO-GENERATED logic conversion of wreal supply/enable monitor "%s"\n'
              '// (vh_convert / Stage B): supply thresholds -> assumed-OK (1\'b1), signal\n'
              '// thresholds -> the logic signal. REVIEW, then overwrite the original.\n'
              % mi['module'])
    return header + text + '\n', []


def convert_file(path):
    """Parse a .va; return [(mi, status, reason, candidate_source_or_None, warns)]."""
    out = []
    raw = open(path, errors='replace').read()
    for mi in vp.parse_text(raw, path):
        src = re.search(r'\bmodule\s+%s\b.*?\bendmodule\b' % re.escape(mi['module']),
                        vp.strip_comments(raw), re.S)
        src = src.group(0) if src else raw
        an = analyze(mi, src)
        if an['status'] == 'digital':
            out.append((mi, 'digital', an['reason'], None, []))
        elif an['status'] == 'convertible':
            cand, warns = gen_converted(mi, src, an)
            out.append((mi, 'converted', an['reason'], cand, warns))
        elif an['status'] == 'wreal_logic':
            cand, warns = gen_wreal_logic(mi, src, an)
            out.append((mi, 'converted', an['reason'], cand, warns))
        else:
            out.append((mi, 'flagged', an['reason'], gen_skeleton(mi, src, an), []))
    return out


def main():
    ap = argparse.ArgumentParser(description="Stage B: analog VerilogA cell -> wreal")
    ap.add_argument('--manifest', help='Stage-A manifest_A.json (convert its veriloga leaves)')
    ap.add_argument('--src', action='append', default=[], help='cell .va file or dir (standalone)')
    ap.add_argument('--out', help='output dir for the report (default: manifest dir)')
    ap.add_argument('--no-cell-write', action='store_true',
                    help="do not write veriloga_wreal.va beside the original cells")
    args = ap.parse_args()

    # collect (module_path, original_src_path, export_copy_or_None)
    targets, out_dir, export_dir = [], args.out, None
    if args.manifest:
        man = json.load(open(args.manifest))
        out_dir = out_dir or os.path.dirname(os.path.abspath(args.manifest))
        export_dir = os.path.join(out_dir, 'export')
        for lf in man.get('veriloga_leaves', []):
            exp = os.path.join(out_dir, lf['gathered']) if lf.get('gathered') else None
            targets.append((lf['src'], exp))
    if args.src:
        files = []
        for s in args.src:
            if os.path.isdir(s):
                import glob
                files += glob.glob(os.path.join(s, '**', '*.va'), recursive=True)
                files += glob.glob(os.path.join(s, '**', '*.vams'), recursive=True)
            else:
                files.append(s)
        for f in sorted(set(files)):
            targets.append((os.path.abspath(f), None))
    if not targets:
        sys.exit("ERROR: nothing to convert; pass --manifest or --src")
    if not out_dir:
        sys.exit("ERROR: --out required with --src")
    os.makedirs(out_dir, exist_ok=True)

    rows, records = [], []
    for src_path, export_copy in targets:
        if not os.path.isfile(src_path):
            rows.append((os.path.basename(src_path), 'MISSING', 'file not found', '', ''))
            continue
        for mi, status, reason, cand, warns in convert_file(src_path):
            cell_cand = ''
            if cand and not args.no_cell_write:
                cell_cand = os.path.join(os.path.dirname(src_path), 'veriloga_wreal.va')
                open(cell_cand, 'w').write(cand)
            exp_note = ''
            if status == 'converted' and export_copy:
                open(export_copy, 'w').write(cand)
                exp_note = 'export updated'
            elif status == 'flagged' and export_copy:
                exp_note = 'export still ANALOG -- not digital-verifiable yet'
            rows.append((mi['module'], status.upper(), reason,
                         cell_cand or ('(skipped)' if cand else ''), exp_note))
            records.append({'module': mi['module'], 'status': status, 'reason': reason,
                            'original': src_path, 'cell_candidate': cell_cand or None,
                            'export': exp_note or None, 'warnings': warns})

    # detection list (stdout + files)
    W = max([len(r[0]) for r in rows] + [10])
    L = ["=" * 78, "STAGE B  --  ANALOG -> DIGITAL  DETECTION LIST", "=" * 78,
         "%-*s  %-9s  %s" % (W, 'cell', 'status', 'detail'), "-" * 78]
    order = {'CONVERTED': 0, 'DIGITAL': 1, 'FLAGGED': 2, 'MISSING': 3}
    for r in sorted(rows, key=lambda x: (order.get(x[1], 9), x[0])):
        L.append("%-*s  %-9s  %s" % (W, r[0], r[1], r[2]))
        if r[3]:
            L.append("%-*s  %-9s    -> %s%s" % (W, '', '', r[3],
                     ("   [%s]" % r[4]) if r[4] else ''))
        elif r[4]:
            L.append("%-*s  %-9s    [%s]" % (W, '', '', r[4]))
    n_conv = sum(1 for r in rows if r[1] == 'CONVERTED')
    n_flag = sum(1 for r in rows if r[1] == 'FLAGGED')
    n_dig = sum(1 for r in rows if r[1] == 'DIGITAL')
    L += ["-" * 78,
          "summary: %d converted, %d already-digital, %d need manual work" % (n_conv, n_dig, n_flag)]
    if n_flag:
        L.append("NOTE: FLAGGED cells got a TODO skeleton (veriloga_wreal.va); the design is")
        L.append("      NOT fully pure-digital until you fill them in and overwrite the originals.")
    if any(rec['warnings'] for rec in records):
        L.append("")
        L.append("WARNINGS:")
        for rec in records:
            for w in rec['warnings']:
                L.append("  ! %s: %s" % (rec['module'], w))
    text = '\n'.join(L)
    print(text)
    open(os.path.join(out_dir, 'manifest_B.txt'), 'w').write(text + '\n')
    json.dump({'stage': 'B', 'cells': records}, open(os.path.join(out_dir, 'manifest_B.json'), 'w'),
              indent=2)


if __name__ == '__main__':
    main()
