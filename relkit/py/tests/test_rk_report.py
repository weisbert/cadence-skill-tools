"""rk_report: self-contained HTML aux report."""

import os
import re
import shutil
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rkt_helpers as H  # noqa: E402
import rk_common  # noqa: E402
import rk_parse  # noqa: E402
import rk_report  # noqa: E402
import relkit  # noqa: E402

FX = os.path.join(H.FIXTURES, "parse")


class ReportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = H.tmpdir()

    def tearDown(self):
        H.rmtree(self.tmp)

    def _deos_run(self):
        run_dir = os.path.join(self.tmp, "run")
        td = os.path.join(self.tmp, "work", "dynamic_eos")
        os.makedirs(run_dir)
        for sub in ("summary_rpt", "sim1/eos_spectre", "sim2/eos_spectre"):
            os.makedirs(os.path.join(td, sub))
        shutil.copyfile(os.path.join(FX, "deos_summary.txt"), os.path.join(td, "summary_rpt", "summary.txt"))
        for sim in ("sim1", "sim2"):
            shutil.copyfile(os.path.join(FX, "deos_eos_full.rpt"),
                            os.path.join(td, sim, "eos_spectre", "amp_core_eos_full.rpt"))
            with open(os.path.join(td, sim, "amp_core.report"), "w") as f:
                f.write("per sim report <b>\n")
        with open(os.path.join(td, "tb_top_amp_core_DynamicEOS.report"), "w") as f:
            f.write("official\n")
        run = {"schema": 1, "id": "20261008-101500_deos", "type": "deos", "rs_type": "dynamic_eos",
               "run_dir": H.p(run_dir), "type_dir": H.p(td), "state": "done", "test": "test0",
               "maestro": {"lib": "mylib", "cell": "tb_top", "view": "maestro"},
               "dut": {"inst": "I0", "lib": "mylib", "cell": "amp_core"},
               "settings": {"life_time": "10", "life_time_unit": "years", "start_time": "0n",
                            "stop_time": "20n", "simulation_time": "20n"},
               "corners": [{"name": "FF125", "temperature": "125",
                            "sections": [{"section": "TOP_FF"}], "vars": {"VSET": "12"}}],
               "corner_map": [{"key": "FF125_test0_FF125", "corner": "FF125", "sim": "sim1"},
                              {"key": "SS_t-40_test0_SS_t-40", "corner": "SS_t-40", "sim": "sim2"}],
               "timeline": []}
        rk_common.write_json(os.path.join(run_dir, "run.json"), run)
        return run_dir

    def test_report(self):
        run_dir = self._deos_run()
        rk_parse.collect(run_dir)
        out = os.path.join(self.tmp, "o.json")
        self.assertEqual(relkit.main(["report", "--run", run_dir, "--out", out]), 0)
        d = H.read_json(out)
        self.assertTrue(d["html_path"].endswith("/aux_report.html"))
        self.assertEqual(len(d["official_reports"]), 3)
        with open(d["html_path"], encoding="utf-8") as f:
            html = f.read()
        self.assertTrue(html.startswith("<!doctype html>"))
        self.assertNotRegex(html, r"(src|href)\s*=\s*[\"']?(https?:)?//")
        self.assertNotIn("<script", html)
        self.assertIn("I0.X2.M1", html)                 # the DEOS violation row
        self.assertIn('class="fail"', html)
        self.assertIn("badge fail", html)
        self.assertIn("tb_top_amp_core_DynamicEOS.report", html)
        with open(d["official_reports"][1]["copy"], encoding="utf-8") as f:
            self.assertIn("per sim report", f.read())
        run = H.read_json(os.path.join(run_dir, "run.json"))
        self.assertEqual(run["aux_report"], d["html_path"])
        self.assertTrue(re.search(r"@media \(prefers-color-scheme: dark\)", html))

    def test_report_without_summary(self):
        run_dir = self._deos_run()
        res = rk_report.make_report(run_dir)
        with open(res["html_path"], encoding="utf-8") as f:
            self.assertIn("No parsed results", f.read())


if __name__ == "__main__":
    unittest.main()
