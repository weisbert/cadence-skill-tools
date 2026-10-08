"""rk_yml: yml structure (key names / order / tags as the RelStudio GUI writes them),
settings precedence, netlist helpers, emir-inputs."""

import datetime
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rkt_helpers as H  # noqa: E402
import rk_common  # noqa: E402
import rk_site  # noqa: E402
import rk_yml  # noqa: E402
import rk_yaml  # noqa: E402
import relkit  # noqa: E402
from rk_yaml import Tagged  # noqa: E402

# Key order of the GUI-generated ymls (RelStudio 4.1.x, plan 4.2).
SIM_KEYS = ["Name", "Simulator_Accuracy", "Sim_Mt", "Simulation_Options", "Simulation_Cmd",
            "Flag_Is_Delete_Simulation_Data", "Flag_Is_Save_Final_Result"]
CLUSTER_KEYS = ["Using_Cluster", "Cluster_Type", "Group", "Queue", "CPU", "Memory", "GPU",
                "Machine_Arch"]
COMMON_KEYS = ["Project_Name", "Cell_Name", "IP_Name", "Technology", "Tech_Voltage", "Tech_Layout",
               "Rel_Tool_Dir", "Rel_Tech_Dir", "Configuration_Dir", "Script_Dir", "Work_Dir",
               "Sim_Start_Time", "Sim_Machine", "User_Name", "ToolVersion", "SystemVersion",
               "rerunDir", "jobUniqueIdentifier", "Foundry"]
AGING_TOP = ["Flow_Type", "Agemos_Flag", "Selfheat_Bsim", "Corners", "Advance", "Rel_Type", "History"]
AGING_ENTRY = ["Mode_Type", "Netlist_File", "Analysis_Type", "Netlist_Format", "Model_File",
               "Relxpert_Uri_Libs", "Mode_Name", "Test_Name", "Simulator", "Cluster",
               "Skip_Simulation", "Corner_Group", "Temperature", "Time_Windows",
               "Parameter_Groups", "Parameters"]
AGING_STATE = ["Start_Time", "Stop_Time", "Life_Time", "Life_Time_Unit"]
DEOS_TOP = ["Flow_Type", "Is_Alps_Boost", "Aps", "Waveform_Debug", "Cell_Counts", "Corners",
            "Rel_Type", "History"]
DEOS_ENTRY = ["Mode_Type", "Netlist_File", "Mode_Name", "Test_Name", "Simulator", "Cluster",
              "Skip_Simulation", "Corner_Group", "Temperature", "Time_Windows", "Parameter_Groups",
              "Parameters"]
DEOS_STATE = ["Start_Time", "Stop_Time", "Life_Time", "Simulation_Time", "Life_Time_Unit",
              "Tddb_Temperature"]
EMIR_TOP = ["Corners", "Rel_Type", "History"]
EMIR_ENTRY = ["Mode_Type", "Netlist_File", "Flow_Type", "isNewPredictFlow", "Run_Type",
              "Is_Run_Selfheat", "Is_Calibre_Flow", "Sim_Cell", "Instance_Name", "Gds_File",
              "Dspf_File", "Gds_Map_File", "Method", "Sim_Temperature", "Rc_Temperature",
              "Rc_Corner", "Advance", "Supplies", "Limits", "Mode_Name", "Test_Name", "Simulator",
              "Cluster", "Skip_Simulation", "Corner_Group", "Time_State", "Parameter_Groups",
              "Parameters"]
EMIR_STATE = ["Start_Time", "Stop_Time", "Dynamic_Time_Step", "Em_Temperature", "Life_Time",
              "Life_Time_Unit"]
TOTEM_KEYS = ["Is_Multi_Process", "Is_Gui_Background", "Switch_Model_Table", "Is_Dyn_Ldo",
              "Is_Top_Analysis", "Is_Cmm", "Vp_Pairing", "Is_Post_Sim", "Is_Internal_Pin",
              "Is_Fem_Calculate", "Is_Fit_Calculate", "Is_Heat_Sink", "Macro_Type", "Is_No_Ace",
              "Is_Extract_View_Netlist", "Probe_Bus_Delimiter_Checked", "Probe_Bus_Delimiter",
              "Apache_Db_Dir", "Auto_Ploc_Cmd", "Files_To_Delete", "Pad_Location_File"]
