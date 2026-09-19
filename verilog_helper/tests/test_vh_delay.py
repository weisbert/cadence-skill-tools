#!/usr/bin/env python3
"""Unit tests for vh_delay.py -- mock Verilog-AMS snippets, python stdlib only.

    python3 -m unittest discover -s verilog_helper/tests -v
    python3 verilog_helper/tests/test_vh_delay.py
"""
import os
import sys
import json
import shutil
import tempfile
import unittest
import warnings

warnings.simplefilter("ignore", ResourceWarning)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

import vh_delay as vd   # noqa: E402


TABLE = {
    "schema": "vh_delay/1", "version": "v1", "unit": "ps", "scale": 1.0,
    "classes": {
        "inv":      {"ps": 12.0, "kind": "tpd"},
        "dff":      {"ps": 50.0, "kind": "clk2q"},
        "tff":      {"ps": 50.0, "kind": "clk2q"},
        "pdown":    {"ps": 60.0, "kind": "tpd"},
        "power_sw": {"ps": 80.0, "kind": "tpd"},
        "gain":     {"ps": 25.0, "kind": "tpd"},
    },
    "modules": {
        "inv_ps":   {"class": "inv"},
        "inv_sec":  {"class": "inv"},
        "dff_m":    {"class": "dff"},
        "tff_m":    {"class": "tff"},
        "pdown_m":  {"class": "pdown", "delay_const_rhs": True},
        "psw_m":    {"class": "power_sw"},
        "gain_m":   {"class": "gain", "assign_sites": ["o"]},
    },
}

INV_PS = """`timescale 1ps/1ps
module inv_ps ( out, VDD, VSS, in );
  input in, VDD, VSS;
  output out;
  reg out;
  wire powerOK;
  assign powerOK = ((VDD-VSS)>=0.72);
  initial begin
    out = 1'b0;
  end
  always@(*) begin
    if (!powerOK) begin
       out = 1'b0;
    end
    else begin
       out <= #10 ~ in ;
    end
  end
endmodule
"""

INV_SEC = """`timescale 1s/1fs
module inv_sec ( out, in );
  input in; output reg out;
  always @(*) out <= #(10e-12) ~in;
endmodule
"""

DFF = """`timescale 1ps/1ps
module dff_m ( Q, QB, D, clk, VDD, VSS );
  input D, clk, VDD, VSS; output Q, QB;
  reg Q; reg QB;
  wire powerOK;
  assign powerOK = ((VDD-VSS)>=0.72);
  initial begin
    Q = 1'b0;
    QB = 1'b0;
  end
  always @( posedge clk or negedge powerOK) begin
   if(! powerOK)
    begin
    Q <= 1'b0;
    QB<=1'b0;
  end
  else begin
      Q <= D;
     QB<=  ~D;
   end
  end
endmodule
"""

TFF = """`timescale 1ps/1ps
module tff_m ( q, qb, clk, ld, datab );
  input clk, ld, datab; output q, qb;
  reg q; reg qb;
  always @(posedge clk or posedge ld) begin
    if(ld) begin
       q <= #10 ~datab;
       qb <= #10 datab;
    end
    else begin
       q <= #20 ~q;
       qb <= #10 q;
    end
  end
endmodule
"""

PDOWN = """`timescale 1ps/1ps
module pdown_m ( Z, VSS, IN );
  input IN, VSS; output Z;
  reg Z;
  wire powerOK;
  assign powerOK = (VSS <= 0);
  always @(*) begin
    if (!powerOK)        Z = 1'bx;   // UNKNOWN
    else if (IN == 1'b1) Z = 1'b0;   // ACTIVE -> pull low
    else                 Z = 1'bz;   // RELEASED
  end
endmodule
"""

PSW = """`timescale 1s/1fs
module psw_m ( vdd_div, en_b );
  input en_b; output reg vdd_div;
  always@(*) begin
     vdd_div = ~en_b;
  end
endmodule
"""

GAIN = """`timescale 1ps/1ps
module gain_m ( o, i );
  input i; output o;
  assign o = ~i;
endmodule
"""

TWO_MODS = """`timescale 1ps/1ps
module not_in_table ( y, a );
  input a; output reg y;
  always @(*) y <= ~a;
endmodule

module inv_ps ( out, in );
  input in; output reg out;
  always @(*) out <= #10 ~in;
endmodule
"""

