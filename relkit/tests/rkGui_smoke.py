#!/usr/bin/env python3
"""Drive tests/rkGui_smoke.il (relkit panel + IPC) in the live Virtuoso.

    python3 relkit/tests/rkGui_smoke.py [--keep] [--no-display] [--bridge ID]

Run on the dev VM after `bash relkit/tools/sync_vm.sh`. Needs skillbridge
(found like run_skill_test.py does) and the VM dev site
<workarea>/.relkit_site.json (fake RelStudio + fake extraction tools).

The panel is built headless; asynchronous steps (subprocesses, pollers) need
Virtuoso's event loop, which runs between bridge calls, so this driver calls
one phase function at a time and waits with one-line probes in between.

Scratch: <workarea>/relkit_dev/tmp/gui_smoke/ (own site file with fast
polling, own work/persist/artifact roots); removed at the end unless --keep.
The Maestro view is opened read-only; the per-cell settings directory the
panel writes (<lib>/Test/relkit/) is removed again if it did not exist before.
--bridge ID: skillbridge server id (default "default", or $SB_ID). Running it
against a dedicated Virtuoso keeps a shared one out of harm's way: its .cdsinit
loads skillbridge/python_server.il and calls pyStartServer(?id ID) -- guarded
like skillbridge/sbStart.il, because the Maestro session the test opens starts
an axl worker Virtuoso that runs the same .cdsinit and would take the socket.
Prints rkTestReport(); exit 0 only on PASS.
"""
import hashlib
import json
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RELKIT = os.path.dirname(HERE)
SKILL_TOOLS = os.path.dirname(RELKIT)
WORKAREA = os.environ.get("RELKIT_WORKAREA") or os.path.dirname(SKILL_TOOLS)

for p in (os.environ.get("SKILLBRIDGE_PATH"), os.path.join(SKILL_TOOLS, "skillbridge")):
    if p and os.path.isdir(p) and p not in sys.path:
        sys.path.insert(0, p)

from skillbridge import Workspace  # noqa: E402

LIB, CELL = "sim_yusheng", "Test"


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Bridge(object):
    def __init__(self, ident=None):
        self.ws = Workspace.open(ident) if ident else Workspace.open()

    def ev(self, expr):
        """Evaluate one line of SKILL; returns the %L text of the value
        ("ERR: ..." when it raised). Clears errset.errset (CONTRACT 8)."""
        s = ('(let ((rkE (errset %s t)) rkR) (setq rkR (if rkE (sprintf nil "%%L" (car rkE)) '
             '(sprintf nil "ERR: %%L" errset.errset))) (putprop (quote errset) nil (quote errset)) rkR)'
             % expr)
        return self.ws["evalstring"](s)

    def load(self, path):
        r = self.ev("(load %s)" % q(path))
        if r != "t":
            raise RuntimeError("load %s failed: %s" % (path, r))

    def check(self, label, ok):
        self.ev("(rkCheck %s %s)" % (q(label), "t" if ok else "nil"))

    def wait(self, expr, label, timeout=120.0, every=1.0, watch=None):
        """Wait until expr evaluates to non-nil. watch(bridge) runs every tick."""
        t0 = time.time()
        last = None
        while time.time() - t0 < timeout:
            last = self.ev(expr)
            if watch:
                watch(self)
            if last not in ("nil", None) and not last.startswith("ERR"):
                return last
            time.sleep(every)
        self.check("%s (timed out after %ds; last %s)" % (label, timeout, last), False)
        return None


def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def write_json(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)