LIMIT_KEYS = ["Dynamic_IR_Limits", "IR_AVG_Limits", "IR_MAX_Limit", "IR_MIN_Limit",
              "Power_EM_AVG_Limits", "Power_EM_Peak_Limits", "Power_EM_RMS_Limits",
              "Signal_EM_AVG_Limits", "Signal_EM_Peak_Limits", "Signal_EM_RMS_Limits",
              "Static_EM_Limits", "Static_IR_Limits"]
NOW = datetime.datetime(2026, 10, 8, 10, 7, 0)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = H.tmpdir()
        self.wa, self.sp, self.net = H.make_workarea(self.tmp)

    def tearDown(self):
        H.rmtree(self.tmp)

    def build(self, run_type, ctx=None, site_over=None, **kw):
        ctx = ctx or H.make_ctx(self.wa, self.sp, self.net, run_type)
        site, _p, _w = rk_site.site_from_ctx(ctx)
        if site_over:
            site.update(site_over)
        return rk_yml.build_doc(ctx, site, run_type, "/scratch/jdoe/rs/tb_top/amp_core/relsim1/3",
                                3, now=NOW, host="host01",
                                tools={"alps": "/opt/alps/bin/alps"},
                                sysver="TestOS 1", **kw)


class AgingYmlTest(Base):
    def test_structure_and_order(self):
        doc, info = self.build("aging")
        self.assertEqual(list(doc), ["Simulation", "Common"])
        sim = doc["Simulation"]
        self.assertEqual(list(sim), AGING_TOP)
        self.assertEqual(sim["Rel_Type"], "AnalogAging")
        self.assertEqual(sim["History"], 3)
        self.assertEqual(sim["Advance"], {"Tmi_Option": None, "Alps_Flow": {
            "en_level": 7, "r_bti_core_nmos": 1, "r_bti_core_pmos": 1, "r_bti_io_nmos": 1,
            "r_bti_io_pmos": 1}})
        self.assertEqual(list(sim["Corners"]), ["FF125_test0_FF125", "SS_t-40_test0_SS_t-40"])
        self.assertEqual(info["corner_keys"], list(sim["Corners"]))
        items = sim["Corners"]["FF125_test0_FF125"]
        self.assertEqual([list(i)[0] for i in items], ["Aged_1", "Stress_1"])
        aged, stress = items[0]["Aged_1"], items[1]["Stress_1"]
        self.assertEqual(list(aged), AGING_ENTRY)
        self.assertEqual(aged["Mode_Type"], "Aged")
        self.assertEqual(stress["Mode_Type"], "Stress")
        self.assertEqual(list(aged["Simulator"]), SIM_KEYS)
        self.assertEqual(aged["Simulator"]["Simulation_Cmd"],
                         "alps -errpreset moderate +mt 8 -lqtimeout -closelink -d")
        self.assertEqual(list(aged["Cluster"]), CLUSTER_KEYS)
        self.assertEqual(aged["Cluster"]["Group"], "example_group")
        self.assertEqual(aged["Skip_Simulation"], {"Flag": False})
        self.assertEqual(aged["Mode_Name"], Tagged("FF125"))
        self.assertIsInstance(aged["Mode_Name"], Tagged)
        self.assertIsInstance(aged["Test_Name"], Tagged)
        self.assertEqual(aged["Corner_Group"], {"FF125": {
            "Model_File": ["$MODEL_ROOT/alps/toplevel.scs"] * 2, "Sections": ["TOP_FF", "pre_sim"]}})
        self.assertEqual(aged["Temperature"], [125])
        st = aged["Time_Windows"][0]["State_1"]
        self.assertEqual(list(st), AGING_STATE)
        self.assertEqual(st["Life_Time"], [Tagged("10")])
        self.assertEqual(aged["Model_File"], "/opt/rel_tech_lib/aging/hrmiagefile.scs")
        self.assertEqual(aged["Netlist_File"], self.net)
        # parameters: netlist + global vars + corner override; sorted; !!str one-element lists
        self.assertEqual(list(aged["Parameters"]), ["EN2", "VDDA", "VSET", "fin", "vin"])
        self.assertEqual(aged["Parameters"]["VSET"], [Tagged("12")])
        self.assertEqual(aged["Parameters"]["VDDA"], [Tagged("VSET*0.0125+0.7")])
        ss = sim["Corners"]["SS_t-40_test0_SS_t-40"][1]["Stress_1"]
        self.assertEqual(ss["Parameters"]["VSET"], [Tagged("10")])
        self.assertEqual(ss["Temperature"], [-40])
        self.assertEqual(info["corner_map"][1], {"key": "SS_t-40_test0_SS_t-40", "corner": "SS_t-40",
                                                 "sim": "sim2", "temperature": "-40",
                                                 "mode": "Stress_1", "eval_temperatures": ["-40"]})

    def test_common(self):
        doc, _ = self.build("aging")
        com = doc["Common"]
        self.assertEqual(list(com), COMMON_KEYS)
        self.assertEqual(com["Project_Name"], Tagged("relsim1"))
        self.assertEqual(com["Cell_Name"], Tagged("amp_core"))   # D13: DUT cell
        self.assertEqual(com["IP_Name"], Tagged("tb_top"))
        self.assertEqual(com["Technology"], 999)
        self.assertEqual(com["Rel_Tool_Dir"], H.FAKE_HOME)
        self.assertEqual(com["Script_Dir"], H.FAKE_HOME + "/script/analog_aging")
        self.assertEqual(com["Work_Dir"], "/scratch/jdoe/rs/tb_top/amp_core/relsim1/3")
        self.assertEqual(com["Sim_Start_Time"], "2026-10-08 10:07:00")
        self.assertEqual(com["Configuration_Dir"], self.wa)
        self.assertEqual(com["User_Name"], "jdoe")
        self.assertEqual(com["rerunDir"], "")
        self.assertEqual(com["jobUniqueIdentifier"], "")
        self.assertEqual(com["Foundry"], "x")

    def test_no_toolversion_when_nothing_found(self):
        ctx = H.make_ctx(self.wa, self.sp, self.net, "aging")
        site, _p, _w = rk_site.site_from_ctx(ctx)
        doc, info = rk_yml.build_doc(ctx, site, "aging", "/w/1", 1, tools={})
        self.assertNotIn("ToolVersion", doc["Common"])

    def test_eval_temperatures_entries(self):
        ctx = H.make_ctx(self.wa, self.sp, self.net, "aging",
                         settings={"aging": {"eval_temperatures": ["-40", "125"], "life_time": "5"}})
        doc, info = self.build("aging", ctx=ctx)
        items = doc["Simulation"]["Corners"]["FF125_test0_FF125"]
        self.assertEqual([list(i)[0] for i in items], ["Aged_1", "Aged_2", "Stress_1"])
        self.assertEqual(items[0]["Aged_1"]["Temperature"], [-40])
        self.assertEqual(items[1]["Aged_2"]["Temperature"], [125])
        self.assertEqual(items[2]["Stress_1"]["Temperature"], [125])
        self.assertEqual(items[2]["Stress_1"]["Time_Windows"][0]["State_1"]["Life_Time"],
                         [Tagged("5")])
        self.assertEqual(info["corner_map"][0]["eval_temperatures"], ["-40", "125"])

    def test_eval_temperatures_list_layout(self):
        ctx = H.make_ctx(self.wa, self.sp, self.net, "aging",
                         settings={"aging": {"eval_temperatures": "-40, 125"}})
        doc, _ = self.build("aging", ctx=ctx, site_over={"aging_eval_layout": "temperature_list"})
        items = doc["Simulation"]["Corners"]["FF125_test0_FF125"]
        self.assertEqual([list(i)[0] for i in items], ["Aged_1", "Stress_1"])
        self.assertEqual(items[0]["Aged_1"]["Temperature"], [-40, 125])

    def test_dump_text(self):
        doc, _ = self.build("aging")
        text = rk_yaml.dump(doc)
        self.assertIn("\n          Mode_Name: !!str FF125\n", text)
        self.assertIn("\n                  - !!str 10\n", text)
        self.assertIn("\n              - !!str VSET*0.0125+0.7\n", text)
        self.assertIn("\n          Parameter_Groups: ~\n", text)
        self.assertIn('\n  rerunDir: ""\n', text)
        self.assertIn("\n  Project_Name: !!str relsim1\n", text)
        self.assertTrue(text.startswith("Simulation:\n  Flow_Type: Native\n  Agemos_Flag: false\n"))
        back = rk_yaml.load(text)
        self.assertEqual(back["Simulation"]["Corners"]["FF125_test0_FF125"][0]["Aged_1"]["Temperature"],
                         [125])

    def test_errors(self):
        ctx = H.make_ctx(self.wa, self.sp, self.net, "aging")
        for c in ctx["corners"]:
            c["selected"] = False
        with self.assertRaises(rk_common.RkError):
            self.build("aging", ctx=ctx)
        ctx = H.make_ctx(self.wa, self.sp, self.net, "aging")
        ctx["dut"] = None
        with self.assertRaises(rk_common.RkError):
            self.build("aging", ctx=ctx)

    def test_parameters_from_ctx_when_netlist_unreadable(self):
        ctx = H.make_ctx(self.wa, self.sp, self.net, "aging")
        ctx["netlist"]["path"] = "/not/here.scs"
        ctx["netlist"]["parameters"] = {"VSET": "10", "ZZ": "3"}
        doc, info = self.build("aging", ctx=ctx)
        aged = doc["Simulation"]["Corners"]["FF125_test0_FF125"][0]["Aged_1"]
        self.assertEqual(list(aged["Parameters"]), ["VSET", "ZZ", "vin"])
        self.assertFalse(any("not readable" in w for w in info["warnings"]))

    def test_model_file_map(self):
        site = {"model_file_map": [{"match": r"^/proj/model/(\w+)\.scs$",
                                    "replace": r"$MODEL_ROOT/spectre/\1.scs"}]}
        self.assertEqual(rk_yml.map_model_file("/proj/model/toplevel.scs", site),
                         "$MODEL_ROOT/spectre/toplevel.scs")
        self.assertEqual(rk_yml.map_model_file("/other/x.lib", site), "/other/x.lib")


