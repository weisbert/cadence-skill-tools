"""rk_submit: Work_Dir/History, job-file state, license detection, and full fake
end-to-end runs (build-yml -> submit -> status polling -> collect -> report) for
aging / DEOS / EMIR, including "license fails 2x then succeeds"."""

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
import rk_site  # noqa: E402
import rk_submit  # noqa: E402
import rk_aged  # noqa: E402
import relkit  # noqa: E402

FX = os.path.join(H.FIXTURES, "parse")
HAVE_SH = os.path.exists("/bin/sh") or bool(shutil.which("sh"))


class WorkDirTest(unittest.TestCase):
    def setUp(self):
        self.tmp = H.tmpdir()
        self.wa, self.sp, self.net = H.make_workarea(self.tmp)
        self.ctx = H.make_ctx(self.wa, self.sp, self.net)
        self.site, _p, _w = rk_site.site_from_ctx(self.ctx)

    def tearDown(self):
        H.rmtree(self.tmp)

    def test_numbering_and_sharing(self):
        base = self.wa + "/rs_work/tb_top/amp_core/relsim1"
        self.assertEqual(rk_submit.preview_work_dir(self.ctx, self.site), (base + "/1", 1))
        os.makedirs(base + "/4")          # e.g. a GUI run
        os.makedirs(base + "/notanumber")
        wd, h, td = rk_submit.allocate_work_dir(self.ctx, self.site, "analog_aging", "sha")
        self.assertEqual((wd, h, td), (base + "/5", 5, base + "/5/analog_aging"))
        self.assertTrue(os.path.isdir(td))
        # DEOS of the same design shares History 5 (like the GUI)
        wd, h, td = rk_submit.allocate_work_dir(self.ctx, self.site, "dynamic_eos", "sha")
        self.assertEqual(h, 5)
        # a second aging run needs a new History
        wd, h, td = rk_submit.allocate_work_dir(self.ctx, self.site, "analog_aging", "sha")
        self.assertEqual(h, 6)
        # a changed netlist never shares
        wd, h, td = rk_submit.allocate_work_dir(self.ctx, self.site, "emir", "other")
        self.assertEqual(h, 7)
        m = H.read_json(base + "/5/.relkit_history.json")
        self.assertEqual(m["types"], ["analog_aging", "dynamic_eos"])
        # never reuse a History dir relkit did not create
        os.makedirs(base + "/8")
        wd, h, td = rk_submit.allocate_work_dir(self.ctx, self.site, "emir", "other")
        self.assertEqual(h, 9)


class JobFilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = H.tmpdir()

    def tearDown(self):
        H.rmtree(self.tmp)

    def _job(self, text, ok=False):
        d = os.path.join(self.tmp, "sim%d" % len(os.listdir(self.tmp)))
        os.makedirs(d)
        if text is not None:
            with open(os.path.join(d, "job.out"), "w") as f:
                f.write(text)
        if ok:
            open(os.path.join(d, ".ok.txt"), "w").close()
        return d

    def test_job_state(self):
        self.assertEqual(rk_submit.job_state(self._job(None)), ("queued", None))
        self.assertEqual(rk_submit.job_state(self._job("-STATUS-:  Start ParaCheck.\n"))[0], "running")
        self.assertEqual(rk_submit.job_state(self._job(
            "-STATUS-: x\n-STATUS-: Run Simulation successfully.\n", ok=True)), ("done", 0))
        self.assertEqual(rk_submit.job_state(self._job(
            "-STATUS-: Run Simulation successfully.\n"))[0], "running")   # no .ok.txt yet
        self.assertEqual(rk_submit.job_state(self._job("-ERROR-: Run Simulation Failed\n"))[0], "failed")
        self.assertEqual(rk_submit.job_state(self._job("x\n    EXIT_CODE:   11003\n")), ("failed", 11003))
        self.assertEqual(rk_submit.job_state(self._job(" EXIT_CODE:(0)\n Program succeed!\n")),
                         ("done", 0))
        self.assertEqual(rk_submit.job_state(self._job("-ERROR-: /x/cell1.report is not existed\n"))[0],
                         "failed")

    def test_parse_mapping_and_sim_dirs(self):
        td = os.path.join(self.tmp, "emir")
        os.makedirs(td)
        shutil.copyfile(os.path.join(FX, "emir_mapping.txt"), os.path.join(td, "mapping.txt"))
        rows = rk_submit.parse_mapping(os.path.join(td, "mapping.txt"))
        self.assertEqual(rows[0]["pvt_key"], "FF125_test0_FF125_0")
        self.assertEqual(rows[0]["top_cell"], "amp_core")
        sims = rk_submit.sim_dirs({"type": "emir", "type_dir": td})
        self.assertEqual(sims[0]["dir"], H.p(os.path.join(td, "amp_core", "sim1")))
        td2 = os.path.join(self.tmp, "analog_aging")
        os.makedirs(td2)
        shutil.copyfile(os.path.join(FX, "aging_mapping.txt"), os.path.join(td2, "mapping.txt"))
        sims = rk_submit.sim_dirs({"type": "aging", "type_dir": td2})
        self.assertEqual([(s["sim"], s["key"]) for s in sims],
                         [("sim1", "FF125_test0_FF125"), ("sim2", "SS_t-40_test0_SS_t-40")])
        self.assertEqual(len(sims[0]["rows"]), 2)

    def test_detect_license(self):
        site = rk_site.deep_merge(rk_site.read_json(rk_site.DEFAULTS_PATH), {})
        d = self._job("Checking out redhawk_x license (Lic-216).\nNote: Using license file `1@h'.\n"
                      "Checkout 1 FEATURE_A.\n-ERROR-: Run Simulation Failed\n")
        lic, m, tail = rk_submit.detect_license(site, [d])
        self.assertFalse(lic, m)                       # informational lines are ignored
        self.assertTrue(tail[-1].startswith("-ERROR-"))
        ads = os.path.join(d, "pwr_sig_sh_em", "adsRpt")
        os.makedirs(ads)
        with open(os.path.join(ads, "totem.log"), "w") as f:
            f.write("INFO(TEC-194): Checking out x license (Lic-216).\n"
                    "ERROR(LIC-2): license checkout failed for feature totem\n")
        lic, m, _t = rk_submit.detect_license(site, [d])
        self.assertTrue(lic)
        self.assertEqual(len(m), 1)
        self.assertIn("license checkout failed", m[0]["line"])
        # a log older than the current attempt does not count
        old = time.time() - 600
        os.utime(os.path.join(ads, "totem.log"), (old, old))
        lic, m, _t = rk_submit.detect_license(site, [d], since=time.time())
        self.assertFalse(lic)


# --------------------------------------------------------------------------
# end-to-end through the fake RelStudio

