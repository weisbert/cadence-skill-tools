"""Unit tests for rk_site (site lookup, deep merge, ${VAR} expansion).

Synthetic values only (CONTRACT section 8: no site-specific data in fixtures).
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import rk_site  # noqa: E402


def _write(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f)


class SiteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rk_site_")
        self.wa = os.path.join(self.tmp, "wa")
        os.makedirs(self.wa)
        self.env = {"USER": "jdoe", "RELSTUDIO_HOME": "/opt/relstudio",
                    "MY_ROOT": "/proj/root"}

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- lookup order -------------------------------------------------------
    def test_defaults_only_when_nothing_found(self):
        env = dict(self.env)
        repo_site = os.path.join(rk_site.RELKIT_DIR, "site.json")
        if os.path.isfile(repo_site):
            self.skipTest("relkit/site.json exists on this machine")
        site, path, warnings = rk_site.load_site(workarea=self.wa, environ=env)
        self.assertIsNone(path)
        self.assertTrue(any("defaults" in w for w in warnings))
        self.assertEqual(site["persist_root"], self.wa + "/relkit_runs")
        self.assertEqual(site["artifact_root"], self.wa + "/Reliability")
        self.assertEqual(site["relstudio_home"], "/opt/relstudio")
        self.assertEqual(site["submit_strategy"], "start")
        self.assertIs(site["dry_run"], False)

    def test_workarea_file_found(self):
        _write(os.path.join(self.wa, ".relkit_site.json"), {"python": "/usr/bin/python3"})
        site, path, _ = rk_site.load_site(workarea=self.wa, environ=self.env)
        self.assertEqual(path, os.path.join(self.wa, ".relkit_site.json"))
        self.assertEqual(site["python"], "/usr/bin/python3")

    def test_env_override_wins(self):
        _write(os.path.join(self.wa, ".relkit_site.json"), {"python": "wa"})
        explicit = os.path.join(self.tmp, "explicit.json")
        _write(explicit, {"python": "explicit"})
        env = dict(self.env, RELKIT_SITE=explicit)
        site, path, _ = rk_site.load_site(workarea=self.wa, environ=env)
        self.assertEqual(path, explicit)
        self.assertEqual(site["python"], "explicit")

    def test_env_override_missing_is_error(self):
        env = dict(self.env, RELKIT_SITE=os.path.join(self.tmp, "nope.json"))
        with self.assertRaises(rk_site.SiteError):
            rk_site.load_site(workarea=self.wa, environ=env)

    def test_invalid_json_is_error(self):
        p = os.path.join(self.wa, ".relkit_site.json")
        with open(p, "w", encoding="utf-8") as f:
            f.write("{not json")
        with self.assertRaises(rk_site.SiteError):
            rk_site.load_site(workarea=self.wa, environ=self.env)

    # -- merge --------------------------------------------------------------
    def test_deep_merge_objects_and_null(self):
        _write(os.path.join(self.wa, ".relkit_site.json"), {
            "cluster": {"Queue": "q1"},
            "emir": {"license_policy": "fail"},
            "model_file_map": [],
            "extract": {"tools": {"qrc": "/opt/fake/qrc"}},
            "tech": None,
        })
        site, _, _ = rk_site.load_site(workarea=self.wa, environ=self.env)
        self.assertEqual(site["cluster"]["Queue"], "q1")
        self.assertEqual(site["cluster"]["CPU"], 8)            # default kept
        self.assertEqual(site["emir"]["license_policy"], "fail")
        self.assertEqual(site["emir"]["license_retry_minutes"], 10)
        self.assertEqual(site["model_file_map"], [])           # list replaced
        self.assertEqual(site["extract"]["tools"]["qrc"], "/opt/fake/qrc")
        self.assertEqual(site["extract"]["tools"]["si"], "si")
        self.assertIsNone(site["tech"])                        # null replaces

    def test_deep_merge_does_not_mutate(self):
        base = {"a": {"b": 1}}
        out = rk_site.deep_merge(base, {"a": {"c": 2}})
        self.assertEqual(base, {"a": {"b": 1}})
        self.assertEqual(out, {"a": {"b": 1, "c": 2}})

    # -- expansion ----------------------------------------------------------
    def test_expand_builtin_and_env(self):
        _write(os.path.join(self.wa, ".relkit_site.json"), {
            "work_root": "/scratch/${USER}/rel",
            "python": "${MY_ROOT}/bin/python3",
            "extract": {"tools": {"si": "${RELKIT_DIR}/py/tests/fake_tools/si"}},
        })
        site, _, warnings = rk_site.load_site(workarea=self.wa, environ=self.env)
        self.assertEqual(site["work_root"], "/scratch/jdoe/rel")
        self.assertEqual(site["python"], "/proj/root/bin/python3")
        self.assertTrue(site["extract"]["tools"]["si"].endswith("/py/tests/fake_tools/si"))
        self.assertFalse([w for w in warnings if "unknown" in w])

    def test_bare_dollar_is_literal(self):
        out = rk_site.expand_vars("$MODEL_ROOT/alps/toplevel.scs", {}, {"MODEL_ROOT": "/x"})
        self.assertEqual(out, "$MODEL_ROOT/alps/toplevel.scs")

    def test_unknown_var_kept_with_warning(self):
        w = []
        out = rk_site.expand_vars("a/${NOPE_VAR}/b", {}, {}, w)
        self.assertEqual(out, "a/${NOPE_VAR}/b")
        self.assertEqual(len(w), 1)

    def test_builtin_var_beats_env(self):
        out = rk_site.expand_vars("${USER}", {"USER": "ctxuser"}, {"USER": "envuser"})
        self.assertEqual(out, "ctxuser")

    def test_explicit_relstudio_home_from_ctx(self):
        ctx = {"workarea": self.wa, "site_path": None, "user": "jdoe",
               "relstudio_home": "/opt/relstudio_ctx"}
        site, path, _ = rk_site.site_from_ctx(ctx, environ=self.env)
        self.assertIsNone(path)
        self.assertEqual(site["relstudio_home"], "/opt/relstudio_ctx")

    def test_site_relstudio_home_overrides(self):
        _write(os.path.join(self.wa, ".relkit_site.json"), {"relstudio_home": "/opt/rs_site"})
        site, _, _ = rk_site.load_site(workarea=self.wa, environ=self.env,
                                       relstudio_home="/opt/rs_ctx")
        self.assertEqual(site["relstudio_home"], "/opt/rs_site")

    def test_get_dotted(self):
        self.assertEqual(rk_site.get({"a": {"b": 3}}, "a.b"), 3)
        self.assertIsNone(rk_site.get({"a": {}}, "a.b"))

    # -- shipped files ------------------------------------------------------
    def test_shipped_example_is_valid_and_loads(self):
        ex = os.path.join(rk_site.RELKIT_DIR, "site.example.json")
        site, path, _ = rk_site.load_site(workarea=self.wa, path=ex, environ=self.env)
        self.assertEqual(path, ex)
        for key in ("python", "work_root", "artifact_root", "persist_root", "tech",
                    "cluster", "simulator", "emir", "extract", "aging_model",
                    "submit_strategy", "dry_run", "model_file_map"):
            self.assertIn(key, site)
        self.assertIn(site["submit_strategy"], ("start", "submit_batch"))
        self.assertIn(site["emir"]["license_policy"], ("wait_forever", "wait_hours", "fail"))


if __name__ == "__main__":
    unittest.main()
