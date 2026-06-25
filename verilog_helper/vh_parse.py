#!/usr/bin/env python3
"""Verilog-A/AMS static parser (library + CLI).

Extracts, per module: ports (ordered), port directions, net types/disciplines,
parameters, and sub-instantiations WITH their port->net connections. Then builds
the instance graph: top modules, leaf modules, external (undefined) masters, and
flags duplicate module definitions.

CLI:  python3 vh_parse.py <file_or_dir> ...   -> prints an inventory.
Library:  parse_files(paths) -> (files, modules, index, dups); build_graph(...).
"""
import re, sys, os, json, glob

KW = set("""module endmodule input output inout electrical wreal wire reg real integer
parameter localparam analog begin end if else case endcase for while initial always assign
function endfunction task endtask branch ground genvar defparam generate endgenerate
voltage current logic supply0 supply1 tri wand wor time signed posedge negedge string
discipline enddiscipline nature endnature aliasparam default disable fork join repeat
forever return null automatic and or not nand nor xor xnor buf""".split())


def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    s = re.sub(r'//[^\n]*', ' ', s)
    # Verilog (* attribute *) instances (the AMS netlister tags every instance with
    # `(* integer library_binding = "LIB"; *)` BETWEEN the master and instance names --
    # the embedded ';' and the '(' also break statement splitting / instance parsing).
    s = re.sub(r'\(\*.*?\*\)', ' ', s, flags=re.S)
    return s


def find_matching(s, i):
    """s[i] must be '('. Return index of the matching ')', or -1."""
    depth = 0
    while i < len(s):
        if s[i] == '(':
            depth += 1
        elif s[i] == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def split_statements(body):
    """Split on ';' at paren/bracket depth 0."""
    stmts, depth, cur = [], 0, []
    for ch in body:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if ch == ';' and depth == 0:
            stmts.append(''.join(cur))
            cur = []
        else:
            cur.append(ch)
    if ''.join(cur).strip():
        stmts.append(''.join(cur))
    return stmts