class E2EBase(unittest.TestCase):
    site_over = None
    fake = None

    def setUp(self):
        self.tmp = H.tmpdir("rk_e2e_")
        self.wa, self.sp, self.net = H.make_workarea(self.tmp, site_over=self.site_over)
        self.old_env = os.environ.get("RELKIT_FAKE_RS_CONFIG")
        self.set_fake(self.fake or {"job_seconds": 0.3})

    def tearDown(self):
        if self.old_env is None:
            os.environ.pop("RELKIT_FAKE_RS_CONFIG", None)
        else:
            os.environ["RELKIT_FAKE_RS_CONFIG"] = self.old_env
        # give detached children a moment to exit before removing their dirs
        time.sleep(0.3)
        H.rmtree(self.tmp)

    def set_fake(self, cfg):
        p = H.write_json(os.path.join(self.tmp, "fake_config.json"), cfg)
        os.environ["RELKIT_FAKE_RS_CONFIG"] = p

    def set_site(self, **over):
        site = H.read_json(self.sp)
        for k, v in over.items():
            if isinstance(v, dict) and isinstance(site.get(k), dict):
                site[k].update(v)
            else:
                site[k] = v
        H.write_json(self.sp, site)

    def cli(self, *argv):
        out = os.path.join(self.tmp, "out_%d.json" % int(time.time() * 1e6))
        rc = relkit.main(list(argv) + ["--out", out])
        d = H.read_json(out)
        self.assertEqual(rc == 0, d["ok"])
        return d

    def submit(self, run_type, settings=None):
        ctx = H.make_ctx(self.wa, self.sp, self.net, run_type, settings=settings)
        cp = H.write_json(os.path.join(self.tmp, "ctx_%s.json" % run_type), ctx)
        d = self.cli("submit", "--ctx", cp)
        self.assertTrue(d["ok"], d)
        return d

    def wait(self, run_dir, timeout=90, until=None):
        end = time.time() + timeout
        seen = []
        while time.time() < end:
            d = self.cli("status", "--run", run_dir)
            self.assertTrue(d["ok"], d)
            if not seen or seen[-1] != d["state"]:
                seen.append(d["state"])
            if (until and d["state"] == until) or (until is None and d["final"]):
                return d, seen
            time.sleep(0.2)
        self.fail("run did not finish in %ss; states %s; last %s" % (timeout, seen, d))


