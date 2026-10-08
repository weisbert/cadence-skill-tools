"""Donau profiles (site donau_profiles / donau_default, per-run pick) -> yml Cluster
blocks, run.json settings and rerun. Synthetic names only."""

import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rkt_helpers as H  # noqa: E402
import rk_common  # noqa: E402
import rk_site  # noqa: E402
import rk_yml  # noqa: E402
import relkit  # noqa: E402

PROFILES = {
    "std": {"Queue": "short", "CPU": 8},
    "emir": {"Queue": "long", "CPU": 16, "Memory": 64000},
    "_doc": "ignored",
}
DEFAULTS = {"aging": "std", "deos": "std", "emir": "emir"}


def site_with(**over):
    site = rk_site.deep_merge(rk_site.read_json(rk_site.DEFAULTS_PATH),
                              {"cluster": {"Group": "example_group", "Queue": "normal"}})
    return rk_site.deep_merge(site, over)


class ProfilesTest(unittest.TestCase):
    def test_legacy_cluster_is_profile_default(self):
        site = site_with()
        prof = rk_yml.donau_profiles(site)
        self.assertEqual(list(prof), ["default"])
        self.assertEqual(prof["default"]["Group"], "example_group")
        for t in ("aging", "deos", "emir"):
            name, blk = rk_yml.resolve_donau(site, t)
            self.assertEqual(name, "default")
            self.assertEqual(blk, rk_yml.cluster_block(site))

    def test_profiles_merge_over_cluster(self):
        site = site_with(donau_profiles=PROFILES, donau_default=DEFAULTS)
        prof = rk_yml.donau_profiles(site)
        self.assertEqual(sorted(prof), ["emir", "std"])          # "_doc" skipped
        self.assertEqual(prof["emir"]["Group"], "example_group")   # from cluster
        self.assertEqual(prof["emir"]["Queue"], "long")
        self.assertEqual(prof["emir"]["CPU"], 16)
        self.assertEqual(rk_yml.resolve_donau(site, "aging")[0], "std")
        self.assertEqual(rk_yml.resolve_donau(site, "deos")[0], "std")
        name, blk = rk_yml.resolve_donau(site, "emir")
        self.assertEqual((name, blk["Queue"], blk["Memory"]), ("emir", "long", 64000))
        self.assertEqual(list(blk), rk_yml.CLUSTER_KEYS)

    def test_pick_and_unknown(self):
        site = site_with(donau_profiles=PROFILES, donau_default=DEFAULTS)
        self.assertEqual(rk_yml.resolve_donau(site, "aging", "emir")[0], "emir")
        w = []
        self.assertEqual(rk_yml.resolve_donau(site, "aging", "gone", w)[0], "std")
        self.assertTrue(w and "gone" in w[0])
        # no donau_default: "default" if present else the first name
        site2 = site_with(donau_profiles={"b": {}, "a": {}})
        self.assertEqual(rk_yml.resolve_donau(site2, "emir")[0], "a")
        with self.assertRaises(rk_common.RkError):
            rk_yml.cluster_block(site2, "zzz")


class YmlTest(unittest.TestCase):
    def setUp(self):
        self.tmp = H.tmpdir("rk_donau_")
        self.wa, self.sp, self.net = H.make_workarea(self.tmp, site_over={
            "donau_profiles": PROFILES, "donau_default": DEFAULTS})

    def tearDown(self):
        H.rmtree(self.tmp)

    def site(self):
        site, _p, _w = rk_site.site_from_ctx({"site_path": self.sp, "workarea": self.wa})
        return site

    def clusters(self, doc):
        out = []

        def walk(o):
            if isinstance(o, dict):
                if "Cluster" in o:
                    out.append(o["Cluster"])
                for v in o.values():
                    walk(v)
            elif isinstance(o, list):
                for v in o:
                    walk(v)
        walk(doc)
        return out

    def test_build_doc_per_type(self):
        site = self.site()
        for t, queue in (("aging", "short"), ("deos", "short"), ("emir", "long")):
            ctx = H.make_ctx(self.wa, self.sp, self.net, t)
            doc, info = rk_yml.build_doc(ctx, site, t, "/w/1", 1, tools={}, sysver="")
            cl = self.clusters(doc)
            self.assertTrue(cl)
            self.assertTrue(all(c["Queue"] == queue for c in cl), (t, cl))
            self.assertTrue(all(c["Group"] == "example_group" for c in cl))
            self.assertEqual(info["settings"]["donau_profile"], DEFAULTS[t])
            self.assertEqual(info["cluster"]["Queue"], queue)

    def test_panel_pick(self):
        site = self.site()
        ctx = H.make_ctx(self.wa, self.sp, self.net, "aging",
                         settings={"aging": {"donau_profile": "emir"}})
        doc, info = rk_yml.build_doc(ctx, site, "aging", "/w/1", 1, tools={}, sysver="")
        self.assertTrue(all(c["CPU"] == 16 for c in self.clusters(doc)))
        self.assertEqual(rk_yml.effective_settings(ctx, site, "aging")["donau_profile"], "emir")

    def test_run_json_and_rerun(self):
        os.environ["RELKIT_FAKE_RS_CONFIG"] = H.write_json(
            os.path.join(self.tmp, "fake.json"), {"job_seconds": 0.2})
        try:
            ctx = H.make_ctx(self.wa, self.sp, self.net, "deos",
                             settings={"deos": {"donau_profile": "emir"}})
            cp = H.write_json(os.path.join(self.tmp, "ctx.json"), ctx)
            out = os.path.join(self.tmp, "o1.json")
            self.assertEqual(relkit.main(["submit", "--ctx", cp, "--out", out]), 0)
            sub = H.read_json(out)
            run = H.read_json(os.path.join(sub["run_dir"], "run.json"))
            self.assertEqual(run["settings"]["donau_profile"], "emir")
            self.assertEqual(run["cluster"]["Queue"], "long")
            out2 = os.path.join(self.tmp, "o2.json")
            self.assertEqual(relkit.main(["runs", "settings-for-rerun", "--run", sub["run_dir"],
                                          "--out", out2]), 0)
            self.assertEqual(H.read_json(out2)["settings"]["donau_profile"], "emir")
            end = time.time() + 60
            while time.time() < end:
                o3 = os.path.join(self.tmp, "o3_%d.json" % int(time.time() * 1e6))
                relkit.main(["status", "--run", sub["run_dir"], "--out", o3])
                if H.read_json(o3)["final"]:
                    break
                time.sleep(0.2)
            time.sleep(0.3)
        finally:
            os.environ.pop("RELKIT_FAKE_RS_CONFIG", None)


if __name__ == "__main__":
    unittest.main()