class DeosYmlTest(Base):
    def test_structure(self):
        ctx = H.make_ctx(self.wa, self.sp, self.net, "deos",
                         settings={"deos": {"tddb_temperature": 105}})
        doc, info = self.build("deos", ctx=ctx)
        sim = doc["Simulation"]
        self.assertEqual(list(sim), DEOS_TOP)
        self.assertEqual(sim["Aps"], "+aps")
        self.assertEqual(sim["Cell_Counts"], 1)
        self.assertEqual(sim["Rel_Type"], "DynamicEOS")
        e = sim["Corners"]["FF125_test0_FF125"]
        self.assertEqual(list(e), DEOS_ENTRY)
        self.assertEqual(e["Mode_Type"], "Stress")
        st = e["Time_Windows"][0]["State_1"]
        self.assertEqual(list(st), DEOS_STATE)
        self.assertEqual(st["Life_Time"], 10)
        self.assertEqual(st["Simulation_Time"], "20n")
        self.assertEqual(st["Tddb_Temperature"], 105)
        self.assertEqual(doc["Common"]["Script_Dir"], H.FAKE_HOME + "/script/dynamic_eos")

    def test_tddb_defaults_to_corner_temperature(self):
        doc, _ = self.build("deos")
        st = doc["Simulation"]["Corners"]["SS_t-40_test0_SS_t-40"]["Time_Windows"][0]["State_1"]
        self.assertEqual(st["Tddb_Temperature"], -40)