def prepare(scratch):
    if os.path.isdir(scratch):
        shutil.rmtree(scratch)
    os.makedirs(os.path.join(scratch, "wa"))
    with open(os.path.join(WORKAREA, ".relkit_site.json"), encoding="utf-8") as f:
        site = json.load(f)
    fake = os.path.join(RELKIT, "py", "tests")
    site.update({
        # the fakes of THIS relkit tree (the dev site may point at another copy)
        "relstudio_home": os.path.join(fake, "fake_relstudio"),
        "donau_profiles": {"std": {"Queue": "short", "CPU": 8},
                           "emir": {"Queue": "long", "CPU": 16, "Memory": 64000}},
        "donau_default": {"aging": "std", "deos": "std", "emir": "emir"},
        "work_root": os.path.join(scratch, "work"),
        "persist_root": os.path.join(scratch, "runs"),
        "artifact_root": os.path.join(scratch, "Reliability"),
        "supervise_poll_seconds": 1,
        "start_wait_minutes": 1,
        "dry_run": False,
    })
    site.setdefault("emir", {})["license_retry_minutes"] = 0.05
    ex = site.setdefault("extract", {})
    for k in ("pdk_layer_map", "calibre_lvs_dir", "calibre_lvs_basename", "lvs_variant",
              "technology_library_file", "technology_name", "qrc_query_cmd",
              "qrc_preserve_cell_list", "power_nets", "ground_nets", "layer_map",
              "lvs_deck_dir", "qrc_deck_dir", "tech_name"):
        ex.pop(k, None)          # the env rules of site_defaults.json apply
    ex["tools"] = {t: os.path.join(fake, "fake_tools", t) for t in ("strmout", "si", "calibre", "qrc")}
    ex["power_names"] = ["VDD"]
    ex["ground_names"] = ["VSS"]
    # a synthetic PDK tree; its variables go to pdk_env.txt (used unless the
    # Virtuoso under test already has them in its own environment)
    sys.path.insert(0, os.path.join(RELKIT, "py", "tests"))
    import fake_pdk
    env = fake_pdk.make_fake_pdk(os.path.join(scratch, "fakepdk"))
    with open(os.path.join(scratch, "pdk_env.txt"), "w", encoding="utf-8") as f:
        for k, v in env.items():
            f.write("%s=%s\n" % (k, v))
    # synthetic Maestro job policies, found through site job_policy_dirs (the
    # owner's real .cadence/jobpolicy dirs are never written)
    jp = os.path.join(scratch, "jobpolicy")
    os.makedirs(jp)
    with open(os.path.join(jp, "relkit_demo_short.jp"), "w", encoding="utf-8") as f:
        f.write('distributionmethod=Command\n'
                'jobsubmitcommand=dsub -A grp_demo.cls -q short -R "cpu=4;mem=8000"\n'
                'maxjobs=20\nname=relkit_demo_short\n')
    with open(os.path.join(jp, "relkit_demo_local.jp"), "w", encoding="utf-8") as f:
        f.write('distributionmethod=Local\nmaxjobs=1\nname=relkit_demo_local\n')
    site["job_policy_dirs"] = [jp]
    site.setdefault("gui", {})["status_poll_seconds"] = 2
    write_json(os.path.join(scratch, "wa", ".relkit_site.json"), site)
    write_json(os.path.join(scratch, "fake_rs.json"), {
        "mode": "license_fail", "license_fail_times": 2, "job_seconds": 1,
        "deos_violation": True,
        "instances": ["I7.PIN5", "I7.PIN1", "I7.MP0", "I7.MN0"]})
    write_json(os.path.join(scratch, "fake_tools.json"), {"lvs": "fail"})


