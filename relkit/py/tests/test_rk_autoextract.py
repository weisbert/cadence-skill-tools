"""EMIR auto-extract: freshness of <artifact_root>/<DUT>/<DUT>.gds/.dspf (missing /
stale / fresh / running / unresolved), cds.lib parsing, the chain extraction ->
EMIR inside one detached supervisor (LVS fail -> lvs_failed, cancel while
extracting), and the `progress` rows (extract steps, simN jobs, cluster job
ids). Fake RelStudio + fake extraction tools; synthetic names only."""

import json
import os
import shutil
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rkt_helpers as H  # noqa: E402
import rk_common  # noqa: E402
import rk_extract  # noqa: E402
import rk_site  # noqa: E402
import rk_submit  # noqa: E402
import relkit  # noqa: E402

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
FAKE_TOOLS = os.path.join(TESTS_DIR, "fake_tools")
HAVE_SH = os.path.exists("/bin/sh") or bool(shutil.which("sh"))

SITE_EXTRACT = {
    "layout_view": "layout", "check_files": False,
    "layer_map": "/proj/pdk/example/layermap.txt",
    "lvs_deck_dir": "/proj/pdk/example/calibre/lvs", "lvs_basename": "example_lvs.rul",
    "lvs_variant": "default", "qrc_deck_dir": "/proj/pdk/example/qrc",
    "cdl_include_file": "", "technology_library_file": "/proj/pdk/example/quantus/lib.defs",
    "tech_name": "example_tech", "temperature": 25,
    "power_names": ["VDD"], "ground_names": ["VSS"],
}


def fake_tools():
    return {t: [sys.executable, os.path.join(FAKE_TOOLS, t)]
            for t in ("strmout", "si", "calibre", "qrc")}


class CdslibTest(unittest.TestCase):
    def setUp(self):
        self.tmp = H.tmpdir("rk_cds_")

    def tearDown(self):
        H.rmtree(self.tmp)

    def test_parse(self):
        os.makedirs(os.path.join(self.tmp, "sub"))
        with open(os.path.join(self.tmp, "sub", "more.lib"), "w") as f:
            f.write("DEFINE inclib ../libs/inclib\nDEFINE mylib /elsewhere/mylib\n")
        with open(os.path.join(self.tmp, "cds.lib"), "w") as f:
            f.write("# comment line\n"
                    "DEFINE mylib ./libs/mylib   -- trailing comment\n"
                    "SOFTDEFINE soft $RKT_LIBROOT/soft\n"
                    "DEFINE gone /x/gone\nUNDEFINE gone\n"
                    "INCLUDE sub/more.lib\n"
                    "SOFTINCLUDE /no/such/file.lib\n")
        libs = rk_extract.cdslib_libs(os.path.join(self.tmp, "cds.lib"),
                                      {"RKT_LIBROOT": "/root"})
        self.assertEqual(libs["mylib"], H.p(os.path.normpath(os.path.join(self.tmp, "libs", "mylib"))))
        self.assertEqual(libs["inclib"], H.p(os.path.normpath(os.path.join(self.tmp, "libs", "inclib"))))
        self.assertEqual(libs["soft"], H.p(os.path.normpath("/root/soft")))
        self.assertNotIn("gone", libs)


