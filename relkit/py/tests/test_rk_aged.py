"""rk_aged (R1): .hrmiage0 rewrite, HRMI block extraction, persisted files, missing/reuse."""

import os
import shutil
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rkt_helpers as H  # noqa: E402
import rk_aged  # noqa: E402
import rk_common  # noqa: E402
import relkit  # noqa: E402

FX = os.path.join(H.FIXTURES, "parse")


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


class UnitTest(unittest.TestCase):
    def test_rewrite_hrmiage0(self):
        text = read(os.path.join(FX, "stress.hrmiage0"))
        out = rk_aged.rewrite_hrmiage0(text, "/proj/wa/relkit_runs/r/hrmi/1/x.hrmiage0.dat")
        first = out.splitlines()[0]
        self.assertEqual(first, "age_data_file\t1\t/proj/wa/relkit_runs/r/hrmi/1/x.hrmiage0.dat")
        self.assertEqual(out.splitlines()[1:], text.splitlines()[1:])
        with self.assertRaises(rk_common.RkError):
            rk_aged.rewrite_hrmiage0("tr_start 0\n", "/x")

    def test_injection_block(self):
        block = rk_aged.injection_block(read(os.path.join(FX, "aged_netlist_tail.scs")))
        self.assertEqual(block[0], "simulator lang=spectre")
        self.assertEqual(block[-1], ".option dagetime=10y")
        self.assertTrue(any("section=AGEING_MACRO" in l for l in block))
        self.assertTrue(any("hrmiinput=" in l for l in block))
        self.assertIsNone(rk_aged.injection_block("simulator lang=spectre\nM1 (a b c d) n\n"))
        inc = rk_aged.aged_include_text(block, "/new/x.hrmiage0", "rid", "1")
        self.assertIn('option4 options hrmiinput="/new/x.hrmiage0"', inc)
        self.assertIn('include "/opt/pdk/models/alps/macro_model_usage.scs" section=AGEING_MACRO', inc)
        self.assertTrue(inc.rstrip().endswith("simulator lang=spectre"))
        self.assertNotIn(".alter", inc)


DELTA_HEADER = ["_key", "_sev", "Output", "Test", "Point", "Fresh corner", "Aged corner",
                "Fresh", "Aged", "Delta", "Delta %"]


def write_delta(path, rows):
    rk_common.write_tsv(path, DELTA_HEADER, rows)


