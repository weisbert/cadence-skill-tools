"""Donau settings from Maestro job policies (rk_donau): .jp / dsub parsing,
choice resolution, yml Cluster + Sim_Mt, run.json and rerun. Synthetic
accounts / queues / paths only."""

import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rkt_helpers as H  # noqa: E402
import rk_donau  # noqa: E402
import rk_site  # noqa: E402
import rk_yml  # noqa: E402
import relkit  # noqa: E402

JP_TEXT = """blockemail=1
configuretimeout=300
distributionmethod=Command
jobsubmitcommand=dsub -A grp_demo.cls -q short -R "cpu=4;mem=8000"
maxjobs=20
name=demo_short
"""

POL_SHORT = {"name": "demo_short", "distributionmethod": "Command",
             "jobsubmitcommand": 'dsub -A grp_demo.cls -q short -R "cpu=4;mem=8000"'}
POL_BIG = {"name": "demo_big", "distributionmethod": "Command",
           "jobsubmitcommand": "dsub -Kco -A grp_demo.big -q long -R cpu=16,mem=64G,gpu=2 -n x"}
POL_LOCAL = {"name": "demo_local", "distributionmethod": "Local", "maxjobs": "1"}


def jp_ctx(current="demo_short", extra=None):
    avail = [{"name": "demo_short", "path": None, "props": POL_SHORT},
             {"name": "demo_big", "path": None, "props": POL_BIG},
             {"name": "demo_local", "path": None, "props": POL_LOCAL}]
    avail += extra or []
    cur = {"demo_short": POL_SHORT, "demo_big": POL_BIG, "demo_local": POL_LOCAL}.get(current)
    return {"current_name": current, "current": cur, "available": avail}


def site_with(**over):
    site = rk_site.deep_merge(rk_site.read_json(rk_site.DEFAULTS_PATH),
                              {"cluster": {"Group": "example_group", "Queue": "normal",
                                           "CPU": 8, "Memory": 12000, "GPU": 4}})
    return rk_site.deep_merge(site, over)


class ParseTest(unittest.TestCase):
    def test_jp_text(self):
        d = rk_donau.parse_jp_text(JP_TEXT + "\n# comment\nbroken line\n")
        self.assertEqual(d["name"], "demo_short")
        self.assertEqual(d["distributionmethod"], "Command")
        self.assertTrue(d["jobsubmitcommand"].startswith("dsub -A grp_demo.cls"))
        self.assertNotIn("broken line", d)

    def test_dsub_variants(self):
        P = rk_donau.parse_submit_command
        self.assertEqual(P('dsub -A g.c -q short -R "cpu=8;mem=8000"'),
                         {"Group": "g.c", "Queue": "short", "CPU": 8, "Memory": 8000})
        self.assertEqual(P("dsub -A g -q q -R cpu=4,mem=16G"),
                         {"Group": "g", "Queue": "q", "CPU": 4, "Memory": 16384})
        # -R twice, flags and unknown options with values, absolute path, env prefix
        got = P('FOO=1 /usr/bin/dsub -Kco -n job1 -A g -R "cpu=2" -o out.log -q long '
                '-R "mem=4000MB; gpu=1"')
        self.assertEqual(got, {"Group": "g", "Queue": "long", "CPU": 2, "Memory": 4000,
                               "GPU": 1})
        self.assertEqual(P("dsub -q short -Rcpu=8;mem=1G"),
                         {"Queue": "short", "CPU": 8, "Memory": 1024})
        self.assertEqual(P("dsub -q short"), {"Queue": "short"})

    def test_not_dsub(self):
        for cmd, frag in (("bsub -q normal -n 4", "not a dsub"), ("", "empty"),
                          ('dsub -R "cpu=8', "cannot split"), ("FOO=1", "no command")):
            with self.assertRaises(ValueError) as cm:
                rk_donau.parse_submit_command(cmd)
            self.assertIn(frag, str(cm.exception))
        with self.assertRaises(ValueError):
            rk_donau.parse_submit_command('dsub -R "mem=lots"')

    def test_policy_cluster(self):
        site = site_with()
        blk, notes = rk_donau.policy_cluster(POL_SHORT, site)
        self.assertEqual((blk["Group"], blk["Queue"], blk["CPU"], blk["Memory"]),
                         ("grp_demo.cls", "short", 4, 8000))
        self.assertEqual(blk["GPU"], 4)                 # not in the policy -> site
        self.assertEqual(blk["Machine_Arch"], "x86")    # site default
        self.assertTrue(blk["Using_Cluster"])
        self.assertEqual(notes, [])
        blk, notes = rk_donau.policy_cluster(POL_BIG, site)
        self.assertEqual((blk["CPU"], blk["Memory"], blk["GPU"]), (16, 65536, 2))
        blk, notes = rk_donau.policy_cluster(
            {"distributionmethod": "Command", "jobsubmitcommand": "dsub -q q1"}, site)
        self.assertEqual((blk["Queue"], blk["Group"], blk["CPU"]), ("q1", "example_group", 8))
        self.assertEqual(len(notes), 3)                 # Group, CPU, Memory from site
        with self.assertRaises(ValueError) as cm:
            rk_donau.policy_cluster(POL_LOCAL, site)
        self.assertIn("Local", str(cm.exception))


