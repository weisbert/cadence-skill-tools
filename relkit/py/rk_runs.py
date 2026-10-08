"""rk_runs -- Persistent run records: create/update API + list / show / note / delete /
compare / settings-for-rerun / copy-reports (plan 4.9, D15; CONTRACT section 4).

A run record lives in <persist_root>/<maestro lib>/<maestro cell>/<run id>/,
run id = <YYYYMMDD-HHMMSS>_<type> (same-second collision: _2, _3 ...):

    run.json        the record (CONTRACT 4.1); every write goes through
                    update_run()/set_state() (lock + atomic replace)
    note.json       {"note", "tags", "updated", "user"} -- `runs note` only
    input/          netlist copy, netlist.sha1, yml copies, files.json
                    (path + sha1 + sha256 of netlist / yml / dspf / gds;
                    DSPF and GDS themselves are not copied)
    summary.json    rk_parse
    tables/         TSV tables
    reports/        text copies of RelStudio's official reports (PDF: path only)
    aux_report.html rk_report;  hrmi/  rk_aged;  logs/  rk_submit

Library API for the other modules (rk_submit calls these instead of writing
run.json by hand):

    create_run(ctx, site=None, run_type=None, settings=None, extra=None) -> (run_dir, run)
    load_run(run_dir) -> dict
    update_run(run_dir, fields=None, fn=None) -> run        locked read-modify-write
    set_state(run_dir, state, msg="", **fields) -> run      + timeline entry
    add_input_file(run_dir, path, kind="yml") -> "input/<name>"
    copy_reports(run_dir, paths=None, discover=True) -> list
    refresh_raw_data(run_dir) -> bool                        marks "raw data cleaned"
    effective_settings(ctx, site, run_type) -> dict

Python 3.8+, stdlib only.
"""

import datetime
import errno
import glob
import hashlib
import json
import os
import re
import shutil
import socket
import time

import rk_common
import rk_site

RS_TYPES = {"aging": "analog_aging", "deos": "dynamic_eos", "emir": "emir"}
FINAL_STATES = ("done", "failed", "cancelled", "dry_run_done")
RUN_ID_RE = re.compile(r"^\d{8}-\d{6}_(aging|deos|emir)(_\d+)?$")
MAX_REPORT_COPY_BYTES = 5 * 1024 * 1024
TEXT_REPORT_EXTS = (".report", ".rpt", ".txt", ".html", ".htm", ".csv")
REFERENCE_ONLY_EXTS = (".pdf",)

# Metric used for the `key_metric` column, per type (first name found wins;
# matched against summary corner metric names, case-insensitive substring).
KEY_METRICS = {
    "aging": ["didsat(HCI+BTI,%)", "didsat"],
    "deos": ["Total_DPM", "DPM"],
    "emir": ["Pwr_AVG", "Sig_AVG", "Pwr_RMS"],
}


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def _posix(p):
    return p.replace("\\", "/") if p else p


def _join(*parts):
    return _posix(os.path.join(*parts))


def _hashes(path):
    h1, h2 = hashlib.sha1(), hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h1.update(b)
            h2.update(b)
    return h1.hexdigest(), h2.hexdigest()


def file_record(path, copy=None):
    """{path, exists, size, mtime, sha1, sha256[, copy]} for an input file."""
    rec = {"path": _posix(path) if path else path, "exists": False, "size": None,
           "mtime": None, "sha1": None, "sha256": None}
    if copy is not None:
        rec["copy"] = copy
    if path and os.path.isfile(path):
        st = os.stat(path)
        rec.update(exists=True, size=st.st_size,
                   mtime=datetime.datetime.fromtimestamp(int(st.st_mtime)).isoformat())
        rec["sha1"], rec["sha256"] = _hashes(path)
    return rec


class _Lock(object):
    """Cross-process lock on a run dir (O_EXCL lock file; stale after 60 s)."""

    def __init__(self, run_dir, timeout=30.0, stale=60.0):
        self.path = os.path.join(run_dir, ".run.json.lock")
        self.timeout, self.stale = timeout, stale

    def __enter__(self):
        deadline = time.time() + self.timeout
        while True:
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(fd, ("%d %s\n" % (os.getpid(), socket.gethostname())).encode())
                os.close(fd)
                return self
            except OSError as e:
                if e.errno not in (errno.EEXIST, errno.EACCES):
                    raise
                try:
                    if time.time() - os.path.getmtime(self.path) > self.stale:
                        os.remove(self.path)
                        continue
                except OSError:
                    continue
                if time.time() > deadline:
                    raise rk_common.RkError("run record is locked: %s" % self.path)
                time.sleep(0.05)

    def __exit__(self, *exc):
        try:
            os.remove(self.path)
        except OSError:
            pass
        return False


