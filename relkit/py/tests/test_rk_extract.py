"""Tests for rk_extract: template rendering (golden), the full chain with fake
tools, the LVS-fail branch, other failures, background start/cancel and
artifact detection. Synthetic names only (amp_core, mylib, /proj/...)."""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

PY_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PY_DIR)

import relkit  # noqa: E402
import rk_common  # noqa: E402
import rk_extract  # noqa: E402

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
FAKE_DIR = os.path.join(TESTS_DIR, "fake_tools")
GOLDEN_DIR = os.path.join(TESTS_DIR, "fixtures", "extract")

SITE_EXTRACT = {
    "layout_view": "layout",
    "pdk_layer_map": "/proj/pdk/example/layermap.txt",
    "calibre_lvs_dir": "/proj/pdk/example/calibre/lvs",
    "calibre_lvs_basename": "example_lvs.rul",
    "lvs_variant": "default",
    "qrc_query_cmd": "/proj/pdk/example/qrc/query_cmd",
    "qrc_preserve_cell_list": "/proj/pdk/example/qrc/preserveCellList.txt",
    "technology_library_file": "/proj/pdk/example/quantus/lib.defs",
    "technology_name": "example_tech",
    "technology_corner": "typical",
    "temperature": 25,
    "power_nets": ["VDD", "AVDD"],
    "ground_nets": ["VSS", "AVSS"],
}


def _fake_tools():
    return {t: [sys.executable, os.path.join(FAKE_DIR, t)]
            for t in ("strmout", "si", "calibre", "qrc")}


def make_ctx(workarea, site_path, settings=None):
    return {
        "schema": 1, "user": "jdoe", "workarea": workarea, "site_path": site_path,
        "relstudio_home": "/opt/relstudio",
        "maestro": {"lib": "mylib", "cell": "tb_top", "view": "maestro"},
        "dut": {"inst": "I0", "lib": "mylib", "cell": "amp_core", "view": "schematic"},
        "settings": {"extract": settings or {"layout_lib": None, "layout_view": None,
                                             "technology_corner": None, "temperature": None}},
    }