class E2ETest(E2EBase):
    def check_done(self, sub, run_type, n_corners=2):
        st, seen = self.wait(sub["run_dir"])
        self.assertEqual(st["state"], "done", (st, seen))
        run_dir = sub["run_dir"]
        run = H.read_json(os.path.join(run_dir, "run.json"))
        self.assertTrue(run["summary_ready"])
        self.assertTrue(st["summary_ready"])
        summary = H.read_json(os.path.join(run_dir, "summary.json"))
        self.assertEqual(summary["type"], run_type)
        self.assertEqual(len(summary["corners"]), n_corners)
        for c in summary["corners"]:
            self.assertIs(c["pass"], True)
            self.assertTrue(os.path.isfile(c["table_path"]), c)
        self.assertTrue(os.path.isfile(os.path.join(run_dir, "aux_report.html")))
        self.assertEqual(run["aux_report"], H.p(os.path.join(run_dir, "aux_report.html")))
        self.assertTrue(any(r["name"].endswith(".report") and "/" not in r["name"]
                            for r in run["official_reports"]), run["official_reports"])
        self.assertTrue(all(r["copy"] and os.path.isfile(r["copy"]) for r in run["official_reports"]))
        self.assertTrue(os.path.isfile(os.path.join(run_dir, "input", os.path.basename(self.net))))
        self.assertTrue(os.path.isfile(os.path.join(run_dir, "input", "netlist.sha1")))
        self.assertTrue(os.path.isfile(os.path.join(run_dir, "logs", "relsim_start.log")) or
                        os.path.isfile(os.path.join(run_dir, "logs", "relsim_submit.log")))
        self.assertEqual([j["state"] for j in run["jobs"]], ["done"] * n_corners)
        for c in run["corner_map"]:
            self.assertTrue(c["sim_dir"].endswith(c["sim"]))
        return run, summary, seen

    def test_aging_start(self):
        sub = self.submit("aging")
        self.assertEqual(sub["rs_history"], 1)
        self.assertTrue(sub["yml_path"].endswith("/analog_aging/analog_aging.yml"))
        self.assertTrue(sub["run_id"].endswith("_aging"))
        run, summary, seen = self.check_done(sub, "aging")
        self.assertEqual(summary["corners"][0]["stress_id"], "1")
        # R1 on the finished run
        d = self.cli("aged-include", "--run", sub["run_dir"], "--netlist", self.net)
        self.assertTrue(d["ok"], d)
        self.assertIs(d["netlist_match"], True)
        self.assertEqual(len(d["items"]), 2)
        with open(d["items"][0]["include_path"], encoding="utf-8") as f:
            inc = f.read()
        self.assertIn("section=AGEING_MACRO", inc)
        self.assertIn('hrmiinput="%s"' % d["items"][0]["hrmiage0"], inc)

    def test_deos_start_shares_history_with_aging(self):
        a = self.submit("aging")
        d = self.submit("deos")
        self.assertEqual(a["rs_history"], d["rs_history"])
        self.check_done(d, "deos")
        self.wait(a["run_dir"])

    def test_emir_license_fails_twice_then_succeeds(self):
        self.set_fake({"mode": "license_fail", "license_fail_times": 2, "job_seconds": 0.3})
        sub = self.submit("emir")
        run, summary, seen = self.check_done(sub, "emir")
        lic = run["license"]
        self.assertEqual(lic["retries"], 2)
        self.assertEqual(len(lic["log"]), 2)
        self.assertIn("license", lic["log"][0]["matches"][0]["line"].lower())
        states = [t["state"] for t in run["timeline"]]
        self.assertEqual(states.count("waiting_license"), 2)
        sim1 = [c for c in run["corner_map"] if c["sim"] == "sim1"][0]["sim_dir"]
        self.assertTrue(os.path.isfile(os.path.join(sim1, "job.out.try1")))
        self.assertTrue(os.path.isfile(os.path.join(sim1, "job.out.try2")))

    def test_emir_license_policy_fail(self):
        self.set_fake({"mode": "license_fail", "license_fail_times": 5, "job_seconds": 0.2})
        sub = self.submit("emir", settings={"emir": {"license_policy": "fail"}})
        st, seen = self.wait(sub["run_dir"])
        self.assertEqual(st["state"], "failed")
        self.assertIn("license", st["message"].lower())

    def test_emir_license_wait_hours_deadline(self):
        self.set_fake({"mode": "license_fail", "license_fail_times": 50, "job_seconds": 0.2})
        sub = self.submit("emir", settings={"emir": {"license_policy": "wait_hours",
                                                     "license_wait_hours": 0.0003}})
        st, seen = self.wait(sub["run_dir"])
        self.assertEqual(st["state"], "failed", seen)
        self.assertIn("still unavailable", st["message"])
        self.assertIsNotNone(st["license"]["deadline"])

    def test_job_failure_not_license(self):
        self.set_fake({"mode": "fail", "fail_sims": ["sim2"], "job_seconds": 0.2})
        sub = self.submit("emir")
        st, seen = self.wait(sub["run_dir"])
        self.assertEqual(st["state"], "failed")
        self.assertTrue(any("Run Simulation Failed" in l for l in st["failure_tail"]))
        run = H.read_json(os.path.join(sub["run_dir"], "run.json"))
        self.assertTrue(run["license"]["unmatched_tail"])
        self.assertEqual(sorted(j["state"] for j in run["jobs"]), ["done", "failed"])

    def test_dry_run(self):
        self.set_site(dry_run=True)
        sub = self.submit("deos")
        self.assertIs(sub["dry_run"], True)
        st, seen = self.wait(sub["run_dir"])
        self.assertEqual(st["state"], "dry_run_done")
        self.assertEqual([j["state"] for j in st["jobs"]], ["prepared", "prepared"])
        td = H.read_json(os.path.join(sub["run_dir"], "run.json"))["type_dir"]
        self.assertTrue(os.path.isfile(os.path.join(td, "batch_submit_list.txt")))
        self.assertTrue(os.path.isfile(os.path.join(td, "sim1", "script", "Dynamic_EOS.conf")))
        self.assertFalse(os.path.exists(os.path.join(td, "sim1", "job.out")))

    @unittest.skipUnless(HAVE_SH, "needs a POSIX sh for batch_submit_list.txt")
    def test_submit_batch_strategy(self):
        self.set_site(submit_strategy="submit_batch")
        sub = self.submit("aging")
        self.check_done(sub, "aging")
        self.assertTrue(os.path.isfile(os.path.join(sub["run_dir"], "logs", "batch_submit.log")))

    def test_start_blocks_and_summarizes_itself(self):
        self.set_fake({"job_seconds": 0.3, "start_blocks": True})
        sub = self.submit("deos")
        run, summary, seen = self.check_done(sub, "deos")
        with open(os.path.join(sub["run_dir"], "logs", "relsim_start.log"), encoding="utf-8") as f:
            log = f.read()
        self.assertIn("summary flow", log)
        self.assertFalse(os.path.isfile(os.path.join(sub["run_dir"], "logs", "relsim_summary.log")))

    def test_violations_reported(self):
        self.set_fake({"job_seconds": 0.2, "deos_violation": True})
        sub = self.submit("deos")
        st, seen = self.wait(sub["run_dir"])
        self.assertEqual(st["state"], "done")
        summary = H.read_json(os.path.join(sub["run_dir"], "summary.json"))
        self.assertIs(summary["pass"], False)
        self.assertTrue(all(c["metrics"]["violations"] == 1 for c in summary["corners"]))

    def test_cancel(self):
        self.set_fake({"job_seconds": 30})
        sub = self.submit("deos")
        self.wait(sub["run_dir"], until="running")
        d = self.cli("cancel", "--run", sub["run_dir"])
        self.assertEqual(d["state"], "cancelled")
        st = self.cli("status", "--run", sub["run_dir"])
        self.assertEqual(st["state"], "cancelled")
        self.assertTrue(st["final"])

    def test_status_restarts_dead_supervisor(self):
        self.set_fake({"job_seconds": 1.5})
        sub = self.submit("deos")
        self.wait(sub["run_dir"], until="running")
        run = H.read_json(os.path.join(sub["run_dir"], "run.json"))
        rk_submit.kill_tree(run["supervisor_pid"])
        time.sleep(0.5)
        hb = os.path.join(sub["run_dir"], "logs", "supervisor.heartbeat")
        old = time.time() - 3600
        os.utime(hb, (old, old))
        st, seen = self.wait(sub["run_dir"])
        self.assertEqual(st["state"], "done", seen)
        run2 = H.read_json(os.path.join(sub["run_dir"], "run.json"))
        self.assertNotEqual(run2["supervisor_pid"], run["supervisor_pid"])

    def test_submit_errors(self):
        ctx = H.make_ctx(self.wa, self.sp, self.net, "emir",
                         settings={"emir": {"dspf_file": "/nonexistent.dspf"}})
        cp = H.write_json(os.path.join(self.tmp, "c1.json"), ctx)
        d = self.cli("submit", "--ctx", cp)
        self.assertFalse(d["ok"])
        self.assertIn("dspf_file", d["error"])
        self.set_site(relstudio_home=self.tmp)
        ctx = H.make_ctx(self.wa, self.sp, self.net, "deos")
        cp = H.write_json(os.path.join(self.tmp, "c2.json"), ctx)
        d = self.cli("submit", "--ctx", cp)
        self.assertFalse(d["ok"])
        self.assertIn("run_relsim", d["error"])
        self.assertFalse(os.path.exists(os.path.join(self.wa, "relkit_runs")))
        # a yml-level error (no test) fails before any run record / History dir exists
        self.set_site(relstudio_home=H.FAKE_HOME)
        ctx = H.make_ctx(self.wa, self.sp, self.net, "deos")
        ctx["test"] = ""
        cp = H.write_json(os.path.join(self.tmp, "c3.json"), ctx)
        d = self.cli("submit", "--ctx", cp)
        self.assertFalse(d["ok"])
        self.assertIn("ctx.test", d["error"])
        self.assertFalse(os.path.exists(os.path.join(self.wa, "relkit_runs")))
        self.assertFalse(os.path.exists(os.path.join(self.wa, "rs_work")))


if __name__ == "__main__":
    unittest.main()