def _tolist(v):
    return list(v) if isinstance(v, (list, tuple)) else []


# --------------------------------------------------------------------------
# creation / update API (used by rk_submit, rk_parse, rk_report, rk_aged)
# --------------------------------------------------------------------------

def new_run_id(run_type, now=None):
    now = now or datetime.datetime.now()
    return "%s_%s" % (now.strftime("%Y%m%d-%H%M%S"), run_type)


def persist_root_of(site):
    root = site.get("persist_root")
    if not root:
        raise rk_common.RkError("site persist_root is not set")
    return _posix(root)


def record_parent(site, lib, cell):
    return _join(persist_root_of(site), lib, cell)


def effective_settings(ctx, site, run_type):
    """settings[run_type] after defaults. Uses rk_yml.effective_settings (the
    one rk_submit/build-yml use) when available; the fallback below applies
    site.defaults.<type>, then (EMIR) site.emir.{rc_corner, license_policy,
    license_wait_hours} and maestro lib as layout_lib, then non-null ctx values."""
    try:
        import rk_yml
        fn = getattr(rk_yml, "effective_settings", None)
    except Exception:  # rk_yml broken: keep the history usable
        fn = None
    if fn is not None:
        return fn(ctx, site, run_type)
    base = dict(((site.get("defaults") or {}).get(run_type)) or {})
    if run_type == "emir":
        em = site.get("emir") or {}
        for k_set, k_site in (("rc_corner", "rc_corner"), ("license_policy", "license_policy"),
                              ("license_wait_hours", "license_wait_hours")):
            if base.get(k_set) is None and em.get(k_site) is not None:
                base[k_set] = em.get(k_site)
        if base.get("layout_lib") is None:
            base["layout_lib"] = ((ctx.get("maestro") or {}).get("lib"))
    over = ((ctx.get("settings") or {}).get(run_type)) or {}
    for k, v in over.items():
        if v is not None:
            base[k] = v
    return base


def _make_run_dir(parent, run_id):
    if not os.path.isdir(parent):
        os.makedirs(parent)
    n = 1
    while True:
        rid = run_id if n == 1 else "%s_%d" % (run_id, n)
        d = os.path.join(parent, rid)
        try:
            os.mkdir(d)
            return _posix(d), rid
        except FileExistsError:
            n += 1
            if n > 999:
                raise rk_common.RkError("cannot create a run dir under %s" % parent)


