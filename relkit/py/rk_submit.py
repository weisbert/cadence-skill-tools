"""rk_submit -- Work_Dir/History, run_relsim adapter, supervisor, status state machine,
Totem license retry (plan 4.3, D9, D18).

Subcommands (docs/CONTRACT.md section 3):
  submit     --ctx          create the run record, build the yml, start the supervisor
  status     --run DIR      state of a run (respawns a dead supervisor of a live run)
  cancel     --run DIR      ask the supervisor to stop (or mark cancelled if it is gone)
  supervise  --run DIR      INTERNAL: the detached loop started by submit

The supervisor is a detached process (own session) that survives Virtuoso:
  submitting -> queued -> running -> summarizing -> done
  any -> failed;  EMIR license failure -> waiting_license -> (resubmit) -> queued
  user -> cancelled;  dry run -> dry_run_done
It is the only writer of run.json's state fields (rk_parse / rk_report /
rk_aged write their own keys).

Job state is read from RelStudio's files: <type_dir>/mapping.txt (run
identities), <simdir>/job.out (`-STATUS-`, `-ERROR-: Run Simulation Failed`,
`EXIT_CODE`, `Program succeed|failed`) and <simdir>/.ok.txt.

Python 3.8+, stdlib only.
"""

import datetime
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import traceback

import rk_common
import rk_site
import rk_yml

PY_DIR = os.path.dirname(os.path.abspath(__file__))
FINAL_STATES = ("done", "failed", "cancelled", "dry_run_done")
HISTORY_MARKER = ".relkit_history.json"
DEFAULT_LICENSE_IGNORE = [
    r"^\s*INFO",
    r"Checking out .*license",
    r"Checkout \d+ ",
    r"Using license file",
    r"Time spent in licensing",
    r"time for checking out license",
]


# --------------------------------------------------------------------------
# generic helpers

def now():
    return datetime.datetime.now().replace(microsecond=0)


def iso(t):
    return t.isoformat() if t else None


def parse_iso(s):
    if not s:
        return None
    try:
        return datetime.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None


def posix(p):
    return p.replace("\\", "/") if p else p


def read_text(path, limit=None, tail=False):
    try:
        with open(path, "rb") as f:
            if limit and tail:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - limit))
            data = f.read(limit) if (limit and not tail) else f.read()
        return data.decode("utf-8", errors="replace")
    except OSError:
        return None


def tail_lines(path, n):
    t = read_text(path, limit=256 * 1024, tail=True)
    if t is None:
        return []
    return t.splitlines()[-n:]


def load_run(run_dir):
    p = os.path.join(run_dir, "run.json")
    if not os.path.isfile(p):
        raise rk_common.RkError("not a run record (no run.json): %s" % run_dir)
    try:
        return rk_common.read_json(p)
    except ValueError as e:
        raise rk_common.RkError("run.json unreadable in %s: %s" % (run_dir, e))


def save_run(run_dir, run):
    rk_common.write_json(os.path.join(run_dir, "run.json"), run)


def update_run(run_dir, fn):
    """Read-modify-write run.json (fn(run) mutates in place)."""
    run = load_run(run_dir)
    fn(run)
    save_run(run_dir, run)
    return run


def set_state(run, state, msg=""):
    if run.get("state") != state or msg != run.get("message"):
        run.setdefault("timeline", []).append({"t": iso(now()), "state": state, "msg": msg})
    if run.get("state") != state:
        run["state_since"] = iso(now())
    run["state"] = state
    run["message"] = msg


def site_for_run(run):
    ctx_like = {"site_path": run.get("site_path"), "workarea": run.get("workarea"),
                "user": run.get("user"), "relstudio_home": run.get("relstudio_home")}
    site, _p, _w = rk_site.site_from_ctx(ctx_like)
    return site


def pid_alive(pid):
    if not pid:
        return False
    if os.name == "nt":
        try:
            import ctypes
            h = ctypes.windll.kernel32.OpenProcess(0x1000, False, int(pid))
            if not h:
                return False
            code = ctypes.c_ulong()
            ok = ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
            ctypes.windll.kernel32.CloseHandle(h)
            return bool(ok) and code.value == 259  # STILL_ACTIVE
        except Exception:
            return False
    try:
        os.kill(int(pid), 0)
    except OSError as e:
        import errno
        return e.errno == errno.EPERM
    # a zombie child of ours counts as dead
    try:
        wpid, _st = os.waitpid(int(pid), os.WNOHANG)
        if wpid == int(pid):
            return False
    except (ChildProcessError, OSError):
        pass
    return True