def main(argv):
    keep = "--keep" in argv
    display = "--no-display" not in argv
    ident = os.environ.get("SB_ID")
    if "--bridge" in argv:
        ident = argv[argv.index("--bridge") + 1]
    scratch = os.path.join(WORKAREA, "relkit_dev", "tmp", "gui_smoke")
    libdir = os.path.join(WORKAREA, LIB)
    settings_dir = os.path.join(libdir, CELL, "relkit")
    had_settings = os.path.isdir(settings_dir)
    mae = os.path.join(libdir, CELL, "maestro")
    before = {f: md5(os.path.join(mae, f)) for f in ("maestro.sdb", "active.state", "data.dm")}
    jp_dirs = [os.path.join(WORKAREA, ".cadence", "jobpolicy"),
               os.path.expanduser("~/.cadence/jobpolicy")]
    jp_before = {d: sorted(os.listdir(d)) if os.path.isdir(d) else None for d in jp_dirs}
    prepare(scratch)

    b = Bridge(ident)
    b.load(os.path.join(RELKIT, "relkit.il"))
    b.load(os.path.join(HERE, "rk_testlib.il"))
    b.load(os.path.join(HERE, "rkGui_smoke.il"))
    try:
        r = b.ev("(rkGuiT_setup %s)" % q(scratch))
        print("setup:", r)
        b.check("setup ran (%s)" % r, r == "t")

        # --- Donau: Maestro job policies (async `relkit.py donau`)
        b.wait("rk_guiDonauRes", "Maestro job policies (donau)", 60)
        print("donau:", b.ev("rkGuiT_jpOrig"), "| attached:", b.ev("rkGuiT_jpAttached"))
        b.ev("(rkGuiT_checkDonau)")

        # --- extract-resolve: env missing, then complete
        b.ev("(rkGuiT_resolveMissing)")
        b.wait("rk_guiResolve", "resolve (env missing)", 60)
        print("resolve 1:", b.ev("(rkGuiGet 'rk_geXStatus)"))
        b.ev("(rkGuiT_checkMissing)")
        b.ev("(rkGuiT_resolveFull)")
        b.wait("rk_guiResolve", "resolve (env complete)", 60)
        print("resolve 2:", b.ev("(rkGuiGet 'rk_geXStatus)"))
        b.ev("(rkGuiT_checkReady)")
        b.wait("rk_guiFresh", "extract-check (auto DSPF/GDS state)", 60)
        print("auto:", b.ev("(rkGuiGet 'rk_geAuto)"))
        b.ev("(rkGuiT_checkAutoState)")

        # --- extraction: LVS fails first
        b.ev("(rkGuiT_extract)")
        st = b.wait('(member (rkGuiT_extractState) (list "lvs_failed" "failed" "done" "cancelled" "not_started"))',
                    "extract finishes (lvs fail)", 90)
        print("extract 1:", b.ev("(rkGuiT_extractState)"), b.ev("(rkGuiGet 'rk_geXStatus)"))
        if st:
            b.ev("(rkGuiT_checkLvsFail)")
        # then passes
        write_json(os.path.join(scratch, "fake_tools.json"), {"lvs": "pass"})
        b.ev("(rkGuiT_extract)")
        b.wait('(member (rkGuiT_extractState) (list "lvs_failed" "failed" "done" "cancelled" "not_started"))',
               "extract finishes (pass)", 90)
        print("extract 2:", b.ev("(rkGuiT_extractState)"), b.ev("(rkGuiGet 'rk_geXStatus)"))
        b.ev("(rkGuiT_checkExtractDone)")
        b.wait('(pcreMatchp "dspf$" (rkGuiGet (quote rk_geDspf)))', "detect existing", 60)
        b.ev("(rkGuiT_checkDetect)")
        b.wait('(pcreMatchp "supplies filled|failed" (rkGuiGet (quote rk_geStatus)))', "emir-inputs", 60)
        print("supplies:", b.ev("(rkGuiGet 'rk_geStatus)"), b.ev("(rkGuiGet 'rk_gePower)"),
              b.ev("(rkGuiGet 'rk_geGround)"))
        b.ev("(rkGuiT_checkSupplies)")

        # --- submit all three, follow to the end
        print("submit:", b.ev("(rkGuiT_submit)"))
        seen = {"license": False}

        def watch(br):
            s = br.ev("(rkGuiGet 'rk_geStatus)") or ""
            if "waiting for a Totem license" in s:
                if not seen["license"]:
                    print("  EMIR status:", s)
                seen["license"] = True
        b.wait("(rkGuiT_allFinal)", "all three runs final", 600, 2.0, watch)
        print("states:", b.ev("(rkGuiT_states)"))
        for ty in ("aging", "deos", "emir"):
            print("  %s:" % ty, b.ev("(rkGuiGet '%s)" % {"aging": "rk_gaStatus", "deos": "rk_gdStatus",
                                                           "emir": "rk_geStatus"}[ty]))
        b.check("EMIR status line showed 'waiting for a Totem license (retry N)'", seen["license"])
        b.ev("(rkGuiT_checkRuns)")
        b.ev("(rkGuiT_drill)")

        # --- progress window (context menu on the Runs page + page button)
        b.ev("(rkGuiT_runsRefresh)")
        b.wait("rk_guiRunsRows", "runs list (progress)", 60)
        b.ev("(rkGuiT_progress)")
        b.wait("rk_guiProgRes", "progress rows", 60)
        print("progress:", b.ev("(rkGuiT_progSummary)"))
        b.ev("(rkGuiT_checkProgress)")

        # --- EMIR auto-extract with LVS failing -> lvs_failed
        write_json(os.path.join(scratch, "fake_tools.json"), {"lvs": "fail"})
        print("emir lvs-fail submit:", b.ev("(rkGuiT_emirLvsFail)"))
        b.wait('(rk_guiIsFinal (rkGuiT_state "emir"))', "EMIR auto-extract LVS-fail run final", 180, 2.0)
        print("  emir:", b.ev("(rkGuiGet 'rk_geStatus)"), "|", b.ev("(rkGuiGet 'rk_geXStatus)"))
        b.ev("(rkGuiT_checkEmirLvsFail)")
        write_json(os.path.join(scratch, "fake_tools.json"), {"lvs": "pass"})

        # --- Runs page
        b.ev("(rkGuiT_runsRefresh)")
        b.wait("rk_guiRunsRows", "runs list", 60)
        b.ev("(rkGuiT_checkRunsList)")
        b.ev("(rkGuiT_runsActions)")
        b.wait('(pcreMatchp "^compare " (rkGuiGet (quote rk_grStatus)))', "compare", 60)
        print("compare:", b.ev("(rkGuiGet 'rk_grStatus)"))
        b.wait('(equal (rkGet (nth (rkGuiT_runsIdx (car (rkGuiT_ids))) rk_guiRunsRows) "note") "smoke note")',
               "note listed", 60)
        b.ev("(rkGuiT_checkNote)")
        b.ev("(rkGuiT_rerun)")
        b.wait('(pcreMatchp "^panel filled|rerun settings failed" rk_guiMsg)', "rerun fill", 60)
        print("rerun:", b.ev("rk_guiMsg"))
        b.ev("(rkGuiT_checkRerun)")
        b.ev("(rkGuiT_aged)")
        b.wait('(pcreMatchp "aged corner|corner\\\\(s\\\\) in Maestro|failed|not available" (rkGuiGet (quote rk_gaStatus)))',
               "R1 button", 60)
        print("R1:", b.ev("(rkGuiGet 'rk_gaStatus)"))
        b.ev("(rkGuiT_checkAged)")
        b.ev("(rkGuiT_agedKeepFalse)")

        # --- reopen (resume) before deleting, so every page has its last run
        b.ev("(rkGuiT_reopen)")
        b.wait('(and (get (rkGuiField (quote rk_gdRes)) (quote choices)) (pcreMatchp "^last run" (rkGuiGet (quote rk_geStatus))))',
               "resume loads the last results", 60)
        b.ev("(rkGuiT_checkResume)")
        b.ev("(rkGuiT_runsRefresh)")
        b.wait("rk_guiRunsRows", "runs list (2)", 60)
        b.ev("(rkGuiT_delete)")
        b.wait('(pcreMatchp "deleted record|delete failed" (rkGuiGet (quote rk_grStatus)))', "delete", 60)
        b.wait("(null (rkGuiT_runsIdx (car (rkGuiT_ids))))", "deleted run leaves the list", 60)
        b.ev("(rkGuiT_checkDeleted)")

        # --- the real window: displayed from a timer, then closed
        if display:
            b.ev("(rkGuiT_displayLater)")
            b.wait("rkGuiT_shown", "panel displayed", 30)
            b.ev("(rkGuiT_closeShown)")
            b.ev("(rkGuiT_closedNoPollers)")
    finally:
        b.ev("(rkGuiT_cleanup)")
        rep = b.ev("(rkTestReport)")
    after = {f: md5(os.path.join(mae, f)) for f in before}
    jp_after = {d: sorted(os.listdir(d)) if os.path.isdir(d) else None for d in jp_dirs}
    b.check("real .cadence/jobpolicy dirs untouched (%s)" % jp_after, jp_before == jp_after)
    if not had_settings and os.path.isdir(settings_dir):
        shutil.rmtree(settings_dir)
    ok_mae = before == after and jp_before == jp_after and (had_settings or not os.path.isdir(settings_dir))
    if not keep:
        shutil.rmtree(scratch, ignore_errors=True)
    print(rep)
    print("maestro view unchanged: %s; settings dir restored: %s" % (before == after,
                                                                     not os.path.isdir(settings_dir) or had_settings))
    return 0 if (": PASS " in rep and ok_mae) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
