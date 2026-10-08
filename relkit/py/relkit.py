#!/usr/bin/env python3
"""relkit.py -- CLI entry point for the relkit Python side.

Usage (always invoked by rkIpc.il as a subprocess, never imported by Virtuoso):

    <python> <relkit>/py/relkit.py <subcommand> --ctx ctx.json --out out.json [options]

Subcommands are contributed by modules from a FIXED list (MODULES below). Each
module exposes register(subparsers) and registers its subcommands with
rk_common.add_command(). Adding a subcommand = edit your own module only.

Exit code 0 when out.json has "ok": true, 1 otherwise. See docs/CONTRACT.md.
Python 3.8+, stdlib only.
"""

import importlib
import os
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import rk_common  # noqa: E402
import rk_site  # noqa: E402

VERSION = "0.1.0"

# Fixed module registry (CONTRACT section 3.1). Order = order in --help.
MODULES = ["rk_yml", "rk_submit", "rk_parse", "rk_report", "rk_aged",
           "rk_extract", "rk_runs", "rk_donau"]


def _cmd_site(args, ctx):
    """Built-in: resolve the site config (debug aid; also used by SKILL smoke tests)."""
    if ctx is not None:
        site, path, warnings = rk_site.site_from_ctx(ctx)
    else:
        site, path, warnings = rk_site.load_site(workarea=args.workarea)
    return {"site": site, "site_path": path, "warnings": warnings}


def _cmd_version(args, ctx):
    return {"version": VERSION, "python": sys.version.split()[0],
            "modules": MODULES}


def build_parser():
    parser = rk_common.ArgumentParser(prog="relkit.py",
                                      description="relkit RelStudio helper CLI")
    sub = parser.add_subparsers(dest="rk_cmd_name", metavar="<subcommand>")
    p = rk_common.add_command(sub, "site", _cmd_site,
                              "resolve and print the site configuration")
    p.add_argument("--workarea", help="workarea when no --ctx is given")
    rk_common.add_command(sub, "version", _cmd_version, "print versions")
    load_errors = {}
    for name in MODULES:
        try:
            mod = importlib.import_module(name)
            mod.register(sub)
        except Exception as e:  # keep the CLI usable if one module is broken
            load_errors[name] = "%s: %s" % (type(e).__name__, e)
            rk_common.log("module %s failed to load: %s", name, load_errors[name])
    return parser, load_errors


def _find_out(argv):
    for i, a in enumerate(argv):
        if a == "--out" and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith("--out="):
            return a[len("--out="):]
    return None


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    out_path = _find_out(argv)
    cmd = argv[0] if argv else None
    result = {"ok": False, "error": None, "cmd": cmd}
    try:
        parser, load_errors = build_parser()
        args = parser.parse_args(argv)
        if not getattr(args, "rk_handler", None):
            raise rk_common.RkError("no subcommand given (try --help)")
        cmd = args.rk_cmd
        result["cmd"] = cmd
        ctx = rk_common.load_ctx(args.ctx) if getattr(args, "ctx", None) else None
        fields = args.rk_handler(args, ctx) or {}
        result.update(fields)
        result["ok"] = True
        result["error"] = None
    except rk_common.RkError as e:
        result.update(e.fields)
        result["ok"] = False
        result["error"] = str(e)
    except SystemExit as e:  # --help
        if e.code in (0, None):
            return 0
        result["error"] = "exit %s" % e.code
    except Exception as e:
        rk_common.log("unhandled error:\n%s", traceback.format_exc())
        result["ok"] = False
        result["error"] = "%s: %s" % (type(e).__name__, e)
    if result.get("error"):
        rk_common.log("%s failed: %s", cmd, result["error"])
    if out_path:
        try:
            rk_common.write_json(out_path, result)
        except Exception as e:
            rk_common.log("cannot write --out %s: %s", out_path, e)
            return 1
    else:
        rk_common.log("no --out given; result: %s", result)
    if out_path:  # rkIpc scratch (<persist_root>/_ipc/*): drop week-old leftovers
        rk_common.prune_ipc_dir(os.path.dirname(os.path.abspath(out_path)))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