class AutoBase(unittest.TestCase):
    """Workarea with cds.lib + layout/schematic cellviews of amp_core, a site
    whose extraction parameters are pinned literals and whose tools are the
    fake ones, the fake RelStudio, and synthetic (unrecorded) DSPF/GDS."""

    def setUp(self):
        self.tmp = H.tmpdir("rk_auto_")
        ext = dict(SITE_EXTRACT, tools=fake_tools())
        self.wa, self.sp, self.net = H.make_workarea(self.tmp, site_over={"extract": ext})
        lib = os.path.join(self.wa, "libs", "mylib", "amp_core")
        for view, name in (("layout", "layout.oa"), ("schematic", "sch.oa")):
            os.makedirs(os.path.join(lib, view))
            with open(os.path.join(lib, view, name), "w") as f:
                f.write("synthetic %s v1\n" % view)
        with open(os.path.join(self.wa, "cds.lib"), "w") as f:
            f.write("DEFINE mylib ./libs/mylib\n")
        self.layout_oa = os.path.join(lib, "layout", "layout.oa")
        self.old = {k: os.environ.get(k) for k in ("RELKIT_FAKE_RS_CONFIG",
                                                   "RELKIT_FAKE_TOOLS_CONFIG")}
        self.set_fake({"job_seconds": 0.3})
        self.set_tools({"lvs": "pass"})

    def tearDown(self):
        for k, v in self.old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        time.sleep(0.3)
        H.rmtree(self.tmp)

    def set_fake(self, cfg):
        os.environ["RELKIT_FAKE_RS_CONFIG"] = H.write_json(os.path.join(self.tmp, "fake_rs.json"), cfg)

    def set_tools(self, cfg):
        os.environ["RELKIT_FAKE_TOOLS_CONFIG"] = H.write_json(
            os.path.join(self.tmp, "fake_tools.json"), cfg)

    def set_site(self, **over):
        site = H.read_json(self.sp)
        for k, v in over.items():
            if isinstance(v, dict) and isinstance(site.get(k), dict):
                site[k].update(v)
            else:
                site[k] = v
        H.write_json(self.sp, site)

    def ctx(self, auto=True, extract=None, run_type="emir"):
        c = H.make_ctx(self.wa, self.sp, self.net, run_type)
        c["settings"]["emir"]["auto_extract"] = auto
        c["settings"]["extract"] = dict({"technology_corner": "typical", "temperature": 25},
                                        **(extract or {}))
        return c

    def cli(self, *argv):
        out = os.path.join(self.tmp, "out_%d.json" % int(time.time() * 1e6))
        rc = relkit.main(list(argv) + ["--out", out])
        d = H.read_json(out)
        self.assertEqual(rc == 0, d["ok"])
        return d

    def cli_ctx(self, cmd, ctx, *extra):
        cp = H.write_json(os.path.join(self.tmp, "ctx_%d.json" % int(time.time() * 1e6)), ctx)
        return self.cli(cmd, "--ctx", cp, *extra)

    def wait(self, run_dir, timeout=120, until=None):
        end = time.time() + timeout
        seen = []
        d = None
        while time.time() < end:
            d = self.cli("status", "--run", run_dir)
            if not seen or seen[-1] != d["state"]:
                seen.append(d["state"])
            if (until and d["state"] == until) or (until is None and d["final"]):
                return d, seen
            time.sleep(0.2)
        self.fail("run did not finish in %ss; states %s; last %s" % (timeout, seen, d))

    def calls(self):
        p = os.path.join(self.tmp, "calls.log")
        if not os.path.isfile(p):
            return []
        with open(p, encoding="utf-8") as f:
            return [json.loads(l)["tool"] for l in f if l.strip()]


class FreshnessTest(AutoBase):
    def test_states(self):
        site, _p, _w = rk_site.site_from_ctx(self.ctx())
        # synthetic pair without a relkit record -> stale
        fr = rk_extract.freshness(self.ctx(), site)
        self.assertEqual(fr["state"], "stale", fr)
        self.assertIn("no relkit extraction record", fr["reasons"][0])
        # no files -> missing
        os.remove(fr["dspf"])
        fr = rk_extract.freshness(self.ctx(), site)
        self.assertEqual(fr["state"], "missing")
        # extract (sync) -> manifest -> fresh
        d = self.cli_ctx("extract", self.ctx(), "--sync")
        self.assertEqual(d["state"], "done", d)
        man = H.read_json(fr["manifest"])
        self.assertEqual(man["layout"]["file"], "layout.oa")
        self.assertEqual(man["schematic"]["file"], "sch.oa")
        self.assertTrue(man["layout"]["md5"])
        d = self.cli_ctx("extract-check", self.ctx())
        self.assertEqual(d["state"], "fresh", d)
        self.assertEqual(d["reasons"], [])
        # a settings change -> stale, named
        d = self.cli_ctx("extract-check", self.ctx(extract={"technology_corner": "cworst"}))
        self.assertEqual(d["state"], "stale")
        self.assertTrue(any("technology_corner" in r for r in d["reasons"]), d["reasons"])
        # touching without a content change keeps it fresh (md5)
        t = time.time() + 5
        os.utime(self.layout_oa, (t, t))
        self.assertEqual(self.cli_ctx("extract-check", self.ctx())["state"], "fresh")
        # a layout edit -> stale
        with open(self.layout_oa, "a") as f:
            f.write("edit\n")
        d = self.cli_ctx("extract-check", self.ctx())
        self.assertEqual(d["state"], "stale")
        self.assertTrue(any(r.startswith("layout changed") for r in d["reasons"]), d["reasons"])
        # the panel's view dirs take precedence over cds.lib
        ctx = self.ctx(extract={"layout_dir": os.path.join(self.tmp, "nowhere")})
        d = self.cli_ctx("extract-check", ctx)
        self.assertTrue(any("layout view not found" in r for r in d["reasons"]), d["reasons"])

    def test_replaced_file_and_running_and_unresolved(self):
        site, _p, _w = rk_site.site_from_ctx(self.ctx())
        self.cli_ctx("extract", self.ctx(), "--sync")
        fr = rk_extract.freshness(self.ctx(), site)
        self.assertEqual(fr["state"], "fresh")
        with open(fr["dspf"], "a") as f:
            f.write("* hand edit\n")
        fr = rk_extract.freshness(self.ctx(), site)
        self.assertTrue(any("replaced" in r for r in fr["reasons"]), fr)
        # a live worker -> running (refused by submit)
        st = rk_extract.read_status(fr["extract_dir"])
        st.update(state="running", pid=os.getpid(), host=__import__("socket").gethostname())
        rk_extract.write_status(fr["extract_dir"], st)
        self.assertEqual(rk_extract.freshness(self.ctx(), site)["state"], "running")
        d = self.cli_ctx("submit", self.ctx())
        self.assertFalse(d["ok"])
        self.assertIn("running", d["error"])
        st["state"] = "done"
        rk_extract.write_status(fr["extract_dir"], st)
        # unresolved environment -> submit refuses, names the variable
        self.set_site(extract={"layer_map": "$RKT_NO_SUCH_LAYERMAP"})
        d = self.cli_ctx("submit", self.ctx())
        self.assertFalse(d["ok"])
        self.assertIn("RKT_NO_SUCH_LAYERMAP", d["missing_env"])
        self.assertIn("Use my own DSPF/GDS files", d["error"])


