#!/usr/bin/env python3
"""R1 end-to-end check on the dev VM: aged corners in a real Maestro view.

    python3 relkit/tests/rkAged_vm_test.py [--lib L --cell C --view V --test T --corner N]
                                           [--sim] [--keep]

Bridge: the skillbridge server id in $SB_ID (default "default").
Needs the live Virtuoso with the skillbridge server and the relkit tree synced
(tools/sync_vm.sh). What it does, in order:

  1. backs up the Maestro view directory and, once the session names it, the
     results location (GNU tar tgz under <workarea>/relkit_dev/backup/, modes and
     mtimes kept) with md5/mode/mtime manifests; a stale edit lock (owner pid
     gone) is moved aside. (Maestro purges histories beyond
     adexl.simulation saveLastNHistoryEntries -- simulation data included -- when
     a run starts, so --sim also raises that limit for the run.)
  2. loads relkit + tests/rkAged_smoke.il (Part A: no Maestro);
  3. opens the view in append mode, writes ctx.json (rkMaeGetContext);
  4. builds a SYNTHETIC aging run record (generic names: cell "tb", fake PDK
     paths under the scratch dir) in <persist_root>/<lib>/<cell>/<run id>/ with a
     Stress .hrmiage0/.dat and an Aged netlist tail holding the HRMI block;
  5. rkAgedPrepare (relkit.py aged-include --netlist <newest history netlist>)
     + rkAgedCreateCorners(... withFresh): 2 aged + 2 fresh corners (eval
     temperatures 55 and -40), checks every model / variable / test scope;
  5b. rkAgedDeltaTable on the newest EXISTING history that has two corners with
     numeric outputs (explicit pair): numeric rows, recorded in the run record
     and its aux report -- no simulation needed;
  6. (--sim) runs ONE Maestro simulation of only those corners, pre-run script
     disabled in memory and history retention raised (Spectre; the aged
     points are expected to fail -- Spectre does not know the ALPS HRMI
     options), then checks that every aged point netlist includes
     aged_<id>.scs, the fresh ones do not, and the include holds the complete
     HRMI block pointing at the persisted .hrmiage0 (whose age_data_file points
     at the persisted .dat);
  7. (--sim) rkAgedDeltaTable on that history: auto pairs (aged vs fresh twin) and an
     explicit pair (fresh 55 vs fresh -40) that must give numeric rows; the
     table must be recorded in run.json and the aux report;
  8. deletes the corners, closes the session WITHOUT saving, restores the view
     directory and the results location from the backups, removes the
     synthetic run record and the scratch dir, and verifies both manifests.

Exit 0 only when every check passed AND the view was restored identically.
"""
import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RELKIT = os.path.dirname(HERE)
SKILL_TOOLS = os.path.dirname(RELKIT)
sys.path.insert(0, os.path.join(RELKIT, "py"))
for p in (os.environ.get("SKILLBRIDGE_PATH"), os.path.join(SKILL_TOOLS, "skillbridge")):
    if p and os.path.isdir(p) and p not in sys.path:
        sys.path.insert(0, p)

import rk_yml  # noqa: E402
from skillbridge import Workspace  # noqa: E402

CHECKS = []


def check(label, ok, detail=""):
    CHECKS.append((label, bool(ok), detail))
    print("%s %s%s" % ("ok  " if ok else "FAIL", label, (" -- " + detail) if detail and not ok else ""))
    return ok


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Bridge:
    def __init__(self):
        self.ws = Workspace.open(os.environ.get("SB_ID") or None)

    def ev(self, expr):
        """One-line evalstring, value printed with %L; errset.errset cleared."""
        return self.ws["evalstring"](
            '(let ((rkR (sprintf nil "%%L" %s))) (putprop (quote errset) nil (quote errset)) rkR)'
            % expr)

    def evs(self, expr):
        """Value of a string-valued expression (unquoted)."""
        r = self.ws["evalstring"](
            '(let ((rkR %s)) (putprop (quote errset) nil (quote errset)) rkR)' % expr)
        return r

    def load(self, path):
        r = self.ev("(errset (load %s) t)" % q(path))
        if r != "(t)":
            raise RuntimeError("load %s failed: %s" % (path, r))


