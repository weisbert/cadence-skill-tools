"""Tests for rk_runs: create/update API, list + filters, note/tags, compare,
settings-for-rerun, copy-reports, Work_Dir removal and delete. Synthetic
names only (tb_top, amp_core, /opt/relstudio ...)."""

import datetime
import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest

PY_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PY_DIR)

import relkit  # noqa: E402
import rk_common  # noqa: E402
import rk_runs  # noqa: E402


def T(day, hms="100000"):
    return datetime.datetime.strptime("202610%02d%s" % (day, hms), "%Y%m%d%H%M%S")


CORNERS = [
    {"name": "FF125", "base_name": "FF125", "enabled": True, "selected": True,
     "sections": [{"model_file": "/proj/model/toplevel.scs", "section": "TOP_FF"}],
     "temperature": "125", "vars": {"VSET": "12"}, "sweep": {}},
    {"name": "SS_t-40", "base_name": "SS", "enabled": True, "selected": False,
     "sections": [{"model_file": "/proj/model/toplevel.scs", "section": "TOP_SS"}],
     "temperature": "-40", "vars": {}, "sweep": {"temperature": "-40"}},
]


class RunsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = rk_runs._posix(tempfile.mkdtemp(prefix="rk_runs_"))
        self.wa = self.tmp + "/wa"
        os.makedirs(self.wa + "/Reliability/amp_core")
        self.netlist = self.wa + "/Reliability/amp_core/tb_top_test0.scs"
        with open(self.netlist, "w", encoding="utf-8", newline="\n") as f:
            f.write("simulator lang=spectre\nI0 (a b) amp_core\n")
        self.site_path = self.tmp + "/site.json"
        with open(self.site_path, "w", encoding="utf-8") as f:
            json.dump({"persist_root": "${WORKAREA}/relkit_runs",
                       "work_root": "${WORKAREA}/rs_work"}, f)
        self.site = rk_common.read_json(self.site_path)
        import rk_site
        self.site, _p, _w = rk_site.load_site(workarea=self.wa, path=self.site_path, user="jdoe")
        self.root = self.wa + "/relkit_runs"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ctx(self, run_type="aging", test="test0", corners=None, settings=None, cell="tb_top"):
        return {
            "schema": 1, "user": "jdoe", "host": "host01", "workarea": self.wa,
            "site_path": self.site_path, "relstudio_home": "/opt/relstudio",
            "relkit_version": "0.1.0",
            "maestro": {"lib": "mylib", "cell": cell, "view": "maestro"},
            "test": test, "tests": ["test0", "test1"],
            "design": {"lib": "mylib", "cell": cell, "view": "config", "is_config": True},
            "history": {"name": "Interactive.3", "dir": "/proj/sim/Interactive.3"},
            "netlist": {"path": self.netlist},
            "dut": {"inst": "I0", "lib": "mylib", "cell": "amp_core", "view": "schematic"},
            "ip_name": cell, "project_name": "relsim1",
            "corners": corners if corners is not None else CORNERS,
            "run_type": run_type,
            "settings": {run_type: settings or {}},
        }

    def mk(self, day, run_type="aging", **kw):
        return rk_runs.create_run(self.ctx(run_type, **kw), self.site, now=T(day))

    def write_summary(self, run_dir, corners):
        rk_common.write_json(run_dir + "/summary.json", {"ok": True, "cmd": "collect",
                                                        "corners": corners})

    def cli(self, *argv, ctx=None):
        out = self.tmp + "/out.json"
        args = list(argv)
        if ctx is not None:
            cp = self.tmp + "/ctx.json"
            rk_common.write_json(cp, ctx)
            args += ["--ctx", cp]
        rc = relkit.main(args + ["--out", out])
        return rc, rk_common.read_json(out)

    # ---------------------------------------------------------------- create

    def test_create_run_record(self):
        run_dir, run = self.mk(8, settings={"life_time": "5", "start_time": None})
        self.assertEqual(run_dir, self.root + "/mylib/tb_top/20261008-100000_aging")
        self.assertEqual(run["id"], "20261008-100000_aging")
        self.assertEqual(run["rs_type"], "analog_aging")
        self.assertEqual(run["state"], "created")
        self.assertEqual(run["timeline"][0]["state"], "created")
        self.assertEqual([c["name"] for c in run["corners"]], ["FF125"])  # selected only
        # defaults applied, null ignored, override kept
        self.assertEqual(run["settings"]["life_time"], "5")
        self.assertEqual(run["settings"]["start_time"], "0n")
        self.assertEqual(run["settings"]["life_time_unit"], "years")
        self.assertEqual(run["relstudio_home"], "/opt/relstudio")
        self.assertEqual(run["cell_name"], "amp_core")
        for sub in ("input", "tables", "reports", "logs"):
            self.assertTrue(os.path.isdir(run_dir + "/" + sub), sub)
        with open(self.netlist, "rb") as f:
            data = f.read()
        sha1 = hashlib.sha1(data).hexdigest()
        self.assertEqual(run["netlist"]["sha1"], sha1)
        self.assertEqual(run["netlist"]["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(run["netlist"]["copy"], "input/tb_top_test0.scs")
        with open(run_dir + "/input/tb_top_test0.scs", "rb") as f:
            self.assertEqual(f.read(), data)
        with open(run_dir + "/input/netlist.sha1", encoding="utf-8") as f:
            self.assertEqual(f.read(), "%s  tb_top_test0.scs\n" % sha1)
        files = rk_common.read_json(run_dir + "/input/files.json")
        self.assertEqual(files["netlist"]["sha1"], sha1)
        self.assertEqual(rk_common.read_json(run_dir + "/run.json"), run)

    def test_emir_inputs_and_collision(self):
        dspf = self.wa + "/Reliability/amp_core/amp_core.dspf"
        with open(dspf, "w") as f:
            f.write("*|DSPF\n")
        d1, r1 = self.mk(8, "emir", settings={"dspf_file": dspf,
                                              "gds_file": self.wa + "/missing.gds"})
        d2, r2 = self.mk(8, "emir")
        self.assertEqual(r2["id"], "20261008-100000_emir_2")
        self.assertTrue(r1["inputs"]["dspf"]["exists"])
        self.assertEqual(len(r1["inputs"]["dspf"]["sha1"]), 40)
        self.assertFalse(r1["inputs"]["gds"]["exists"])
        self.assertEqual(r1["settings"]["rc_corner"], "typical")      # site emir.rc_corner
        self.assertEqual(r1["settings"]["license_policy"], "wait_forever")
        self.assertEqual(r1["settings"]["layout_lib"], "mylib")
        self.assertEqual(r1["settings"]["run_type"], "DYN SEM")
        with self.assertRaises(rk_common.RkError):
            rk_runs.create_run(self.ctx("bogus"), self.site)

    def test_update_state_and_inputs(self):
        run_dir, _ = self.mk(8)
        rk_runs.update_run(run_dir, {"work_dir": "/scratch/x/3", "rs_history": 3})
        rk_runs.set_state(run_dir, "submitting")
        rk_runs.set_state(run_dir, "queued", "job 42", supervisor_pid=123)
        rk_runs.set_state(run_dir, "queued", "job 42")  # no duplicate entry
        run = rk_runs.load_run(run_dir)
        self.assertEqual([t["state"] for t in run["timeline"]],
                         ["created", "submitting", "queued"])
        self.assertEqual(run["state"], "queued")
        self.assertEqual(run["supervisor_pid"], 123)
        self.assertEqual(run["rs_history"], 3)
        yml = self.tmp + "/analog_aging.yml"
        with open(yml, "w") as f:
            f.write("Common:\n")
        self.assertEqual(rk_runs.add_input_file(run_dir, yml), "input/analog_aging.yml")
        rk_runs.add_input_file(run_dir, yml)  # same copy recorded once
        files = rk_common.read_json(run_dir + "/input/files.json")
        self.assertEqual(len(files["yml"]), 1)
        self.assertTrue(os.path.isfile(run_dir + "/input/analog_aging.yml"))
        self.assertFalse(os.path.exists(run_dir + "/.run.json.lock"))

    # ------------------------------------------------------------- list etc.

    def populate(self):
        a1, _ = self.mk(1, "aging")
        a2, _ = self.mk(5, "aging", settings={"life_time": "20"},
                        corners=[dict(CORNERS[1], selected=True)])
        d1, _ = self.mk(6, "deos", test="test1")
        e1, _ = self.mk(7, "emir", cell="tb_other")
        for d in (a1, a2, d1):
            rk_runs.set_state(d, "done")
        self.write_summary(a1, [{"key": "FF125_test0_FF125", "corner": "FF125",
                                 "stress_id": "1", "pass": True,
                                 "metrics": {"didsat(HCI+BTI,%)": 3.17, "Dtemp": "1.2"},
                                 "worst_device": "I0.X1.M3"}])
        self.write_summary(a2, [{"key": "SS_t-40_test0_SS_t-40", "corner": "SS_t-40",
                                 "stress_id": "1", "pass": False,
                                 "metrics": {"didsat(HCI+BTI,%)": 9.0, "Dtemp": "2.4"},
                                 "worst_device": "I0.X2.M1"}])
        self.write_summary(d1, [{"key": "k1", "corner": "FF125", "pass": True,
                                 "metrics": {"Total_DPM": 12.5}},
                                {"key": "k2", "corner": "TT", "pass": True,
                                 "metrics": {"Total_DPM": 30}}])
        return a1, a2, d1, e1

    def test_list_and_filters(self):
        a1, a2, d1, e1 = self.populate()
        rows, warn = rk_runs.list_runs(self.root, "mylib", "tb_top")
        self.assertEqual([r["id"] for r in rows],
                         ["20261006-100000_deos", "20261005-100000_aging",
                          "20261001-100000_aging"])
        self.assertEqual(warn, [])
        r = rows[1]
        self.assertEqual(r["pass"], False)
        self.assertEqual(r["key_metric"], "didsat(HCI+BTI,%) max 9")
        self.assertEqual(r["life"], "20 years")
        self.assertEqual(r["dut"], "I0 (amp_core)")
        self.assertEqual(r["n_corners"], 1)
        self.assertEqual(rows[0]["key_metric"], "Total_DPM max 30")
        self.assertTrue(rows[2]["pass"])
        self.assertEqual(len(rk_runs.list_runs(self.root)[0]), 4)          # all lib/cell
        self.assertEqual([r["id"] for r in rk_runs.list_runs(self.root, run_type="aging")[0]],
                         ["20261005-100000_aging", "20261001-100000_aging"])
        self.assertEqual(len(rk_runs.list_runs(self.root, test="test1")[0]), 1)
        self.assertEqual([r["id"] for r in rk_runs.list_runs(self.root, since="2026-10-05",
                                                              until="20261006")[0]],
                         ["20261006-100000_deos", "20261005-100000_aging"])
        # CLI: ctx -> only this Maestro cell; TSV with _run_dir first
        rc, out = self.cli("runs", "list", ctx=self.ctx())
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(out["runs"]), 3)
        with open(out["table_path"], encoding="utf-8") as f:
            lines = f.read().splitlines()
        self.assertEqual(lines[0].split("\t")[0], "_run_dir")
        self.assertEqual(lines[0].split("\t"), rk_runs.LIST_TSV_HEADER)
        self.assertEqual(len(lines), 4)
        row = lines[2].split("\t")
        self.assertEqual(row[0], a2)
        self.assertEqual(row[1], "fail")
        rc, out = self.cli("runs", "list", "--all", "--type", "emir", ctx=self.ctx())
        self.assertEqual([r["id"] for r in out["runs"]], ["20261007-100000_emir"])
        rc, out = self.cli("runs", "list", "--persist-root", self.root, "--test", "test1")
        self.assertEqual([r["id"] for r in out["runs"]], ["20261006-100000_deos"])
        rc, out = self.cli("runs", "list")
        self.assertEqual(rc, 1)

    def test_note_and_show(self):
        a1, a2, d1, e1 = self.populate()
        rc, out = self.cli("runs", "note", "--run", a1, "--note", "FDR sign-off run",
                           "--tags", "fdr, signoff,fdr")
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["tags"], ["fdr", "signoff"])
        rc, out = self.cli("runs", "note", "--run", a1, "--tags", "fdr")
        self.assertEqual(out["note"], "FDR sign-off run")  # note kept
        row = rk_runs.list_runs(self.root, "mylib", "tb_top")[0][2]
        self.assertEqual(row["note"], "FDR sign-off run")
        self.assertEqual(row["tags"], ["fdr"])
        self.assertNotIn("note", rk_runs.load_run(a1))  # never in run.json
        rc, out = self.cli("runs", "show", "--run", a1)
        self.assertEqual(rc, 0)
        self.assertEqual(out["run"]["id"], "20261001-100000_aging")
        self.assertEqual(out["summary"]["corners"][0]["corner"], "FF125")
        self.assertEqual(out["note"]["note"], "FDR sign-off run")
        rc, out = self.cli("runs", "show", "--run", e1)
        self.assertIsNone(out["summary"])
        rc, out = self.cli("runs", "show", "--run", self.tmp)
        self.assertEqual(rc, 1)
        self.assertIn("not a run record", out["error"])

    def test_compare(self):
        a1, a2, d1, e1 = self.populate()
        rc, out = self.cli("runs", "compare", "--run", a1, "--run2", a2)
        self.assertEqual(rc, 0, out)
        conds = {c["key"]: c for c in out["conditions"]}
        self.assertFalse(conds["settings.life_time"]["same"])
        self.assertEqual((conds["settings.life_time"]["a"], conds["settings.life_time"]["b"]),
                         ("10", "20"))
        self.assertTrue(conds["test"]["same"])
        self.assertTrue(conds["netlist.sha1"]["same"])
        self.assertEqual(conds["corners"]["b"], "SS_t-40")
        self.assertIn("corner.FF125.temperature", conds)
        self.assertIsNone(conds["corner.SS_t-40.temperature"]["a"])
        m = {(r["corner"], r["metric"]): r for r in out["metrics"]}
        k = ("FF125#1 | SS_t-40#1", "didsat(HCI+BTI,%)")  # FF vs SS pairing
        self.assertIn(k, m)
        self.assertAlmostEqual(m[k]["delta"], 5.83)
        self.assertAlmostEqual(m[k]["delta_pct"], 5.83 / 3.17 * 100)
        self.assertAlmostEqual(m[("FF125#1 | SS_t-40#1", "Dtemp")]["delta"], 1.2)
        self.assertEqual(m[("FF125#1 | SS_t-40#1", "pass")]["b"], False)
        for p in (out["table_path"], out["conditions_table_path"]):
            with open(p, encoding="utf-8") as f:
                self.assertTrue(f.readline().startswith("_sev\t"))
        # same-name corners pair by name; unmatched ones still listed
        res = rk_runs.compare_runs(d1, d1)
        self.assertTrue(all(c["same"] for c in res["conditions"]))
        self.assertEqual(sorted({r["corner"] for r in res["metrics"]}), ["FF125", "TT"])
        self.assertTrue(all(r["delta"] in (0, None) for r in res["metrics"]))
        rc, out = self.cli("runs", "compare", "--run", a1)
        self.assertEqual(rc, 1)

    def test_settings_for_rerun(self):
        a1, a2, d1, e1 = self.populate()
        rc, out = self.cli("runs", "settings-for-rerun", "--run", a2)
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["run_type"], "aging")
        self.assertEqual(out["test"], "test0")
        self.assertEqual(out["corners"], ["SS_t-40"])
        self.assertEqual(out["dut"]["cell"], "amp_core")
        self.assertEqual(out["ip_name"], "tb_top")
        self.assertEqual(out["settings"]["life_time"], "20")
        self.assertEqual(out["corner_details"][0]["temperature"], "-40")

    def make_work_dir(self, run_dir):
        wd = self.wa + "/rs_work/tb_top/amp_core/relsim1/3"
        td = wd + "/analog_aging"
        os.makedirs(td + "/sim1")
        for rel, text in (("tb_top_cell1_AnalogAging.report", "aging report\n"),
                          ("sim1/cell1.report", "sim1 report\n"),
                          ("sim1/cell1.report.pdf", "%PDF-1.4\n")):
            with open(td + "/" + rel, "w", encoding="utf-8") as f:
                f.write(text)
        rk_runs.update_run(run_dir, {"work_dir": wd, "type_dir": td, "rs_history": 3})
        return wd, td

    def test_work_dir_removed_still_viewable(self):
        a1, a2, d1, e1 = self.populate()
        wd, td = self.make_work_dir(a1)
        rc, out = self.cli("runs", "copy-reports", "--run", a1)
        self.assertEqual(rc, 0, out)
        recs = {os.path.basename(r["path"]): r for r in out["report_copies"]}
        self.assertEqual(recs["tb_top_cell1_AnalogAging.report"]["copy"],
                         "reports/tb_top_cell1_AnalogAging.report")
        self.assertEqual(recs["cell1.report"]["copy"], "reports/sim1__cell1.report")
        self.assertEqual(recs["cell1.report.pdf"]["kind"], "pdf")
        self.assertIsNone(recs["cell1.report.pdf"]["copy"])
        self.assertTrue(os.path.isfile(a1 + "/reports/sim1__cell1.report"))
        self.assertFalse(os.path.exists(a1 + "/reports/sim1__cell1.report.pdf"))
        row = rk_runs.list_runs(self.root, "mylib", "tb_top", run_type="aging")[0][1]
        self.assertTrue(row["raw_data_present"])
        # scratch-disk cleanup: the Work_Dir vanishes
        shutil.rmtree(wd)
        rc, out = self.cli("runs", "list", ctx=self.ctx())
        row = [r for r in out["runs"] if r["run_dir"] == a1][0]
        self.assertFalse(row["raw_data_present"])
        self.assertTrue(row["pass"])  # summary still there
        run = rk_runs.load_run(a1)
        self.assertFalse(run["raw_data_present"])
        self.assertTrue(run["raw_data_cleaned"])
        rc, out = self.cli("runs", "show", "--run", a1)
        self.assertEqual(out["summary"]["corners"][0]["worst_device"], "I0.X1.M3")
        self.assertEqual(out["run"]["netlist"]["copy"], "input/tb_top_test0.scs")
        self.assertTrue(os.path.isfile(a1 + "/input/tb_top_test0.scs"))
        # copying again keeps the earlier copies
        copies = rk_runs.copy_reports(a1)
        rec = [r for r in copies if r["path"].endswith("sim1/cell1.report")][0]
        self.assertEqual(rec["copy"], "reports/sim1__cell1.report")
        self.assertIn("kept earlier copy", rec["note"])
        with open(self.tmp + "/out_runs.tsv", encoding="utf-8") as f:
            self.assertIn("cleaned", f.read())

    def test_delete(self):
        a1, a2, d1, e1 = self.populate()
        wd, td = self.make_work_dir(a1)
        rc, out = self.cli("runs", "delete", "--run", e1)  # state created: active
        self.assertEqual(rc, 1)
        self.assertIn("cancel it first", out["error"])
        rc, out = self.cli("runs", "delete", "--run", a1)
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["deleted"], a1)
        self.assertFalse(os.path.exists(a1))
        self.assertTrue(os.path.isdir(td))                 # Work_Dir untouched
        self.assertTrue(os.path.isfile(td + "/sim1/cell1.report"))
        self.assertEqual(len(rk_runs.list_runs(self.root, "mylib", "tb_top")[0]), 2)
        rc, out = self.cli("runs", "delete", "--run", e1, "--force")
        self.assertEqual(rc, 0)
        # a dir that is not a run record is never deleted
        os.makedirs(self.tmp + "/notarun")
        rc, out = self.cli("runs", "delete", "--run", self.tmp + "/notarun")
        self.assertEqual(rc, 1)
        self.assertTrue(os.path.isdir(self.tmp + "/notarun"))
        # a record whose Work_Dir would overlap is refused
        bad, _ = self.mk(9)
        rk_runs.set_state(bad, "done", work_dir=bad + "/inner")
        with self.assertRaises(rk_common.RkError):
            rk_runs.delete_run(bad)
        self.assertTrue(os.path.isdir(bad))

    def test_record_written_by_submit_shape(self):
        """A run.json shaped like rk_submit's own writer (no rk_runs.create_run)."""
        d = self.root + "/mylib/tb_top/20261003-090000_deos"
        os.makedirs(d + "/input")
        rk_common.write_json(d + "/input/files.json", {})
        wd = self.tmp + "/gone_work_dir/3"
        run = {"schema": 1, "id": "20261003-090000_deos", "type": "deos",
               "rs_type": "dynamic_eos", "created": "2026-10-03T09:00:00", "user": "jdoe",
               "maestro": {"lib": "mylib", "cell": "tb_top", "view": "maestro"},
               "test": "test0", "dut": {"inst": "I0", "lib": "mylib", "cell": "amp_core",
                                        "view": "schematic", "terms": ["VDD"]},
               "corners": [CORNERS[0]], "settings": {"life_time": "10",
                                                     "life_time_unit": "years"},
               "work_dir": wd, "type_dir": wd + "/dynamic_eos",
               "netlist": {"path": "/x.scs", "sha1": "ab", "signature": None},
               "state": "running", "state_since": "2026-10-03T09:01:00", "message": "",
               "timeline": [], "summary": None, "raw_data_present": True}
        rk_common.write_json(d + "/run.json", run)
        row = rk_runs.list_runs(self.root, "mylib", "tb_top")[0][0]
        self.assertEqual(row["id"], "20261003-090000_deos")
        self.assertFalse(row["raw_data_present"])                     # reported ...
        self.assertTrue(rk_runs.load_run(d)["raw_data_present"])      # ... not written (live run)
        run["state"] = "done"
        rk_common.write_json(d + "/run.json", run)
        rk_runs.list_runs(self.root, "mylib", "tb_top")
        self.assertFalse(rk_runs.load_run(d)["raw_data_present"])     # final: recorded
        self.assertEqual(rk_runs.settings_for_rerun(d)["corners"], ["FF125"])
        res = rk_runs.compare_runs(d, d)
        self.assertTrue(all(c["same"] for c in res["conditions"]))

    def test_key_metric_and_pass_helpers(self):
        self.assertIsNone(rk_runs.overall_pass(None))
        self.assertIsNone(rk_runs.overall_pass({"corners": [{"pass": True}, {"pass": None}]}))
        self.assertEqual(rk_runs.key_metric({"corners": [
            {"pass": True, "metrics": {"Pwr_AVG": "71.25%"}},
            {"pass": False, "metrics": {"Pwr_AVG": "48.9%"}}]}, "emir"), "Pwr_AVG max 71.25")
        self.assertEqual(rk_runs.key_metric({"corners": [{"pass": False, "metrics": {}}]},
                                            "emir"), "1/1 corners fail")
        self.assertEqual(rk_runs.key_metric({"key_metric": "x", "corners": []}, "aging"), "x")
        self.assertEqual(rk_runs._to_num("9.00e+00#@#I0.X1.M3"), 9.0)
        self.assertIsNone(rk_runs._to_num("NULL"))


if __name__ == "__main__":
    unittest.main()
