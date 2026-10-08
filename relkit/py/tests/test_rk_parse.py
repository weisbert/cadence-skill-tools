"""rk_parse: parsers on synthetic fixtures with the real files' layouts, and collect."""

import os
import shutil
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rkt_helpers as H  # noqa: E402
import rk_common  # noqa: E402
import rk_parse  # noqa: E402
import relkit  # noqa: E402

FX = os.path.join(H.FIXTURES, "parse")


def fx(name):
    return os.path.join(FX, name)


def put(src, dst):
    d = os.path.dirname(dst)
    if not os.path.isdir(d):
        os.makedirs(d)
    shutil.copyfile(fx(src), dst)


def make_run(tmp, run_type, corner_map):
    run_dir = os.path.join(tmp, "run")
    os.makedirs(run_dir)
    rs = {"aging": "analog_aging", "deos": "dynamic_eos", "emir": "emir"}[run_type]
    type_dir = os.path.join(tmp, "work", rs)
    os.makedirs(type_dir)
    run = {"schema": 1, "id": "20261008-100700_%s" % run_type, "type": run_type, "rs_type": rs,
           "run_dir": H.p(run_dir), "type_dir": H.p(type_dir), "corner_map": corner_map,
           "state": "summarizing", "timeline": []}
    rk_common.write_json(os.path.join(run_dir, "run.json"), run)
    return run_dir, type_dir


class HelpersTest(unittest.TestCase):
    def test_fnum(self):
        self.assertEqual(rk_parse.fnum("9.00e+00"), 9.0)
        self.assertEqual(rk_parse.fnum("71.25%"), 71.25)
        self.assertEqual(rk_parse.fnum("21.30mv"), 21.3)
        self.assertEqual(rk_parse.fnum("3.79e-08(1)"), 3.79e-08)
        self.assertIsNone(rk_parse.fnum("NULL"))
        self.assertIsNone(rk_parse.fnum("pass"))

    def test_split_cell(self):
        c = rk_parse.split_cell("9.00e+00#@#I0.X1.I8.MP0(pch_a.31)#@#I0.X1.I8.MP0")
        self.assertEqual((c["value"], c["device"], c["model"]), (9.0, "I0.X1.I8.MP0", "pch_a.31"))
        c = rk_parse.split_cell("71.25%#@#Violation_Number:0#*#limit:100%#@#(12.000,-40.000)")
        self.assertEqual(c["value"], 71.25)
        self.assertIsNone(c["device"])
        c = rk_parse.split_cell("21.30mv#@#limit:41#@#XXI0/XX2/MMP1@1")
        self.assertEqual((c["value"], c["device"]), (21.3, "XXI0/XX2/MMP1@1"))
        c = rk_parse.split_cell("pass#@#I0.X1.MP0(pch_a)#@#I0.X1.MP0")
        self.assertIsNone(c["value"])
        self.assertEqual(c["device"], "I0.X1.MP0")

    def test_aligned_table_positional_fallback(self):
        lines = ["A    B          C", "1    has space  x", "2    y          z"]
        h, rows = rk_parse.parse_aligned_table(lines)
        self.assertEqual(h, ["A", "B", "C"])
        self.assertEqual(rows[0], {"A": "1", "B": "has space", "C": "x"})
        self.assertEqual(rows[1], {"A": "2", "B": "y", "C": "z"})

    def test_summary_real_layout(self):
        with open(fx("aging_summary.txt"), encoding="utf-8") as f:
            h, rows = rk_parse.parse_aligned_table(f.read().splitlines())
        self.assertEqual(len(h), 24)
        self.assertEqual(rows[0]["Str_Corner"], "FF125")
        self.assertEqual(rows[1]["Pass/Fail"], "Fail")
        self.assertEqual(rows[0]["dvtlin_IO(BTI,V)"], "NULL")

    def test_dfr0(self):
        h, rows = rk_parse.parse_dfr0(fx("aging.hrmideg1.dfr0"))
        self.assertEqual(h[0], "Instance")
        self.assertEqual([r[0] for r in rows][:2], ["I0.X9.M7", "I0.X1.I4.I3.M2"])  # |didsat| desc
        h, rows = rk_parse.parse_dfr0(fx("aging.hrmideg1.dfr0"), limit=2)
        self.assertEqual(len(rows), 2)

    def test_eos_full(self):
        cols, rows, total = rk_parse.parse_eos_full(fx("deos_eos_full.rpt"))
        self.assertEqual(cols[0], "Device_Name")
        self.assertEqual(len(cols), 11)
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0]["Violation"], "vgs/vgd")
        self.assertEqual(rows[3]["Violation"], "vds_on")
        self.assertFalse(rk_parse.eos_row_violates(rows[0]))
        self.assertTrue(rk_parse.eos_row_violates(rows[3]))

    def test_max_voltage(self):
        d = rk_parse.parse_max_voltage(fx("deos_max_voltage.rpt"))
        self.assertEqual(d["Total_Mos_Number"], 55)
        self.assertEqual(d["Vds_Violation_Number"], 1)
        self.assertAlmostEqual(d["Total_DPM_Value"], 5.197822e-08)

    def test_em_ir_power(self):
        self.assertEqual(rk_parse.parse_em_worst(fx("emir.em.worst.avg.empty")), [])
        rows = rk_parse.parse_em_worst(fx("emir.em.worst.avg.viol"))
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["layer"], "M2")
        self.assertEqual(rows[0]["ratio"], 135.2)
        self.assertEqual(rows[0]["net"], "net_out")
        ir = rk_parse.parse_ir_worst(fx("emir.ir.worst"), limit=3)
        self.assertEqual(len(ir), 3)
        self.assertEqual(ir[0]["net"], "VDD")
        self.assertAlmostEqual(ir[0]["drop_mv"], 21.3)
        self.assertEqual(ir[0]["location"], "(13.500,-40.750)")
        pw = rk_parse.parse_power_summary(fx("emir_power_summary.rpt"))
        self.assertAlmostEqual(pw["total_W"], 4.2731e-04)