def create_run(ctx, site=None, run_type=None, settings=None, extra=None, now=None):
    """Create the record dir + input/ + run.json (state `created`).

    ctx      : ctx.json dict (CONTRACT 2)
    settings : settings[type] after defaults (None -> effective_settings())
    extra    : dict merged into run.json last (e.g. work_dir, rs_history ...)
    Returns (run_dir, run)."""
    if site is None:
        site, _p, _w = rk_site.site_from_ctx(ctx)
    run_type = run_type or ctx.get("run_type")
    if run_type not in RS_TYPES:
        raise rk_common.RkError("unknown run type %r (aging | deos | emir)" % run_type)
    maestro = ctx.get("maestro") or {}
    if not maestro.get("lib") or not maestro.get("cell"):
        raise rk_common.RkError("ctx.maestro lib/cell missing; cannot place the run record")
    if settings is None:
        settings = effective_settings(ctx, site, run_type)
    parent = record_parent(site, maestro["lib"], maestro["cell"])
    run_dir, rid = _make_run_dir(parent, new_run_id(run_type, now))
    in_dir = os.path.join(run_dir, "input")
    os.makedirs(in_dir)
    for sub in ("tables", "reports", "logs"):
        os.makedirs(os.path.join(run_dir, sub))

    files = {"netlist": None, "yml": [], "dspf": None, "gds": None}
    nl = ctx.get("netlist") or {}
    nl_path = nl.get("path")
    netlist = {"path": _posix(nl_path) if nl_path else None, "sha1": None, "sha256": None,
               "copy": None}
    if nl_path and os.path.isfile(nl_path):
        name = os.path.basename(nl_path)
        shutil.copyfile(nl_path, os.path.join(in_dir, name))
        rec = file_record(nl_path, copy="input/" + name)
        netlist.update(sha1=rec["sha1"], sha256=rec["sha256"], copy=rec["copy"])
        with open(os.path.join(in_dir, "netlist.sha1"), "w", encoding="utf-8",
                  newline="\n") as f:
            f.write("%s  %s\n" % (rec["sha1"], name))
        files["netlist"] = rec
    elif nl_path:
        files["netlist"] = file_record(nl_path)
    for kind, key in (("dspf", "dspf_file"), ("gds", "gds_file")):
        if settings.get(key):
            files[kind] = file_record(settings[key])
    rk_common.write_json(os.path.join(in_dir, "files.json"), files)

    created = (now or datetime.datetime.now()).replace(microsecond=0).isoformat()
    dut = ctx.get("dut") or {}
    run = {
        "schema": 1, "id": rid, "type": run_type, "rs_type": RS_TYPES[run_type],
        "created": created, "user": ctx.get("user"),
        "host": ctx.get("host") or socket.gethostname(),
        "relkit_version": ctx.get("relkit_version"),
        "maestro": {"lib": maestro.get("lib"), "cell": maestro.get("cell"),
                    "view": maestro.get("view")},
        "test": ctx.get("test"),
        "design": ctx.get("design"),
        "history": ({"name": (ctx.get("history") or {}).get("name"),
                     "dir": (ctx.get("history") or {}).get("dir")}
                    if ctx.get("history") else None),
        "dut": {k: dut.get(k) for k in ("inst", "lib", "cell", "view")} if dut else None,
        "ip_name": ctx.get("ip_name") or maestro.get("cell"),
        "project_name": ctx.get("project_name") or site.get("project_name"),
        "cell_name": dut.get("cell"),
        "corners": [c for c in _tolist(ctx.get("corners")) if c.get("selected")],
        "settings": settings,
        "site_path": ctx.get("site_path"),
        "relstudio_home": ctx.get("relstudio_home") or site.get("relstudio_home"),
        "submit_strategy": site.get("submit_strategy"),
        "dry_run": bool(site.get("dry_run")),
        "work_dir": None, "rs_history": None, "type_dir": None, "yml": None,
        "corner_map": [],
        "netlist": netlist,
        "inputs": {"dspf": files["dspf"], "gds": files["gds"]},
        "state": "created",
        "timeline": [{"t": created, "state": "created", "msg": ""}],
        "jobs": [], "supervisor_pid": None,
        "license": {"retries": 0, "log": []},
        "official_reports": [], "report_copies": [], "aux_report": None, "summary": None,
        "raw_data_present": True,
    }
    if extra:
        run.update(extra)
    rk_common.write_json(os.path.join(run_dir, "run.json"), run)
    return run_dir, run


def load_run(run_dir):
    path = os.path.join(run_dir, "run.json")
    if not os.path.isfile(path):
        raise rk_common.RkError("not a run record (no run.json): %s" % run_dir)
    try:
        run = rk_common.read_json(path)
    except ValueError as e:
        raise rk_common.RkError("run.json in %s is not valid JSON: %s" % (run_dir, e))
    if not isinstance(run, dict):
        raise rk_common.RkError("run.json in %s is not an object" % run_dir)
    return run


def update_run(run_dir, fields=None, fn=None):
    """Locked read-modify-write of run.json: run.update(fields), then fn(run)."""
    with _Lock(run_dir):
        run = load_run(run_dir)
        if fields:
            run.update(fields)
        if fn is not None:
            fn(run)
        rk_common.write_json(os.path.join(run_dir, "run.json"), run)
    return run


def set_state(run_dir, state, msg="", **fields):
    """Set run.state and append {t, state, msg} to the timeline (only when the
    state or message changes)."""
    def apply(run):
        tl = run.setdefault("timeline", [])
        last = tl[-1] if tl else {}
        if last.get("state") != state or last.get("msg") != (msg or ""):
            tl.append({"t": rk_common.now_iso(), "state": state, "msg": msg or ""})
        run["state"] = state
        run.update(fields)
    return update_run(run_dir, fn=apply)


def add_input_file(run_dir, path, kind="yml"):
    """Copy an input (yml ...) into input/ and record path + hashes in
    input/files.json[kind]. Returns the relative copy path."""
    if not os.path.isfile(path):
        raise rk_common.RkError("input file not found: %s" % path)
    in_dir = os.path.join(run_dir, "input")
    if not os.path.isdir(in_dir):
        os.makedirs(in_dir)
    name = os.path.basename(path)
    shutil.copyfile(path, os.path.join(in_dir, name))
    rel = "input/" + name
    fpath = os.path.join(in_dir, "files.json")
    with _Lock(run_dir):
        files = rk_common.read_json(fpath) if os.path.isfile(fpath) else {}
        lst = [x for x in _tolist(files.get(kind)) if x.get("copy") != rel]
        lst.append(file_record(path, copy=rel))
        files[kind] = lst
        rk_common.write_json(fpath, files)
    return rel