class EmirYmlTest(Base):
    def test_structure(self):
        doc, info = self.build("emir")
        sim = doc["Simulation"]
        self.assertEqual(list(sim), EMIR_TOP)
        self.assertEqual(sim["Rel_Type"], "EMIR")
        self.assertEqual(list(sim["Corners"]), ["FF125_test0_FF125_0", "SS_t-40_test0_SS_t-40_0"])
        e = sim["Corners"]["FF125_test0_FF125_0"]
        self.assertEqual(list(e), EMIR_ENTRY)
        self.assertEqual(e["Flow_Type"], "Totem")
        self.assertEqual(e["Run_Type"], "DYN SEM")
        self.assertIs(e["Is_Run_Selfheat"], True)
        self.assertEqual(e["Sim_Cell"], "amp_core")
        self.assertEqual(e["Instance_Name"], "I0")
        self.assertEqual(e["Sim_Temperature"], [125])
        self.assertEqual(e["Rc_Temperature"], 125)
        self.assertEqual(e["Rc_Corner"], "typical")
        self.assertEqual(e["Method"], "iterated")
        self.assertEqual(e["Gds_Map_File"], "/opt/rel_tech_lib/em/gds/gds.map")
        self.assertEqual(list(e["Advance"]), ["Totem_Flow", "Patron_Flow", "Predict_Flow"])
        self.assertEqual(list(e["Advance"]["Totem_Flow"]), TOTEM_KEYS)
        self.assertEqual(e["Advance"]["Totem_Flow"]["Probe_Bus_Delimiter"], '"<" "\\<" ">" "\\>"')
        self.assertEqual(e["Supplies"], {"Power": {"VDD": 0.825}, "Ground": {"VSS": 0, "VSUB": 0}})
        self.assertEqual(list(e["Limits"]), LIMIT_KEYS)
        self.assertEqual(e["Limits"]["Static_IR_Limits"], 3)
        self.assertEqual(e["Skip_Simulation"], {"Flag": False, "Start_Step": 0, "Is_Run_Through": True})
        self.assertEqual(e["Simulator"]["Simulation_Cmd"],
                         "alps input.scs -format fsdb -ade -o SIM_DIR/psf -p 8 -errpreset moderate ")
        ts = e["Time_State"]
        self.assertEqual(ts["Is_Multi_State"], False)
        self.assertEqual(list(ts["States"][0]["State_1"]), EMIR_STATE)
        self.assertEqual(ts["States"][0]["State_1"]["Em_Temperature"], 110)
        self.assertEqual(doc["Common"]["Script_Dir"], H.FAKE_HOME + "/script/em")
        text = rk_yaml.dump(doc)
        self.assertIn('      Simulation_Cmd: "alps input.scs -format fsdb -ade -o SIM_DIR/psf -p 8 '
                      '-errpreset moderate "\n', text)
        self.assertIn('          Probe_Bus_Delimiter: "\\"<\\" \\"\\\\<\\" \\">\\" \\"\\\\>\\""\n', text)

    def test_overrides(self):
        ctx = H.make_ctx(self.wa, self.sp, self.net, "emir", settings={"emir": {
            "limits": {"Static_IR_Limits": "4"}, "rc_temperature": 55, "selfheat": False,
            "run_type": "STA"}})
        doc, _ = self.build("emir", ctx=ctx, site_over={"emir": dict(
            rk_site.get(rk_site.site_from_ctx(ctx)[0], "emir"),
            totem_flow={"Macro_Type": "analog"})})
        e = doc["Simulation"]["Corners"]["FF125_test0_FF125_0"]
        self.assertEqual(e["Limits"]["Static_IR_Limits"], 4)
        self.assertEqual(e["Rc_Temperature"], 55)
        self.assertIs(e["Is_Run_Selfheat"], False)
        self.assertEqual(e["Run_Type"], "STA")
        self.assertEqual(e["Advance"]["Totem_Flow"]["Macro_Type"], "analog")