class ChainTest(AutoBase):
    def test_extract_then_emir_then_fresh(self):
        sub = self.cli_ctx("submit", self.ctx())
        self.assertTrue(sub["ok"], sub)
        self.assertEqual(sub["state"], "extracting")
        self.assertEqual(sub["extract"]["check"], "stale")
        st, seen = self.wait(sub["run_dir"])
        self.assertEqual(st["state"], "done", seen)
        self.assertEqual(seen[0], "extracting")
        run = H.read_json(os.path.join(sub["run_dir"], "run.json"))
        tl = [t["state"] for t in run["timeline"]]
        self.assertLess(tl.index("extracting"), tl.index("submitting"))
        self.assertEqual(run["extract"]["state"], "done")
        self.assertEqual([s["state"] for s in run["extract"]["steps"]], ["done"] * 4)
        self.assertTrue(any("strmout:running" in t["msg"] or "strmout:done" in t["msg"]
                            for t in run["timeline"] if t["state"] == "extracting"))
        files = H.read_json(os.path.join(sub["run_dir"], "input", "files.json"))
        self.assertTrue(files["dspf"]["exists"] and files["dspf"]["sha1"])
        self.assertTrue(os.path.isfile(run["extract"]["dspf"].replace(".dspf", ".extract.json")))
        pr = self.cli("progress", "--run", sub["run_dir"])
        ex = [r for r in pr["rows"] if r["stage"] == "extract"]
        jobs = [r for r in pr["rows"] if r["stage"] == "job"]
        self.assertEqual([r["name"] for r in ex], ["strmout", "si", "lvs", "qrc"])
        self.assertTrue(all(r["state"] == "done" and r["elapsed"] for r in ex), ex)
        self.assertEqual(len(jobs), 2)
        self.assertTrue(all(r["state"] == "done" for r in jobs), jobs)
        self.assertTrue(all(r["corner"] for r in jobs), jobs)
        n_calls = len(self.calls())
        self.assertEqual(n_calls, 4)
        # second EMIR: the pair is fresh -> no extraction
        sub2 = self.cli_ctx("submit", self.ctx())
        self.assertEqual(sub2["state"], "submitting", sub2)
        self.assertEqual(sub2["extract"]["check"], "fresh")
        st2, seen2 = self.wait(sub2["run_dir"])
        self.assertEqual(st2["state"], "done", seen2)
        self.assertNotIn("extracting", seen2)
        self.assertEqual(len(self.calls()), n_calls)
        pr2 = self.cli("progress", "--run", sub2["run_dir"])
        self.assertEqual(pr2["rows"][0]["state"], "fresh")

    def test_lvs_fail(self):
        self.set_tools({"lvs": "fail"})
        sub = self.cli_ctx("submit", self.ctx())
        st, seen = self.wait(sub["run_dir"])
        self.assertEqual(st["state"], "lvs_failed", seen)
        self.assertTrue(st["final"])
        self.assertTrue(st["extract"]["lvs_report"].endswith(".lvs.report"))
        self.assertIn("-runset", st["extract"]["calibre_gui_cmd"])
        self.assertNotIn("-batch", st["extract"]["calibre_gui_cmd"])
        run = H.read_json(os.path.join(sub["run_dir"], "run.json"))
        self.assertFalse(os.path.isfile(os.path.join(run["type_dir"], "mapping.txt")))  # EMIR never ran
        d = self.cli("runs", "delete", "--run", sub["run_dir"])   # final: deletable
        self.assertTrue(d["ok"], d)

    def test_cancel_while_extracting(self):
        self.set_tools({"lvs": "pass", "delay": 30})
        sub = self.cli_ctx("submit", self.ctx())
        self.wait(sub["run_dir"], until="extracting")
        d = self.cli("cancel", "--run", sub["run_dir"])
        self.assertEqual(d["state"], "cancelled", d)
        xst = rk_extract.read_status(sub["extract"]["dir"])
        self.assertEqual(xst["state"], "cancelled")

    def test_own_files_skip_extraction(self):
        sub = self.cli_ctx("submit", self.ctx(auto=False))
        self.assertEqual(sub["extract"], {"mode": "own"})
        st, seen = self.wait(sub["run_dir"])
        self.assertEqual(st["state"], "done", seen)
        self.assertEqual(self.calls(), [])