COMMENTED = """`timescale 1ps/1ps
module inv_ps ( out, in );
  input in; output reg out;
  // a decoy in a comment:  out <= ~in;
  /* another decoy: out <= 1'b1; */
  always @(*) out <= #10 ~in;
endmodule
"""


def T(scale=None):
    return vd.Table(json.loads(json.dumps(TABLE)), scale)


class SiteDiscovery(unittest.TestCase):
    def sites(self, text, mod, const=False):
        scan = vd.mask_comments(text)
        name, a, b = vd.find_modules(text)[-1] if mod is None else \
            [m for m in vd.find_modules(text) if m[0] == mod][0]
        return vd.module_sites(text, scan, a, b, delay_const_rhs=const)

    def test_inv_one_site_reset_branch_skipped(self):
        s = self.sites(INV_PS, "inv_ps")
        self.assertEqual(len(s), 1)
        self.assertEqual(s[0]["lhs"], "out")
        self.assertEqual(s[0]["dly"], "#10")

    def test_dff_reset_and_initial_skipped(self):
        s = self.sites(DFF, "dff_m")
        self.assertEqual([x["lhs"] for x in s], ["Q", "QB"])
        self.assertEqual([x["dly"] for x in s], ["", ""])

    def test_tff_four_sites_in_source_order(self):
        s = self.sites(TFF, "tff_m")
        self.assertEqual([x["dly"] for x in s], ["#10", "#10", "#20", "#10"])

    def test_const_rhs_skipped_unless_opted_in(self):
        self.assertEqual(len(self.sites(PDOWN, "pdown_m", const=False)), 0)
        s = self.sites(PDOWN, "pdown_m", const=True)
        self.assertEqual(len(s), 2)          # 1'b0 and 1'bz, NOT the !powerOK 1'bx
        self.assertNotIn("1'bx", [x["rhs"] for x in s])

    def test_comments_are_not_sites(self):
        s = self.sites(COMMENTED, "inv_ps")
        self.assertEqual(len(s), 1)

    def test_assign_is_not_an_always_site(self):
        s = self.sites(GAIN, "gain_m")
        self.assertEqual(s, [])


class Injection(unittest.TestCase):
    def test_existing_delay_replaced_not_stacked(self):
        out, done = vd.apply_text(INV_PS, T())
        self.assertEqual(done, [("inv_ps", "inv", 1)])
        self.assertIn("out <= #(VH_TPD_INV) ~ in ;", out)
        self.assertNotIn("#10", out.split(vd.MARK_END)[1])   # only in the VH_ORIG record
        self.assertEqual(out.count("#(VH_TPD_INV)"), 1)

    def test_missing_delay_inserted(self):
        out, _ = vd.apply_text(DFF, T())
        self.assertIn("Q <= #(VH_TPD_DFF) D;", out)
        self.assertIn("QB<= #(VH_TPD_DFF) ~D;", out)
        # the async-clear branch must stay immediate
        self.assertIn("Q <= 1'b0;", out)
        self.assertIn("QB<=1'b0;", out)
        # the initial block must stay immediate
        self.assertIn("Q = 1'b0;", out)

    def test_timescale_ps_file(self):
        out, _ = vd.apply_text(INV_PS, T())
        self.assertIn("parameter real VH_TPD_INV = 12.0 * VH_TPD_SCALE_P;", out)

    def test_timescale_seconds_file_converted(self):
        out, _ = vd.apply_text(INV_SEC, T())
        self.assertIn("parameter real VH_TPD_INV = 1.2e-11 * VH_TPD_SCALE_P;", out)

    def test_table_scale_baked_in(self):
        out, _ = vd.apply_text(INV_PS, T(scale=2.0))
        self.assertIn("parameter real VH_TPD_INV = 24.0 * VH_TPD_SCALE_P;", out)

    def test_macro_guards_present(self):
        out, _ = vd.apply_text(INV_PS, T())
        self.assertIn("`ifdef VH_TPD_SCALE", out)
        self.assertIn("`ifdef VH_TPD_INV_PS", out)
        self.assertIn("parameter real VH_TPD_INV = (`VH_TPD_INV_PS) * 1.0 * VH_TPD_SCALE_P;", out)

    def test_tff_all_branches_one_class(self):
        out, done = vd.apply_text(TFF, T())
        self.assertEqual(done[0][2], 4)
        self.assertEqual(out.count("#(VH_TPD_TFF)"), 4)

    def test_blocking_becomes_nonblocking(self):
        out, _ = vd.apply_text(PSW, T())
        self.assertIn("vdd_div <= #(VH_TPD_POWER_SW) ~en_b;", out)

    def test_pdown_const_rhs_opt_in(self):
        out, done = vd.apply_text(PDOWN, T())
        self.assertEqual(done[0][2], 2)
        self.assertIn("Z <= #(VH_TPD_PDOWN) 1'b0;", out)
        self.assertIn("Z <= #(VH_TPD_PDOWN) 1'bz;", out)
        self.assertIn("if (!powerOK)        Z = 1'bx;", out)   # untouched

    def test_assign_site_opt_in(self):
        out, done = vd.apply_text(GAIN, T())
        self.assertEqual(done, [("gain_m", "gain", 1)])
        self.assertIn("assign #(VH_TPD_GAIN) o = ~i;", out)

    def test_module_not_in_table_untouched(self):
        out, done = vd.apply_text(TWO_MODS, T())
        self.assertEqual([d[0] for d in done], ["inv_ps"])
        self.assertIn("always @(*) y <= ~a;", out)

    def test_only_filter(self):
        out, done = vd.apply_text(TWO_MODS, T(), only={"nothing"})
        self.assertEqual(done, [])
        self.assertEqual(out, TWO_MODS)