class SettingsTest(Base):
    def test_precedence(self):
        ctx = H.make_ctx(self.wa, self.sp, self.net, "aging",
                         settings={"aging": {"life_time": None, "stop_time": "50n"}})
        site, _p, _w = rk_site.site_from_ctx(ctx)
        site["defaults"]["aging"]["life_time"] = "7"
        st = rk_yml.effective_settings(ctx, site, "aging")
        self.assertEqual(st["life_time"], "7")      # ctx null -> site default
        self.assertEqual(st["stop_time"], "50n")    # ctx wins
        self.assertEqual(st["start_time"], "0n")    # builtin
        st = rk_yml.effective_settings(ctx, site, "emir")
        self.assertEqual(st["license_policy"], "wait_forever")
        self.assertEqual(st["rc_corner"], "typical")
        self.assertEqual(st["layout_lib"], "mylib")


class NetlistTest(unittest.TestCase):
    def test_parse(self):
        nl = rk_yml.parse_netlist(text=H.NETLIST)
        self.assertEqual(nl["parameters"], {"VSET": "10", "fin": "5G", "EN2": "1", "vin": "0.2",
                                            "VDDA": "VSET*0.0125+0.7"})
        self.assertEqual(nl["subckts"]["amp_core"], ["IN", "OUT", "VDD", "VSS", "VSUB"])
        tops = {i["name"]: i for i in nl["top_instances"]}
        self.assertEqual(tops["I0"]["nodes"], ["in", "out", "vdda", "0", "0"])
        self.assertEqual(tops["I0"]["master"], "amp_core")
        self.assertEqual(tops["V0"]["params"]["dc"], "VDDA")
        self.assertNotIn("tran", tops)
        self.assertEqual(len([i for i in nl["instances"] if i["subckt"] == "amp_core"]), 3)

    def test_eval_expr(self):
        params = {"VSET": "10", "VDDA": "VSET*0.0125+0.7", "a": "b", "b": "a"}
        self.assertAlmostEqual(rk_yml.eval_expr("VDDA", params), 0.825)
        self.assertAlmostEqual(rk_yml.eval_expr("400.0m", {}), 0.4)
        self.assertAlmostEqual(rk_yml.eval_expr("5G", {}), 5e9)
        self.assertAlmostEqual(rk_yml.eval_expr("2meg", {}), 2e6)
        self.assertAlmostEqual(rk_yml.eval_expr("max(1,2)*1.5e-3", {}), 3e-3)
        self.assertIsNone(rk_yml.eval_expr("a", params))         # cycle
        self.assertIsNone(rk_yml.eval_expr("unknown+1", params))
        self.assertIsNone(rk_yml.eval_expr("__import__('os')", params))

    def test_signature(self):
        tmp = H.tmpdir()
        try:
            a = os.path.join(tmp, "a.scs")
            b = os.path.join(tmp, "b.scs")
            c = os.path.join(tmp, "c.scs")
            with open(a, "w") as f:
                f.write(H.NETLIST)
            with open(b, "w") as f:
                f.write(H.NETLIST.replace("w=2u", "w=4u").replace("VSET=10", "VSET=11"))
            with open(c, "w") as f:
                f.write(H.NETLIST.replace("    M2 (OUT", "    M9 (OUT"))
            sa = rk_yml.netlist_signature(a)
            self.assertEqual(sa, rk_yml.netlist_signature(b))
            self.assertNotEqual(sa, rk_yml.netlist_signature(c))
        finally:
            H.rmtree(tmp)