def _split_commas(s):
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(''.join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if ''.join(cur).strip():
        parts.append(''.join(cur).strip())
    return parts


def parse_range(w):
    """'[13:0]' -> (13, 0); '[3]' -> (3, 3); '' / None -> None. Tolerates spaces."""
    if not w:
        return None
    m = re.match(r'\s*\[\s*(\d+)\s*(?::\s*(\d+)\s*)?\]', w)
    if not m:
        return None
    msb = int(m.group(1))
    lsb = int(m.group(2)) if m.group(2) is not None else msb
    return (msb, lsb)


def range_bits(w):
    """List of bit indices a range covers, MSB-first. '[3:0]'->[3,2,1,0]; ''->[]."""
    r = parse_range(w)
    if not r:
        return []
    msb, lsb = r
    step = -1 if msb >= lsb else 1
    return list(range(msb, lsb + step, step))


def parse_conns(connstr):
    """Return {'named': {port:net}} or {'pos': [net,...]}."""
    named = re.findall(r'\.(\w+)\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)', connstr)
    if named:
        return {'named': {p: n.strip() for p, n in named}, 'pos': None}
    return {'named': None, 'pos': _split_commas(connstr)}


def parse_instance(stmt):
    """Parse one statement; return {master,inst,conns} if it is an instantiation."""
    s = stmt.strip()
    m = re.match(r'(\\?\w+)\s*', s)
    if not m:
        return None
    master = m.group(1)
    if master in KW:
        return None
    i = m.end()
    # optional parameter override  #( ... )
    mm = re.match(r'#\s*', s[i:])
    if mm:
        j = i + mm.end()
        if j < len(s) and s[j] == '(':
            k = find_matching(s, j)
            if k < 0:
                return None
            i = k + 1
    # instance name, with an optional array range:  foo I12[1:0] (...)
    mm = re.match(r'\s*(\\?\w+)\s*(\[[^\]]*\])?\s*', s[i:])
    if not mm:
        return None
    inst = mm.group(1)
    if inst in KW:
        return None
    arr = (mm.group(2) or '').strip() or None      # array-instance range, e.g. '[1:0]'
    i += mm.end()
    if i >= len(s) or s[i] != '(':
        return None
    k = find_matching(s, i)
    if k < 0:
        return None
    return {'master': master, 'inst': inst, 'arr': arr,
            'conns': parse_conns(s[i + 1:k])}


def parse_file(path):
    return parse_text(open(path, errors='replace').read(), path)


_BE = re.compile(r'\b(begin|end)\b')


def strip_analog(body):
    """Remove `analog begin..end` (balance-matched) and `analog <stmt>;` regions, so that
    STRUCTURAL instances elsewhere in a mixed module survive. A naive `analog.*?end` regex
    is wrong: for `analog V(x)<+...;` (no begin) it runs to a *later* begin/end and eats
    the instances in between -- the exact cause of a structural-verilogams leaf (e.g. a
    delay cell) coming out with zero instances and its sub-cells unresolved at xrun."""
    out, i, n = [], 0, len(body)
    pat = re.compile(r'\banalog\b')
    while True:
        m = pat.search(body, i)
        if not m:
            out.append(body[i:]); break
        out.append(body[i:m.start()])
        j = m.end()
        while j < n and body[j].isspace():
            j += 1
        if j < n and body[j] == '@':                       # optional @(event) control
            j += 1
            while j < n and body[j].isspace():
                j += 1
            if j < n and body[j] == '(':
                depth = 0
                while j < n:
                    c = body[j]; j += 1
                    if c == '(':
                        depth += 1
                    elif c == ')':
                        depth -= 1
                        if depth == 0:
                            break
                while j < n and body[j].isspace():
                    j += 1
        if body.startswith('begin', j) and (j + 5 >= n or not (body[j + 5].isalnum() or body[j + 5] == '_')):
            depth = 0                                       # balance-match begin..end
            i = n
            for t in _BE.finditer(body, j):
                depth += 1 if t.group(1) == 'begin' else -1
                if depth == 0:
                    i = t.end(); break
        else:                                              # single statement -> next ;
            depth, k = 0, j
            while k < n:
                c = body[k]
                if c in '([{':
                    depth += 1
                elif c in ')]}':
                    depth -= 1
                elif c == ';' and depth == 0:
                    k += 1; break
                k += 1
            i = k
    return ''.join(out)


def parse_text(raw, path='<text>'):
    """Parse module definitions out of a Verilog/VerilogA source string."""
    src = strip_comments(raw)
    mods = []
    for m in re.finditer(
            r'\bmodule\s+(\w+)\s*(?:#\s*\([^;]*?\))?\s*\((.*?)\)\s*;(.*?)\bendmodule\b',
            src, flags=re.S):
        name, portlist, body = m.group(1), m.group(2), m.group(3)
        ports = [p.strip() for p in portlist.split(',') if p.strip()]
        info = {'module': name, 'file': path, 'ports': ports, 'dirs': {},
                'ntype': {}, 'params': [], 'instances': [], 'kind': None}
        for d in ('input', 'output', 'inout'):
            for mm in re.finditer(r'\b%s\b\s*(\[[^\]]*\])?\s*([^;]+);' % d, body):
                w = (mm.group(1) or '').strip()
                rest = mm.group(2)
                # tolerate a combined net type:  input wreal x;  output reg [3:0] y;
                rest = re.sub(r'^\s*(?:wreal|wire|reg|real|integer|logic|tri|'
                              r'supply[01]|wand|wor)\b\s*', '', rest)
                wm = re.match(r'\s*(\[[^\]]*\])', rest)   # optional range after the type
                if wm:
                    w = w or wm.group(1).strip()
                    rest = rest[wm.end():]
                for nm in rest.split(','):
                    nm = nm.strip()
                    # tolerate an unpacked array decl:  output y[3:0];  -> name y, width [3:0]
                    am = re.match(r'^(\w+)\s*(\[[^\]]*\])\s*$', nm)
                    if am:
                        info['dirs'][am.group(1)] = (d, w or am.group(2).strip())
                    elif re.match(r'^\w+$', nm):
                        info['dirs'][nm] = (d, w)
        for disc in ('electrical', 'wreal', 'wire', 'reg', 'logic'):
            for mm in re.finditer(r'\b%s\b\s*(\[[^\]]*\])?\s*([^;]+);' % disc, body):
                for nm in mm.group(2).split(','):
                    nm = re.sub(r'\[[^\]]*\]\s*$', '', nm.strip()).strip()  # drop unpacked range
                    if re.match(r'^\w+$', nm):
                        info['ntype'][nm] = disc
        for mm in re.finditer(
                r'\b(?:parameter|localparam)\b\s*(?:real|integer)?\s*(\w+)\s*=\s*([^,;]+)', body):
            info['params'].append((mm.group(1), mm.group(2).strip()))
        has_analog = (bool(re.search(r'\banalog\b\s*(begin\b|@|\w+\s*\()', body))
                      or '<+' in body or bool(re.search(r'\b[VI]\s*\(', body)))
        has_elec = ('electrical' in info['ntype'].values()
                    or bool(re.search(r'\belectrical\b', body)))
        has_wreal = ('wreal' in info['ntype'].values() or bool(re.search(r'\bwreal\b', body)))
        info['kind'] = 'analog' if (has_elec or has_analog) else ('wreal' if has_wreal else 'digital')
        b2 = strip_analog(body)
        b2 = re.sub(r'\bfunction\b.*?\bendfunction\b', ' ', b2, flags=re.S)
        for stmt in split_statements(b2):
            inst = parse_instance(stmt)
            if inst:
                info['instances'].append(inst)
        mods.append(info)
    return mods


def parse_files(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += glob.glob(os.path.join(p, '**', '*.va'), recursive=True)
            files += glob.glob(os.path.join(p, '**', '*.vams'), recursive=True)
        else:
            files.append(p)
    files = sorted(set(files))
    mods, index, dups = [], {}, []
    for f in files:
        for mi in parse_file(f):
            if mi['module'] in index:
                dups.append((mi['module'], mi['file'], index[mi['module']]['file']))
            else:
                index[mi['module']] = mi
            mods.append(mi)
    return files, mods, index, dups


def build_graph(mods, index):
    used = set()
    for mi in mods:
        for it in mi['instances']:
            used.add(it['master'])
    defined = set(index)
    tops = sorted({mi['module'] for mi in mods if mi['module'] not in used})
    leaves = sorted({mi['module'] for mi in mods if not mi['instances']})
    externals = sorted(used - defined)
    return {'tops': tops, 'leaves': leaves, 'externals': externals, 'used': sorted(used)}


def main(paths):
    files, mods, index, dups = parse_files(paths)
    g = build_graph(mods, index)
    print("=" * 78)
    print("MODULE INVENTORY  (%d files, %d module defs)" % (len(files), len(mods)))
    print("=" * 78)
    print("%-22s %-7s %3s %3s  %s" % ("module", "kind", "#io", "#sub", "instantiates"))
    print("-" * 78)
    for mi in sorted(index.values(), key=lambda x: x['module']):
        sub = ",".join(sorted({it['master'] for it in mi['instances']})) or "-"
        print("%-22s %-7s %3d %3d  %s" % (mi['module'], mi['kind'],
              len(mi['ports']), len(mi['instances']), sub))
    print()
    print("TOP    (instantiated by nobody): ", g['tops'])
    print("LEAF   (instantiate nothing)   : ", g['leaves'])
    print("EXTERNAL (used, undefined)     : ", g['externals'] or "(none)")
    if dups:
        print("DUPLICATE module defs          : ")
        for nm, f2, f1 in dups:
            print("    %s : %s  (ignored; kept %s)" % (nm, f2, f1))
    out = '/tmp/va_inventory.json'
    json.dump({'files': files, 'graph': g,
               'modules': [{k: v for k, v in mi.items()} for mi in index.values()]},
              open(out, 'w'), indent=2)
    print("\n[json -> %s]" % out)


if __name__ == '__main__':
    main(sys.argv[1:] or ['.'])