class CollectTest(unittest.TestCase):
    def setUp(self):
        self.tmp = H.tmpdir()

    def tearDown(self):
        H.rmtree(self.tmp)

    def test_aging(self):
        cmap = [{"key": "FF125_test0_FF125", "corner": "FF125", "sim": "sim1"},
                {"key": "SS_t-40_test0_SS_t-40", "corner": "SS_t-40", "sim": "sim2"}]
        run_dir, td = make_run(self.tmp, "aging", cmap)
        put("aging_summary.txt", os.path.join(td, "summary_rpt", "summary.txt"))
        put("aging_summary_id.yml", os.path.join(td, "summary_rpt", "summary_id.yml"))
        put("aging_mapping.txt", os.path.join(td, "mapping.txt"))
        put("aging.hrmideg1.dfr0", os.path.join(td, "sim1", "10y_point", "Stress_1",
                                                "amp_core_Stress_1.hrmideg1.dfr0"))
        res = rk_parse.collect(run_dir)
        self.assertEqual(res["type"], "aging")
        self.assertIs(res["pass"], False)
        c1, c2 = res["corners"]
        self.assertEqual((c1["key"], c1["corner"], c1["stress_id"], c1["pass"]),
                         ("FF125_test0_FF125", "FF125", "1", True))
        self.assertEqual(c1["worst_device"], "I0.X1.I8.MP0")
        self.assertEqual(c1["worst_model"], "pch_a.31")
        self.assertEqual(c1["metrics"]["didsat(HCI+BTI,%)"], 7.83)
        self.assertIsNone(c1["metrics"]["dvtlin_IO(HCI+BTI,V)"])
        self.assertIs(c2["pass"], False)
        self.assertIsNone(c2["table_path"])           # sim2 has no dfr0 in this fixture
        h, rows = read_tsv(c1["table_path"])
        self.assertEqual(h[:3], ["_inst", "_sev", "Instance"])
        self.assertEqual(rows[0][0], "I0.X9.M7")
        self.assertEqual(rows[0][1], "fail")          # |-29.46| >= 20
        self.assertEqual(rows[1][1], "warn")          # 17.12
        self.assertEqual(rows[2][1], "")
        sh, srows = read_tsv(res["summary_table_path"])
        self.assertEqual(sh[:6], ["_key", "_sev", "Corner", "Stress", "Temp", "Pass"])
        self.assertEqual(srows[1][1], "fail")
        run = H.read_json(os.path.join(run_dir, "run.json"))
        self.assertTrue(run["summary_ready"])
        self.assertEqual(run["summary"]["n_corners"], 2)
        self.assertTrue(os.path.isfile(os.path.join(run_dir, "summary.json")))

    def test_deos(self):
        cmap = [{"key": "FF125_test0_FF125", "corner": "FF125", "sim": "sim1"},
                {"key": "SS_t-40_test0_SS_t-40", "corner": "SS_t-40", "sim": "sim2"}]
        run_dir, td = make_run(self.tmp, "deos", cmap)
        put("deos_summary.txt", os.path.join(td, "summary_rpt", "summary.txt"))
        put("deos_mapping.txt", os.path.join(td, "mapping.txt"))
        for sim in ("sim1", "sim2"):
            put("deos_eos_full.rpt", os.path.join(td, sim, "eos_spectre", "amp_core_eos_full.rpt"))
            put("deos_max_voltage.rpt", os.path.join(td, sim, "eos_spectre", "max_voltage.rpt"))
        res = rk_parse.collect(run_dir)
        c1, c2 = res["corners"]
        self.assertIs(c1["pass"], True)
        self.assertIs(c2["pass"], False)
        self.assertAlmostEqual(c1["metrics"]["Total_DPM"], 5.19e-08)
        self.assertEqual(c1["metrics"]["vds"], 1)
        self.assertEqual(c1["metrics"]["n_mos"], 55)
        self.assertEqual(c1["metrics"]["violations"], 1)
        self.assertEqual(c1["metrics"]["Vgs/Vgd_Core"], "pass")
        self.assertEqual(c2["metrics"]["Vds_Core"], "fail")
        self.assertEqual(c2["worst_device"], "I0.X2.M1")
        h, rows = read_tsv(c1["table_path"])
        self.assertEqual(h[:4], ["_inst", "_sev", "Violation", "Device_Name"])
        self.assertEqual(rows[0][0], "I0.X2.M1")      # highest DPM first
        self.assertEqual(rows[0][1], "fail")
        self.assertEqual(rows[1][1], "")

    def test_emir(self):
        cmap = [{"key": "FF125_test0_FF125_0", "corner": "FF125", "sim": "sim1"}]
        run_dir, td = make_run(self.tmp, "emir", cmap)
        put("emir_summary.txt", os.path.join(td, "summary_rpt", "summary.txt"))
        put("emir_mapping.txt", os.path.join(td, "mapping.txt"))
        ads = os.path.join(td, "amp_core", "sim1", "pwr_sig_sh_em", "adsRpt")
        put("emir.em.worst.avg.empty", os.path.join(ads, "Dynamic", "amp_core.em.worst.avg"))
        put("emir.em.worst.avg.viol", os.path.join(ads, "SignalEM", "amp_core.em.worst.avg"))
        put("emir.ir.worst", os.path.join(ads, "Dynamic", "amp_core.ir.worst"))
        put("emir_power_summary.rpt", os.path.join(ads, "power_summary.rpt"))
        res = rk_parse.collect(run_dir)
        c = res["corners"][0]
        self.assertEqual(c["key"], "FF125_test0_FF125_0")
        self.assertEqual(c["corner"], "FF125")
        self.assertIs(c["pass"], True)
        m = c["metrics"]
        self.assertEqual(m["Pwr_AVG_pct"], 71.25)
        self.assertEqual(m["Sig_AVG_violations"], 0)
        self.assertEqual(m["IR_VDD_mV"], 21.3)
        self.assertEqual(m["IR_VSS_A_mV"], 15.6)
        self.assertEqual(m["Dev_Dtemp"], 2.87)
        self.assertAlmostEqual(m["Total_Power_W"], 4.2731e-04)
        self.assertEqual(c["worst_device"], "XXI0/XX2/MMP1@1")
        self.assertEqual(c["ir_worst"][0]["limit"], 41.0)
        h, rows = read_tsv(c["table_path"])
        self.assertEqual(h, ["_inst", "_sev", "Kind", "Mode", "Layer", "Location", "Value", "Net",
                             "Detail"])
        em = [r for r in rows if r[2] == "EM"]
        self.assertEqual(len(em), 2)
        self.assertEqual(em[0][1], "fail")
        self.assertEqual(em[0][3], "SignalEM/avg")
        irw = [r for r in rows if r[2] == "IR worst"]
        self.assertEqual(irw[0][0], "XXI0/XX2/MMP1@1")
        self.assertEqual(len([r for r in rows if r[2] == "IR"]), 4)

    def test_missing_raw_data_uses_saved_summary(self):
        cmap = [{"key": "FF125_test0_FF125", "corner": "FF125", "sim": "sim1"}]
        run_dir, td = make_run(self.tmp, "deos", cmap)
        put("deos_summary.txt", os.path.join(td, "summary_rpt", "summary.txt"))
        rk_parse.collect(run_dir)
        shutil.rmtree(os.path.dirname(td))
        res = rk_parse.collect(run_dir)
        self.assertIs(res["raw_data_present"], False)
        self.assertEqual(len(res["corners"]), 2)

    def test_no_summary_is_an_error(self):
        run_dir, td = make_run(self.tmp, "aging", [])
        out = os.path.join(self.tmp, "o.json")
        self.assertEqual(relkit.main(["collect", "--run", run_dir, "--out", out]), 1)
        self.assertIn("no RelStudio summary", H.read_json(out)["error"])


def read_tsv(path):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().splitlines()
    return lines[0].split("\t"), [l.split("\t") for l in lines[1:]]


if __name__ == "__main__":
    unittest.main()
