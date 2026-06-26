#!/usr/bin/env python3
"""vh_undump_debug.py -- reconstruct a build tree from a vh_dump_debug.sh text dump.

The air-gap debug round-trip is two scripts:
    red zone : bash vh_dump_debug.sh <build>      # files -> ONE .txt (copy-paste out)
    here     : python3 vh_undump_debug.py d.txt <out>   # .txt -> files (split back)

It splits on the `===== FILE: <label>  (N lines, M bytes) =====` ... `===== END: ...`
markers the dumper writes, recreating each <label> (export/foo.vams, sim/run.sh, ...) as a
real file under <out>. Non-file sections (header, `-v libs`) are ignored. A trailing
annotation like ` [first 500]` on a label (e.g. the capped xrun.log) is stripped.

    python3 vh_undump_debug.py <dump.txt|-> <out-dir>
"""
import sys, os, re

START = re.compile(r'^===== FILE: (.+?)\s+\(\d+ lines, \d+ bytes\) =====\s*$')
END   = re.compile(r'^===== END:')


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: vh_undump_debug.py <dump.txt|-> <out-dir>")
    src = sys.stdin if sys.argv[1] == '-' else open(sys.argv[1], errors='replace')
    lines = src.read().splitlines()
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)

    n, i = 0, 0
    while i < len(lines):
        m = START.match(lines[i])
        if not m:
            i += 1
            continue
        label = re.sub(r'\s*\[.*$', '', m.group(1)).strip()   # drop " [first 500]" etc.
        j, body = i + 1, []
        while j < len(lines) and not END.match(lines[j]):
            body.append(lines[j])
            j += 1
        if label and not label.startswith(('/', '..')) and '\x00' not in label:
            path = os.path.join(out, label)
            os.makedirs(os.path.dirname(path) or out, exist_ok=True)
            with open(path, 'w') as fh:
                fh.write('\n'.join(body) + ('\n' if body else ''))
            print("  wrote %-40s (%d lines)" % (label, len(body)))
            n += 1
        i = j + 1

    if src is not sys.stdin:
        src.close()
    print("reconstructed %d file(s) into %s/" % (n, out))


if __name__ == '__main__':
    main()