def spawn_detached(argv, log_path, cwd=None, env=None):
    """Start argv in its own session, stdout+stderr appended to log_path."""
    d = os.path.dirname(log_path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    logf = open(log_path, "ab")
    kw = {"stdin": subprocess.DEVNULL, "stdout": logf, "stderr": subprocess.STDOUT,
          "cwd": cwd, "env": env, "close_fds": True}
    if os.name == "nt":
        kw["creationflags"] = 0x00000008 | 0x00000200  # DETACHED_PROCESS | NEW_PROCESS_GROUP
    else:
        kw["start_new_session"] = True
    try:
        p = subprocess.Popen(argv, **kw)
    finally:
        logf.close()
    return p


def forget(p):
    """Drop a detached child we will never wait for (no ResourceWarning; the
    CLI process exits right away, so no zombie is left behind)."""
    pid = p.pid
    p.returncode = 0
    return pid


def shell_argv(cmd):
    sh = "/bin/sh" if os.path.exists("/bin/sh") else (shutil.which("sh") or "sh")
    return [sh, "-c", cmd]


# --------------------------------------------------------------------------
# Work_Dir / History

def work_base(ctx, site):
    root = site.get("work_root")
    if not root:
        raise rk_common.RkError("site work_root is not set")
    dut = ctx.get("dut") or {}
    ip = ctx.get("ip_name") or (ctx.get("maestro") or {}).get("cell") or dut.get("cell")
    cell = dut.get("cell")
    project = ctx.get("project_name") or site.get("project_name") or "relsim1"
    if not ip or not cell:
        raise rk_common.RkError("ip_name / dut.cell missing; cannot form Work_Dir")
    return posix(os.path.join(root, ip, cell, project))


def _history_numbers(base):
    nums = []
    if os.path.isdir(base):
        for n in os.listdir(base):
            if n.isdigit() and os.path.isdir(os.path.join(base, n)):
                nums.append(int(n))
    return sorted(nums)


def _marker_identity(ctx, netlist_sha1):
    m = ctx.get("maestro") or {}
    return {"lib": m.get("lib"), "cell": m.get("cell"), "test": ctx.get("test"),
            "dut_cell": (ctx.get("dut") or {}).get("cell"), "netlist_sha1": netlist_sha1}


def preview_work_dir(ctx, site):
    """(Work_Dir, History) the next submit would most likely use (nothing created)."""
    base = work_base(ctx, site)
    nums = _history_numbers(base)
    n = (nums[-1] + 1) if nums else 1
    return posix(os.path.join(base, str(n))), n


def allocate_work_dir(ctx, site, rs_type, netlist_sha1):
    """Create (or reuse) the History dir and Work_Dir/<rs_type>/.

    History = largest existing integer + 1 (plan 4.3). The three run types of
    the same design share one History dir like the GUI does: the newest History
    dir is reused when relkit created it for the same Maestro cell / test / DUT /
    netlist and it has no <rs_type>/ yet.
    """
    base = work_base(ctx, site)
    os.makedirs(base, exist_ok=True)
    ident = _marker_identity(ctx, netlist_sha1)
    nums = _history_numbers(base)
    hist = None
    if nums:
        last = os.path.join(base, str(nums[-1]))
        mpath = os.path.join(last, HISTORY_MARKER)
        if os.path.isfile(mpath) and not os.path.exists(os.path.join(last, rs_type)):
            try:
                m = rk_common.read_json(mpath)
                if all(m.get(k) == v for k, v in ident.items()):
                    hist = nums[-1]
            except ValueError:
                pass
    if hist is None:
        hist = (nums[-1] + 1) if nums else 1
        while True:
            try:
                os.mkdir(os.path.join(base, str(hist)))
                break
            except FileExistsError:
                hist += 1
    work_dir = os.path.join(base, str(hist))
    type_dir = os.path.join(work_dir, rs_type)
    os.makedirs(type_dir, exist_ok=True)
    mpath = os.path.join(work_dir, HISTORY_MARKER)
    marker = dict(ident)
    try:
        if os.path.isfile(mpath):
            old = rk_common.read_json(mpath)
            marker["types"] = sorted(set((old.get("types") or []) + [rs_type]))
        else:
            marker["types"] = [rs_type]
    except ValueError:
        marker["types"] = [rs_type]
    rk_common.write_json(mpath, marker)
    return posix(work_dir), hist, posix(type_dir)


# --------------------------------------------------------------------------
# run_relsim adapter

def relsim_script(home):
    if not home:
        raise rk_common.RkError("RelStudio home unknown (site relstudio_home / $RELSTUDIO_HOME)")
    base = os.path.join(home, "script", "python")
    for name in ("run_relsim.pyc", "run_relsim.py"):
        p = os.path.join(base, name)
        if os.path.isfile(p):
            return posix(p)
    raise rk_common.RkError("run_relsim.pyc/.py not found under %s" % posix(base))


def relsim_argv(site, home, rs_type, mode, yml, user=None, name=None):
    argv = [site.get("python") or sys.executable, relsim_script(home),
            "-t", rs_type, "-m", mode, "-c", yml]
    if mode == "report":
        argv += ["-u", user or rk_site.default_user(), "-n", name or "relkit"]
    return argv


def run_relsim(run, site, mode, wait=True, timeout=None):
    """Run run_relsim in type_dir, log to logs/relsim_<mode>.log.

    wait=True -> returns exit code (None on timeout); False -> Popen."""
    run_dir = run["run_dir"]
    log_path = os.path.join(run_dir, "logs", "relsim_%s.log" % mode)
    name = "%s_%s_%s" % (run.get("ip_name"), run.get("cell_name"),
                         rk_yml.RS_TYPES[run["type"]][2])
    argv = relsim_argv(site, run.get("relstudio_home"), run["rs_type"], mode, run["yml"],
                       user=run.get("user"), name=name)
    with open(log_path, "ab") as lf:
        lf.write(("\n[relkit %s] %s\n" % (iso(now()), " ".join(argv))).encode("utf-8"))
    if not wait:
        return spawn_detached(argv, log_path, cwd=run["type_dir"])
    with open(log_path, "ab") as lf:
        p = subprocess.Popen(argv, cwd=run["type_dir"], stdin=subprocess.DEVNULL,
                             stdout=lf, stderr=subprocess.STDOUT)
        try:
            return p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            return None


# --------------------------------------------------------------------------
# reading RelStudio's job files

def parse_mapping(path):
    """mapping.txt -> list of row dicts (header line starts with '#')."""
    text = read_text(path)
    if not text:
        return []
    header = None
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        if line.startswith("#"):
            header = [h.strip() for h in line[1:].split(";")]
            continue
        if header is None:
            continue
        parts = line.split(";")
        if len(parts) > len(header):  # params may contain ';' -- keep tail columns aligned
            extra = len(parts) - len(header)
            pi = header.index("params") if "params" in header else None
            if pi is not None:
                parts = parts[:pi] + [";".join(parts[pi:pi + extra + 1])] + parts[pi + extra + 1:]
        rows.append(dict(zip(header, [p.strip() for p in parts])))
    return rows


def sim_dirs(run):
    """Ordered list of {sim, key, dir, rows} from mapping.txt (fallback: glob)."""
    type_dir = run["type_dir"]
    rows = parse_mapping(os.path.join(type_dir, "mapping.txt"))
    out = {}
    order = []
    for r in rows:
        sim = r.get("pvt_index")
        if not sim:
            continue
        key = (r.get("pvt_key") or "").split(",")[0]
        if sim not in out:
            if run["type"] == "emir" and r.get("top_cell"):
                d = os.path.join(type_dir, r["top_cell"], sim)
            else:
                d = os.path.join(type_dir, sim)
            out[sim] = {"sim": sim, "key": key, "dir": posix(d), "rows": []}
            order.append(sim)
        out[sim]["rows"].append(r)
    if not order:
        cands = glob.glob(os.path.join(type_dir, "sim*")) + glob.glob(os.path.join(type_dir, "*", "sim*"))
        for d in sorted(cands):
            if os.path.isdir(d) and re.match(r"^sim\d+$", os.path.basename(d)):
                sim = os.path.basename(d)
                out[sim] = {"sim": sim, "key": None, "dir": posix(d), "rows": []}
                order.append(sim)
    return [out[s] for s in order]


_EXIT_RE = re.compile(r"EXIT_CODE:\s*\(?\s*(-?\d+)\s*\)?")
_FAIL_RE = re.compile(r"-ERROR-:\s*(Run Simulation Failed|.*is not existed)|Program failed")


def job_state(simdir):
    """(state, exit_code) of one sim from its job.out / .ok.txt."""
    out = os.path.join(simdir, "job.out")
    if not os.path.isfile(out):
        return "queued", None
    text = read_text(out, limit=512 * 1024, tail=True) or ""
    ok = os.path.isfile(os.path.join(simdir, ".ok.txt"))
    codes = [int(c) for c in _EXIT_RE.findall(text)]
    exit_code = codes[-1] if codes else None
    if _FAIL_RE.search(text) or (exit_code not in (None, 0)):
        return "failed", exit_code if exit_code is not None else 1
    if ok and ("Run Simulation successfully" in text or "Program succeed" in text):
        return "done", 0
    if "Program succeed" in text:
        return "done", 0
    return "running", None


def scan_jobs(run):
    jobs = []
    cmap = {c.get("key"): c for c in run.get("corner_map") or []}
    for s in sim_dirs(run):
        st, code = job_state(s["dir"])
        jobs.append({"sim": s["sim"], "key": s["key"], "dir": s["dir"], "state": st,
                     "exit_code": code, "job_id": None,
                     "corner": (cmap.get(s["key"]) or {}).get("corner")})
    return jobs


def apply_mapping_to_corner_map(run, sims):
    cmap = {c.get("key"): c for c in run.get("corner_map") or []}
    for s in sims:
        c = cmap.get(s["key"])
        if c is not None:
            c["sim"] = s["sim"]
            c["sim_dir"] = s["dir"]


# --------------------------------------------------------------------------
# license detection (EMIR, D9)

def license_files(simdir):
    files = [os.path.join(simdir, "job.out"), os.path.join(simdir, "job.err")]
    em = os.path.join(simdir, "pwr_sig_sh_em")
    files += [os.path.join(em, "adsRpt", "totem.log"), os.path.join(em, "adsRpt", "totem.err")]
    files += sorted(glob.glob(os.path.join(em, "*.log")))
    return [f for f in files if os.path.isfile(f)]


def detect_license(site, failed_dirs, since=None):
    """-> (is_license_problem, matches[{file, line}], tail_lines_of_first_job_out).

    since: epoch seconds of the current attempt; older log files (left over
    from a previous attempt) are ignored."""
    kws = rk_site.get(site, "emir.license_keywords") or []
    ign = rk_site.get(site, "emir.license_ignore")
    if ign is None:
        ign = DEFAULT_LICENSE_IGNORE
    try:
        kre = [re.compile(k, re.I) for k in kws]
        ire = [re.compile(k, re.I) for k in ign]
    except re.error as e:
        raise rk_common.RkError("bad emir.license_keywords/license_ignore regex: %s" % e)
    matches = []
    for d in failed_dirs:
        for f in license_files(d):
            if since is not None and os.path.getmtime(f) < since - 2:
                continue
            text = read_text(f, limit=2 * 1024 * 1024, tail=True) or ""
            for line in text.splitlines():
                if any(r.search(line) for r in kre) and not any(r.search(line) for r in ire):
                    matches.append({"file": posix(f), "line": line.strip()[:400]})
                    if len(matches) >= 20:
                        break
    n = int(rk_site.get(site, "emir.license_tail_lines") or 50)
    tail = tail_lines(os.path.join(failed_dirs[0], "job.out"), n) if failed_dirs else []
    return bool(matches), matches, tail


# --------------------------------------------------------------------------
# official reports

def official_report_files(run):
    """Text reports RelStudio wrote: type_dir/*.report and per-sim *.report (+ .pdf)."""
    type_dir = run["type_dir"]
    pats = [os.path.join(type_dir, "*.report"), os.path.join(type_dir, "sim*", "*.report"),
            os.path.join(type_dir, "*", "sim*", "*.report")]
    seen = []
    for pat in pats:
        for f in sorted(glob.glob(pat)):
            if f not in seen and os.path.isfile(f):
                seen.append(f)
    return seen


def copy_official_reports(run, max_bytes=8 * 1024 * 1024):
    rep_dir = os.path.join(run["run_dir"], "reports")
    out = []
    for f in official_report_files(run):
        rel = os.path.relpath(f, run["type_dir"]).replace("\\", "/")
        local = os.path.join(rep_dir, rel.replace("/", "__"))
        entry = {"name": rel, "path": posix(f), "copy": None,
                 "pdf": posix(f + ".pdf") if os.path.isfile(f + ".pdf") else None}
        try:
            if os.path.getsize(f) <= max_bytes:
                os.makedirs(rep_dir, exist_ok=True)
                shutil.copyfile(f, local)
                entry["copy"] = posix(local)
        except OSError:
            pass
        out.append(entry)
    return out


# --------------------------------------------------------------------------
# submit

def _persist_dir(ctx, site, run_type):
    root = site.get("persist_root")
    if not root:
        raise rk_common.RkError("site persist_root is not set")
    m = ctx.get("maestro") or {}
    lib, cell = m.get("lib"), m.get("cell")
    if not lib or not cell:
        raise rk_common.RkError("ctx.maestro.lib/cell missing")
    stamp = now().strftime("%Y%m%d-%H%M%S")
    base = os.path.join(root, lib, cell)
    os.makedirs(base, exist_ok=True)
    rid = "%s_%s" % (stamp, run_type)
    n = 1
    while True:
        cand = rid if n == 1 else "%s_%d" % (rid, n)
        try:
            os.mkdir(os.path.join(base, cand))
            return cand, posix(os.path.join(base, cand))
        except FileExistsError:
            n += 1


def _file_info(path, max_hash=512 * 1024 * 1024):
    info = {"path": posix(path), "exists": bool(path) and os.path.isfile(path),
            "size": None, "mtime": None, "sha1": None}
    if info["exists"]:
        st = os.stat(path)
        info["size"] = st.st_size
        info["mtime"] = iso(datetime.datetime.fromtimestamp(int(st.st_mtime)))
        if st.st_size <= max_hash:
            info["sha1"] = rk_yml.file_sha1(path)
    return info


def cmd_submit(args, ctx):
    run_type = ctx.get("run_type")
    rs_type, yml_name, _rel, _sub = rk_yml.rs_info(run_type)
    site, site_path, site_warn = rk_site.site_from_ctx(ctx)
    home = site.get("relstudio_home") or ctx.get("relstudio_home")
    relsim_script(home)  # fail early
    rk_yml.selected_corners(ctx)
    netlist = (ctx.get("netlist") or {}).get("path")
    if not netlist or not os.path.isfile(netlist):
        raise rk_common.RkError("netlist not found: %s (export it first)" % netlist)
    settings = rk_yml.effective_settings(ctx, site, run_type)
    if run_type == "emir":
        for k in ("dspf_file", "gds_file"):
            if not settings.get(k) or not os.path.isfile(settings[k]):
                raise rk_common.RkError("EMIR %s not found: %s" % (k, settings.get(k)))
        if not ((settings.get("supplies") or {}).get("power")):
            raise rk_common.RkError("EMIR supplies.power is empty")
    dry_run = bool(site.get("dry_run"))
    strategy = site.get("submit_strategy") or "start"
    if strategy not in ("start", "submit_batch"):
        raise rk_common.RkError("site submit_strategy must be start|submit_batch, not %r" % strategy)

    # Validate the whole yml before anything is created on disk, so a bad ctx
    # never leaves an empty run record or an empty RelStudio History dir.
    preview_dir, preview_hist = preview_work_dir(ctx, site)
    rk_yml.build_doc(ctx, site, run_type, preview_dir, preview_hist, tools={}, sysver="")

    run_id, run_dir = _persist_dir(ctx, site, run_type)
    os.makedirs(os.path.join(run_dir, "input"), exist_ok=True)
    os.makedirs(os.path.join(run_dir, "logs"), exist_ok=True)
    net_copy = os.path.join(run_dir, "input", os.path.basename(netlist))
    shutil.copyfile(netlist, net_copy)
    net_sha1 = rk_yml.file_sha1(netlist)
    with open(os.path.join(run_dir, "input", "netlist.sha1"), "w", encoding="utf-8",
              newline="\n") as f:
        f.write("%s  %s\n" % (net_sha1, posix(netlist)))
    try:
        signature = rk_yml.netlist_signature(netlist)
    except Exception as e:  # never block a submit on this
        signature = None
        site_warn.append("netlist signature failed: %s" % e)

    work_dir, history, type_dir = allocate_work_dir(ctx, site, rs_type, net_sha1)
    doc, info = rk_yml.build_doc(ctx, site, run_type, work_dir, history)
    yml_path = posix(os.path.join(type_dir, yml_name))
    rk_yml.write_yml(yml_path, doc)
    shutil.copyfile(yml_path, os.path.join(run_dir, "input", yml_name))
    files = {}
    if run_type == "emir":
        files = {"dspf": _file_info(settings.get("dspf_file")),
                 "gds": _file_info(settings.get("gds_file"))}
    rk_common.write_json(os.path.join(run_dir, "input", "files.json"), files)

    m = ctx.get("maestro") or {}
    hist = ctx.get("history") or {}
    run = {
        "schema": 1, "id": run_id, "type": run_type, "rs_type": rs_type,
        "created": iso(now()), "user": ctx.get("user") or rk_site.default_user(),
        "host": ctx.get("host"),
        "maestro": {"lib": m.get("lib"), "cell": m.get("cell"), "view": m.get("view")},
        "test": ctx.get("test"), "design": ctx.get("design"),
        "history": {"name": hist.get("name"), "dir": hist.get("dir")} if hist else None,
        "dut": ctx.get("dut"),
        "ip_name": ctx.get("ip_name") or m.get("cell"),
        "project_name": ctx.get("project_name") or site.get("project_name") or "relsim1",
        "cell_name": (ctx.get("dut") or {}).get("cell"),
        "corners": [c for c in ctx.get("corners") or [] if c.get("selected") is True],
        "settings": info["settings"],
        "workarea": ctx.get("workarea"), "site_path": site_path,
        "relstudio_home": posix(home), "submit_strategy": strategy, "dry_run": dry_run,
        "work_dir": work_dir, "rs_history": history, "type_dir": type_dir, "yml": yml_path,
        "run_dir": run_dir,
        "corner_map": info["corner_map"],
        "netlist": {"path": posix(netlist), "sha1": net_sha1, "signature": signature,
                    "copy": "input/" + os.path.basename(netlist),
                    "rewrites": (ctx.get("netlist") or {}).get("rewrites") or []},
        "state": "created", "state_since": iso(now()), "message": "",
        "timeline": [], "jobs": [], "supervisor_pid": None, "start_pid": None,
        "license": {"retries": 0, "log": [], "waiting": False, "next_retry": None,
                    "policy": settings.get("license_policy") if run_type == "emir" else None,
                    "deadline": None, "first_wait": None, "unmatched_tail": []},
        "failure_tail": [], "warnings": site_warn + info["warnings"],
        "official_reports": [], "aux_report": None, "summary": None, "summary_ready": False,
        "raw_data_present": True,
    }
    set_state(run, "created", "run record created")
    set_state(run, "submitting", "starting supervisor")
    save_run(run_dir, run)
    pid = forget(start_supervisor(run_dir))
    run = update_run(run_dir, lambda r: r.update({"supervisor_pid": pid}))
    return {"run_id": run_id, "run_dir": run_dir, "work_dir": work_dir,
            "rs_history": history, "type_dir": type_dir, "yml_path": yml_path,
            "state": run["state"], "supervisor_pid": pid, "dry_run": dry_run,
            "warnings": run["warnings"]}


def start_supervisor(run_dir):
    argv = [sys.executable, os.path.join(PY_DIR, "relkit.py"), "supervise", "--run", run_dir,
            "--out", os.path.join(run_dir, "logs", "supervise_out.json")]
    return spawn_detached(argv, os.path.join(run_dir, "logs", "supervise.log"), cwd=run_dir)


# --------------------------------------------------------------------------
# supervisor

class Supervisor(object):
    def __init__(self, run_dir):
        self.run_dir = run_dir
        self.run = load_run(run_dir)
        self.site = site_for_run(self.run)
        self.poll = float(self.site.get("supervise_poll_seconds") or 30)
        self.start_proc = None
        self.hb = os.path.join(run_dir, "logs", "supervisor.heartbeat")

    # -- persistence
    def reload(self):
        self.run = load_run(self.run_dir)

    def save(self):
        save_run(self.run_dir, self.run)

    def state(self, st, msg=""):
        self.reload()
        set_state(self.run, st, msg)
        self.save()
        rk_common.log("%s: %s %s", self.run["id"], st, msg)

    def heartbeat(self):
        with open(self.hb, "w", encoding="utf-8") as f:
            f.write("%s %d\n" % (iso(now()), os.getpid()))

    def cancel_requested(self):
        return os.path.isfile(os.path.join(self.run_dir, "cancel.request"))

    def start_alive(self):
        if self.start_proc is not None:
            return self.start_proc.poll() is None
        return pid_alive(self.run.get("start_pid"))

    def sleep(self):
        end = time.time() + self.poll
        while time.time() < end:
            if self.cancel_requested():
                return
            time.sleep(min(0.2, self.poll))

    # -- main
    def loop(self):
        self.reload()
        self.run["supervisor_pid"] = os.getpid()
        self.save()
        self.heartbeat()
        if self.run["state"] in ("created", "submitting"):
            try:
                self.submit_flow(first=True)
            except Exception as e:  # never die in "submitting" (status would respawn us forever)
                rk_common.log("submit failed:\n%s", traceback.format_exc())
                self.state("failed", "submit failed: %s: %s" % (type(e).__name__, e))
        errors = 0
        while True:
            self.reload()
            if self.run["state"] in FINAL_STATES:
                break
            self.heartbeat()
            if self.cancel_requested():
                self.do_cancel()
                break
            try:
                self.step()
                errors = 0
            except rk_common.RkError as e:
                self.state("failed", str(e))
            except Exception as e:
                # transient trouble (NFS hiccup, file being rewritten): retry a few polls
                errors += 1
                rk_common.log("supervisor step error %d:\n%s", errors, traceback.format_exc())
                if errors >= 5:
                    self.state("failed", "supervisor error: %s: %s" % (type(e).__name__, e))
            if self.run["state"] in FINAL_STATES:
                break
            self.sleep()
        self.heartbeat()
        return self.run

    def submit_flow(self, first=False):
        self.reload()
        self.run["attempt_started"] = time.time()
        self.save()
        run, site = self.run, self.site
        if run.get("dry_run"):
            self.state("submitting", "dry run: run_relsim -m submit")
            rc = run_relsim(run, site, "submit", wait=True, timeout=3600)
            self.reload()
            sims = sim_dirs(self.run)
            apply_mapping_to_corner_map(self.run, sims)
            self.run["jobs"] = [{"sim": s["sim"], "key": s["key"], "state": "prepared",
                                 "job_id": None, "exit_code": None} for s in sims]
            self.save()
            if rc == 0:
                self.state("dry_run_done", "scripts generated, nothing submitted (dry run)")
            else:
                self.fail_with_log("run_relsim -m submit exited %s" % rc, "submit")
            return
        strategy = run.get("submit_strategy") or "start"
        if strategy == "start":
            self.state("submitting", "run_relsim -m start")
            p = run_relsim(run, site, "start", wait=False)
            self.start_proc = p
            self.reload()
            self.run["start_pid"] = p.pid
            self.save()
            self.state("queued", "submitted (run_relsim -m start, pid %d)" % p.pid)
        else:
            self.state("submitting", "run_relsim -m submit + batch_submit_list.txt")
            rc = run_relsim(run, site, "submit", wait=True, timeout=3600)
            if rc != 0:
                self.fail_with_log("run_relsim -m submit exited %s" % rc, "submit")
                return
            lst = os.path.join(run["type_dir"], "batch_submit_list.txt")
            lines = [l.strip() for l in (read_text(lst) or "").splitlines() if l.strip()]
            if not lines:
                self.state("failed", "batch_submit_list.txt is empty or missing")
                return
            log_path = os.path.join(self.run_dir, "logs", "batch_submit.log")
            for line in lines:
                with open(log_path, "ab") as lf:
                    lf.write(("[relkit %s] %s\n" % (iso(now()), line)).encode("utf-8"))
                    rc = subprocess.call(shell_argv(line), cwd=run["type_dir"],
                                         stdin=subprocess.DEVNULL, stdout=lf,
                                         stderr=subprocess.STDOUT)
                if rc != 0:
                    self.state("failed", "submit command exited %s: %s" % (rc, line[:200]))
                    return
            self.state("queued", "submitted %d job(s) from batch_submit_list.txt" % len(lines))

    def fail_with_log(self, msg, mode):
        self.reload()
        self.run["failure_tail"] = tail_lines(
            os.path.join(self.run_dir, "logs", "relsim_%s.log" % mode),
            int(rk_site.get(self.site, "emir.license_tail_lines") or 50))
        set_state(self.run, "failed", msg)
        self.save()

    def step(self):
        st = self.run["state"]
        if st == "waiting_license":
            return self.step_license_wait()
        if st == "summarizing":
            return self.summarize()
        sims = sim_dirs(self.run)
        if not sims:
            if self.start_alive():
                return
            if (self.run.get("submit_strategy") or "start") == "start":
                rc = self.start_proc.poll() if self.start_proc is not None else None
                return self.fail_with_log(
                    "run_relsim -m start ended (exit %s) without mapping.txt" % rc, "start")
            return self.state("failed", "mapping.txt missing after run_relsim -m submit")
        jobs = scan_jobs(self.run)
        self.reload()
        apply_mapping_to_corner_map(self.run, sims)
        self.run["jobs"] = [{k: j[k] for k in ("sim", "key", "corner", "state", "job_id",
                                               "exit_code")} for j in jobs]
        self.save()
        states = [j["state"] for j in jobs]
        if all(s == "done" for s in states):
            self.state("summarizing", "all %d job(s) done" % len(jobs))
            return self.summarize()
        if any(s in ("queued", "running") for s in states):
            n_run = states.count("running")
            new = "running" if n_run else "queued"
            msg = "%d running, %d queued, %d done, %d failed" % (
                n_run, states.count("queued"), states.count("done"), states.count("failed"))
            if new != self.run["state"] or msg != self.run.get("message"):
                self.state(new, msg)
            return
        # every job final and at least one failed
        if self.start_alive():
            return  # let run_relsim -m start finish first
        failed = [j["dir"] for j in jobs if j["state"] == "failed"]
        self.handle_failure(failed)

    def handle_failure(self, failed_dirs):
        run, site = self.run, self.site
        if run["type"] == "emir":
            is_lic, matches, tail = detect_license(site, failed_dirs, run.get("attempt_started"))
            lic = run.setdefault("license", {})
            policy = lic.get("policy") or rk_site.get(site, "emir.license_policy") or "wait_forever"
            if is_lic:
                t = now()
                lic.setdefault("log", []).append({"t": iso(t), "retry": lic.get("retries", 0),
                                                  "matches": matches[:5]})
                if policy == "fail":
                    self.save()
                    return self.state("failed", "Totem license unavailable (policy: fail)")
                if not lic.get("first_wait"):
                    lic["first_wait"] = iso(t)
                if policy == "wait_hours":
                    hours = (run.get("settings") or {}).get("license_wait_hours")
                    if hours is None:
                        hours = rk_site.get(site, "emir.license_wait_hours") or 8
                    deadline = parse_iso(lic["first_wait"]) + datetime.timedelta(hours=float(hours))
                    lic["deadline"] = iso(deadline)
                    if t >= deadline:
                        self.save()
                        return self.state("failed", "Totem license still unavailable after %s h"
                                          % hours)
                minutes = float(rk_site.get(site, "emir.license_retry_minutes") or 10)
                nxt = t + datetime.timedelta(seconds=minutes * 60.0)
                lic["waiting"] = True
                lic["next_retry"] = iso(nxt)
                self.save()
                return self.state("waiting_license", "Totem license unavailable; retry %d at %s"
                                  % (lic.get("retries", 0) + 1, nxt.strftime("%H:%M:%S")))
            run.setdefault("license", {})["unmatched_tail"] = tail
        n = int(rk_site.get(site, "emir.license_tail_lines") or 50)
        run["failure_tail"] = tail_lines(os.path.join(failed_dirs[0], "job.out"), n) if failed_dirs else []
        self.save()
        self.state("failed", "%d job(s) failed (see %s/job.out)" % (
            len(failed_dirs), os.path.basename(failed_dirs[0]) if failed_dirs else "?"))

    def step_license_wait(self):
        lic = self.run.get("license") or {}
        nxt = parse_iso(lic.get("next_retry"))
        dl = parse_iso(lic.get("deadline"))
        t = now()
        if dl and t >= dl:
            return self.state("failed", "Totem license still unavailable at the deadline")
        if nxt and t < nxt:
            return
        self.resubmit()

    def resubmit(self):
        """D18: resubmit the same yml; archive the old job files first."""
        self.reload()
        lic = self.run.setdefault("license", {})
        lic["retries"] = int(lic.get("retries") or 0) + 1
        n = lic["retries"]
        for s in sim_dirs(self.run):
            for fn in ("job.out", "job.err"):
                p = os.path.join(s["dir"], fn)
                if os.path.isfile(p):
                    os.replace(p, "%s.try%d" % (p, n))
            ok = os.path.join(s["dir"], ".ok.txt")
            if os.path.isfile(ok):
                os.remove(ok)
        lic["waiting"] = False
        lic["next_retry"] = None
        self.save()
        self.state("submitting", "license retry %d: resubmitting the same yml" % n)
        self.submit_flow()

    def summarize(self):
        run, site = self.run, self.site
        if self.start_alive():
            started = parse_iso(run.get("state_since")) or now()
            limit = float(site.get("start_wait_minutes") or 60) * 60.0
            if (now() - started).total_seconds() < limit:
                if run.get("message") != "waiting for run_relsim -m start to finish":
                    self.state("summarizing", "waiting for run_relsim -m start to finish")
                return
        summ = os.path.join(run["type_dir"], "summary_rpt", "summary.txt")
        if not os.path.isfile(summ):
            rc = run_relsim(run, site, "summary", wait=True, timeout=3600)
            if rc != 0:
                rk_common.log("run_relsim -m summary exited %s", rc)
        top_reports = glob.glob(os.path.join(run["type_dir"], "*.report"))
        if not top_reports:
            rc = run_relsim(run, site, "report", wait=True, timeout=3600)
            if rc != 0:
                rk_common.log("run_relsim -m report exited %s", rc)
        self.reload()
        self.run["official_reports"] = copy_official_reports(self.run)
        self.run["summary_ready"] = os.path.isfile(summ)
        self.save()
        msgs = []
        try:
            import rk_parse
            rk_parse.collect(self.run_dir)
        except Exception as e:  # result parsing must not lose the run
            msgs.append("collect failed: %s" % e)
            rk_common.log("collect failed: %s", e)
        try:
            import rk_report
            rk_report.make_report(self.run_dir)
        except Exception as e:
            msgs.append("report failed: %s" % e)
            rk_common.log("report failed: %s", e)
        self.state("done", "; ".join(msgs) if msgs else "finished")

    def do_cancel(self):
        if self.start_alive():
            pid = self.start_proc.pid if self.start_proc is not None else self.run.get("start_pid")
            kill_tree(pid)
        self.reload()
        self.run.setdefault("license", {})["waiting"] = False
        self.save()
        self.state("cancelled", "cancelled by user (jobs already handed to the cluster keep running)")


def kill_tree(pid):
    if not pid:
        return
    try:
        if os.name == "nt":
            subprocess.call(["taskkill", "/F", "/T", "/PID", str(pid)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            try:
                os.killpg(os.getpgid(int(pid)), signal.SIGTERM)
            except OSError:
                os.kill(int(pid), signal.SIGTERM)
    except OSError:
        pass


def supervisor_alive(run_dir, run, site):
    hb = os.path.join(run_dir, "logs", "supervisor.heartbeat")
    if not os.path.isfile(hb):
        return pid_alive(run.get("supervisor_pid"))
    poll = float(site.get("supervise_poll_seconds") or 30)
    age = time.time() - os.path.getmtime(hb)
    if age <= max(3 * poll + 30, 90):
        return True
    return pid_alive(run.get("supervisor_pid"))


# --------------------------------------------------------------------------
# status / cancel / supervise handlers

def _status_fields(run_dir, run):
    raw = bool(run.get("type_dir")) and os.path.isdir(run["type_dir"])
    return {"run_id": run.get("id"), "run_dir": posix(run_dir), "type": run.get("type"),
            "state": run.get("state"), "state_since": run.get("state_since"),
            "final": run.get("state") in FINAL_STATES, "message": run.get("message"),
            "jobs": run.get("jobs") or [],
            "license": {k: (run.get("license") or {}).get(k) for k in
                        ("waiting", "retries", "next_retry", "policy", "deadline")},
            "work_dir": run.get("work_dir"), "official_reports": run.get("official_reports") or [],
            "summary_ready": bool(run.get("summary_ready")), "raw_data_present": raw,
            "aux_report": run.get("aux_report"), "failure_tail": run.get("failure_tail") or []}


def cmd_status(args, ctx):
    run_dir = os.path.abspath(args.run)
    run = load_run(run_dir)
    raw = bool(run.get("type_dir")) and os.path.isdir(run["type_dir"])
    if raw != run.get("raw_data_present"):
        run = update_run(run_dir, lambda r: r.update({"raw_data_present": raw}))
    if run.get("state") not in FINAL_STATES and not os.environ.get("RELKIT_NO_RESPAWN"):
        site = site_for_run(run)
        if not supervisor_alive(run_dir, run, site):
            if os.path.isfile(os.path.join(run_dir, "cancel.request")):
                def mark(r):
                    set_state(r, "cancelled", "cancelled (supervisor was not running)")
                run = update_run(run_dir, mark)
            else:
                pid = forget(start_supervisor(run_dir))
                rk_common.log("supervisor of %s was not running; restarted (pid %d)",
                              run.get("id"), pid)
                run = update_run(run_dir, lambda r: r.update({"supervisor_pid": pid}))
    return _status_fields(run_dir, run)


def cmd_cancel(args, ctx):
    run_dir = os.path.abspath(args.run)
    run = load_run(run_dir)
    if run.get("state") in FINAL_STATES:
        return {"run_id": run.get("id"), "state": run.get("state")}
    with open(os.path.join(run_dir, "cancel.request"), "w", encoding="utf-8") as f:
        f.write(iso(now()) + "\n")
    site = site_for_run(run)
    if not supervisor_alive(run_dir, run, site):
        def mark(r):
            set_state(r, "cancelled", "cancelled (supervisor was not running)")
        run = update_run(run_dir, mark)
        if run.get("start_pid") and pid_alive(run.get("start_pid")):
            kill_tree(run.get("start_pid"))
        return {"run_id": run.get("id"), "state": "cancelled"}
    deadline = time.time() + min(10.0, 2 * float(site.get("supervise_poll_seconds") or 30) + 1)
    while time.time() < deadline:
        run = load_run(run_dir)
        if run.get("state") in FINAL_STATES:
            break
        time.sleep(0.2)
    return {"run_id": run.get("id"), "state": run.get("state")}


def cmd_supervise(args, ctx):
    run_dir = os.path.abspath(args.run)
    sup = Supervisor(run_dir)
    run = sup.loop()
    return {"run_id": run.get("id"), "state": run.get("state")}


def register(subparsers):
    rk_common.add_command(subparsers, "submit", cmd_submit,
                          "create a run record and start the RelStudio flow in the background",
                          ctx_required=True)
    p = rk_common.add_command(subparsers, "status", cmd_status,
                              "report the state of a run",
                              ctx_required=False)
    p.add_argument("--run", required=True, help="run record directory (absolute)")
    p = rk_common.add_command(subparsers, "cancel", cmd_cancel,
                              "cancel a running / license-waiting run",
                              ctx_required=False)
    p.add_argument("--run", required=True, help="run record directory (absolute)")
    p = rk_common.add_command(subparsers, "supervise", cmd_supervise,
                              "INTERNAL: detached supervisor loop started by submit",
                              ctx_required=False)
    p.add_argument("--run", required=True, help="run record directory (absolute)")