class ResolveTest(unittest.TestCase):
    def test_default_is_maestro_current(self):
        site = site_with()
        ctx = {"job_policy": jp_ctx()}
        self.assertEqual(rk_donau.default_value(ctx, site, "aging"), "maestro")
        ch = rk_donau.resolve(ctx, site, "aging")
        self.assertEqual((ch["value"], ch["kind"], ch["name"]), ("maestro", "policy", "demo_short"))
        self.assertEqual(ch["block"]["Queue"], "short")
        self.assertEqual(rk_donau.sim_mt(site, ch["block"]), 4)

    def test_pick_policy_and_site(self):
        site = site_with(donau_profiles={"std": {"Queue": "s"}, "emir": {"Queue": "l", "CPU": 16}},
                         donau_default={"emir": "emir"})
        ctx = {"job_policy": jp_ctx()}
        ch = rk_donau.resolve(ctx, site, "emir", "policy:demo_big")
        self.assertEqual((ch["name"], ch["block"]["CPU"]), ("demo_big", 16))
        ch = rk_donau.resolve(ctx, site, "emir", "site:emir")
        self.assertEqual((ch["kind"], ch["block"]["Queue"]), ("site", "l"))
        ch = rk_donau.resolve(ctx, site, "emir", "emir")          # legacy bare name
        self.assertEqual((ch["value"], ch["kind"]), ("emir", "site"))

    def test_unusable_falls_back(self):
        site = site_with(donau_profiles={"std": {"Queue": "s"}, "emir": {"Queue": "l"}},
                         donau_default={"aging": "std", "emir": "emir"})
        # Maestro uses a Local policy -> default is the site profile
        ctx = {"job_policy": jp_ctx("demo_local")}
        self.assertEqual(rk_donau.default_value(ctx, site, "aging"), "std")
        self.assertEqual(rk_donau.default_value(ctx, site, "emir"), "emir")
        w = []
        ch = rk_donau.resolve(ctx, site, "aging", "policy:demo_local", w)
        self.assertEqual(ch["value"], "std")
        self.assertTrue(w and "demo_local" in w[0] and "Local" in w[0])
        # a usable Maestro policy is the fallback before the site
        w = []
        ch = rk_donau.resolve({"job_policy": jp_ctx()}, site, "aging", "policy:gone", w)
        self.assertEqual(ch["name"], "demo_short")
        self.assertIn("gone", w[0])
        # no job_policy in ctx at all (old ctx): site default, no warning
        self.assertEqual(rk_donau.resolve({}, site, "aging")["value"], "std")

    def test_props_read_from_jp_file(self):
        tmp = H.tmpdir("rk_jp_")
        try:
            path = os.path.join(tmp, "demo_file.jp")
            with open(path, "w", encoding="utf-8") as f:
                f.write(JP_TEXT.replace("demo_short", "demo_file"))
            ctx = {"job_policy": {"current_name": "demo_file", "current": None,
                                  "available": [{"name": "demo_file", "path": path,
                                                 "props": None}]}}
            ch = rk_donau.resolve(ctx, site_with(), "deos")
            self.assertEqual((ch["value"], ch["name"], ch["block"]["Group"]),
                             ("maestro", "demo_file", "grp_demo.cls"))
            self.assertEqual(ch["path"], path)
            self.assertTrue(ch["mtime"])
        finally:
            H.rmtree(tmp)

    def test_choices_and_summary(self):
        site = site_with(donau_profiles={"std": {"Queue": "s"}})
        ch = rk_donau.choices({"job_policy": jp_ctx()}, site, "aging")
        labels = [c["label"] for c in ch]
        self.assertEqual(labels, ["Maestro current (demo_short)", "demo_big", "demo_local",
                                  "demo_short", "site: std"])
        self.assertIn("Queue short", ch[0]["summary"])
        self.assertIn("Sim_Mt 4", ch[0]["summary"])
        self.assertIn("not usable", ch[2]["summary"])
        self.assertEqual(ch[2]["value"], "policy:demo_local")

    def test_sim_mt_rules(self):
        blk = {"CPU": 6}
        self.assertEqual(rk_donau.sim_mt(site_with(), blk), 6)
        self.assertEqual(rk_donau.sim_mt(site_with(simulator={"Sim_Mt": 12}), blk), 12)
        self.assertEqual(rk_donau.sim_mt(site_with(simulator={"Sim_Mt": "auto"}), blk), 6)
        self.assertEqual(rk_donau.sim_mt(site_with(), blk, "3"), 3)        # panel override
        self.assertEqual(rk_donau.sim_mt(site_with(), {}), 8)


class YmlRunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = H.tmpdir("rk_jpy_")
        self.wa, self.sp, self.net = H.make_workarea(self.tmp)

    def tearDown(self):
        H.rmtree(self.tmp)

    def site(self):
        site, _p, _w = rk_site.site_from_ctx({"site_path": self.sp, "workarea": self.wa})
        return site

    def ctx(self, t, **kw):
        c = H.make_ctx(self.wa, self.sp, self.net, t, **kw)
        c["job_policy"] = jp_ctx()
        return c

    def test_yml_cluster_and_sim_mt(self):
        site = self.site()
        doc, info = rk_yml.build_doc(self.ctx("aging"), site, "aging", "/w/1", 1,
                                     tools={}, sysver="")
        blocks = []

        def walk(o):
            if isinstance(o, dict):
                if "Cluster" in o:
                    blocks.append((o["Cluster"], o.get("Simulator")))
                for v in o.values():
                    walk(v)
            elif isinstance(o, list):
                for v in o:
                    walk(v)
        walk(doc)
        self.assertTrue(blocks)
        for clu, sim in blocks:
            self.assertEqual((clu["Group"], clu["Queue"], clu["CPU"], clu["Memory"]),
                             ("grp_demo.cls", "short", 4, 8000))
            if sim:
                self.assertEqual(sim["Sim_Mt"], 4)
                self.assertIn("+mt 4", sim["Simulation_Cmd"])
        self.assertEqual(info["settings"]["donau_profile"], "maestro")
        self.assertEqual((info["donau"]["kind"], info["donau"]["name"], info["donau"]["sim_mt"]),
                         ("policy", "demo_short", 4))
        # panel Sim_Mt override
        doc, info = rk_yml.build_doc(self.ctx("emir", settings={"emir": {"sim_mt": "2"}}),
                                     site, "emir", "/w/1", 1, tools={}, sysver="")
        self.assertEqual(info["donau"]["sim_mt"], 2)

    def test_run_json_and_rerun_pin(self):
        os.environ["RELKIT_FAKE_RS_CONFIG"] = H.write_json(
            os.path.join(self.tmp, "fake.json"), {"job_seconds": 0.2})
        try:
            cp = H.write_json(os.path.join(self.tmp, "ctx.json"), self.ctx("deos"))
            out = os.path.join(self.tmp, "o1.json")
            self.assertEqual(relkit.main(["submit", "--ctx", cp, "--out", out]), 0)
            sub = H.read_json(out)
            run = H.read_json(os.path.join(sub["run_dir"], "run.json"))
            self.assertEqual(run["settings"]["donau_profile"], "maestro")
            self.assertEqual(run["cluster"]["Queue"], "short")
            self.assertEqual((run["donau"]["kind"], run["donau"]["name"]), ("policy", "demo_short"))
            out2 = os.path.join(self.tmp, "o2.json")
            self.assertEqual(relkit.main(["runs", "settings-for-rerun", "--run", sub["run_dir"],
                                          "--out", out2]), 0)
            self.assertEqual(H.read_json(out2)["settings"]["donau_profile"], "policy:demo_short")
            end = time.time() + 60
            while time.time() < end:
                o3 = os.path.join(self.tmp, "o3_%d.json" % int(time.time() * 1e6))
                relkit.main(["status", "--run", sub["run_dir"], "--out", o3])
                if H.read_json(o3)["final"]:
                    break
                time.sleep(0.2)
        finally:
            os.environ.pop("RELKIT_FAKE_RS_CONFIG", None)

    def test_donau_cli(self):
        cp = H.write_json(os.path.join(self.tmp, "ctx.json"), self.ctx("aging"))
        out = os.path.join(self.tmp, "d.json")
        self.assertEqual(relkit.main(["donau", "--ctx", cp, "--out", out]), 0)
        d = H.read_json(out)
        self.assertEqual(d["current_name"], "demo_short")
        self.assertEqual(d["types"]["emir"]["default"], "maestro")
        self.assertEqual(d["types"]["aging"]["choices"][0]["label"],
                         "Maestro current (demo_short)")


if __name__ == "__main__":
    unittest.main()