class Idempotency(unittest.TestCase):
    CASES = [INV_PS, INV_SEC, DFF, TFF, PDOWN, PSW, GAIN, TWO_MODS, COMMENTED]

    def test_apply_twice_equals_once(self):
        for src in self.CASES:
            a, _ = vd.apply_text(src, T())
            b, _ = vd.apply_text(a, T())
            self.assertEqual(a, b)
            self.assertEqual(a.count(vd.MARK_BEGIN), b.count(vd.MARK_BEGIN))

    def test_revert_is_byte_exact(self):
        for src in self.CASES:
            a, _ = vd.apply_text(src, T())
            back, n = vd.revert_text(a)
            self.assertEqual(back, src)
            self.assertEqual(n, a.count(vd.MARK_BEGIN))

    def test_reapply_with_new_scale_updates_value(self):
        a, _ = vd.apply_text(INV_PS, T())
        b, _ = vd.apply_text(a, T(scale=3.0))
        self.assertIn("parameter real VH_TPD_INV = 36.0 * VH_TPD_SCALE_P;", b)
        self.assertEqual(b.count("VH_TPD_INV ="), 2)   # the ifdef pair, not 4
        back, _ = vd.revert_text(b)
        self.assertEqual(back, INV_PS)

    def test_revert_of_untouched_text_is_noop(self):
        back, n = vd.revert_text(INV_PS)
        self.assertEqual((back, n), (INV_PS, 0))


class CLI(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="vhdly")
        self.src = os.path.join(self.d, "src")
        os.makedirs(self.src)
        for n, txt in (("inv_ps.vams", INV_PS), ("dff_m.vams", DFF),
                       ("psw_m.vams", PSW), ("other.vams", TWO_MODS)):
            open(os.path.join(self.src, n), "w").write(txt)
        self.tab = os.path.join(self.d, "t.json")
        json.dump(TABLE, open(self.tab, "w"))

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def _run(self, *argv):
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = vd.main(list(argv))
        return rc, buf.getvalue()

    def test_apply_out_dir_leaves_src_untouched(self):
        before = {f: open(os.path.join(self.src, f)).read() for f in os.listdir(self.src)}
        out = os.path.join(self.d, "out")
        rc, _ = self._run("apply", "--table", self.tab, "--src", self.src, "--out", out)
        self.assertEqual(rc, 0)
        for f, txt in before.items():
            self.assertEqual(open(os.path.join(self.src, f)).read(), txt)
        self.assertEqual(sorted(os.listdir(out)), sorted(before))
        self.assertIn("VH_TPD_DFF", open(os.path.join(out, "dff_m.vams")).read())

    def test_apply_requires_out_or_in_place(self):
        with self.assertRaises(SystemExit):
            self._run("apply", "--table", self.tab, "--src", self.src)

    def test_dry_run_writes_nothing_and_prints_diff(self):
        out = os.path.join(self.d, "dry")
        rc, txt = self._run("apply", "--table", self.tab, "--src", self.src,
                            "--out", out, "--dry-run")
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(out))
        self.assertIn("--- a/inv_ps.vams", txt)
        self.assertIn("+parameter real VH_TPD_INV", txt)

    def test_in_place_makes_orig_backup_and_revert_restores(self):
        orig = open(os.path.join(self.src, "inv_ps.vams")).read()
        rc, _ = self._run("apply", "--table", self.tab, "--src", self.src, "--in-place")
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.exists(os.path.join(self.src, "inv_ps.vams.orig")))
        self.assertIn("VH_TPD_INV", open(os.path.join(self.src, "inv_ps.vams")).read())
        rc, _ = self._run("revert", "--src", self.src, "--in-place")
        self.assertEqual(rc, 0)
        self.assertEqual(open(os.path.join(self.src, "inv_ps.vams")).read(), orig)
        self.assertFalse(os.path.exists(os.path.join(self.src, "inv_ps.vams.orig")))

    def test_report_lists_sites_and_current_delay(self):
        rc, txt = self._run("report", "--src", self.src, "--table", self.tab)
        self.assertEqual(rc, 0)
        self.assertIn("inv_ps", txt)
        self.assertIn("#10", txt)
        self.assertIn("dff_m", txt)
        self.assertIn("carry NO delay at all", txt)

    def test_flags_prints_scale_macro(self):
        rc, txt = self._run("flags", "--table", self.tab)
        self.assertEqual(rc, 0)
        self.assertIn("+define+VH_TPD_SCALE=", txt)
        self.assertIn("+define+VH_TPD_DFF_PS=", txt)


