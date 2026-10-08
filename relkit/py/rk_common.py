"""rk_common -- shared CLI conventions for every relkit subcommand.

Convention (docs/CONTRACT.md section 3):
  * every subcommand accepts --ctx <ctx.json> and --out <out.json>
  * the handler returns a dict of extra fields; relkit.py writes
        {"ok": true, "error": null, "cmd": <name>, ...fields}
    to --out (atomically) and exits 0
  * on failure the handler raises RkError (or anything else); relkit.py writes
        {"ok": false, "error": "<message>", "cmd": <name>, ...e.fields}
    and exits 1
  * logs go to stderr only (rkIpc redirects stderr to <out>.log)

Python 3.8+, stdlib only.
"""

import argparse
import datetime
import json
import os
import sys
import tempfile
import time


class RkError(Exception):
    """A clean, user-facing failure. `fields` are merged into out.json."""

    def __init__(self, message, **fields):
        Exception.__init__(self, message)
        self.fields = fields


def log(msg, *args):
    if args:
        msg = msg % args
    ts = datetime.datetime.now().strftime("%H:%M:%S")
    sys.stderr.write("[relkit %s] %s\n" % (ts, msg))
    sys.stderr.flush()


def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _replace(src, dst):
    """os.replace; on Windows retried for a while, because a reader that has
    `dst` open makes the rename fail there (POSIX renames over open files)."""
    if os.name != "nt":
        os.replace(src, dst)
        return
    for i in range(40):
        try:
            os.replace(src, dst)
            return
        except PermissionError:
            if i == 39:
                raise
            time.sleep(0.05)


def write_json(path, obj, indent=2):
    """Atomic UTF-8 JSON write (ensure_ascii=False so SKILL never sees \\uXXXX
    for non-ASCII text; control characters are still escaped)."""
    d = os.path.dirname(os.path.abspath(path))
    if d and not os.path.isdir(d):
        os.makedirs(d)
    fd, tmp = tempfile.mkstemp(prefix=".tmp_", suffix=".json", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            json.dump(obj, f, ensure_ascii=False, indent=indent, sort_keys=False)
            f.write("\n")
        _replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_tsv(path, header, rows):
    """TSV for SKILL tables (CONTRACT section 5.2): UTF-8, LF, first line =
    header, tab separated, no quoting; tabs/newlines inside cells -> space;
    None -> empty cell."""
    def cell(v):
        if v is None:
            return ""
        if isinstance(v, bool):
            return "true" if v else "false"
        s = str(v)
        return s.replace("\t", " ").replace("\r", " ").replace("\n", " ")

    d = os.path.dirname(os.path.abspath(path))
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\t".join(cell(h) for h in header) + "\n")
        for r in rows:
            f.write("\t".join(cell(v) for v in r) + "\n")


def load_ctx(path):
    if not path:
        return None
    if not os.path.isfile(path):
        raise RkError("ctx file not found: %s" % path)
    try:
        ctx = read_json(path)
    except ValueError as e:
        raise RkError("ctx file %s is not valid JSON: %s" % (path, e))
    if not isinstance(ctx, dict):
        raise RkError("ctx file %s must contain a JSON object" % path)
    return ctx


def add_common_args(parser, ctx_required=False):
    """Add --ctx and --out to a subcommand parser."""
    parser.add_argument("--ctx", required=ctx_required,
                        help="ctx.json written by the SKILL side")
    parser.add_argument("--out", required=True,
                        help="out.json to write the result to")
    return parser


def add_command(subparsers, name, handler, help_text, ctx_required=False):
    """Register a subcommand. handler(args, ctx) -> dict of extra out fields.

    Returns the argparse sub-parser so the module can add its own options.
    """
    p = subparsers.add_parser(name, help=help_text, description=help_text)
    add_common_args(p, ctx_required=ctx_required)
    p.set_defaults(rk_handler=handler, rk_cmd=name)
    return p


IPC_KEEP_DAYS = 14


def prune_ipc_dir(path, keep_days=IPC_KEEP_DAYS, now=None):
    """Delete files older than keep_days from an rkIpc scratch dir
    (<persist_root>/_ipc: one ctx/out/log triple per button press, never
    needed afterwards). Only plain files directly in a dir named "_ipc";
    at most once a day (marker file). Never raises. Returns the count."""
    try:
        d = os.path.abspath(path)
        if os.path.basename(d) != "_ipc" or not os.path.isdir(d):
            return 0
        t = time.time() if now is None else now
        marker = os.path.join(d, ".pruned")
        if os.path.isfile(marker) and t - os.path.getmtime(marker) < 86400:
            return 0
        with open(marker, "w", encoding="utf-8") as f:
            f.write("%s\n" % now_iso())
        n = 0
        limit = t - keep_days * 86400.0
        for name in os.listdir(d):
            p = os.path.join(d, name)
            try:
                if name != ".pruned" and os.path.isfile(p) and os.path.getmtime(p) < limit:
                    os.remove(p)
                    n += 1
            except OSError:
                pass
        return n
    except Exception:  # housekeeping must never fail a command
        return 0


def now_iso():
    return datetime.datetime.now().replace(microsecond=0).isoformat()


class ArgumentParser(argparse.ArgumentParser):
    """argparse that raises instead of exiting, so usage errors still yield out.json."""

    def error(self, message):
        raise RkError("usage error: %s" % message)