def md5_manifest(root):
    """{relpath: (md5 | link target | "dir", mode, mtime)} for root and everything below."""
    out = {}
    for d, dirs, files in os.walk(root):
        st = os.lstat(d)
        out[os.path.relpath(d, root) + "/"] = ("dir", st.st_mode, st.st_mtime_ns)
        for f in files:
            p = os.path.join(d, f)
            st = os.lstat(p)
            if os.path.islink(p):
                out[os.path.relpath(p, root)] = ("link:" + os.readlink(p), st.st_mode, st.st_mtime_ns)
                continue
            h = hashlib.md5()
            with open(p, "rb") as fh:
                h.update(fh.read())
            out[os.path.relpath(p, root)] = (h.hexdigest(), st.st_mode, st.st_mtime_ns)
    return out


def lock_is_stale(lock):
    """True when the edit-lock owner process is gone (same host)."""
    try:
        txt = open(lock, encoding="utf-8", errors="replace").read()
    except OSError:
        return False
    m = re.search(r"^ProcessIdentifier\s+(\d+)", txt, re.M)
    h = re.search(r"^HostName\s+(\S+)", txt, re.M)
    if not m or not h or h.group(1) != os.uname().nodename.split(".")[0]:
        return False
    return not os.path.exists("/proc/%s" % m.group(1))


AGED_TAIL = """// synthetic Aged_1 netlist tail (relkit R1 VM test; generic names only)
simulator lang=spectre
global 0
saveOptions options save=selected

simulator lang=spectre

include "{pdk}/alps/macro_model_usage.scs" section=AGEING_MACRO
option1 options hrmiflag=0.1 hrmiage=yes close_all_feature=yes
option2 options hrmiagemodel="{pdk}/alps/fake_aging_model_alps.scs"
option3 options hrmiageso="{pdk}/alps/fake_aging_model_alps.so"
option4 options hrmiinput="{stress}/tb_Stress_1.hrmiage0"

simulator lang=spice
.option dagetime=10y
"""


