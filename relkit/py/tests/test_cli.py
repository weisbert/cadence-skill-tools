"""CLI convention tests for relkit.py (registry, --out shape, exit codes)."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

PY_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PY_DIR)

import relkit  # noqa: E402

# Every subcommand promised by docs/CONTRACT.md section 3.
CONTRACT_COMMANDS = ["site", "version", "build-yml", "emir-inputs", "submit", "status",
                     "cancel", "supervise", "collect", "report", "aged-include",
                     "extract", "extract-status", "extract-cancel", "runs"]


class CliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rk_cli_")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _read(self, p):
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)

    def test_registry_has_all_contract_commands(self):
        parser, errors = relkit.build_parser()
        self.assertEqual(errors, {})
        sub = [a for a in parser._actions if a.__class__.__name__ == "_SubParsersAction"][0]
        for name in CONTRACT_COMMANDS:
            self.assertIn(name, sub.choices, name)

    def test_version_ok(self):
        out = os.path.join(self.tmp, "o.json")
        rc = relkit.main(["version", "--out", out])
        self.assertEqual(rc, 0)
        d = self._read(out)
        self.assertIs(d["ok"], True)
        self.assertIsNone(d["error"])
        self.assertEqual(d["cmd"], "version")

    def test_site_with_ctx(self):
        ctx = {"workarea": self.tmp, "site_path": None, "user": "jdoe",
               "relstudio_home": "/opt/relstudio"}
        cp = os.path.join(self.tmp, "ctx.json")
        with open(cp, "w", encoding="utf-8") as f:
            json.dump(ctx, f)
        out = os.path.join(self.tmp, "o.json")
        self.assertEqual(relkit.main(["site", "--ctx", cp, "--out", out]), 0)
        d = self._read(out)
        self.assertEqual(d["site"]["relstudio_home"], "/opt/relstudio")
        self.assertEqual(d["site"]["persist_root"], self.tmp + "/relkit_runs")

    def test_failure_shape_and_exit_code(self):
        out = os.path.join(self.tmp, "o.json")
        rc = relkit.main(["status", "--out", out])  # missing --run
        self.assertEqual(rc, 1)
        d = self._read(out)
        self.assertIs(d["ok"], False)
        self.assertTrue(d["error"])

    def test_missing_ctx_file(self):
        out = os.path.join(self.tmp, "o.json")
        rc = relkit.main(["build-yml", "--ctx", os.path.join(self.tmp, "nope.json"),
                          "--out", out])
        self.assertEqual(rc, 1)
        self.assertIn("ctx file not found", self._read(out)["error"])

    def test_ipc_dir_pruned(self):
        ipc = os.path.join(self.tmp, "_ipc")
        os.makedirs(ipc)
        old, new = os.path.join(ipc, "old_ctx.json"), os.path.join(ipc, "new_ctx.json")
        for p in (old, new):
            with open(p, "w", encoding="utf-8") as f:
                f.write("{}\n")
        t = os.path.getmtime(new) - 20 * 86400
        os.utime(old, (t, t))
        self.assertEqual(relkit.main(["version", "--out", os.path.join(ipc, "v_out.json")]), 0)
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(new))
        # at most once a day; never outside a dir named _ipc
        os.utime(new, (t, t))
        self.assertEqual(relkit.main(["version", "--out", os.path.join(ipc, "v2_out.json")]), 0)
        self.assertTrue(os.path.exists(new))
        other = os.path.join(self.tmp, "keep.json")
        with open(other, "w", encoding="utf-8") as f:
            f.write("{}\n")
        os.utime(other, (t, t))
        self.assertEqual(relkit.main(["version", "--out", os.path.join(self.tmp, "o.json")]), 0)
        self.assertTrue(os.path.exists(other))

    def test_subprocess_invocation(self):
        out = os.path.join(self.tmp, "o.json")
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        r = subprocess.run([sys.executable, os.path.join(PY_DIR, "relkit.py"),
                            "version", "--out", out], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIs(self._read(out)["ok"], True)


if __name__ == "__main__":
    unittest.main()