class RenderGoldenTest(unittest.TestCase):
    """The three rendered files for a fixed synthetic context."""

    def params(self):
        site = {"artifact_root": "/proj/wa/Reliability", "extract": dict(SITE_EXTRACT)}
        site["extract"]["tools"] = {}
        ctx = make_ctx("/proj/wa", None, {"technology_corner": "cworst", "temperature": 55})
        return rk_extract.resolve_params(ctx, site)

    def _golden(self, name, text):
        path = os.path.join(GOLDEN_DIR, name)
        if os.environ.get("RELKIT_REGEN_GOLDEN"):
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
        with open(path, "r", encoding="utf-8") as f:
            self.assertEqual(text, f.read(), "golden mismatch: %s" % name)

    def test_si_env(self):
        p = self.params()
        txt = rk_extract.render_template("si/si.env.tmpl", rk_extract.si_env_values(p))
        self._golden("si.env", txt)
        self.assertIn('simRunDir = "/proj/wa/Reliability/amp_core/extract/lvs"', txt)
        self.assertIn('hnlNetlistFileName = "amp_core.src.net"', txt)
        self.assertIn("simViewList = '(\"auCdl\" \"schematic\")", txt)
        self.assertIn("simReNetlistAll = nil\n", txt)
        self.assertNotIn("##", txt)

    def test_qci(self):
        p = self.params()
        txt = rk_extract.render_template("calibre/lvs.qci.tmpl", rk_extract.qci_values(p))
        self._golden("amp_core.qci", txt)
        self.assertIn("*lvsRulesFile: /proj/pdk/example/calibre/lvs/example_lvs.rul.default.qcilvs\n", txt)
        self.assertIn("*lvsPowerNames: VDD AVDD\n", txt)
        self.assertIn("-query_input /proj/pdk/example/qrc/query_cmd -query svdb", txt)
        self.assertNotIn("cmnVConnectNamesState", txt)
        self.assertTrue(txt.startswith("*lvsRulesFile:"))

    def test_dspf_cmd(self):
        p = self.params()
        txt = rk_extract.render_template("quantus/dspf.cmd.tmpl", rk_extract.qrc_values(p))
        self._golden("amp_core.dspf.cmd", txt)
        self.assertIn('-file_name "/proj/wa/Reliability/amp_core/extract/qrc/amp_core.dspf"', txt)
        self.assertIn('"cworst"', txt)
        self.assertIn("-temperature \\\n              55\n", txt)
        self.assertIn('-ground_net "VSS"', txt)
        self.assertIn('extract \\\n              -selection "all" \\\n              -type "rc_coupled"\n', txt)
        self.assertNotIn("parasitic_blocking_device_cells_type", txt)

    def test_options_and_conditionals(self):
        p = self.params()
        p["lvs_options"].update(connect_by_name=True, run_qrc_query=False)
        q = rk_extract.render_template("calibre/lvs.qci.tmpl", rk_extract.qci_values(p))
        self.assertIn("*cmnShowOptions: 1\n*cmnVConnectNamesState: ALL\n*cmnSpecifyLicenseWaitTime: 1", q)
        self.assertNotIn("-query_input", q)
        p["qrc_options"].update(
            extract_rules=[{"selection": "all", "type": "c_only_coupled"},
                           {"selection": "net", "selection_arg": "clk*", "type": "rc_coupled"}],
            parasitic_blocking_device_cells_type="soft", output_xy=[])
        d = rk_extract.render_template("quantus/dspf.cmd.tmpl", rk_extract.qrc_values(p))
        self.assertIn('-selection "net" "clk*"', d)
        self.assertLess(d.index('"c_only_coupled"'), d.index('"net" "clk*"'))
        self.assertIn('-parasitic_blocking_device_cells_type "soft" \\\n              -net_name_space', d)
        self.assertNotIn("-output_xy", d)
        p["qrc_options"]["extract_rules"] = [{"selection": "net", "type": "rc_coupled"}]
        with self.assertRaises(rk_common.RkError):
            rk_extract.qrc_values(p)

    def test_missing_settings(self):
        site = {"artifact_root": "/proj/wa/Reliability",
                "extract": {"pdk_layer_map": None, "temperature": 25}}
        with self.assertRaises(rk_common.RkError) as cm:
            rk_extract.resolve_params(make_ctx("/proj/wa", None), site)
        missing = cm.exception.fields["missing"]
        self.assertIn("extract.pdk_layer_map", missing)
        self.assertIn("extract.technology_corner", missing)
        with self.assertRaises(rk_common.RkError):
            ctx = make_ctx("/proj/wa", None)
            ctx["dut"] = None
            rk_extract.resolve_params(ctx, {"artifact_root": "/x", "extract": SITE_EXTRACT})

    def test_commands(self):
        p = self.params()
        c = rk_extract.build_commands(p)
        self.assertEqual(c["strmout"]["argv"],
                         ["strmout", "-library", "mylib", "-topCell", "amp_core", "-view", "layout",
                          "-strmFile", "/proj/wa/Reliability/amp_core/extract/lvs/amp_core.calibre.db",
                          "-layerMap", "/proj/pdk/example/layermap.txt"])
        self.assertEqual(c["si"]["argv"], ["si", "-batch", "-command", "netlist",
                                           "-cdslib", "/proj/wa/cds.lib"])
        self.assertEqual(c["si"]["cwd"], "/proj/wa/Reliability/amp_core/extract/si")
        self.assertEqual(c["lvs"]["argv"][-1], "-batch")
        self.assertEqual(c["lvs"]["cwd"], "/proj/wa")
        self.assertEqual(rk_extract.shell_join(rk_extract.calibre_gui_argv(p)),
                         "calibre -gui -lvs -runset /proj/wa/Reliability/amp_core/extract/amp_core.qci")


class LvsReportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rk_lvs_")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def parse(self, text):
        p = os.path.join(self.tmp, "r.lvs.report")
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
        return rk_extract.parse_lvs_report(p)

    def test_variants(self):
        self.assertTrue(self.parse("#  CORRECT  #\nDISCREPANCIES = 0\n")["passed"])
        r = self.parse("#  CORRECT  #\nDISCREPANCIES = 3\n")
        self.assertFalse(r["passed"])
        self.assertEqual(r["discrepancies"], 3)
        r = self.parse("#  CORRECT  #\n  CELL  SUMMARY\n  CORRECT  amp_core  amp_core\n")
        self.assertTrue(r["passed"])
        self.assertFalse(self.parse("#  CORRECT  #\n")["passed"])
        r = self.parse("#  INCORRECT  #\n CELL SUMMARY\n INCORRECT  amp_core  amp_core\n"
                       " CORRECT  sub1  sub1\n")
        self.assertFalse(r["passed"])
        self.assertEqual(r["banner"], "INCORRECT")
        self.assertEqual(r["incorrect_cells"], ["amp_core"])
        r = self.parse("nothing here\n")
        self.assertIsNotNone(r["error"])
        self.assertIsNotNone(rk_extract.parse_lvs_report(os.path.join(self.tmp, "no"))["error"])