def build_run(scratch, persist_root, ctx, corner_name, hist_netlist, run_id):
    """Synthetic aging run record + Work_Dir tree -> run_dir."""
    lib, cell = ctx["maestro"]["lib"], ctx["maestro"]["cell"]
    test = ctx["test"]
    corner = [c for c in ctx["corners"] if c["name"] == corner_name]
    if not corner:
        raise RuntimeError("corner %s not in ctx (have %s)" % (corner_name, [c["name"] for c in ctx["corners"]]))
    corner = dict(corner[0], selected=True)
    pdk = os.path.join(scratch, "fake_pdk")
    os.makedirs(os.path.join(pdk, "alps"), exist_ok=True)
    with open(os.path.join(pdk, "alps", "macro_model_usage.scs"), "w") as f:
        f.write("// fake macro model file (relkit R1 VM test)\nsection AGEING_MACRO\nendsection AGEING_MACRO\n")
    type_dir = os.path.join(scratch, "work", "analog_aging")
    point = os.path.join(type_dir, "sim1", "10y_point")
    stress = os.path.join(point, "Stress_1", "tb_Stress_1")
    os.makedirs(stress, exist_ok=True)
    os.makedirs(os.path.join(point, "Aged_1"), exist_ok=True)
    dat = os.path.join(stress, "tb_Stress_1.hrmiage0.dat")
    with open(dat, "wb") as f:
        f.write(b"synthetic hrmi age data\n" * 40)
    with open(os.path.join(stress, "tb_Stress_1.hrmiage0"), "w") as f:
        f.write("age_data_file\t1\t%s\ntr_start\t0\ntr_end\t2e-08\nage_time\t10y\n" % dat)
    with open(os.path.join(point, "Aged_1", "tb_Aged_1.scs"), "w") as f:
        f.write(AGED_TAIL.format(pdk=pdk, stress=stress))
    os.makedirs(os.path.join(type_dir, "summary_rpt"), exist_ok=True)
    with open(os.path.join(type_dir, "summary_rpt", "summary_id.yml"), "w") as f:
        f.write("1: %s/sim1\n" % type_dir)
    key = "%s_%s_%s" % (corner_name, test, corner_name)
    with open(os.path.join(type_dir, "mapping.txt"), "w") as f:
        f.write("#index;pvt_index;pvt_key;sim_type;test_name;mode_name;corner_name;sim_temp;"
                "analysis_type;life_time;params;simulator\n")
        f.write("1;sim1;%s,1;Stress_1;%s;%s;%s;55;multi_age_points;10y;;alps\n" % (key, test, corner_name, corner_name))
        f.write("2;sim1;%s,0;Aged_1;%s;%s;%s;55;multi_age_points;10y;;alps\n" % (key, test, corner_name, corner_name))
    run_dir = os.path.join(persist_root, lib, cell, run_id)
    os.makedirs(run_dir)
    run = {"schema": 1, "id": run_id, "type": "aging", "rs_type": "analog_aging",
           "created": time.strftime("%Y-%m-%dT%H:%M:%S"), "user": os.environ.get("USER"),
           "maestro": {"lib": lib, "cell": cell, "view": ctx["maestro"]["view"]}, "test": test,
           "dut": {"inst": "I0", "lib": lib, "cell": "tb", "view": "schematic"},
           "ip_name": cell, "project_name": "relsim1", "cell_name": "tb",
           "corners": [corner], "settings": {"life_time": "10", "life_time_unit": "years",
                                             "eval_temperatures": ["55", "-40"]},
           "run_dir": run_dir, "work_dir": os.path.join(scratch, "work"), "type_dir": type_dir,
           "corner_map": [{"key": key, "corner": corner_name, "sim": "sim1", "temperature": "55",
                           "mode": "Stress_1", "eval_temperatures": ["55", "-40"]}],
           "netlist": {"path": hist_netlist, "signature": rk_yml.netlist_signature(hist_netlist)},
           "state": "done", "timeline": [], "jobs": []}
    with open(os.path.join(run_dir, "run.json"), "w", encoding="utf-8") as f:
        json.dump(run, f, indent=2)
    return run_dir