def _discover_reports(type_dir):
    found = []
    if not type_dir or not os.path.isdir(type_dir):
        return found
    for pat in ("*.report", "*.report.pdf", "sim*/*.report", "sim*/*.report.pdf",
                "*/sim*/*.report", "*/sim*/*.report.pdf"):
        found.extend(sorted(glob.glob(os.path.join(type_dir, pat))))
    return [_posix(p) for p in found]


def copy_reports(run_dir, paths=None, discover=True):
    """Copy RelStudio's official TEXT reports into reports/ (PDFs are only
    referenced). Sources: `paths`, run.official_reports, and (discover) the
    *.report / *.report.pdf files of type_dir, its simN/ and */simN/ dirs.
    Earlier copies are kept when the Work_Dir is gone. Returns the list."""
    run = load_run(run_dir)
    srcs = []
    for p in list(paths or []) + _tolist(run.get("official_reports")):
        if isinstance(p, dict):
            p = p.get("path")
        if p:
            srcs.append(_posix(p))
    if discover:
        srcs.extend(_discover_reports(run.get("type_dir")))
    type_dir = _posix(run.get("type_dir") or "")
    rep_dir = os.path.join(run_dir, "reports")
    if not os.path.isdir(rep_dir):
        os.makedirs(rep_dir)
    new = []
    seen = set()
    for src in srcs:
        if src in seen:
            continue
        seen.add(src)
        rec = {"path": src, "kind": None, "copy": None, "size": None, "note": None}
        low = src.lower()
        if low.endswith(REFERENCE_ONLY_EXTS):
            rec["kind"] = "pdf"
            rec["exists"] = os.path.isfile(src)
        elif low.endswith(TEXT_REPORT_EXTS):
            rec["kind"] = "text"
            if os.path.isfile(src):
                size = os.path.getsize(src)
                rec["size"] = size
                if size > MAX_REPORT_COPY_BYTES:
                    rec["note"] = "too large to copy (%d bytes)" % size
                else:
                    if type_dir and src.startswith(type_dir + "/"):
                        rel = src[len(type_dir) + 1:]
                    else:
                        rel = os.path.basename(src)
                    name = rel.replace("/", "__")
                    shutil.copyfile(src, os.path.join(rep_dir, name))
                    rec["copy"] = "reports/" + name
            else:
                rec["note"] = "missing"
        else:
            rec["kind"] = "other"
            rec["note"] = "not a text report; referenced only"
        new.append(rec)

    def apply(r):
        old = {x.get("path"): x for x in _tolist(r.get("report_copies"))}
        for rec in new:
            prev = old.get(rec["path"])
            if prev and prev.get("copy") and not rec.get("copy"):
                rec = dict(prev, note="source gone; kept earlier copy")
            old[rec["path"]] = rec
        for path, rec in list(old.items()):
            if rec.get("copy") and path and not os.path.isfile(path):
                old[path] = dict(rec, note="source gone; kept earlier copy")
        r["report_copies"] = list(old.values())
    run = update_run(run_dir, fn=apply)
    return run["report_copies"]


def raw_data_present(run):
    """True/False from the filesystem; None when the run has no Work_Dir yet."""
    d = run.get("type_dir") or run.get("work_dir")
    if not d:
        return None
    return os.path.isdir(d)


def refresh_raw_data(run_dir, run=None):
    """Recompute raw_data_present; on a change, record it in run.json (with
    raw_data_cleaned = time it was first seen gone). Returns the value.
    Only runs in a final state are written: a live run's supervisor (rk_submit)
    owns run.json and does not take our lock."""
    run = run or load_run(run_dir)
    present = raw_data_present(run)
    if present is None:
        return bool(run.get("raw_data_present", True))
    if present != run.get("raw_data_present", True) and run.get("state") in FINAL_STATES:
        fields = {"raw_data_present": present}
        if not present:
            fields["raw_data_cleaned"] = rk_common.now_iso()
        try:
            update_run(run_dir, fields)
        except rk_common.RkError:
            pass  # locked by a writer: report the value, store it next time
        run.update(fields)
    return present


# --------------------------------------------------------------------------
# reading: note / summary / list rows
# --------------------------------------------------------------------------

def read_note(run_dir):
    path = os.path.join(run_dir, "note.json")
    if os.path.isfile(path):
        try:
            d = rk_common.read_json(path)
            return {"note": d.get("note") or "", "tags": _tolist(d.get("tags")),
                    "updated": d.get("updated")}
        except ValueError:
            pass
    return {"note": "", "tags": [], "updated": None}


