"""Shared implementation of the fake strmout / si / calibre / qrc (tests only).

Each fake writes the same-named products the real tool would (shape per the
Auto_ext command lines that rk_extract reproduces), or fails on request.

Behaviour switch (docs/CONTRACT.md section 7): JSON from
$RELKIT_FAKE_TOOLS_CONFIG, else fake_tools/fake_config.json, else defaults:

    {"lvs": "pass" | "fail",        # LVS report banner CORRECT / INCORRECT
     "fail_step": null | "strmout" | "si" | "lvs" | "qrc",   # exit 1, no product
     "delay": 0,                    # seconds each tool sleeps (cancel tests)
     "lvs_no_banner": false}        # LVS report without a banner (truncated)

Every invocation is appended to calls.log next to the config file (or in the
cwd when there is no config file), one JSON line {"tool", "argv", "cwd"}.

Python 3.8+, stdlib only.
"""

import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load_config():
    path = os.environ.get("RELKIT_FAKE_TOOLS_CONFIG") or os.path.join(HERE, "fake_config.json")
    cfg = {"lvs": "pass", "fail_step": None, "delay": 0, "lvs_no_banner": False}
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as f:
            cfg.update(json.load(f))
        cfg["_dir"] = os.path.dirname(os.path.abspath(path))
    else:
        cfg["_dir"] = os.getcwd()
    return cfg


def _arg(argv, name):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None


def _write(path, text):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def _record(cfg, tool, argv):
    try:
        with open(os.path.join(cfg["_dir"], "calls.log"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"tool": tool, "argv": argv, "cwd": os.getcwd()}) + "\n")
    except OSError:
        pass


def _kv_file(path, pattern):
    vals = {}
    with open(path, "r", encoding="utf-8") as f:
        for m in re.finditer(pattern, f.read(), re.MULTILINE):
            vals.setdefault(m.group(1), m.group(2).strip())
    return vals


def fake_strmout(argv, cfg):
    out = _arg(argv, "-strmFile")
    cell = _arg(argv, "-topCell")
    if not out or not cell or not _arg(argv, "-layerMap") or not _arg(argv, "-library"):
        print("fake strmout: missing -strmFile/-topCell/-layerMap/-library")
        return 2
    print("fake strmout: %s/%s/%s -> %s" % (_arg(argv, "-library"), cell,
                                            _arg(argv, "-view"), out))
    _write(out, "FAKE-GDSII %s\n" % cell)
    return 0


def fake_si(argv, cfg):
    env = os.path.join(os.getcwd(), "si.env")
    if not os.path.isfile(env):
        print("fake si: no si.env in %s" % os.getcwd())
        return 2
    if os.path.exists(os.path.join(os.getcwd(), ".running")):
        print("fake si: Simulation is already running in run directory")
        return 3
    v = _kv_file(env, r'^\s*(\w+)\s*=\s*"([^"]*)"\s*$')
    run_dir, name, cell = v.get("simRunDir"), v.get("hnlNetlistFileName"), v.get("simCellName")
    if not run_dir or not name:
        print("fake si: si.env lacks simRunDir/hnlNetlistFileName")
        return 2
    _write(os.path.join(os.getcwd(), ".running"), "")  # real si leaves it behind
    _write(os.path.join(run_dir, name),
           "* fake CDL netlist\n.SUBCKT %s VDD VSS\nM1 a b VSS VSS nch\n.ENDS\n" % cell)
    print("fake si: wrote %s" % os.path.join(run_dir, name))
    return 0


def fake_calibre(argv, cfg):
    runset = _arg(argv, "-runset")
    if not runset or not os.path.isfile(runset):
        print("fake calibre: runset not found: %s" % runset)
        return 2
    if "-batch" not in argv:
        print("fake calibre: GUI mode with runset %s (nothing to do)" % runset)
        return 0
    q = _kv_file(runset, r"^\*(\w+):\s*(.*?)\s*$")
    run_dir = q.get("lvsRunDir")
    cell = q.get("lvsLayoutPrimary")
    for need in ("lvsLayoutPaths", "lvsSourcePath"):
        f = os.path.join(run_dir, q.get(need, ""))
        if not os.path.isfile(f):
            print("fake calibre: input missing: %s" % f)
            return 4
    report = os.path.join(run_dir, q["lvsReportFile"])
    if cfg.get("lvs_no_banner"):
        _write(report, "LVS REPORT (truncated)\n")
        return 0
    if cfg.get("lvs") == "fail":
        text = ("                  ##################     _   _\n"
                "                 #                  #     *   *\n"
                "                 #     INCORRECT    #       |\n"
                "                 #                  #     \\___/\n"
                "                  ##################\n\n"
                "  DISCREPANCIES = 2\n\n"
                "                               CELL  SUMMARY\n"
                "  Result         Layout                        Source\n"
                "  -----------    -----------                   --------------\n"
                "  INCORRECT      %s                     %s\n" % (cell, cell))
    else:
        text = ("                 #     CORRECT     #\n\n"
                "                               CELL  SUMMARY\n"
                "  Result         Layout                        Source\n"
                "  -----------    -----------                   --------------\n"
                "  CORRECT        %s                     %s\n" % (cell, cell))
    _write(report, "Calibre LVS report (fake)\n" + text)
    post = q.get("lvsPostTriggers", "")
    if "query_output" in post:
        qdir = os.path.join(run_dir, "query_output")
        if not os.path.isdir(qdir):
            os.makedirs(qdir)
        if "-query_input" in post:
            _write(os.path.join(qdir, "Design.gds.map"), "fake layer map\n")
            _write(os.path.join(qdir, "Design.props"), "fake props\n")
    print("fake calibre: LVS %s, report %s" % (cfg.get("lvs"), report))
    return 0


def fake_qrc(argv, cfg):
    cmd = _arg(argv, "-cmd")
    if not cmd or not os.path.isfile(cmd):
        print("fake qrc: command file not found: %s" % cmd)
        return 2
    with open(cmd, "r", encoding="utf-8") as f:
        text = f.read()
    m = re.search(r'-file_name\s+"([^"]+)"', text)
    d = re.search(r'-layer_map_file\s+"([^"]+)"', text)
    if not m:
        print("fake qrc: no output_setup -file_name")
        return 2
    if d and not os.path.isfile(d.group(1)):
        print("fake qrc: input_db layer map missing: %s (did LVS run the query?)" % d.group(1))
        return 5
    t = re.search(r'-temperature\s*\\?\s*\n?\s*(\S+)', text)
    _write(m.group(1), "*|DSPF 1.3\n*|DESIGN fake\n*|TEMPERATURE %s\n.ENDS\n"
           % (t.group(1) if t else "?"))
    print("fake qrc: wrote %s" % m.group(1))
    return 0


TOOLS = {"strmout": fake_strmout, "si": fake_si, "calibre": fake_calibre, "qrc": fake_qrc}
STEP_OF = {"strmout": "strmout", "si": "si", "calibre": "lvs", "qrc": "qrc"}


def main(tool, argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    cfg = load_config()
    _record(cfg, tool, argv)
    delay = float(cfg.get("delay") or 0)
    if delay:
        time.sleep(delay)
    if cfg.get("fail_step") == STEP_OF[tool] and not (tool == "calibre" and "-batch" not in argv):
        print("fake %s: failing on request (fail_step=%s)" % (tool, cfg.get("fail_step")))
        return 1
    return TOOLS[tool](argv, cfg)