class ProgressTest(AutoBase):
    def test_running_rows(self):
        self.set_site(supervise_poll_seconds=0.2)
        self.set_fake({"job_seconds": 4})
        sub = self.cli_ctx("submit", self.ctx(auto=False, run_type="deos"), )
        self.wait(sub["run_dir"], until="running")
        time.sleep(0.6)
        pr = self.cli("progress", "--run", sub["run_dir"])
        jobs = [r for r in pr["rows"] if r["stage"] == "job"]
        self.assertEqual(len(jobs), 2)
        self.assertTrue(any(r["state"] == "running" for r in jobs), jobs)
        run_rows = [r for r in jobs if r["state"] == "running"]
        self.assertTrue(run_rows[0]["started"] and run_rows[0]["elapsed"], run_rows)
        self.assertIn("-STATUS-", run_rows[0]["last"])
        self.assertTrue(run_rows[0]["log"].endswith("job.out"))
        self.assertEqual(pr["state"], "running")
        self.wait(sub["run_dir"])

    @unittest.skipUnless(HAVE_SH, "needs a POSIX sh for batch_submit_list.txt")
    def test_job_ids_from_submit_batch(self):
        self.set_site(submit_strategy="submit_batch", donau_query_cmd="echo state-of-{job_id}")
        sub = self.cli_ctx("submit", self.ctx(auto=False, run_type="deos"))
        st, seen = self.wait(sub["run_dir"])
        self.assertEqual(st["state"], "done", seen)
        run = H.read_json(os.path.join(sub["run_dir"], "run.json"))
        self.assertEqual([d["job_id"] for d in run["donau_jobs"]], ["4201", "4202"])
        self.assertEqual([d["sim"] for d in run["donau_jobs"]], ["sim1", "sim2"])
        self.assertEqual([j["job_id"] for j in run["jobs"]], ["4201", "4202"])
        pr = self.cli("progress", "--run", sub["run_dir"])
        jobs = [r for r in pr["rows"] if r["stage"] == "job"]
        self.assertEqual([r["job_id"] for r in jobs], ["4201", "4202"])
        self.assertEqual(jobs[0]["donau"], "state-of-4201")


class HelpersTest(unittest.TestCase):
    def test_job_id_and_sim(self):
        self.assertEqual(rk_submit.job_id_of("Job <123> is submitted to queue <q>."), "123")
        self.assertEqual(rk_submit.job_id_of("blah\njob_id: 77\n"), "77")
        self.assertIsNone(rk_submit.job_id_of("nothing here"))
        site = {"donau_job_id_regex": r"JID=(\d+)"}
        self.assertEqual(rk_submit.job_id_of("x JID=5", site), "5")
        self.assertEqual(rk_submit.sim_of_line('cd /w/emir/cellA/sim3; run'), "sim3")
        self.assertEqual(rk_submit.sim_of_line('nohup x --sim sim12 > /dev/null &'), "sim12")
        self.assertIsNone(rk_submit.sim_of_line("simulate everything"))

    def test_merge_job_times(self):
        j1 = [{"sim": "sim1", "key": "k", "corner": "c", "state": "running", "exit_code": None}]
        a = rk_submit.merge_job_times([], j1, [{"sim": "sim1", "job_id": "9"}])
        self.assertTrue(a[0]["started"])
        self.assertIsNone(a[0]["ended"])
        self.assertEqual(a[0]["job_id"], "9")
        a[0]["started"] = "2026-01-01T00:00:00"
        j2 = [dict(j1[0], state="done", exit_code=0)]
        b = rk_submit.merge_job_times(a, j2)
        self.assertEqual(b[0]["started"], "2026-01-01T00:00:00")
        self.assertTrue(b[0]["ended"])
        self.assertEqual(b[0]["job_id"], "9")

    def test_use_auto_extract(self):
        self.assertTrue(rk_submit.use_auto_extract({}))
        self.assertFalse(rk_submit.use_auto_extract({"dspf_file": "a", "gds_file": "b"}))
        self.assertTrue(rk_submit.use_auto_extract({"dspf_file": "a", "gds_file": "b",
                                                    "auto_extract": True}))
        self.assertFalse(rk_submit.use_auto_extract({"auto_extract": False}))


if __name__ == "__main__":
    unittest.main()