def write_note(run_dir, note=None, tags=None, user=None):
    load_run(run_dir)  # must be a run record
    cur = read_note(run_dir)
    if note is not None:
        cur["note"] = note
    if tags is not None:
        if isinstance(tags, str):
            tags = tags.split(",")
        clean = []
        for t in tags:
            t = t.strip()
            if t and t not in clean:
                clean.append(t)
        cur["tags"] = clean
    cur["updated"] = rk_common.now_iso()
    cur["user"] = user
    rk_common.write_json(os.path.join(run_dir, "note.json"), cur)
    return cur


def read_summary(run_dir, run=None):
    path = os.path.join(run_dir, "summary.json")
    if os.path.isfile(path):
        try:
            return rk_common.read_json(path)
        except ValueError:
            return None
    s = (run or {}).get("summary")
    if isinstance(s, dict):
        return s
    if isinstance(s, str) and os.path.isfile(s):
        try:
            return rk_common.read_json(s)
        except ValueError:
            return None
    return None


def _to_num(v):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    m = re.match(r"^\s*([-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?)\s*%?", str(v))
    return float(m.group(1)) if m else None


def overall_pass(summary):
    if not summary:
        return None
    vals = [c.get("pass") for c in _tolist(summary.get("corners"))]
    if not vals:
        return None
    if any(v is False for v in vals):
        return False
    if all(v is True for v in vals):
        return True
    return None


def key_metric(summary, run_type):
    if not summary:
        return None
    if summary.get("key_metric") is not None:
        return summary.get("key_metric")
    corners = _tolist(summary.get("corners"))
    if not corners:
        return None
    for want in KEY_METRICS.get(run_type, []):
        best = None
        name = None
        for c in corners:
            for k, v in (c.get("metrics") or {}).items():
                if want.lower() in k.lower():
                    n = _to_num(v)
                    if n is not None and (best is None or n > best):
                        best, name = n, k
        if best is not None:
            return "%s max %g" % (name, best)
    nfail = sum(1 for c in corners if c.get("pass") is False)
    return "%d/%d corners fail" % (nfail, len(corners))


def _life(run):
    s = run.get("settings") or {}
    if s.get("life_time") in (None, ""):
        return None
    return ("%s %s" % (s.get("life_time"), s.get("life_time_unit") or "")).strip()


def _dut_label(run):
    d = run.get("dut") or {}
    if not d:
        return None
    if d.get("inst") and d.get("cell"):
        return "%s (%s)" % (d["inst"], d["cell"])
    return d.get("inst") or d.get("cell")


def list_row(run_dir, run=None):
    run = run or load_run(run_dir)
    summary = read_summary(run_dir, run)
    note = read_note(run_dir)
    return {
        "id": run.get("id") or os.path.basename(run_dir),
        "type": run.get("type"),
        "test": run.get("test"),
        "dut": _dut_label(run),
        "n_corners": len(_tolist(run.get("corners"))),
        "life": _life(run),
        "state": run.get("state"),
        "pass": overall_pass(summary),
        "key_metric": key_metric(summary, run.get("type")),
        "note": note["note"],
        "tags": note["tags"],
        "created": run.get("created"),
        "run_dir": _posix(run_dir),
        "raw_data_present": refresh_raw_data(run_dir, run),
        "lib": (run.get("maestro") or {}).get("lib"),
        "cell": (run.get("maestro") or {}).get("cell"),
    }


def _norm_date(s):
    if not s:
        return None
    d = re.sub(r"[^0-9]", "", str(s))
    if len(d) < 8:
        raise rk_common.RkError("bad date %r (use YYYYMMDD or YYYY-MM-DD)" % s)
    return d[:8]


def find_run_dirs(persist_root, lib=None, cell=None):
    """Run record dirs under persist_root (only <lib>/<cell> when both given)."""
    if lib and cell:
        parents = [os.path.join(persist_root, lib, cell)]
    else:
        parents = []
        if os.path.isdir(persist_root):
            for l in sorted(os.listdir(persist_root)):
                if l.startswith("_") or (lib and l != lib):
                    continue
                ld = os.path.join(persist_root, l)
                if not os.path.isdir(ld):
                    continue
                for c in sorted(os.listdir(ld)):
                    if os.path.isdir(os.path.join(ld, c)):
                        parents.append(os.path.join(ld, c))
    out = []
    for par in parents:
        if not os.path.isdir(par):
            continue
        for name in os.listdir(par):
            d = os.path.join(par, name)
            if os.path.isfile(os.path.join(d, "run.json")):
                out.append(_posix(d))
    return out