class PackageHook(unittest.TestCase):
    """vh_package --delays injects into the PACKAGED copies only."""

    def test_package_injects_delays(self):
        import vh_package  # noqa: F401  (import here so the test is skippable)
        d = tempfile.mkdtemp(prefix="vhpkg")
        try:
            build = os.path.join(d, "sim")
            os.makedirs(build)
            top = os.path.join(build, "top.vams")
            open(top, "w").write("`timescale 1ps/1ps\nmodule top(); endmodule\n")
            leaf = os.path.join(build, "dff_m.vams")
            open(leaf, "w").write(DFF)
            open(os.path.join(build, "tb.vams"), "w").write(
                "module tb; initial $display(\"=== TB PASS ===\"); endmodule\n")
            json.dump({"top": "top", "top_file": top, "tb": "tb.vams",
                       "existing_verilogams": [{"file": leaf}],
                       "external_stubbed": [], "ext_flags": [], "sim_top": "tb"},
                      open(os.path.join(build, "manifest.json"), "w"))
            tabp = os.path.join(d, "t.json")
            json.dump(TABLE, open(tabp, "w"))
            sys.argv = ["vh_package.py", "--build", build, "--delays", tabp]
            import io
            import contextlib
            with contextlib.redirect_stdout(io.StringIO()):
                vh_package.main()
            pkg = os.path.join(d, "package", "top_pkg")
            packed = open(os.path.join(pkg, "dff_m.vams")).read()
            self.assertIn("VH_TPD_DFF", packed)
            self.assertIn("Q <= #(VH_TPD_DFF) D;", packed)
            # the build input is NOT modified
            self.assertEqual(open(leaf).read(), DFF)
            self.assertTrue(os.path.exists(os.path.join(pkg, "delays.json")))
            man = json.load(open(os.path.join(pkg, "manifest_D.json")))
            self.assertEqual(man["delays_table"], "t.json")
            self.assertEqual(man["delays_applied"][0]["module"], "dff_m")
        finally:
            shutil.rmtree(d, ignore_errors=True)


class RealTable(unittest.TestCase):
    """The shipped WuR table must be self-consistent."""

    def test_wur_table_classes_resolve(self):
        p = os.path.join(ROOT, "delays", "wur_ndiv_delays.json")
        if not os.path.isfile(p):
            self.skipTest("table not present")
        tab = vd.Table.load(p)
        for mod, ent in tab.modules.items():
            self.assertIn(ent["class"], tab.classes, "%s -> unknown class" % mod)
            self.assertGreater(tab.ps(ent["class"]), 0.0)
        # parameter names must be unique per class and valid Verilog identifiers
        import re
        names = {tab.param(c) for c in tab.classes}
        self.assertEqual(len(names), len(tab.classes))
        for n in names:
            self.assertTrue(re.match(r"^[A-Za-z_]\w*$", n))


if __name__ == "__main__":
    unittest.main(verbosity=2)
