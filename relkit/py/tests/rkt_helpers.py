"""Shared synthetic fixtures for the Python-core tests (rk_yml / rk_submit / rk_parse /
rk_report / rk_aged). Generic names only (CONTRACT section 8)."""

import json
import os
import shutil
import sys
import tempfile

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PY_DIR = os.path.dirname(TESTS_DIR)
if PY_DIR not in sys.path:
    sys.path.insert(0, PY_DIR)
FIXTURES = os.path.join(TESTS_DIR, "fixtures")
FAKE_HOME = os.path.join(TESTS_DIR, "fake_relstudio").replace("\\", "/")

NETLIST = """// Generated for: spectre
// Design library name: mylib
// Design cell name: tb_top
// Design view name: config
simulator lang=spectre
global 0
parameters VSET=10 fin=5G EN2=1 vin=0.2 \\
    VDDA=VSET*0.0125+0.7
include "toplevel.scs" section=TOP_FF
include "toplevel.scs" section=pre_sim

// Library name: mylib
// Cell name: amp_core
subckt amp_core IN OUT VDD VSS VSUB
    M1 (OUT IN VSS VSUB) nch_x l=20n w=1u
    M2 (OUT IN VDD VDD) pch_x l=20n w=2u
    X1 (OUT VDD VSS) inv_x
ends amp_core
subckt inv_x A VDD VSS
    MP0 (A A VDD VDD) pch_x l=20n w=1u
    MN0 (A A VSS VSS) nch_x l=20n w=1u
ends inv_x
I0 (in out vdda 0 0) amp_core
V0 (vdda 0) vsource dc=VDDA type=dc
V1 (in 0) vsource dc=vin type=dc
simulatorOptions options temp=27 reltol=1e-3
tran tran stop=20n write="spectre.ic" \\
    writefinal="spectre.fc"
"""


def tmpdir(prefix="rk_t_"):
    return tempfile.mkdtemp(prefix=prefix)


def p(path):
    return path.replace("\\", "/")


def make_workarea(root, site_over=None, poll=0.2):
    """Create <root>/wa with a netlist, fake DSPF/GDS and a .relkit_site.json
    pointing at the fake RelStudio. Returns (workarea, site_path, netlist)."""
    wa = p(os.path.join(root, "wa"))
    art = os.path.join(wa, "Reliability", "amp_core")
    os.makedirs(art)
    net = p(os.path.join(art, "tb_top_test0.scs"))
    with open(net, "w", encoding="utf-8", newline="\n") as f:
        f.write(NETLIST)
    for name in ("amp_core.dspf", "amp_core.gds"):
        with open(os.path.join(art, name), "w", encoding="utf-8") as f:
            f.write("synthetic %s\n" % name)
    site = {
        "python": p(sys.executable),
        "relstudio_home": FAKE_HOME,
        "work_root": wa + "/rs_work",
        "supervise_poll_seconds": poll,
        "tool_version_names": [],
        "tech": {"Foundry": "x", "Technology": 999, "Tech_Voltage": "0.9V_1.5V",
                 "Tech_Layout": "1P5M_EXAMPLE", "Rel_Tech_Dir": "/opt/rel_tech_lib/tech/foundry"},
        "cluster": {"Group": "example_group", "Queue": "normal"},
        "aging_model": {"Model_File": "/opt/rel_tech_lib/aging/hrmiagefile.scs",
                        "Relxpert_Uri_Libs": "/opt/rel_tech_lib/aging/hrmiaging.so"},
        "emir": {"gds_map_file": "/opt/rel_tech_lib/em/gds/gds.map",
                 "license_retry_minutes": 0.01},
    }
    if site_over:
        for k, v in site_over.items():
            if isinstance(v, dict) and isinstance(site.get(k), dict):
                site[k].update(v)
            else:
                site[k] = v
    sp = wa + "/.relkit_site.json"
    with open(sp, "w", encoding="utf-8") as f:
        json.dump(site, f, indent=1)
    return wa, sp, net


def make_ctx(wa, site_path, net, run_type="aging", corners=None, settings=None):
    if corners is None:
        corners = [
            {"name": "FF125", "base_name": "FF125", "enabled": True, "selected": True,
             "sections": [{"model_file": "/proj/model/toplevel.scs", "section": "TOP_FF"},
                          {"model_file": "/proj/model/toplevel.scs", "section": "pre_sim"}],
             "temperature": "125", "vars": {"VSET": "12"}, "sweep": {}},
            {"name": "SS_t-40", "base_name": "SS", "enabled": True, "selected": True,
             "sections": [{"model_file": "/proj/model/toplevel.scs", "section": "TOP_SS"}],
             "temperature": "-40", "vars": {}, "sweep": {"temperature": "-40"}},
            {"name": "TT", "base_name": "TT", "enabled": True, "selected": False,
             "sections": [{"model_file": "/proj/model/toplevel.scs", "section": "TOP_TT"}],
             "temperature": "27", "vars": {}, "sweep": {}},
        ]
    art = os.path.dirname(net)
    st = {"emir": {"dspf_file": p(os.path.join(art, "amp_core.dspf")),
                   "gds_file": p(os.path.join(art, "amp_core.gds")),
                   "supplies": {"power": {"VDD": "0.825"}, "ground": {"VSS": "0", "VSUB": "0"}}}}
    if settings:
        for k, v in settings.items():
            st.setdefault(k, {}).update(v)
    return {
        "schema": 1, "relkit_version": "0.1.0", "created": "2026-10-08T10:07:00",
        "user": "jdoe", "host": "host01", "workarea": wa, "site_path": site_path,
        "relstudio_home": None, "relkit_dir": p(os.path.dirname(PY_DIR)),
        "maestro": {"lib": "mylib", "cell": "tb_top", "view": "maestro", "session": "s0",
                    "view_dir": wa + "/mylib/tb_top/maestro"},
        "test": "test0", "tests": ["test0"],
        "design": {"lib": "mylib", "cell": "tb_top", "view": "config", "is_config": True},
        "history": {"name": "Interactive.1", "dir": "/proj/sim/Interactive.1",
                    "netlist_dir": "/proj/sim/Interactive.1/1/test0/netlist"},
        "netlist": {"source": "/proj/sim/input.scs", "path": net, "map_dir": None,
                    "rewrites": []},
        "dut": {"inst": "I0", "lib": "mylib", "cell": "amp_core", "view": "schematic",
                "terms": ["IN", "OUT", "VDD", "VSS", "VSUB"]},
        "ip_name": "tb_top", "project_name": "relsim1",
        "global_vars": {"VSET": "10", "vin": "0.2"},
        "corners": corners, "run_type": run_type, "settings": st,
    }


def write_json(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1)
    return path


def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def rmtree(path):
    shutil.rmtree(path, ignore_errors=True)