def list_runs(persist_root, lib=None, cell=None, run_type=None, test=None,
              since=None, until=None):
    """-> (rows newest first, warnings)."""
    since, until = _norm_date(since), _norm_date(until)
    rows, warnings = [], []
    for d in find_run_dirs(persist_root, lib, cell):
        try:
            run = load_run(d)
        except rk_common.RkError as e:
            warnings.append(str(e))
            continue
        if run_type and run.get("type") != run_type:
            continue
        if test and run.get("test") != test:
            continue
        day = re.sub(r"[^0-9]", "", run.get("created") or os.path.basename(d))[:8]
        if since and day < since:
            continue
        if until and day > until:
            continue
        rows.append(list_row(d, run))
    rows.sort(key=lambda r: (r.get("created") or "", r.get("id") or ""), reverse=True)
    return rows, warnings


LIST_TSV_HEADER = ["_run_dir", "_sev", "ID", "Type", "Test", "DUT", "Corners", "Life",
                   "State", "Pass/Fail", "Key metric", "Note", "Tags", "Created",
                   "Raw data"]


def write_list_tsv(path, rows):
    out = []
    for r in rows:
        sev = ""
        if r["pass"] is False or r["state"] == "failed":
            sev = "fail"
        elif r["state"] in ("waiting_license", "cancelled"):
            sev = "warn"
        pf = {True: "Pass", False: "Fail"}.get(r["pass"], "")
        out.append([r["run_dir"], sev, r["id"], r["type"], r["test"], r["dut"],
                    r["n_corners"], r["life"], r["state"], pf, r["key_metric"],
                    r["note"], ",".join(r["tags"]), r["created"],
                    "present" if r["raw_data_present"] else "cleaned"])
    rk_common.write_tsv(path, LIST_TSV_HEADER, out)
    return path


# --------------------------------------------------------------------------
# compare / rerun / delete
# --------------------------------------------------------------------------

def _flat(prefix, v, out):
    if isinstance(v, dict):
        if not v:
            out[prefix] = "{}"
        for k in v:
            _flat("%s.%s" % (prefix, k) if prefix else k, v[k], out)
    elif isinstance(v, list):
        out[prefix] = json.dumps(v, ensure_ascii=False, sort_keys=True)
    else:
        out[prefix] = v


def conditions_of(run):
    """Ordered {key: value} of everything that defines a run's conditions."""
    c = {}
    c["type"] = run.get("type")
    c["test"] = run.get("test")
    m = run.get("maestro") or {}
    c["maestro"] = "%s/%s" % (m.get("lib"), m.get("cell"))
    d = run.get("design") or {}
    c["design"] = "%s/%s/%s" % (d.get("lib"), d.get("cell"), d.get("view")) if d else None
    du = run.get("dut") or {}
    c["dut.inst"] = du.get("inst")
    c["dut.cell"] = "%s/%s" % (du.get("lib"), du.get("cell")) if du else None
    c["ip_name"] = run.get("ip_name")
    c["project_name"] = run.get("project_name")
    c["history"] = (run.get("history") or {}).get("name")
    c["netlist.sha1"] = (run.get("netlist") or {}).get("sha1")
    inputs = run.get("inputs") or {}
    for k in ("dspf", "gds"):
        if inputs.get(k):
            c["%s.sha1" % k] = inputs[k].get("sha1")
    corners = _tolist(run.get("corners"))
    c["corners"] = " ".join(x.get("name") or "" for x in corners)
    for x in corners:
        n = x.get("name")
        c["corner.%s.temperature" % n] = x.get("temperature")
        c["corner.%s.sections" % n] = " ".join(
            "%s:%s" % (os.path.basename(s.get("model_file") or ""), s.get("section"))
            for s in _tolist(x.get("sections")))
        c["corner.%s.vars" % n] = " ".join(
            "%s=%s" % (k, v) for k, v in sorted((x.get("vars") or {}).items()))
    s = {}
    _flat("", run.get("settings") or {}, s)
    for k in s:
        c["settings.%s" % k] = s[k]
    c["relstudio_home"] = run.get("relstudio_home")
    c["submit_strategy"] = run.get("submit_strategy")
    c["dry_run"] = run.get("dry_run")
    c["state"] = run.get("state")
    return c


def _corner_label(c):
    lab = c.get("corner") or c.get("key") or "?"
    if c.get("stress_id") not in (None, ""):
        lab = "%s#%s" % (lab, c.get("stress_id"))
    return lab


