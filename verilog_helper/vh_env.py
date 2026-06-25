#!/usr/bin/env python3
"""vh_env -- the tool-owned, remembered EXTERNAL HDL environment.

External cells (std-cell / behavioral models the design instantiates but does not
define) are normally pointed at via an AMS testbench's *Library Files (-v)* option.
The user runs ordinary (non-AMS) analyses and won't build an AMS TB just to hold
those paths -- so this tool owns the list instead: you set it once, the tool
remembers it (user-level config), and Stage A/C bake it into the xrun run.

Remembered at  $XDG_CONFIG_HOME/verilog_helper/env.json  (default ~/.config/...),
a single user-level set reused across designs; any per-run --ext-* override wins.

Config schema:
  { "lib_files": ["…/ams_models/L16_SVT_ana.v", …],   # xrun -v <file>
    "lib_dirs":  ["…/some_lib"],                        # xrun -y <dir> (+libext)
    "inc_dirs":  ["…/includes"],                        # xrun +incdir+<dir>
    "updated":   "<iso8601>" }

CLI:
  python3 vh_env.py show
  python3 vh_env.py add-lib <file>...   |  add-dir <dir>...  |  add-inc <dir>...
  python3 vh_env.py remove <path>...    |  clear
"""
import sys, os, json, glob, datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vh_parse as vp

LIBEXTS = (".v", ".va", ".vams")
_EMPTY = {"lib_files": [], "lib_dirs": [], "inc_dirs": []}


def default_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "verilog_helper", "env.json")


def load_env(path=None):
    path = path or default_path()
    env = {k: list(v) for k, v in _EMPTY.items()}
    if path and os.path.isfile(path):
        try:
            d = json.load(open(path))
            for k in _EMPTY:
                env[k] = [str(x) for x in d.get(k, []) if str(x).strip()]
        except (ValueError, OSError) as e:
            sys.stderr.write("  [vh_env] WARNING: could not read %s (%s)\n" % (path, e))
    return env


def save_env(env, path=None):
    path = path or default_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    out = {k: dedup(env.get(k, [])) for k in _EMPTY}
    out["updated"] = datetime.datetime.now().isoformat(timespec="seconds")
    json.dump(out, open(path, "w"), indent=2)
    return path


def dedup(seq):
    seen, out = set(), []
    for x in seq:
        x = os.path.abspath(os.path.expanduser(str(x))) if x else x
        if x and x not in seen:
            seen.add(x)
            out.append(x)
    return out


def merge(env, lib_files=None, lib_dirs=None, inc_dirs=None):
    """Union new entries into env (in place), returning it."""
    env["lib_files"] = dedup(env.get("lib_files", []) + list(lib_files or []))
    env["lib_dirs"] = dedup(env.get("lib_dirs", []) + list(lib_dirs or []))
    env["inc_dirs"] = dedup(env.get("inc_dirs", []) + list(inc_dirs or []))
    return env


def is_empty(env):
    return not (env.get("lib_files") or env.get("lib_dirs") or env.get("inc_dirs"))


def xrun_flags(env):
    """xrun command-line fragments for this env: -v <file>, -y <dir>, +incdir+<dir>."""
    flags = []
    for f in env.get("lib_files", []):
        flags += ["-v", f]
    for d in env.get("lib_dirs", []):
        flags += ["-y", d]
    for d in env.get("inc_dirs", []):
        flags.append("+incdir+" + d)
    return flags


def _dir_sources(d):
    files = []
    for ext in LIBEXTS:
        files += glob.glob(os.path.join(d, "**", "*" + ext), recursive=True)
    return sorted(set(files))


def index_modules(env, max_bytes=20 * 1024 * 1024, warn=None):
    """Parse every -v file and -y dir source; return {module: {'file','kind'}}.

    First definition wins (lib_files before lib_dirs). Oversized files are skipped
    with a warning (regex parse of a multi-MB std-cell lib is rarely what you want).
    """
    warn = warn if warn is not None else []
    index, files = {}, []
    for f in env.get("lib_files", []):
        files.append(f)
    for d in env.get("lib_dirs", []):
        if os.path.isdir(d):
            files += _dir_sources(d)
        else:
            warn.append("lib dir not found: %s" % d)
    for f in files:
        if not os.path.isfile(f):
            warn.append("lib file not found: %s" % f)
            continue
        if os.path.getsize(f) > max_bytes:
            warn.append("skipped oversized lib file (>%dMB): %s"
                        % (max_bytes // (1024 * 1024), f))
            continue
        try:
            for mi in vp.parse_file(f):
                index.setdefault(mi["module"], {"file": f, "kind": mi["kind"]})
        except Exception as e:                       # never let a bad lib kill the run
            warn.append("parse error in %s: %s" % (f, e))
    return index


# --------------------------------------------------------------------------- #
def _cli(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    path = default_path()
    env = load_env(path)
    if cmd == "show":
        print("env file: %s%s" % (path, "" if os.path.isfile(path) else "  (not created yet)"))
        for k in ("lib_files", "lib_dirs", "inc_dirs"):
            print("%-10s:" % k)
            for x in env.get(k, []):
                exists = "" if os.path.exists(x) else "   <-- MISSING"
                print("    %s%s" % (x, exists))
        idx = index_modules(env)
        if idx:
            print("modules provided (%d): %s" % (
                len(idx), ", ".join("%s[%s]" % (m, idx[m]["kind"])
                                    for m in sorted(idx))[:600]))
        return 0
    if cmd == "clear":
        save_env({k: [] for k in _EMPTY}, path)
        print("cleared %s" % path)
        return 0
    if cmd in ("add-lib", "add-dir", "add-inc"):
        key = {"add-lib": "lib_files", "add-dir": "lib_dirs", "add-inc": "inc_dirs"}[cmd]
        env[key] = dedup(env.get(key, []) + rest)
        save_env(env, path)
        print("updated %s" % key)
        return _cli(["show"])
    if cmd == "remove":
        tgt = set(dedup(rest))
        for k in _EMPTY:
            env[k] = [x for x in env.get(k, []) if x not in tgt]
        save_env(env, path)
        return _cli(["show"])
    sys.stderr.write("unknown command: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
