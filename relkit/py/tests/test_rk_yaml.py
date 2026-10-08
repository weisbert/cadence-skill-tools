"""rk_yaml: emitter rules (GUI style) and the subset loader."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import rk_yaml  # noqa: E402
from rk_yaml import Tagged, dump, load  # noqa: E402


class EmitTest(unittest.TestCase):
    def test_scalars(self):
        self.assertEqual(rk_yaml.scalar(None), "~")
        self.assertEqual(rk_yaml.scalar(True), "true")
        self.assertEqual(rk_yaml.scalar(False), "false")
        self.assertEqual(rk_yaml.scalar(125), "125")
        self.assertEqual(rk_yaml.scalar(-40), "-40")
        self.assertEqual(rk_yaml.scalar(0.82), "0.82")
        self.assertEqual(rk_yaml.scalar(110.0), "110.0")
        self.assertEqual(rk_yaml.scalar(1e-05), "1.0e-05")

    def test_plain_vs_quoted_strings(self):
        for s in ("0n", "20n", "years", "DYN SEM", "$MODEL_ROOT/alps/toplevel.scs", "+aps",
                  "2026-10-08 09:43:24", "x", "/opt/a//b.scs", "1P5M_EXAMPLE", "0.9V_1.5V"):
            self.assertEqual(rk_yaml.scalar(s), s, s)
        self.assertEqual(rk_yaml.scalar(""), '""')
        self.assertEqual(rk_yaml.scalar("10"), '"10"')
        self.assertEqual(rk_yaml.scalar("true"), '"true"')
        self.assertEqual(rk_yaml.scalar("~"), '"~"')
        self.assertEqual(rk_yaml.scalar("alps -p 8 "), '"alps -p 8 "')
        self.assertEqual(rk_yaml.scalar('"<" "\\<" ">" "\\>"'),
                         '"\\"<\\" \\"\\\\<\\" \\">\\" \\"\\\\>\\""')
        self.assertEqual(rk_yaml.scalar("a: b"), '"a: b"')
        self.assertEqual(rk_yaml.scalar("- x"), '"- x"')
        self.assertEqual(rk_yaml.scalar("#x"), '"#x"')

    def test_tagged(self):
        self.assertEqual(rk_yaml.scalar(Tagged("10")), "!!str 10")
        self.assertEqual(rk_yaml.scalar(Tagged("VSET*0.0125+0.7")), "!!str VSET*0.0125+0.7")
        self.assertEqual(rk_yaml.scalar(Tagged("FF125")), "!!str FF125")
        self.assertEqual(rk_yaml.scalar(Tagged("a: b")), '!!str "a: b"')
        self.assertEqual(rk_yaml.scalar(Tagged('"q"')), '!!str "\\"q\\""')

    def test_gui_layout(self):
        doc = {"Simulation": {"Corners": {"K": [
            {"Aged_1": {"Mode_Type": "Aged", "Mode_Name": Tagged("FF125"),
                        "Model_File": ["$MODEL_ROOT/alps/toplevel.scs"],
                        "Time_Windows": [{"State_1": {"Life_Time": [Tagged("10")]}}],
                        "Parameter_Groups": None}},
            {"Stress_1": {"Mode_Type": "Stress"}}]}, "History": 2},
            "Common": {"rerunDir": "", "E": {}, "L": []}}
        expect = "\n".join([
            "Simulation:",
            "  Corners:",
            "    K:",
            "      - Aged_1:",
            "          Mode_Type: Aged",
            "          Mode_Name: !!str FF125",
            "          Model_File:",
            "            - $MODEL_ROOT/alps/toplevel.scs",
            "          Time_Windows:",
            "            - State_1:",
            "                Life_Time:",
            "                  - !!str 10",
            "          Parameter_Groups: ~",
            "      - Stress_1:",
            "          Mode_Type: Stress",
            "  History: 2",
            "Common:",
            '  rerunDir: ""',
            "  E: {}",
            "  L: []",
            ""])
        self.assertEqual(dump(doc), expect)

    def test_list_item_is_flat_dict(self):
        self.assertEqual(dump([{"a": 1, "b": 2}, "x"]), "- a: 1\n  b: 2\n- x\n")


class LoadTest(unittest.TestCase):
    def test_round_trip(self):
        doc = {"A": {"b": [1, -2, 0.5, "0n", None, True, False, "", "10", Tagged("7")],
                     "c": {"d": {"e": "x y"}}, "f": [{"g": 1, "h": [{"i": "j"}]}],
                     "q": '"<" "\\<"', "t": "alps -p 8 ", "e": {}, "l": []}}
        back = load(dump(doc))
        self.assertEqual(back["A"]["b"], [1, -2, 0.5, "0n", None, True, False, "", "10", "7"])
        self.assertEqual(back["A"]["c"], {"d": {"e": "x y"}})
        self.assertEqual(back["A"]["f"], [{"g": 1, "h": [{"i": "j"}]}])
        self.assertEqual(back["A"]["q"], '"<" "\\<"')
        self.assertEqual(back["A"]["t"], "alps -p 8 ")
        self.assertEqual(back["A"]["e"], {})
        self.assertEqual(back["A"]["l"], [])

    def test_keep_tags(self):
        d = load("a: !!str 10\nb:\n  - !!str x\n", keep_tags=True)
        self.assertIsInstance(d["a"], Tagged)
        self.assertEqual(d["a"].value, "10")
        self.assertIsInstance(d["b"][0], Tagged)
        self.assertEqual(load("a: !!str 10\n"), {"a": "10"})

    def test_gui_style_snippet(self):
        text = "\n".join([
            "Simulation:",
            "  Corners:",
            "    FF_test0_FF_0:",
            "      Mode_Type: Stress",
            '      Simulation_Cmd: "alps input.scs -p 8 "',
            "      Supplies:",
            "        Power:",
            "          VDD: 0.82",
            "        Ground:",
            "          VSS: 0",
            "      Time_State:",
            "        Is_Multi_State: false",
            "        States:",
            "          - State_1:",
            "              Start_Time: 0n",
            "              Em_Temperature: 110",
            "      Parameter_Groups: ~",
            "  Rel_Type: EMIR",
            "  History: 2",
            "Common:",
            '  rerunDir: ""',
            "  Sim_Start_Time: 2026-10-08 09:43:49",
            ""])
        d = load(text)
        c = d["Simulation"]["Corners"]["FF_test0_FF_0"]
        self.assertEqual(c["Simulation_Cmd"], "alps input.scs -p 8 ")
        self.assertEqual(c["Supplies"]["Power"]["VDD"], 0.82)
        self.assertEqual(c["Supplies"]["Ground"]["VSS"], 0)
        self.assertEqual(c["Time_State"]["States"][0]["State_1"]["Em_Temperature"], 110)
        self.assertIsNone(c["Parameter_Groups"])
        self.assertEqual(d["Simulation"]["History"], 2)
        self.assertEqual(d["Common"]["rerunDir"], "")
        self.assertEqual(d["Common"]["Sim_Start_Time"], "2026-10-08 09:43:49")

    def test_bad_indent(self):
        with self.assertRaises(rk_yaml.YamlError):
            load("a:\n  b: 1\n    c: 2\n")


if __name__ == "__main__":
    unittest.main()