def _pair_corners(ca, cb):
    """Same-name corners pair up; the rest pair in order (FF vs SS compare)."""
    ib = {_corner_label(c): c for c in cb}
    pairs, used, rest_a = [], set(), []
    for c in ca:
        lab = _corner_label(c)
        if lab in ib:
            pairs.append((lab, c, ib[lab]))
            used.add(lab)
        else:
            rest_a.append(c)
    rest_b = [c for c in cb if _corner_label(c) not in used]
    for i in range(max(len(rest_a), len(rest_b))):
        a = rest_a[i] if i < len(rest_a) else None
        b = rest_b[i] if i < len(rest_b) else None
        if a is not None and b is not None:
            lab = "%s | %s" % (_corner_label(a), _corner_label(b))
        else:
            lab = _corner_label(a or b)
        pairs.append((lab, a, b))
    return pairs


def metric_rows(sa, sb):
    rows = []
    for lab, a, b in _pair_corners(_tolist((sa or {}).get("corners")),
                                   _tolist((sb or {}).get("corners"))):
        a, b = a or {}, b or {}
        names = []
        for src in (a.get("metrics") or {}, b.get("metrics") or {}):
            for k in src:
                if k not in names:
                    names.append(k)
        items = [("pass", a.get("pass"), b.get("pass"))]
        items += [(k, (a.get("metrics") or {}).get(k), (b.get("metrics") or {}).get(k))
                  for k in names]
        items.append(("worst_device", a.get("worst_device"), b.get("worst_device")))
        for k, va, vb in items:
            na, nb = _to_num(va), _to_num(vb)
            delta = pct = None
            if na is not None and nb is not None:
                delta = nb - na
                pct = (delta / abs(na) * 100.0) if na != 0 else None
            rows.append({"corner": lab, "metric": k, "a": va, "b": vb,
                         "delta": delta, "delta_pct": pct})
    return rows


def compare_runs(dir_a, dir_b, table_dir=None, stem="runs_compare"):
    ra, rb = load_run(dir_a), load_run(dir_b)
    ca, cb = conditions_of(ra), conditions_of(rb)
    keys = list(ca)
    keys += [k for k in cb if k not in ca]
    conds = [{"key": k, "a": ca.get(k), "b": cb.get(k), "same": ca.get(k) == cb.get(k)}
             for k in keys]
    metrics = metric_rows(read_summary(dir_a, ra), read_summary(dir_b, rb))
    res = {"a": list_row(dir_a, ra), "b": list_row(dir_b, rb),
           "conditions": conds, "metrics": metrics,
           "table_path": None, "conditions_table_path": None}
    if table_dir:
        ida, idb = res["a"]["id"], res["b"]["id"]

        def fmt(v):
            return "" if v is None else ("%.4g" % v if isinstance(v, float) else v)

        mpath = _join(table_dir, stem + "_metrics.tsv")
        rk_common.write_tsv(mpath, ["_sev", "Corner", "Metric", "A " + ida, "B " + idb,
                                    "Delta", "Delta %"],
                            [["warn" if r["a"] != r["b"] else "", r["corner"], r["metric"],
                              r["a"], r["b"], fmt(r["delta"]), fmt(r["delta_pct"])]
                             for r in metrics])
        cpath = _join(table_dir, stem + "_conditions.tsv")
        rk_common.write_tsv(cpath, ["_sev", "Condition", "A " + ida, "B " + idb, "Same"],
                            [["" if c["same"] else "warn", c["key"], c["a"], c["b"],
                              "yes" if c["same"] else "no"] for c in conds])
        res["table_path"], res["conditions_table_path"] = mpath, cpath
    return res


def settings_for_rerun(run_dir):
    """What the panel needs to refill itself from an old run."""
    run = load_run(run_dir)
    corners = _tolist(run.get("corners"))
    return {
        "run_id": run.get("id"),
        "run_type": run.get("type"),
        "test": run.get("test"),
        "maestro": run.get("maestro"),
        "design": run.get("design"),
        "dut": run.get("dut"),
        "ip_name": run.get("ip_name"),
        "project_name": run.get("project_name"),
        "corners": [c.get("name") for c in corners],
        "corner_details": corners,
        "settings": run.get("settings") or {},
        "netlist": run.get("netlist"),
    }


def _inside(child, parent):
    c = os.path.normcase(os.path.realpath(child))
    p = os.path.normcase(os.path.realpath(parent))
    return c == p or c.startswith(p.rstrip(os.sep) + os.sep)


