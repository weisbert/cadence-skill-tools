"""Tests for rk_pdk (extraction parameters derived from the environment, the
Auto_ext rules) and for `extract-resolve` / `extract` on top of it, with a
synthetic PDK tree (fake_pdk.py) and the fake tools."""

import json
import os
import shutil
import sys
import tempfile
import time
import unittest

PY_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, PY_DIR)
sys.path.insert(0, TESTS_DIR)

import fake_pdk  # noqa: E402
import relkit  # noqa: E402
import rk_common  # noqa: E402
import rk_pdk  # noqa: E402
import rk_site  # noqa: E402

FAKE_DIR = os.path.join(TESTS_DIR, "fake_tools")


def defaults_extract():
    return dict(rk_site.read_json(rk_site.DEFAULTS_PATH)["extract"])


class ExprTest(unittest.TestCase):
    ENV = {"A": "/a/b/c/file.x", "B": "/opt/b", "EMPTY": ""}

    def r(self, expr):
        return rk_pdk.resolve_expr(expr, self.ENV)

    def test_forms(self):
        self.assertEqual(self.r("$B/lib"), ("/opt/b/lib", []))
        self.assertEqual(self.r("${B}/lib"), ("/opt/b/lib", []))
        self.assertEqual(self.r("$env(B)/lib"), ("/opt/b/lib", []))
        self.assertEqual(self.r("/literal/path"), ("/literal/path", []))
        self.assertEqual(self.r("$B_X"), (None, ["B_X"]))      # one token, not $B + _X
        self.assertEqual(rk_pdk.env_refs("$A ${B} $env(C) $$D"), ["C", "B", "A"])

    def test_filters(self):
        self.assertEqual(self.r("$A|parent"), ("/a/b/c", []))
        self.assertEqual(self.r("$A | parent | parent"), ("/a/b", []))
        self.assertEqual(self.r("rel|parent"), (".", []))
        with self.assertRaises(rk_common.RkError):
            self.r("$A|dirname")

    def test_escape_and_missing(self):
        self.assertEqual(self.r("$$B/x"), ("$B/x", []))
        self.assertEqual(self.r("$NOPE/x"), (None, ["NOPE"]))
        self.assertEqual(self.r("$EMPTY/x"), (None, ["EMPTY"]))   # empty counts as unset
        self.assertEqual(self.r(None), (None, []))
        self.assertEqual(rk_pdk.substitute("$NOPE/$B", self.ENV), "$NOPE//opt/b")

    def test_tech_name(self):
        env = {"PDK_LAYER_MAP_FILE": "/p/tech/t18/lm.txt"}
        self.assertEqual(rk_pdk.tech_name_from_env(["PDK_TECH_FILE", "PDK_LAYER_MAP_FILE"], env),
                         ("t18", "PDK_LAYER_MAP_FILE"))
        self.assertEqual(rk_pdk.tech_name_from_env(["PDK_TECH_FILE"], env), (None, None))

    def test_corners(self):
        cs = rk_pdk.corner_list({})
        self.assertEqual(len(cs), 9)
        self.assertEqual(rk_pdk.pick_corner(cs, "cworst")["technology_corner"], "CWORST")
        self.assertEqual(rk_pdk.pick_corner(cs, "RCBEST_T")["name"], "rcbest_t")
        self.assertIsNone(rk_pdk.pick_corner(cs, "nope"))
        self.assertEqual(rk_pdk.corner_list({"corners": ["TYPICAL"]}),
                         [{"name": "typical", "technology_corner": "TYPICAL"}])


class ResolveTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rk_pdk_").replace("\\", "/")
        self.env = fake_pdk.make_fake_pdk(self.tmp + "/pdk")
        self.ext = defaults_extract()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_defaults_resolve(self):
        r = rk_pdk.resolve(self.ext, self.env, {"power_names": ["VDD"], "ground_names": ["VSS"]})
        self.assertTrue(r["ready"], r["errors"])
        p = r["params"]
        lvs = self.tmp + "/pdk/verify/runset/Calibre_LVS/LVS/Ver_A/DEMO_LVS_R1"
        self.assertEqual(p["layer_map"], self.env["PDK_LAYER_MAP_FILE"])
        self.assertEqual(p["lvs_deck_dir"], lvs)
        self.assertEqual(p["lvs_basename"], "DEMO_LVS_R1")
        self.assertEqual(r["choices"]["variants"], ["widio", "wodio"])
        self.assertEqual(p["lvs_variant"], "wodio")
        self.assertEqual(r["resolved"]["lvs_variant"]["source"], "default")
        self.assertEqual(p["lvs_rules_file"], lvs + "/DEMO_LVS_R1.wodio.qcilvs")
        self.assertEqual(p["cdl_include_file"], lvs + "/empty.cdl")
        self.assertEqual(p["technology_library_file"], self.tmp + "/pdk/setup/assura_tech.lib")
        self.assertEqual(p["tech_name"], "demo_tech")
        self.assertTrue(p["qrc_deck_dir"].endswith("/QRC/Ver_B/DEMO_QRC_R1/QCI_deck"))
        self.assertEqual(p["qrc_query_cmd"], p["qrc_deck_dir"] + "/query_cmd")
        self.assertEqual(p["qrc_preserve_cell_list"], p["qrc_deck_dir"] + "/preserveCellList.txt")
        self.assertEqual(p["technology_corner"], "TYPICAL")
        self.assertEqual(r["missing_env"], [])
        self.assertEqual(r["resolved"]["layer_map"]["source"], "rule")

    def test_missing_env(self):
        env = dict(self.env)
        del env["calibre_source_added_place"]
        del env["VERIFY_ROOT"]
        r = rk_pdk.resolve(self.ext, env, {})
        self.assertFalse(r["ready"])
        self.assertEqual(sorted(r["missing_env"]), ["VERIFY_ROOT", "calibre_source_added_place"])
        self.assertTrue(any("$calibre_source_added_place" in e for e in r["errors"]))
        self.assertTrue(any("$VERIFY_ROOT" in e for e in r["errors"]))
        r = rk_pdk.resolve(self.ext, {}, {})
        self.assertIn("PDK_TECH_FILE", r["missing_env"])
        self.assertIn("SETUP_ROOT", r["missing_env"])

    def test_variant_choice(self):
        r = rk_pdk.resolve(self.ext, self.env, {"lvs_variant": "widio"})
        self.assertEqual(r["params"]["lvs_variant"], "widio")
        self.assertEqual(r["resolved"]["lvs_variant"]["source"], "user")
        r = rk_pdk.resolve(self.ext, self.env, {"lvs_variant": "nope"})
        self.assertTrue(any("not found" in e for e in r["errors"]))
        shutil.rmtree(self.tmp + "/pdk")
        env = fake_pdk.make_fake_pdk(self.tmp + "/pdk", variants=("a", "b"))
        r = rk_pdk.resolve(self.ext, env, {})
        self.assertTrue(any("choose the LVS variant" in e for e in r["errors"]))
        shutil.rmtree(self.tmp + "/pdk")
        env = fake_pdk.make_fake_pdk(self.tmp + "/pdk", variants=("only",))
        self.assertEqual(rk_pdk.resolve(self.ext, env, {})["params"]["lvs_variant"], "only")

    def test_qrc_multiple_and_none(self):
        shutil.rmtree(self.tmp + "/pdk")
        env = fake_pdk.make_fake_pdk(self.tmp + "/pdk", qrc_decks=2)
        r = rk_pdk.resolve(self.ext, env, {})
        self.assertEqual(len(r["choices"]["qrc_decks"]), 2)
        self.assertIsNone(r["params"]["qrc_deck_dir"])
        self.assertTrue(any("choose the Quantus deck" in e for e in r["errors"]))
        pick = r["choices"]["qrc_decks"][1]
        r = rk_pdk.resolve(self.ext, env, {"qrc_deck": pick})
        self.assertEqual(r["params"]["qrc_deck_dir"], pick)
        self.assertEqual(r["resolved"]["qrc_deck_dir"]["source"], "user")
        r = rk_pdk.resolve(self.ext, env, {"qrc_deck": "/elsewhere/QCI_deck"})
        self.assertTrue(any("is not one of" in e for e in r["errors"]))
        shutil.rmtree(self.tmp + "/pdk/verify/runset/Calibre_QRC")
        r = rk_pdk.resolve(self.ext, env, {})
        self.assertTrue(any("no Quantus deck matches" in e for e in r["errors"]))

    def test_qrc_narrowed_by_lvs_basename(self):
        root = self.tmp + "/pdk/verify/runset/Calibre_QRC/QRC/Ver_B/DEMO_LVS_R1_qrc/QCI_deck"
        fake_pdk._touch(root + "/query_cmd", "")
        fake_pdk._touch(self.tmp + "/pdk/verify/runset/Calibre_QRC/QRC/Ver_B/OTHER/QCI_deck/query_cmd", "")
        r = rk_pdk.resolve(self.ext, self.env, {})
        self.assertEqual(r["params"]["qrc_deck_dir"], root)
        self.assertEqual(r["resolved"]["qrc_deck_dir"]["source"], "derived")

    def test_overrides(self):
        ext = dict(self.ext, layer_map="/pinned/lm.txt", tech_name="pinned_tech",
                   qrc_deck_dir="$VERIFY_ROOT/custom", check_files=False)
        r = rk_pdk.resolve(ext, self.env, {"technology_corner": "rcworst", "temperature": -40})
        p = r["params"]
        self.assertEqual(p["layer_map"], "/pinned/lm.txt")
        self.assertEqual(r["resolved"]["layer_map"]["source"], "literal")
        self.assertEqual(p["tech_name"], "pinned_tech")
        self.assertEqual(p["qrc_deck_dir"], self.env["VERIFY_ROOT"] + "/custom")
        self.assertEqual(p["technology_corner"], "RCWORST")
        self.assertEqual(p["temperature"], -40)
        self.assertEqual(r["resolved"]["temperature"]["source"], "user")

    def test_legacy_keys(self):
        ext = dict(self.ext, pdk_layer_map="/old/lm.txt", power_nets=["AVDD"],
                   qrc_query_cmd="/old/qrc/query_cmd", check_files=False)
        r = rk_pdk.resolve(ext, self.env, {})
        self.assertEqual(r["params"]["layer_map"], "/old/lm.txt")
        self.assertEqual(r["params"]["power_names"], ["AVDD"])
        self.assertEqual(r["params"]["qrc_deck_dir"], "/old/qrc")
        self.assertTrue(any("obsolete" in w for w in r["warnings"]))

    def test_file_checks(self):
        os.remove(self.env["PDK_LAYER_MAP_FILE"])
        r = rk_pdk.resolve(self.ext, self.env, {})
        self.assertTrue(any("layer map not found" in e for e in r["errors"]))
        self.assertTrue(rk_pdk.resolve(dict(self.ext, check_files=False), self.env, {})["ready"])