def check_netlists(resloc, hist, test, names, include, run_dir):
    # numbered point dirs only (psf/ holds a copy of the first point's netlist)
    nls = sorted(p for p in glob.glob(os.path.join(resloc, hist, "*", test, "netlist", "input.scs"))
                 if os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(p)))).isdigit())
    check("point netlists found", len(nls) >= len(names), "%d netlists under %s" % (len(nls), os.path.join(resloc, hist)))
    inc_re = re.compile(r'^\s*include\s+"%s"\s*$' % re.escape(include), re.M)
    with_inc, without = [], []
    for p in nls:
        txt = open(p, encoding="utf-8", errors="replace").read()
        (with_inc if inc_re.search(txt) else without).append(p)
        if inc_re.search(txt):
            check("aged point keeps the source section (%s)" % os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(p)))),
                  re.search(r'^\s*include\s+"[^"]+"\s+section=tt\s*$', txt, re.M), p)
    n_aged = len([n for n in names if "_aged" in n])
    check("aged include in every aged point netlist", len(with_inc) == n_aged,
          "with=%s without=%s" % (with_inc, without))
    check("fresh point netlists without aged include", len(without) == len(names) - n_aged)
    print("  include line: include \"%s\"" % include)
    for p in with_inc[:1]:
        print("  e.g. %s" % p)
    # the include = complete HRMI block, hrmiinput -> persisted .hrmiage0 -> persisted .dat
    txt = open(include, encoding="utf-8").read()
    for pat in (r"^simulator lang=spectre$", r"^include \".*/macro_model_usage\.scs\" section=AGEING_MACRO$",
                r"^option1 options hrmiflag=0\.1 hrmiage=yes close_all_feature=yes$",
                r"^option2 options hrmiagemodel=\"[^\"]+\"$", r"^option3 options hrmiageso=\"[^\"]+\"$",
                r"^option4 options hrmiinput=\"[^\"]+\"$", r"^simulator lang=spice$",
                r"^\.option dagetime=10y$"):
        check("HRMI block line %s" % pat, re.search(pat, txt, re.M))
    check("include ends in spectre mode", txt.rstrip().splitlines()[-1] == "simulator lang=spectre")
    h0 = re.search(r'hrmiinput="([^"]+)"', txt).group(1)
    check("hrmiinput is the persisted copy", h0.startswith(os.path.join(run_dir, "hrmi")) and os.path.isfile(h0), h0)
    first = open(h0, encoding="utf-8").readline().split("\t")
    check("age_data_file -> persisted .dat", first[0] == "age_data_file" and first[1] == "1"
          and first[2].strip() == h0 + ".dat" and os.path.isfile(h0 + ".dat"), repr(first))
    # what Spectre said about an aged point (expected to fail at home: no ALPS)
    for p in with_inc[:1]:
        logs = glob.glob(os.path.join(os.path.dirname(os.path.dirname(p)), "psf", "spectre.out")) + \
            glob.glob(os.path.join(os.path.dirname(os.path.dirname(p)), "*.log"))
        for lg in logs[:1]:
            errs = [l.strip() for l in open(lg, encoding="utf-8", errors="replace") if "ERROR" in l]
            print("  spectre on the aged point (%s): %s" % (lg, errs[:3] or "no ERROR lines"))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", default="sim_yusheng")
    ap.add_argument("--cell", default="Test")
    ap.add_argument("--view", default="maestro")
    ap.add_argument("--test", default="Test")
    ap.add_argument("--corner", default="TT")
    ap.add_argument("--sim", action="store_true",
                    help="also run ONE Maestro simulation of the new corners (step 6/7)")
    ap.add_argument("--keep", action="store_true", help="keep scratch + run record (debug)")
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args(argv)

    br = Bridge()
    br.load(os.path.join(RELKIT, "relkit.il"))
    br.load(os.path.join(HERE, "rk_testlib.il"))
    workarea = br.evs("(rkWorkarea)")
    persist_root = br.evs('(rkSiteGet "persist_root")')
    view_dir = br.evs('(getq (ddGetObj %s %s %s) readPath)' % (q(a.lib), q(a.cell), q(a.view)))
    if not (view_dir and os.path.isdir(view_dir) and
            view_dir.rstrip("/").endswith("/%s/%s" % (a.cell, a.view)) and
            os.path.isfile(os.path.join(view_dir, "maestro.sdb"))):
        print("cannot locate the Maestro view directory: %r" % view_dir)
        return 2
    scratch = os.path.join(workarea, "relkit_dev", "tmp", "rkaged")
    backup_dir = os.path.join(workarea, "relkit_dev", "backup")
    os.makedirs(backup_dir, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = os.path.join(backup_dir, "%s_%s_r1_%s.tgz" % (a.cell, a.view, stamp))

    # 1. backup (view now, results location as soon as the session tells us where it is)
    before = md5_manifest(view_dir)
    parent_st = os.stat(os.path.dirname(view_dir))
    # GNU tar: keeps modes + mtimes (python's tarfile extraction filter would not)
    subprocess.check_call(["tar", "-C", os.path.dirname(view_dir), "--format=posix", "-czpf", backup,
                           os.path.basename(view_dir)])
    print("backup: %s (%d entries)" % (backup, len(before)))
    resloc = None
    res_backup = None
    res_before = None
    res_parent_st = None
    retention = None
    lock = os.path.join(view_dir, "maestro.sdb.cdslck")
    if os.path.exists(lock) and lock_is_stale(lock):
        os.rename(lock, lock + ".r1_aside")
        print("stale edit lock moved aside (restored from the backup at the end)")

    ipc = os.path.join(persist_root, "_ipc")
    ipc_before = set(os.listdir(ipc)) if os.path.isdir(ipc) else set()
    run_dir = None
    hist = None
    restored = False
    try:
        # 2. Part A
        if os.path.isdir(scratch):
            shutil.rmtree(scratch)
        br.load(os.path.join(HERE, "rkAged_smoke.il"))
        print("Part A:", br.evs("(rkTestReport)"))
        # 3. open + ctx
        sess = br.evs("(rkAgedT_open %s %s %s %s)" % (q(a.lib), q(a.cell), q(a.view), q(a.test)))
        print("session:", sess)
        resloc = br.evs("(axlGetResultsLocation (axlGetMainSetupDB %s))" % q(sess))
        if resloc and os.path.isdir(resloc):
            # Maestro purges old histories (sim data included) beyond
            # adexl.simulation saveLastNHistoryEntries when a run starts or the
            # session closes: back the results location up too.
            res_before = md5_manifest(resloc)
            res_parent_st = os.stat(os.path.dirname(resloc))
            res_backup = backup.replace(".tgz", "_results.tgz")
            subprocess.check_call(["tar", "-C", os.path.dirname(resloc), "--format=posix", "-czpf", res_backup,
                                   os.path.basename(resloc)])
            print("results backup: %s (%d entries)" % (res_backup, len(res_before)))
        ctx = json.load(open(os.path.join(scratch, "ctx.json"), encoding="utf-8"))
        hinfo = json.load(open(os.path.join(scratch, "hist.json"), encoding="utf-8"))
        # 4. synthetic run record
        run_id = "%s_aging" % time.strftime("%Y%m%d-%H%M%S")
        run_dir = build_run(scratch, persist_root, ctx, a.corner, hinfo["netlist"], run_id)
        print("synthetic run record:", run_dir)
        # 5. corners
        names = br.ev("(rkAgedT_corners %s)" % q(run_dir))
        print("corners:", names, "| messages:", br.ev("(rkAgedMessages)"))
        names = re.findall(r'"([^"]+)"', names)
        include = br.evs("rkAgedT_include")
        # 5b. delta table on an existing history (explicit corner pair, read only)
        print("delta on an existing history:", br.ev("(rkAgedT_deltaExisting %s)" % q(run_dir)),
              "| messages:", br.ev("(rkAgedMessages)"))
        html = os.path.join(run_dir, "aux_report.html")
        check("aux report shows the existing-history delta",
              os.path.isfile(html) and "Fresh vs aged" in open(html, encoding="utf-8").read())
        for f in sorted(glob.glob(os.path.join(run_dir, "tables", "aged_delta_*.tsv"))):
            print("%s (first rows):" % os.path.basename(f))
            for l in open(f, encoding="utf-8").read().splitlines()[:6]:
                print("   ", l)
        if a.sim:
            # 6. one simulation (history retention raised so nothing old is purged)
            retention = br.ev('(envGetVal "adexl.simulation" "saveLastNHistoryEntries")')
            br.ev('(envSetVal "adexl.simulation" "saveLastNHistoryEntries" (quote int) 100000)')
            hist = br.evs("(rkAgedT_runSim)")
            print("simulation started: history", hist)
            t0 = time.time()
            while br.ev("rkAgedT_done") != "t":
                if time.time() - t0 > a.timeout:
                    check("simulation finished within %ds" % a.timeout, False)
                    break
                time.sleep(5)
            print("simulation finished after %.0fs" % (time.time() - t0))
            if a.keep and resloc:
                keepd = os.path.join(scratch, "history_copy")
                shutil.copytree(os.path.join(resloc, hist), os.path.join(keepd, hist), symlinks=True)
                for ext in (".rdb", ".log"):
                    src = os.path.join(view_dir, "results", a.view, hist + ext)
                    if os.path.isfile(src):
                        shutil.copy2(src, keepd)
                print("history copied to", keepd)
            check_netlists(resloc, hist, a.test, names, include, run_dir)
            # 7. delta table
            print("delta:", br.ev("(rkAgedT_delta %s)" % q(hist)), "| messages:", br.ev("(rkAgedMessages)"))
            rj = json.load(open(os.path.join(run_dir, "run.json"), encoding="utf-8"))
            hists = [e.get("history") for e in rj.get("aged_delta") or []]
            check("delta recorded in run.json", hist in hists, repr(rj.get("aged_delta")))
            html = os.path.join(run_dir, "aux_report.html")
            check("aux report shows the delta", os.path.isfile(html) and "Fresh vs aged" in open(html, encoding="utf-8").read())
            for f in sorted(glob.glob(os.path.join(run_dir, "tables", "aged_delta_*.tsv"))):
                print("%s (first rows):" % os.path.basename(f))
                for l in open(f, encoding="utf-8").read().splitlines()[:8]:
                    print("   ", l)
    finally:
        # 8. clean up + restore
        try:
            br.ev("(rkAgedT_close)")
        except Exception as e:  # noqa: BLE001
            print("close failed:", e)
        if retention is not None:
            br.ev('(envSetVal "adexl.simulation" "saveLastNHistoryEntries" (quote int) %s)' % retention)
            check("history retention setting restored",
                  br.ev('(envGetVal "adexl.simulation" "saveLastNHistoryEntries")') == retention)
        rep = br.evs("(rkTestReport)")
        print("SKILL:", rep)
        check("SKILL smoke (Part A + B)", ": PASS " in rep, rep)
        time.sleep(10)          # let Maestro finish any clean-up after the close
        shutil.rmtree(view_dir)
        subprocess.check_call(["tar", "-C", os.path.dirname(view_dir), "-xpzf", backup])
        os.utime(os.path.dirname(view_dir), (parent_st.st_atime, parent_st.st_mtime))
        if res_backup:
            if md5_manifest(resloc) != res_before:
                print("results location changed (new history data and/or purges): restoring it")
            shutil.rmtree(resloc)
            subprocess.check_call(["tar", "-C", os.path.dirname(resloc), "-xpzf", res_backup])
            os.utime(os.path.dirname(resloc), (res_parent_st.st_atime, res_parent_st.st_mtime))
        restored = True
        if not a.keep:
            if run_dir and os.path.isdir(run_dir):
                shutil.rmtree(run_dir)
                parent = os.path.dirname(run_dir)
                for _ in range(2):          # <persist_root>/<lib>/<cell> if now empty
                    if os.path.isdir(parent) and not os.listdir(parent):
                        os.rmdir(parent)
                    parent = os.path.dirname(parent)
            if os.path.isdir(scratch):
                shutil.rmtree(scratch)
            for f in sorted(set(os.listdir(ipc)) - ipc_before) if os.path.isdir(ipc) else []:
                if re.search(r"_aged-(include|delta)_out\.(json|log)$", f):
                    os.remove(os.path.join(ipc, f))
    time.sleep(5)               # and check again a little later (async Maestro clean-up)
    after = md5_manifest(view_dir)
    check("Maestro view restored identically", restored and after == before,
          "changed: %s" % sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k)))
    if res_before is not None:
        res_after = md5_manifest(resloc)
        check("results location restored identically", res_after == res_before,
              "changed: %s" % sorted(k for k in set(res_before) | set(res_after)
                                     if res_before.get(k) != res_after.get(k))[:20])
    n_fail = len([c for c in CHECKS if not c[1]])
    print("rkAged VM test: %s (%d checks, %d failed)" % ("PASS" if not n_fail else "FAIL", len(CHECKS), n_fail))
    return 0 if not n_fail else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