def delete_run(run_dir, force=False):
    """Delete the record directory only (never Work_Dir). Refuses a run that
    is still active unless force."""
    run = load_run(run_dir)
    name = os.path.basename(os.path.normpath(run_dir))
    if not RUN_ID_RE.match(name) and run.get("id") != name:
        raise rk_common.RkError("refusing to delete %s: not a run record dir name" % run_dir)
    if run.get("state") not in FINAL_STATES and not force:
        raise rk_common.RkError("run %s is %s; cancel it first (or --force)"
                                % (name, run.get("state")), state=run.get("state"))
    for key in ("work_dir", "type_dir"):
        wd = run.get(key)
        if wd and (_inside(wd, run_dir) or _inside(run_dir, wd)):
            raise rk_common.RkError("refusing to delete %s: it overlaps %s %s"
                                    % (run_dir, key, wd))
    shutil.rmtree(run_dir)
    return _posix(run_dir)


# --------------------------------------------------------------------------
# subcommand
# --------------------------------------------------------------------------

def _table_dir(args):
    out = os.path.abspath(args.out)
    return os.path.dirname(out), os.path.splitext(os.path.basename(out))[0]


def _need_run(args):
    if not args.run:
        raise rk_common.RkError("runs %s needs --run DIR" % args.action)
    return _posix(os.path.abspath(args.run))


def _cmd_runs(args, ctx):
    act = args.action
    if act == "list":
        if args.persist_root:
            root = _posix(args.persist_root)
            lib = cell = None
        elif ctx is not None:
            site, _p, _w = rk_site.site_from_ctx(ctx)
            root = persist_root_of(site)
            m = ctx.get("maestro") or {}
            lib, cell = m.get("lib"), m.get("cell")
        else:
            raise rk_common.RkError("runs list needs --ctx or --persist-root")
        if args.all:
            lib = cell = None
        rows, warnings = list_runs(root, lib, cell, args.type, args.test,
                                   args.since, args.until)
        tdir, stem = _table_dir(args)
        tsv = write_list_tsv(_join(tdir, stem + "_runs.tsv"), rows)
        return {"runs": rows, "table_path": tsv, "persist_root": root,
                "warnings": warnings}
    run_dir = _need_run(args)
    if act == "show":
        run = load_run(run_dir)
        refresh_raw_data(run_dir, run)
        return {"run": run, "summary": read_summary(run_dir, run),
                "note": read_note(run_dir), "row": list_row(run_dir, run)}
    if act == "note":
        if args.note is None and args.tags is None:
            raise rk_common.RkError("runs note needs --note and/or --tags")
        n = write_note(run_dir, args.note, args.tags, (ctx or {}).get("user"))
        return {"run_id": os.path.basename(run_dir), "note": n["note"], "tags": n["tags"]}
    if act == "delete":
        return {"deleted": delete_run(run_dir, force=args.force)}
    if act == "compare":
        if not args.run2:
            raise rk_common.RkError("runs compare needs --run and --run2")
        tdir, stem = _table_dir(args)
        return compare_runs(run_dir, _posix(os.path.abspath(args.run2)), tdir, stem)
    if act == "settings-for-rerun":
        return settings_for_rerun(run_dir)
    if act == "copy-reports":
        return {"report_copies": copy_reports(run_dir, args.file or None)}
    raise rk_common.RkError("unknown runs action %s" % act)


def register(subparsers):
    p = rk_common.add_command(subparsers, "runs", _cmd_runs,
                              "run-history operations",
                              ctx_required=False)
    p.add_argument("action", choices=["list", "show", "note", "delete", "compare",
                                      "settings-for-rerun", "copy-reports"])
    p.add_argument("--run", help="run record directory (show/note/delete/compare/settings-for-rerun/copy-reports)")
    p.add_argument("--run2", help="second run directory (compare)")
    p.add_argument("--note", help="note text (note)")
    p.add_argument("--tags", help="comma-separated tags (note)")
    p.add_argument("--type", choices=["aging", "deos", "emir"], help="filter (list)")
    p.add_argument("--test", help="filter by Maestro test (list)")
    p.add_argument("--since", help="filter: created on/after YYYYMMDD (list)")
    p.add_argument("--until", help="filter: created on/before YYYYMMDD (list)")
    p.add_argument("--all", action="store_true", help="list all lib/cell under persist_root (list)")
    p.add_argument("--persist-root", dest="persist_root",
                   help="persist_root when no --ctx is given (list)")
    p.add_argument("--force", action="store_true", help="delete even an active run (delete)")
    p.add_argument("--file", action="append",
                   help="extra report file to copy (copy-reports; repeatable)")