class CliTest(Base):
    def test_build_yml_cli(self):
        ctx = H.make_ctx(self.wa, self.sp, self.net, "deos")
        cp = H.write_json(os.path.join(self.tmp, "ctx.json"), ctx)
        out = os.path.join(self.tmp, "o.json")
        self.assertEqual(relkit.main(["build-yml", "--ctx", cp, "--out", out]), 0)
        d = H.read_json(out)
        self.assertTrue(d["ok"], d)
        self.assertEqual(d["rs_type"], "dynamic_eos")
        self.assertTrue(d["yml_path"].endswith("/o.yml"))
        self.assertEqual(d["rs_history"], 1)
        self.assertTrue(d["work_dir"].endswith("/rs_work/tb_top/amp_core/relsim1/1"))
        self.assertFalse(os.path.exists(d["work_dir"]))      # preview creates nothing
        y = rk_yaml.load_file(d["yml_path"])
        self.assertEqual(y["Simulation"]["Rel_Type"], "DynamicEOS")
        out2 = os.path.join(self.tmp, "o2.json")
        self.assertEqual(relkit.main(["build-yml", "--ctx", cp, "--out", out2, "--type", "emir",
                                      "--work-dir", "/w/relsim1/7",
                                      "--yml", os.path.join(self.tmp, "EM.yml")]), 0)
        d = H.read_json(out2)
        self.assertEqual(d["rs_history"], 7)
        self.assertEqual(d["corner_keys"], ["FF125_test0_FF125_0", "SS_t-40_test0_SS_t-40_0"])

    def test_emir_inputs(self):
        ctx = H.make_ctx(self.wa, self.sp, self.net, "emir")
        cp = H.write_json(os.path.join(self.tmp, "ctx.json"), ctx)
        out = os.path.join(self.tmp, "o.json")
        self.assertEqual(relkit.main(["emir-inputs", "--ctx", cp, "--out", out]), 0)
        d = H.read_json(out)
        ports = {x["name"]: x for x in d["dut_ports"]}
        self.assertEqual([x["name"] for x in d["dut_ports"]], ["IN", "OUT", "VDD", "VSS", "VSUB"])
        self.assertEqual(ports["VDD"]["kind"], "power")
        self.assertEqual(ports["VDD"]["net"], "vdda")
        self.assertEqual(ports["VDD"]["voltage"], "0.825")
        self.assertEqual(ports["IN"]["kind"], "signal")
        self.assertEqual(d["supplies"], {"power": {"VDD": "0.825"},
                                         "ground": {"VSS": "0", "VSUB": "0"}})
        self.assertEqual(d["unresolved"], [])
        self.assertTrue(d["dspf_candidates"][0].endswith("/amp_core.dspf"))
        self.assertTrue(d["gds_candidates"][0].endswith("/amp_core.gds"))


if __name__ == "__main__":
    unittest.main()