class ChainTest(unittest.TestCase):
    """Full chain with the fake tools."""

    def setUp(self):
        self.tmp = rk_extract._posix(tempfile.mkdtemp(prefix="rk_ext_"))
        self.wa = self.tmp + "/wa"
        os.makedirs(self.wa)
        with open(self.wa + "/cds.lib", "w") as f:
            f.write("DEFINE mylib ./mylib\n")
        self.site_path = self.tmp + "/site.json"
        ext = dict(SITE_EXTRACT)
        ext["tools"] = _fake_tools()
        with open(self.site_path, "w", encoding="utf-8") as f:
            json.dump({"artifact_root": "${WORKAREA}/Reliability",
                       "persist_root": "${WORKAREA}/relkit_runs", "extract": ext}, f)
        self.cfg_path = self.tmp + "/fake_tools_config.json"
        self.set_cfg({})
        self._old_env = os.environ.get("RELKIT_FAKE_TOOLS_CONFIG")
        os.environ["RELKIT_FAKE_TOOLS_CONFIG"] = self.cfg_path
        self.ctx = make_ctx(self.wa, self.site_path)
        self.ctx_path = self.tmp + "/ctx.json"
        with open(self.ctx_path, "w", encoding="utf-8") as f:
            json.dump(self.ctx, f)
        self.adir = self.wa + "/Reliability/amp_core"
        self.xdir = self.adir + "/extract"

    def tearDown(self):
        if self._old_env is None:
            os.environ.pop("RELKIT_FAKE_TOOLS_CONFIG", None)
        else:
            os.environ["RELKIT_FAKE_TOOLS_CONFIG"] = self._old_env
        for _ in range(20):
            try:
                shutil.rmtree(self.tmp)
                break
            except OSError:
                time.sleep(0.25)

    def set_cfg(self, cfg):
        with open(self.cfg_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f)

    def calls(self):
        p = self.tmp + "/calls.log"
        if not os.path.isfile(p):
            return []
        with open(p, encoding="utf-8") as f:
            return [json.loads(x) for x in f if x.strip()]

    def run_sync(self):
        out = self.tmp + "/out.json"
        rc = relkit.main(["extract", "--ctx", self.ctx_path, "--out", out, "--sync"])
        return rc, rk_common.read_json(out)

    def status(self):
        out = self.tmp + "/st.json"
        rc = relkit.main(["extract-status", "--ctx", self.ctx_path, "--out", out])
        self.assertEqual(rc, 0)
        return rk_common.read_json(out)

    def test_full_chain(self):
        rc, out = self.run_sync()
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["state"], "done", out)
        st = self.status()
        self.assertEqual(st["state"], "done")
        self.assertTrue(st["final"])
        self.assertEqual([s["state"] for s in st["steps"]], ["done"] * 4)
        self.assertEqual(st["gds"], self.adir + "/amp_core.gds")
        self.assertEqual(st["dspf"], self.adir + "/amp_core.dspf")
        self.assertTrue(os.path.isfile(st["gds"]))
        with open(st["dspf"], encoding="utf-8") as f:
            self.assertIn("*|DSPF", f.read())
        self.assertFalse(os.path.exists(self.xdir + "/qrc/amp_core.dspf"))  # moved
        self.assertTrue(st["lvs"]["passed"])
        self.assertEqual(st["existing"]["gds"]["path"], st["gds"])
        self.assertEqual(st["existing"]["dspf"]["path"], st["dspf"])
        # every intermediate stays under extract/ (D17), never /tmp
        for k in ("qci", "dspf_cmd", "si_env", "layout_db", "src_net", "lvs_report"):
            self.assertTrue(st[k].startswith(self.xdir + "/"), k)
            self.assertTrue(os.path.isfile(st[k]), k)
        calls = self.calls()
        self.assertEqual([c["tool"] for c in calls], ["strmout", "si", "calibre", "qrc"])
        norm = lambda p: os.path.normcase(os.path.realpath(p))  # noqa: E731
        self.assertEqual(norm(calls[0]["cwd"]), norm(self.wa))
        self.assertEqual(norm(calls[1]["cwd"]), norm(self.xdir + "/si"))
        self.assertIn("-cdslib", calls[1]["argv"])
        self.assertEqual(calls[2]["argv"][-1], "-batch")
        self.assertTrue(os.path.isfile(self.xdir + "/logs/qrc.log"))
        with open(self.xdir + "/extract.log", encoding="utf-8") as f:
            self.assertIn("done:", f.read())
        # a second run re-runs cleanly (stale si .running is removed first)
        rc, out = self.run_sync()
        self.assertEqual(out["state"], "done", out)

    def test_lvs_fail_stops_and_offers_gui(self):
        self.set_cfg({"lvs": "fail"})
        rc, out = self.run_sync()
        self.assertEqual(rc, 0)
        self.assertEqual(out["state"], "lvs_failed")
        st = self.status()
        self.assertEqual(st["state"], "lvs_failed")
        self.assertEqual(st["step"], "lvs")
        self.assertEqual([s["state"] for s in st["steps"]], ["done", "done", "failed", "pending"])
        self.assertEqual(st["lvs_report"], self.xdir + "/lvs/amp_core.lvs.report")
        self.assertIn("INCORRECT", st["message"])
        self.assertIn(st["lvs_report"], st["message"])
        self.assertIsNone(st["dspf"])
        self.assertIsNone(st["gds"])
        self.assertIsNone(st["existing"]["dspf"])  # nothing published
        self.assertFalse(os.path.exists(self.adir + "/amp_core.gds"))
        self.assertNotIn("-batch", st["calibre_gui_cmd"])
        self.assertTrue(st["calibre_gui_cmd"].endswith("-gui -lvs -runset " + self.xdir + "/amp_core.qci"))
        self.assertEqual([c["tool"] for c in self.calls()], ["strmout", "si", "calibre"])
        # the GUI command really is runnable with the same runset
        argv = rk_extract.calibre_gui_argv(rk_common.read_json(self.xdir + "/request.json")["params"])
        r = subprocess.run(argv, cwd=st["calibre_gui_cwd"], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn(b"GUI mode", r.stdout)

    def test_step_failures(self):
        for step, n_calls in (("strmout", 1), ("si", 2), ("qrc", 4)):
            self.set_cfg({"fail_step": step})
            try:
                os.remove(self.tmp + "/calls.log")
            except OSError:
                pass
            rc, out = self.run_sync()
            self.assertEqual(out["state"], "failed", (step, out))
            st = self.status()
            self.assertEqual(st["step"], step)
            self.assertEqual(len(self.calls()), n_calls, step)
            self.assertTrue(any("failing on request" in x for x in st["log_tail"]), st["log_tail"])
            self.assertIsNone(st["dspf"])

    def test_lvs_no_banner(self):
        self.set_cfg({"lvs_no_banner": True})
        rc, out = self.run_sync()
        self.assertEqual(out["state"], "failed")
        self.assertIn("no LVS banner", self.status()["message"])

    def test_missing_tool(self):
        with open(self.site_path, encoding="utf-8") as f:
            site = json.load(f)
        site["extract"]["tools"]["strmout"] = self.tmp + "/no_such_strmout"
        with open(self.site_path, "w", encoding="utf-8") as f:
            json.dump(site, f)
        rc, out = self.run_sync()
        self.assertEqual(out["state"], "failed")
        self.assertIn("cannot start", self.status()["message"])

    def wait_final(self, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            st = self.status()
            if st["final"]:
                return st
            time.sleep(0.3)
        self.fail("extraction did not finish: %s" % st)

    def test_background_start(self):
        out = self.tmp + "/out.json"
        rc = relkit.main(["extract", "--ctx", self.ctx_path, "--out", out])
        d = rk_common.read_json(out)
        self.assertEqual(rc, 0, d)
        self.assertEqual(d["state"], "running")
        self.assertTrue(d["pid"])
        self.assertEqual(d["status_path"], self.xdir + "/status.json")
        st = self.wait_final()
        self.assertEqual(st["state"], "done", st)
        self.assertNotEqual(st["pid"], os.getpid())

    def test_cancel_and_refuse_second_start(self):
        self.set_cfg({"delay": 30})
        out = self.tmp + "/out.json"
        self.assertEqual(relkit.main(["extract", "--ctx", self.ctx_path, "--out", out]), 0)
        deadline = time.time() + 30
        while time.time() < deadline:
            st = self.status()
            if st.get("child_pid"):
                break
            time.sleep(0.2)
        self.assertEqual(st["state"], "running")
        self.assertEqual(st["step"], "strmout")
        # a second start is refused while the worker is alive
        rc = relkit.main(["extract", "--ctx", self.ctx_path, "--out", out])
        self.assertEqual(rc, 1)
        self.assertIn("already running", rk_common.read_json(out)["error"])
        t0 = time.time()
        rc = relkit.main(["extract-cancel", "--dir", self.xdir, "--out", out])
        self.assertEqual(rc, 0)
        self.assertEqual(rk_common.read_json(out)["state"], "cancelled")
        self.assertLess(time.time() - t0, 20)
        st = self.status()
        self.assertEqual(st["state"], "cancelled")
        self.assertEqual(st["steps"][0]["state"], "cancelled")

    def test_stale_worker_is_reported_failed(self):
        p = subprocess.Popen([sys.executable, "-c", "pass"])
        p.wait()
        os.makedirs(self.xdir)
        rk_extract.write_status(self.xdir, {
            "state": "running", "step": "lvs", "pid": p.pid, "host": socket.gethostname(),
            "steps": [{"name": "lvs", "state": "running", "log": None}],
            "started": rk_common.now_iso(), "heartbeat": rk_common.now_iso()})
        st = self.status()
        self.assertEqual(st["state"], "failed")
        self.assertIn("is gone", st["message"])

    def test_worker_finishing_during_status_is_not_marked_failed(self):
        # race: status.json read while running, the worker writes "done" and
        # exits before the liveness check -> the re-read must win
        os.makedirs(self.xdir)
        running = {"state": "running", "step": "qrc", "pid": 1, "host": "elsewhere",
                   "steps": [{"name": "qrc", "state": "running", "log": None}],
                   "started": rk_common.now_iso(), "heartbeat": rk_common.now_iso()}
        rk_extract.write_status(self.xdir, running)
        real = rk_extract.worker_alive

        def finishing(st):
            if st.get("state") == "running":
                rk_extract.write_status(self.xdir, dict(running, state="done", step=None))
                return False
            return real(st)
        rk_extract.worker_alive = finishing
        try:
            st = rk_extract.status_out(self.xdir)
        finally:
            rk_extract.worker_alive = real
        self.assertEqual(st["state"], "done", st)
        self.assertEqual(rk_extract.read_status(self.xdir)["state"], "done")

    def test_detect_existing(self):
        st = self.status()
        self.assertEqual(st["state"], "none")
        self.assertIsNone(st["existing"]["gds"])
        os.makedirs(self.adir)
        for name in ("amp_core.gds", "old_amp_core.gds", "amp_core.dspf", "x.spf", "notes.txt"):
            with open(self.adir + "/" + name, "w") as f:
                f.write("x")
        old = time.time() - 3600
        os.utime(self.adir + "/amp_core.dspf", (old, old))
        a = rk_extract.find_artifacts(self.adir, "amp_core")
        self.assertEqual(a["gds"]["path"], self.adir + "/amp_core.gds")
        self.assertEqual(a["dspf"]["path"], self.adir + "/amp_core.dspf")
        self.assertEqual(a["gds_candidates"][0]["path"], self.adir + "/amp_core.gds")
        self.assertEqual(len(a["gds_candidates"]), 2)
        self.assertEqual(sorted(os.path.basename(x["path"]) for x in a["dspf_candidates"]),
                         ["amp_core.dspf", "x.spf"])
        self.assertIn("older", a["warning"])
        st = self.status()
        self.assertEqual(st["existing"]["dspf"]["path"], self.adir + "/amp_core.dspf")
        os.remove(self.adir + "/amp_core.gds")
        self.assertIsNone(rk_extract.find_artifacts(self.adir, "amp_core")["gds"])
        self.assertIsNone(rk_extract.find_artifacts(self.tmp + "/nope", "amp_core")["gds"])

    def test_panel_overrides(self):
        self.ctx["settings"]["extract"] = {"technology_corner": "cbest", "temperature": -40,
                                           "layout_view": "layout_alt", "layout_lib": "otherlib"}
        with open(self.ctx_path, "w", encoding="utf-8") as f:
            json.dump(self.ctx, f)
        rc, out = self.run_sync()
        self.assertEqual(out["state"], "done", out)
        with open(out["dspf_cmd"], encoding="utf-8") as f:
            txt = f.read()
        self.assertIn('"cbest"', txt)
        self.assertIn("              -40\n", txt)
        strm = self.calls()[0]["argv"]
        self.assertEqual(strm[strm.index("-view") + 1], "layout_alt")
        self.assertEqual(strm[strm.index("-library") + 1], "otherlib")


if __name__ == "__main__":
    unittest.main()
