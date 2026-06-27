#!/usr/bin/env python3
"""vh_collect_ext.py -- copy the external -v libraries a run actually uses into the
build, so `export/` holds a SELF-CONTAINED snapshot of exactly what was simulated.

The generated run references external PDK models by absolute path (`-v /.../foo.v`,
read from VH_EXT_LIBS, then ext_libs.list, then the baked EXT in run.sh -- same
precedence run.sh uses). Those files live only on the red zone. This walks that
list and copies each one next to the local cells (default: the sibling `export/`),
so you get one folder with every Verilog the design needs -- local + external.

    python3 vh_collect_ext.py --sim <simdir> [--dest <dir>] [--rewrite]

  --dest    where to copy (default: <sim>/../export if it exists, else <sim>/ext_collected)
  --rewrite after copying, (re)write <sim>/ext_libs.list to point at the LOCAL copies,
            so the next `bash run.sh` uses them (run.sh already prefers ext_libs.list).
            The original is saved as ext_libs.list.bak.

Resolves -v <file>, -y <dir>, +incdir+<dir>. Files/dirs that don't exist are
reported and skipped (nothing is invented). Pure stdlib; safe in the red zone.
"""
import argparse, os, re, shlex, shutil, sys


def from_env():
    v = os.environ.get("VH_EXT_LIBS", "").strip()
    return [("-v", f) for f in shlex.split(v)] if v else None


def from_list(path):
    """Mirror run.sh's ext_libs.list parsing -> [(kind, value)]."""
    if not os.path.isfile(path):
        return None
    ops = []
    for raw in open(path, errors="replace"):
        f = raw.strip()
        if not f or f.startswith("#"):
            continue
        if f.startswith("-"):                       # e.g. "-y /dir" (word-split)
            toks = shlex.split(f)
            i = 0
            while i < len(toks):
                if toks[i] == "-y" and i + 1 < len(toks):
                    ops.append(("-y", toks[i + 1])); i += 2
                elif toks[i] == "-v" and i + 1 < len(toks):
                    ops.append(("-v", toks[i + 1])); i += 2
                else:
                    ops.append(("raw", toks[i])); i += 1
        elif f.startswith("+incdir+"):
            ops.append(("+incdir+", f[len("+incdir+"):]))
        elif f.startswith("+"):
            ops.append(("raw", f))
        else:
            ops.append(("-v", f))
    return ops


def from_runsh(path):
    """Parse the baked `EXT=(...)` array out of a generated run.sh -> [(kind, value)]."""
    if not os.path.isfile(path):
        return None
    txt = open(path, errors="replace").read()
    m = re.search(r"^\s*EXT=\((.*?)\)\s*$", txt, re.M | re.S)
    if not m:
        return None
    toks, ops, i = shlex.split(m.group(1)), [], 0
    while i < len(toks):
        t = toks[i]
        if t in ("-v", "-y") and i + 1 < len(toks):
            ops.append((t, toks[i + 1])); i += 2
        elif t.startswith("+incdir+"):
            ops.append(("+incdir+", t[len("+incdir+"):])); i += 1
        else:
            ops.append(("raw", t)); i += 1
    return ops


def resolve(simdir):
    """external ops with run.sh's precedence: VH_EXT_LIBS > ext_libs.list > run.sh EXT."""
    for src, ops in (("$VH_EXT_LIBS", from_env()),
                     ("ext_libs.list", from_list(os.path.join(simdir, "ext_libs.list"))),
                     ("run.sh EXT", from_runsh(os.path.join(simdir, "run.sh")))):
        if ops:
            return src, ops
    return "(none)", []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", default=".", help="sim dir (has run.sh / ext_libs.list)")
    ap.add_argument("--dest", help="copy target (default: <sim>/../export or <sim>/ext_collected)")
    ap.add_argument("--rewrite", action="store_true",
                    help="repoint <sim>/ext_libs.list at the local copies (backs up .bak)")
    args = ap.parse_args()

    simdir = os.path.abspath(args.sim)
    dest = args.dest
    if not dest:
        sib = os.path.join(simdir, os.pardir, "export")
        dest = os.path.abspath(sib) if os.path.isdir(sib) else os.path.join(simdir, "ext_collected")
    dest = os.path.abspath(dest)
    os.makedirs(dest, exist_ok=True)

    src, ops = resolve(simdir)
    if not ops:
        sys.exit("no external libs found (looked at $VH_EXT_LIBS, %s/ext_libs.list, %s/run.sh)"
                 % (simdir, simdir))
    print("external source : %s  (%d entr%s)" % (src, len(ops), "y" if len(ops) == 1 else "ies"))
    print("dest            : %s\n" % dest)

    copied, missing, new_lines = [], [], []
    for kind, val in ops:
        if kind == "raw":
            new_lines.append(val)                   # unknown flag -- carry through, don't touch
            print("  ~ pass-through %s" % val); continue
        if not os.path.exists(val):
            missing.append(val); print("  ! MISSING   %s" % val); continue
        base = os.path.basename(val.rstrip("/"))
        target = os.path.join(dest, base)
        if os.path.isdir(val):
            if os.path.abspath(val) != target:
                if os.path.isdir(target):
                    shutil.rmtree(target)
                shutil.copytree(val, target)
        else:
            if os.path.abspath(val) != target:
                shutil.copy2(val, target)
        copied.append((kind, base))
        new_lines.append(base if kind == "-v" else "%s %s" % (kind, base) if kind == "-y"
                         else "+incdir+%s" % base)
        print("  + %-9s %s" % (kind, base))

    print("\ncopied %d, missing %d" % (len(copied), len(missing)))
    if missing:
        print("  (missing entries were skipped -- on the red zone, edit ext_libs.list to the\n"
              "   real paths first, then re-run this)")

    if args.rewrite and copied:
        elist = os.path.join(simdir, "ext_libs.list")
        if os.path.isfile(elist):
            shutil.copy2(elist, elist + ".bak")
        rel = os.path.relpath(dest, simdir)
        hdr = ("# repointed by vh_collect_ext to the LOCAL copies under %s/\n"
               "# original saved as ext_libs.list.bak\n" % rel)
        body = "\n".join(os.path.join(rel, l) if l and not l.startswith(("-", "+"))
                         else l for l in new_lines)
        open(elist, "w").write(hdr + body + "\n")
        print("\nrewrote %s -> local copies under %s/ (run.sh will use them next run)" % (elist, rel))
    elif copied:
        print("\n(left ext_libs.list / run.sh untouched; pass --rewrite to point the run at the copies)")


if __name__ == "__main__":
    main()