class PrepareTest(unittest.TestCase):
    def setUp(self):
        self.tmp = H.tmpdir()
        self.run_dir = os.path.join(self.tmp, "run")
        self.type_dir = os.path.join(self.tmp, "work", "analog_aging")
        os.makedirs(self.run_dir)
        for sim, key in (("sim1", "FF125_test0_FF125"), ("sim2", "SS_test0_SS")):
            point = os.path.join(self.type_dir, sim, "10y_point")
            sdir = os.path.join(point, "Stress_1", "amp_core_Stress_1")
            os.makedirs(sdir)
            shutil.copyfile(os.path.join(FX, "stress.hrmiage0"),
                            os.path.join(sdir, "amp_core_Stress_1.hrmiage0"))
            with open(os.path.join(sdir, "amp_core_Stress_1.hrmiage0.dat"), "wb") as f:
                f.write(b"\x00\x01synthetic\xff" * 10)
            os.makedirs(os.path.join(point, "Aged_1"))
            shutil.copyfile(os.path.join(FX, "aged_netlist_tail.scs"),
                            os.path.join(point, "Aged_1", "amp_core_Aged_1.scs"))
        os.makedirs(os.path.join(self.type_dir, "summary_rpt"))
        with open(os.path.join(self.type_dir, "summary_rpt", "summary_id.yml"), "w") as f:
            f.write("1: /elsewhere/analog_aging/sim1\n2: /elsewhere/analog_aging/sim2\n")
        with open(os.path.join(self.type_dir, "mapping.txt"), "w") as f:
            f.write(read(os.path.join(FX, "aging_mapping.txt")).replace("SS_t-40", "SS"))
        self.net = os.path.join(self.tmp, "n.scs")
        with open(self.net, "w") as f:
            f.write(H.NETLIST)
        import rk_yml
        run = {"schema": 1, "id": "20261008-100700_aging", "type": "aging",
               "rs_type": "analog_aging", "run_dir": H.p(self.run_dir),
               "type_dir": H.p(self.type_dir),
               "settings": {"life_time": "10", "life_time_unit": "years"},
               "test": "test0", "maestro": {"lib": "mylib", "cell": "tb_top", "view": "maestro"},
               "corners": [{"name": "FF125", "base_name": "FF125", "selected": True,
                            "sections": [{"model_file": "/proj/model/toplevel.scs",
                                          "section": "TOP_FF"}],
                            "temperature": "125", "vars": {"VSET": "12"}, "sweep": {}}],
               "corner_map": [{"key": "FF125_test0_FF125", "corner": "FF125", "sim": "sim1",
                               "temperature": "125", "eval_temperatures": ["125"]},
                              {"key": "SS_test0_SS", "corner": "SS", "sim": "sim2",
                               "temperature": "-40", "eval_temperatures": ["-40", "125"]}],
               "netlist": {"sha1": "abc", "signature": rk_yml.netlist_signature(self.net)}}
        rk_common.write_json(os.path.join(self.run_dir, "run.json"), run)

    def tearDown(self):
        H.rmtree(self.tmp)

    def test_prepare_all(self):
        res = rk_aged.prepare(self.run_dir, current_netlist=self.net)
        self.assertEqual(res["missing"], [])
        self.assertEqual(res["life"], "10y")
        self.assertIs(res["netlist_match"], True)
        self.assertEqual([i["stress_id"] for i in res["items"]], ["1", "2"])
        it = res["items"][1]
        self.assertEqual(it["key"], "SS_test0_SS")
        self.assertEqual(it["corner"], "SS")
        self.assertEqual(it["eval_temperatures"], ["-40", "125"])
        self.assertTrue(it["include_path"].endswith("/hrmi/2/aged_2.scs"))
        h0 = read(it["hrmiage0"])
        self.assertTrue(h0.startswith("age_data_file\t1\t%s\n" % it["dat"]))
        self.assertTrue(os.path.isfile(it["dat"]))
        inc = read(it["include_path"])
        self.assertIn('hrmiinput="%s"' % it["hrmiage0"], inc)
        run = H.read_json(os.path.join(self.run_dir, "run.json"))
        self.assertEqual(sorted(run["hrmi"]), ["1", "2"])
        # what rkAged needs to rebuild the corner in Maestro
        self.assertEqual(res["run_dir"], H.p(self.run_dir))
        self.assertEqual(res["test"], "test0")
        d0 = res["items"][0]["corner_def"]
        self.assertEqual(d0["name"], "FF125")
        self.assertEqual(d0["temperature"], "125")
        self.assertEqual(d0["vars"], {"VSET": "12"})
        self.assertEqual(d0["sections"], [{"model_file": "/proj/model/toplevel.scs",
                                           "section": "TOP_FF"}])
        self.assertIsNone(res["items"][1]["corner_def"])     # SS not in run.corners

    def test_select_and_reuse_after_clean(self):
        res = rk_aged.prepare(self.run_dir, stress_ids=["2"])
        self.assertEqual([i["stress_id"] for i in res["items"]], ["2"])
        rk_aged.prepare(self.run_dir, stress_ids=["1"])
        run = H.read_json(os.path.join(self.run_dir, "run.json"))
        self.assertEqual(sorted(run["hrmi"]), ["1", "2"])   # a partial prepare merges
        shutil.rmtree(os.path.join(self.run_dir, "hrmi", "1"))
        shutil.rmtree(os.path.join(self.tmp, "work"))
        run = H.read_json(os.path.join(self.run_dir, "run.json"))
        run["summary"] = {"corners": [{"key": "FF125_test0_FF125", "stress_id": "1"},
                                      {"key": "SS_test0_SS", "stress_id": "2"}]}
        rk_common.write_json(os.path.join(self.run_dir, "run.json"), run)
        res = rk_aged.prepare(self.run_dir)
        self.assertEqual([i["stress_id"] for i in res["items"]], ["2"])   # persisted copy reused
        self.assertEqual(len(res["missing"]), 1)
        self.assertEqual(res["missing"][0]["stress_id"], "1")
        self.assertIn("rerun Stress", res["missing"][0]["reason"])
        run = H.read_json(os.path.join(self.run_dir, "run.json"))
        self.assertEqual(sorted(run["hrmi"]), ["2"])        # a missing Stress is dropped

    def test_netlist_mismatch_and_cli(self):
        other = os.path.join(self.tmp, "other.scs")
        with open(other, "w") as f:
            f.write(H.NETLIST.replace("    M1 (OUT", "    M7 (OUT"))
        out = os.path.join(self.tmp, "o.json")
        rc = relkit.main(["aged-include", "--run", self.run_dir, "--stress", "1",
                          "--netlist", other, "--out", out])
        self.assertEqual(rc, 0)
        d = H.read_json(out)
        self.assertIs(d["netlist_match"], False)
        self.assertEqual(len(d["items"]), 1)

    def test_aged_delta_records_and_reports(self):
        rk_aged.prepare(self.run_dir)
        tsv = os.path.join(self.tmp, "delta.tsv")
        write_delta(tsv, [
            ["FF125_aged10y_T125_10081007", "", "gain", "test0", "1",
             "FF125_fresh_T125_10081007", "FF125_aged10y_T125_10081007",
             "20.5", "19.9", "-0.6", "-2.927"],
            ["FF125_aged10y_T125_10081007", "warn", "wave", "test0", "1",
             "FF125_fresh_T125_10081007", "FF125_aged10y_T125_10081007",
             "wave", "", "", ""]])
        out = os.path.join(self.tmp, "d.json")
        rc = relkit.main(["aged-delta", "--run", self.run_dir, "--tsv", tsv,
                          "--history", "Interactive.7", "--out", out])
        self.assertEqual(rc, 0)
        d = H.read_json(out)
        self.assertEqual((d["rows"], d["numeric_rows"]), (2, 1))
        self.assertTrue(d["table_path"].endswith("/tables/aged_delta_Interactive.7.tsv"))
        self.assertTrue(os.path.isfile(d["table_path"]))
        run = H.read_json(os.path.join(self.run_dir, "run.json"))
        self.assertEqual([e["history"] for e in run["aged_delta"]], ["Interactive.7"])
        html = read(d["html_path"])
        self.assertIn("Aged corners in Maestro (R1)", html)
        self.assertIn("Fresh vs aged", html)
        self.assertIn("FF125_aged10y_T125_10081007", html)
        self.assertIn("aged_2.scs", html)
        # recording the same history again replaces the entry
        rc = relkit.main(["aged-delta", "--run", self.run_dir, "--tsv", d["table_path"],
                          "--history", "Interactive.7", "--out", out])
        self.assertEqual(rc, 0)
        run = H.read_json(os.path.join(self.run_dir, "run.json"))
        self.assertEqual(len(run["aged_delta"]), 1)

    def test_aged_delta_rejects_other_tables(self):
        tsv = os.path.join(self.tmp, "x.tsv")
        rk_common.write_tsv(tsv, ["_inst", "Device"], [["I0.M1", "M1"]])
        with self.assertRaises(rk_common.RkError):
            rk_aged.record_delta(self.run_dir, tsv, "h")
        with self.assertRaises(rk_common.RkError):
            rk_aged.record_delta(self.run_dir, os.path.join(self.tmp, "none.tsv"), "h")

    def test_wrong_type(self):
        run = H.read_json(os.path.join(self.run_dir, "run.json"))
        run["type"] = "deos"
        rk_common.write_json(os.path.join(self.run_dir, "run.json"), run)
        with self.assertRaises(rk_common.RkError):
            rk_aged.prepare(self.run_dir)


if __name__ == "__main__":
    unittest.main()