class CliTest(unittest.TestCase):
    """extract-resolve and extract through relkit.py, env from ctx.env."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rk_pdkcli_").replace("\\", "/")
        self.env = fake_pdk.make_fake_pdk(self.tmp + "/pdk")
        self.wa = self.tmp + "/wa"
        os.makedirs(self.wa)
        with open(self.wa + "/cds.lib", "w") as f:
            f.write("DEFINE mylib ./mylib\n")
        self.site_path = self.tmp + "/site.json"
        tools = {t: [sys.executable, os.path.join(FAKE_DIR, t)]
                 for t in ("strmout", "si", "calibre", "qrc")}
        with open(self.site_path, "w", encoding="utf-8") as f:
            json.dump({"artifact_root": "${WORKAREA}/Reliability",
                       "persist_root": "${WORKAREA}/relkit_runs",
                       "extract": {"tools": tools}}, f)
        self.cfg_path = self.tmp + "/fake_tools_config.json"
        with open(self.cfg_path, "w", encoding="utf-8") as f:
            json.dump({}, f)
        self._old = os.environ.get("RELKIT_FAKE_TOOLS_CONFIG")
        os.environ["RELKIT_FAKE_TOOLS_CONFIG"] = self.cfg_path
        self.ctx = {"schema": 1, "user": "jdoe", "workarea": self.wa, "site_path": self.site_path,
                    "maestro": {"lib": "mylib", "cell": "tb_top", "view": "maestro"},
                    "dut": {"inst": "I0", "lib": "mylib", "cell": "amp_core", "view": "schematic",
                            "terms": ["IN", "OUT", "AVDD", "VDDHV", "AVSS", "gnd!"]},
                    "env": self.env, "settings": {"extract": {}}}

    def tearDown(self):
        if self._old is None:
            os.environ.pop("RELKIT_FAKE_TOOLS_CONFIG", None)
        else:
            os.environ["RELKIT_FAKE_TOOLS_CONFIG"] = self._old
        for _ in range(20):
            try:
                shutil.rmtree(self.tmp)
                break
            except OSError:
                time.sleep(0.25)

    def run_cmd(self, *argv):
        ctx_path = self.tmp + "/ctx.json"
        with open(ctx_path, "w", encoding="utf-8") as f:
            json.dump(self.ctx, f)
        out = self.tmp + "/out.json"
        rc = relkit.main([argv[0], "--ctx", ctx_path, "--out", out] + list(argv[1:]))
        return rc, rk_common.read_json(out)

    def test_resolve_preview(self):
        rc, out = self.run_cmd("extract-resolve", "--text", self.tmp + "/preview.txt")
        self.assertEqual(rc, 0, out)
        self.assertTrue(out["ready"], out["errors"])
        self.assertEqual(out["resolved"]["tech_name"]["value"], "demo_tech")
        self.assertEqual(out["choices"]["variants"], ["widio", "wodio"])
        self.assertEqual(out["suggested"]["power_names"], ["AVDD", "VDDHV"])
        self.assertEqual(out["suggested"]["ground_names"], ["AVSS", "gnd!"])
        with open(out["text"], encoding="utf-8") as f:
            txt = f.read()
        self.assertIn("lvs_rules_file", txt)
        self.assertIn("<- $calibre_source_added_place|parent", txt)
        self.ctx["env"] = {"VERIFY_ROOT": ""}
        os_env = {k: os.environ.pop(k) for k in list(self.env) if k in os.environ}
        try:
            rc, out = self.run_cmd("extract-resolve")
        finally:
            os.environ.update(os_env)
        self.assertEqual(rc, 0)            # a preview never fails: it reports
        self.assertFalse(out["ready"])
        self.assertIn("VERIFY_ROOT", out["missing_env"])

    def test_extract_with_env(self):
        self.ctx["settings"]["extract"] = {"lvs_variant": "widio", "technology_corner": "cbest",
                                           "temperature": 85, "power_names": "VDD AVDD",
                                           "ground_names": ["VSS"]}
        rc, out = self.run_cmd("extract", "--sync")
        self.assertEqual(rc, 0, out)
        self.assertEqual(out["state"], "done", out)
        self.assertTrue(out["resolved"]["lvs_rules_file"].endswith("DEMO_LVS_R1.widio.qcilvs"))
        with open(out["qci"], encoding="utf-8") as f:
            q = f.read()
        self.assertIn("DEMO_LVS_R1.widio.qcilvs", q)
        self.assertIn("*lvsPowerNames: VDD AVDD\n", q)
        self.assertIn("-query_input %s/query_cmd" % out["resolved"]["qrc_deck_dir"], q)
        with open(out["dspf_cmd"], encoding="utf-8") as f:
            d = f.read()
        self.assertIn('"CBEST"', d)
        self.assertIn('-technology_name "demo_tech"', d)
        self.assertIn("assura_tech.lib", d)
        with open(out["si_env"], encoding="utf-8") as f:
            self.assertIn("/empty.cdl", f.read())

    def test_extract_fails_up_front_on_missing_env(self):
        self.ctx["env"] = {k: "" for k in self.env}
        os_env = {k: os.environ.pop(k) for k in list(self.env) if k in os.environ}
        try:
            rc, out = self.run_cmd("extract", "--sync")
        finally:
            os.environ.update(os_env)
        self.assertEqual(rc, 1)
        self.assertFalse(out["ok"])
        self.assertIn("environment variable(s)", out["error"])
        self.assertIn("calibre_source_added_place", out["missing_env"])
        self.assertFalse(os.path.isdir(self.wa + "/Reliability/amp_core/extract/lvs"))


if __name__ == "__main__":
    unittest.main()
