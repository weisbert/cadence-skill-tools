#!/usr/bin/env python3
"""Fake RelStudio run_relsim (test double for relkit; plan section 8).

This directory is laid out as a RELSTUDIO_HOME:
    fake_relstudio/script/python/run_relsim.py
relkit's submit adapter runs <home>/script/python/run_relsim.pyc and falls back
to this run_relsim.py.

    run_relsim.py -t {analog_aging,dynamic_eos,emir} -m {submit,start,summary,report}
                  -c <yml> [-u USER -n NAME]
    run_relsim.py --fake-job --type T --yml Y --sim simN      (one "cluster job")

It builds a Work_Dir tree shaped like the real tool's (directory names, file
names, column layouts) with SYNTHETIC content:

  -m submit : needs Work_Dir/<type>/ (else exits 1 like the real hisim.log
              FileNotFoundError); writes hisim.log, mapping.txt, submit_list.txt,
              batch_submit_list.txt, simN/script/{*.conf,run.cshrc},
              simN/netlist/<netlist> (DEOS/EMIR). Submits nothing.
  -m start  : submit + start every job in the background; returns at once
              (config "start_blocks": true -> waits for the jobs, then runs
              summary + report itself).
  -m summary: summary_rpt/summary.txt + summary_id.yml from the job results.
  -m report : <IP>_<Cell>_<Rel_Type>.report at the type dir.

A job writes simN/job.out (-STATUS- lines, then "Run Simulation successfully."
+ .ok.txt, or "-ERROR-: Run Simulation Failed"), the per-type result files and
simN/<cell>.report(.pdf).

Behaviour switch (JSON): $RELKIT_FAKE_RS_CONFIG, else fake_config.json next to
the yml, else fake_relstudio/fake_config.json; default = success.
  {"mode": "ok" | "fail" | "license_fail",
   "license_fail_times": 2,        # license_fail: first N tries fail per sim
   "fail_sims": ["sim2"],          # fail: only these sims (default all)
   "job_seconds": 1.0, "start_blocks": false, "start_exit": 0,
   "aging_fail": false, "deos_violation": false, "emir_violation": false,
   "instances": ["I0.X1.M3", ...], "pdk_dir": "/opt/pdk/models"}

Python 3.8+, stdlib only. Not part of relkit's runtime.
"""

import argparse
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.dirname(os.path.dirname(HERE))
PY_DIR = os.path.dirname(os.path.dirname(HOME))  # relkit/py
if PY_DIR not in sys.path:
    sys.path.insert(0, PY_DIR)

import rk_yaml  # noqa: E402  (relkit/py; the fake only lives inside relkit)

TYPE_INFO = {
    "analog_aging": {"rel": "AnalogAging", "conf": "AnalogAging.conf", "script": "analog_aging"},
    "dynamic_eos": {"rel": "DynamicEOS", "conf": "Dynamic_EOS.conf", "script": "dynamic_eos"},
    "emir": {"rel": "EMIR", "conf": "EM.Config", "script": "em"},
}
DEFAULT_INSTANCES = ["I0.X1.MP0", "I0.X1.MN0", "I0.X1.I2.M3", "I0.X2.M1", "I0.X2.M2",
                     "I0.X3.I4.MP1", "I0.X3.I4.MN1", "I0.M5"]


def ts():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log(type_dir, msg, level="INFO"):
    line = "%s [PID:%d] %s [run_relsim.py:99] %s\n" % (ts(), os.getpid(), level, msg)
    sys.stdout.write(line)
    sys.stdout.flush()
    if type_dir and os.path.isdir(type_dir):
        with open(os.path.join(type_dir, "hisim.log"), "a", encoding="utf-8") as f:
            f.write(line)


def write(path, text):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def append(path, text):
    with open(path, "a", encoding="utf-8", newline="\n") as f:
        f.write(text)
        f.flush()


def load_config(yml):
    cands = []
    if os.environ.get("RELKIT_FAKE_RS_CONFIG"):
        cands.append(os.environ["RELKIT_FAKE_RS_CONFIG"])
    if yml:
        cands.append(os.path.join(os.path.dirname(os.path.abspath(yml)), "fake_config.json"))
    cands.append(os.path.join(HOME, "fake_config.json"))
    for c in cands:
        if c and os.path.isfile(c):
            with open(c, "r", encoding="utf-8") as f:
                return json.load(f)
    return {}


def frac(*parts):
    """Deterministic pseudo-random number in [0,1) from strings."""
    h = hashlib.sha1("|".join(str(p) for p in parts).encode("utf-8")).hexdigest()
    return int(h[:8], 16) / float(0x100000000)


def fmt_table(header, rows):
    widths = [len(h) for h in header]
    for r in rows:
        for i, v in enumerate(r):
            widths[i] = max(widths[i], len(str(v)))
    lines = [" ".join(str(h).ljust(widths[i]) for i, h in enumerate(header))]
    for r in rows:
        lines.append(" ".join(str(v).ljust(widths[i]) for i, v in enumerate(r)))
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
class Setup(object):
    """Everything derived from the yml."""

    def __init__(self, rs_type, yml):
        self.rs_type = rs_type
        self.yml = os.path.abspath(yml)
        with open(yml, "r", encoding="utf-8") as f:
            self.doc = rk_yaml.load(f.read())
        com = self.doc["Common"]
        self.common = com
        self.work_dir = com["Work_Dir"]
        self.type_dir = os.path.join(self.work_dir, rs_type)
        self.cell = str(com["Cell_Name"])
        self.ip = str(com["IP_Name"])
        self.project = str(com["Project_Name"])
        self.history = self.doc["Simulation"].get("History")
        self.cfg = load_config(yml)
        self.sims = self._sims()

    def _sims(self):
        sims = []
        n = 0
        for key, val in self.doc["Simulation"]["Corners"].items():
            if self.rs_type == "analog_aging":
                entries = {}
                for item in val:
                    entries.update(item)
                stress = entries.get("Stress_1") or {}
                aged = []
                for name in sorted(k for k in entries if k.startswith("Aged_")):
                    temps = entries[name].get("Temperature") or []
                    if len(temps) > 1:  # one entry carrying all evaluation temperatures
                        aged += [("Aged_%d" % (len(aged) + i + 1), t) for i, t in enumerate(temps)]
                    else:
                        aged.append((name, temps[0] if temps else 27))
                for t in stress.get("Temperature") or [27]:
                    n += 1
                    sims.append({"sim": "sim%d" % n, "key": key, "entry": stress, "temp": t,
                                 "aged": aged})
            else:
                temps = val.get("Temperature") or val.get("Sim_Temperature") or [27]
                for t in temps:
                    n += 1
                    sims.append({"sim": "sim%d" % n, "key": key, "entry": val, "temp": t,
                                 "aged": []})
        for s in sims:
            e = s["entry"]
            s["mode"] = str(e.get("Mode_Name"))
            s["test"] = str(e.get("Test_Name"))
            s["corner"] = list((e.get("Corner_Group") or {}).keys())[0]
            if self.rs_type == "emir":
                s["dir"] = os.path.join(self.type_dir, str(e.get("Sim_Cell")), s["sim"])
            else:
                s["dir"] = os.path.join(self.type_dir, s["sim"])
        return sims

    def params_str(self, entry, sep=","):
        return sep.join("%s=%s" % (k, v[0] if isinstance(v, list) else v)
                        for k, v in (entry.get("Parameters") or {}).items())

    def life(self, entry):
        if self.rs_type == "analog_aging":
            st = entry["Time_Windows"][0]["State_1"]
            return "%sy" % st["Life_Time"][0]
        if self.rs_type == "dynamic_eos":
            st = entry["Time_Windows"][0]["State_1"]
        else:
            st = entry["Time_State"]["States"][0]["State_1"]
        return "%sy" % st["Life_Time"]

    def window(self, entry):
        if self.rs_type == "emir":
            st = entry["Time_State"]["States"][0]["State_1"]
        else:
            st = entry["Time_Windows"][0]["State_1"]
        return "(%s,%s)" % (st["Start_Time"], st["Stop_Time"])

    def instances(self):
        return list(self.cfg.get("instances") or DEFAULT_INSTANCES)


# --------------------------------------------------------------------------
# -m submit

def do_submit(S):
    if not os.path.isdir(S.type_dir):
        sys.stderr.write("ERROR An unexpected exception occurred: [Errno 2] No such file or "
                         "directory: '%s'\n" % os.path.join(S.type_dir, "hisim.log"))
        return 1
    log(S.type_dir, "begin relsim submit flow of %s" % S.rs_type)
    info = TYPE_INFO[S.rs_type]
    mp = []
    if S.rs_type == "analog_aging":
        mp.append("#index;pvt_index;pvt_key;sim_type;test_name;mode_name;corner_name;sim_temp;"
                  "analysis_type;life_time;params;simulator")
        i = 0
        for s in S.sims:
            i += 1
            mp.append("%d;%s;%s,1;Stress_1;%s;%s;%s;%s;multi_age_points;%s;%s;alps" % (
                i, s["sim"], s["key"], s["test"], s["mode"], s["corner"], s["temp"],
                S.life(s["entry"]), S.params_str(s["entry"])))
            for name, t in s["aged"]:
                i += 1
                mp.append("%d;%s;%s,0;%s;%s;%s;%s;%s;multi_age_points;%s;%s;alps" % (
                    i, s["sim"], s["key"], name, s["test"], s["mode"], s["corner"], t,
                    S.life(s["entry"]), S.params_str(s["entry"])))
    elif S.rs_type == "dynamic_eos":
        mp.append("#index;pvt_index;pvt_key;test_name;mode_name;corner_name;sim_temp;params;simulator")
        for i, s in enumerate(S.sims, 1):
            mp.append("%d;%s;%s;%s;%s;%s;%s;%s;alps" % (i, s["sim"], s["key"], s["test"],
                                                        s["mode"], s["corner"], s["temp"],
                                                        S.params_str(s["entry"])))
    else:
        mp.append("#index;pvt_index;pvt_key;test_name;mode_name;top_cell;corner_name;sim_temp;"
                  "params;states;analysis_type;flow_type;simulator")
        for i, s in enumerate(S.sims, 1):
            e = s["entry"]
            mp.append("%d;%s;%s;%s;%s;%s;%s;%s;%s;State_1;DYN,SEM,SH;Totem;alps" % (
                i, s["sim"], s["key"], s["test"], s["mode"], e.get("Sim_Cell"), s["corner"],
                s["temp"], S.params_str(e)))
    write(os.path.join(S.type_dir, "mapping.txt"), "\n".join(mp) + "\n")
    sub, batch = [], []
    py = sys.executable.replace("\\", "/")
    me = os.path.abspath(__file__).replace("\\", "/")
    for s in S.sims:
        d = s["dir"]
        os.makedirs(os.path.join(d, "script"), exist_ok=True)
        write(os.path.join(d, "script", info["conf"]),
              "# fake %s for %s\nWORK_DIR=%s\nDESIGN_NAME=%s\nTEMPERATURE=%s\n" % (
                  info["conf"], s["sim"], S.type_dir, S.cell, s["temp"]))
        write(os.path.join(d, "script", "run.cshrc"),
              "#! /bin/csh -f\n# fake run.cshrc (%s)\nset PRJ_DIR=%s\n" % (s["sim"], d))
        if S.rs_type != "analog_aging":
            nl = s["entry"].get("Netlist_File")
            dst = os.path.join(d, "netlist", os.path.basename(nl or "netlist.scs"))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if nl and os.path.isfile(nl):
                shutil.copyfile(nl, dst)
            else:
                write(dst, "// fake netlist copy\n")
        job = "%s_%s_%s_%s_%s_%s_end" % (S.ip, S.cell, S.project, S.history, S.rs_type, s["sim"])
        sub.append("cd %s; echo -n %s > /dev/null;(%s/script/run.cshrc)" % (d, job, d))
        batch.append('nohup "%s" "%s" --fake-job --type %s --yml "%s" --sim %s > /dev/null 2>&1 &'
                     % (py, me, S.rs_type, S.yml.replace("\\", "/"), s["sim"]))
    write(os.path.join(S.type_dir, "submit_list.txt"), "\n".join(sub) + "\n")
    write(os.path.join(S.type_dir, "batch_submit_list.txt"), "\n".join(batch) + "\n")
    log(S.type_dir, "end relsim submit flow of %s. The task is success." % S.rs_type)
    return 0


def spawn_job(S, sim):
    argv = [sys.executable, os.path.abspath(__file__), "--fake-job", "--type", S.rs_type,
            "--yml", S.yml, "--sim", sim]
    kw = {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL,
          "stderr": subprocess.DEVNULL, "close_fds": True}
    if os.name == "nt":
        kw["creationflags"] = 0x00000008 | 0x00000200
    else:
        kw["start_new_session"] = True
    p = subprocess.Popen(argv, **kw)
    p.returncode = 0  # detached on purpose; never waited for


def do_start(S):
    rc = do_submit(S)
    if rc != 0:
        return rc
    log(S.type_dir, "begin relsim start flow of %s" % S.rs_type)
    for s in S.sims:
        spawn_job(S, s["sim"])
    if S.cfg.get("start_blocks"):
        deadline = time.time() + 600
        while time.time() < deadline:
            fin = 0
            for s in S.sims:
                t = ""
                p = os.path.join(s["dir"], "job.out")
                if os.path.isfile(p):
                    with open(p, "r", encoding="utf-8") as f:
                        t = f.read()
                if "Run Simulation successfully" in t or "Run Simulation Failed" in t:
                    fin += 1
            if fin == len(S.sims):
                break
            time.sleep(0.2)
        do_summary(S)
        do_report(S, os.environ.get("USER") or "fake", None)
    return int(S.cfg.get("start_exit") or 0)


# --------------------------------------------------------------------------
# one job

def run_job(S, sim):
    s = [x for x in S.sims if x["sim"] == sim][0]
    d = s["dir"]
    os.makedirs(d, exist_ok=True)
    out = os.path.join(d, "job.out")
    cfg = S.cfg
    info = TYPE_INFO[S.rs_type]
    write(out, "Run Cmd: %s/script/%s/fake_flow.pl -c %s/script/%s -no_open -corner %s\n" % (
        HOME.replace("\\", "/"), info["script"], d, info["conf"], sim))
    append(out, "-STATUS-:  Start ParaCheck.\n-STATUS-:  Start ReadUserConfigFile.\n")
    time.sleep(float(cfg.get("job_seconds", 1.0)))
    mode = cfg.get("mode") or "ok"
    if mode == "fail" and (not cfg.get("fail_sims") or sim in cfg.get("fail_sims")):
        append(out, "ERROR: fake simulator crashed\n-ERROR-: Run Simulation Failed\n")
        return 1
    if mode == "license_fail" and S.rs_type == "emir":
        cnt_path = os.path.join(S.type_dir, ".fake_license_count_%s" % sim)
        n = 0
        if os.path.isfile(cnt_path):
            with open(cnt_path, "r", encoding="utf-8") as f:
                n = int(f.read().strip() or 0)
        if n < int(cfg.get("license_fail_times", 2)):
            write(cnt_path, "%d\n" % (n + 1))
            adsrpt = os.path.join(d, "pwr_sig_sh_em", "adsRpt")
            write(os.path.join(adsrpt, "totem.log"),
                  "INFO(TEC-194): Checking out fake_feature license (Lic-216).\n"
                  "ERROR(LIC-002): Failed to check out license 'fake_totem': "
                  "license server not available\n")
            append(out, "Checking out fake_feature license (Lic-216).\n"
                        "-ERROR-: Run Simulation Failed\n")
            return 1
    if S.rs_type == "analog_aging":
        aging_results(S, s)
    elif S.rs_type == "dynamic_eos":
        deos_results(S, s)
    else:
        emir_results(S, s)
    rep = os.path.join(d, ("%s.report" % (s["entry"].get("Sim_Cell") if S.rs_type == "emir"
                                          else S.cell)))
    write(rep, report_text(S, "per-sim report %s" % sim))
    with open(rep + ".pdf", "wb") as f:
        f.write(b"%PDF-1.4\n% fake\n")
    write(os.path.join(d, ".ok.txt"), "")
    append(out, "-STATUS-: Run Simulation successfully.\n")
    return 0


# --------------------------------------------------------------------------
# per-type result files (synthetic, real shapes)

def aging_results(S, s):
    d = s["dir"]
    life = S.life(s["entry"])
    pdk = (S.cfg.get("pdk_dir") or "/opt/pdk/models").rstrip("/")
    point = os.path.join(d, "%s_point" % life)
    stress = os.path.join(point, "Stress_1")
    sname = "%s_Stress_1" % S.cell
    sdir = os.path.join(stress, sname)
    os.makedirs(sdir, exist_ok=True)
    dat = os.path.join(sdir, sname + ".hrmiage0.dat")
    with open(dat, "wb") as f:
        f.write(("fake hrmi age data %s %s\n" % (s["key"], s["temp"])).encode("utf-8") * 40)
    write(os.path.join(sdir, sname + ".hrmiage0"),
          "age_data_file\t1\t%s\n"
          "age_mapping_file\t1\t%s/alps/agemapping.txt\n"
          "sorting_level\t-1\nsorting_num\t10000000\ntr_start\t0.000000e+00\n"
          "tr_end\t2.000000e-08\nageunit\t0\nagetime\t0.000000e+00\n"
          "integrate_temper\t%f\n" % (dat.replace("\\", "/"), pdk, float(s["temp"])))
    write(os.path.join(stress, "HrmiAgeInput.cfg"), "tr_start 0\ntr_end 2e-08\n")
    tail = ("simulator lang=spectre\n\n"
            "include \"%s/alps/macro_model_usage.scs\" section=AGEING_MACRO\n"
            "option1 options hrmiflag=0.1 hrmiage=yes close_all_feature=yes\n"
            "option2 options hrmiagemodel=\"%s/alps/fake_aging_model.scs\"\n"
            "option3 options hrmiageso=\"%s/alps/fake_aging_model.so\"\n"
            "option4 options hrmiinput=\"%%s\"\n\n"
            "simulator lang=spice\n%%s.option dagetime=%s\n" % (pdk, pdk, pdk, life))
    nl = s["entry"].get("Netlist_File")
    body = ""
    if nl and os.path.isfile(nl):
        with open(nl, "r", encoding="utf-8", errors="replace") as f:
            body = f.read()
    write(os.path.join(stress, sname + ".scs"),
          body + "\n" + tail % ((stress + "/HrmiAgeInput.cfg").replace("\\", "/"), ".alter\n")
          + "\n.option hrmi_extrap_only=1\n")
    for name, t in s["aged"]:
        adir = os.path.join(point, name)
        os.makedirs(os.path.join(adir, "%s_%s" % (S.cell, name)), exist_ok=True)
        write(os.path.join(adir, "%s_%s.scs" % (S.cell, name)),
              body + "\n" + tail % ((sdir + "/" + sname + ".hrmiage0").replace("\\", "/"), ""))
    # dfr0
    hdr = ("Instance dtemperature didsat(HCI+BTI,%) didlin(HCI+BTI,%) dvtlin(HCI+BTI,V) "
           "didsat(HCI,%) didlin(HCI,%) dvtlin(HCI,V) didsat(BTI,%) didlin(BTI,%) "
           "dvtlin(BTI,V) Length Model Category")
    rows = []
    fail = S.cfg.get("aging_fail")
    for i, inst in enumerate(S.instances()):
        r = frac(inst, s["key"], s["temp"])
        dids = 0.5 + 9.0 * r
        if fail and i == 0:
            dids = 25.0
        p = "p" in inst.split(".")[-1].lower()
        model = "pch_x.1" if p else "nch_x.1"
        rows.append((dids, "%s %.3e %.3e %.3e %.3e %.3e %.3e %.3e %.3e %.3e %.3e %.3e %s %s" % (
            inst, 1e-3 * r, dids, dids * 0.7, dids * 0.0025, 0.0, 0.0, 0.0, dids, dids * 0.7,
            dids * 0.0025, 2e-8, model, "CoreP" if p else "CoreN")))
    rows.sort(key=lambda x: -x[0])
    dfr0 = os.path.join(stress, sname + ".hrmideg1.dfr0")
    write(dfr0, hdr + "\n" + "\n".join(r[1] for r in rows) + "\n")
    write(os.path.join(d, "results", "%s_point_%s.dfr0" % (life, sname)),
          hdr + "\n" + "\n".join(r[1] for r in rows) + "\n")
    write(os.path.join(d, "fake_result.json"), json.dumps({
        "worst": rows[0][1].split()[0], "dids": rows[0][0], "model": rows[0][1].split()[-2]}))


def deos_results(S, s):
    d = os.path.join(s["dir"], "eos_spectre")
    viol = S.cfg.get("deos_violation")
    rows = []
    for i, inst in enumerate(S.instances()):
        r = frac(inst, s["key"], "deos")
        dpm = 10 ** (-8 - 20 * r)
        p = "p" in inst.split(".")[-1].lower()
        mv = "under_limit"
        dur = 0.0
        if viol and i == 0:
            mv, dur, dpm = "1.21", 3.5e-9, 2.5
        rows.append((dpm, inst, mv, dur, -0.92 if p else 0.92, "pch_x" if p else "nch_x",
                     "CoreP" if p else "CoreN"))
    rows.sort(key=lambda x: -x[0])
    total = sum(r[0] for r in rows)
    lines = ["%s VIOLATION_vgs/vgd: Gate Oxide Integrity, Vgs/Vgd violation and DPM" % (" " * 51),
             "-" * 168,
             "%31s %11s %8s %9s %6s %11s %11s %13s %12s %10s %s" % (
                 "Device_Name", "DPM_EOS", "DPM_NORM", "DPM_Ratio", "Model", "L", "W",
                 "Durations(s)", "Max_volt", "Volt_limit", "Category")]
    for dpm, inst, mv, dur, lim, model, cat in rows:
        lines.append("%31s %11.5e %8s %9s %6s %11.5e %11.5e %13.5e %12s %10s %8s" % (
            inst, dpm, "NULL", "NULL", model, 2e-8, 1e-6, dur, mv, lim, cat))
    lines.append("TOTAL_DPM  %e (1)" % total)
    lines.append("")
    for t in ("vds", "vdb", "vbs", "vgb", "vgs", "vgd"):
        lines.append("%s####%s VIOLATION_%s: device check %s passed %s####" % (
            " " * 20, " " * 41, t, t, " " * 41))
        lines.append("")
    name = "%s_eos_full.rpt" % S.cell
    write(os.path.join(d, name), "\n".join(lines) + "\n")
    top = rows[0]
    nviol = 1 if viol else 0
    write(os.path.join(d, "max_voltage.rpt"),
          "Violation_Type: Vgs/Vgd\nDevice_Name: %s\nDPM_EOS: %e\nDurations: %e\n"
          "Max_Volt: %s\nVol_Limit: %s\nModel: %s\n\n#vds\nNo violation!\n\n#vdb\n"
          "No violation!\n\n#vbs\nNo violation!\n\n#vgb\nNo violation!\n\n"
          "Total_Mos_Number              : %d\nVgs_Vgd_Violation_Number      : %d\n"
          "Vds_Violation_Number          : 0\nVdb_Violation_Number          : 0\n"
          "Vbs_Violation_Number          : 0\nVgb_Violation_Number          : 0\n"
          "Total_DPM_Value               : %e\n" % (
              top[1], top[0], top[3], top[2], top[4], top[5], len(rows), nviol, total))
    write(os.path.join(d, "max_dpm.rpt"), "%s %e NULL NULL %s\n" % (top[1], top[0], top[5]))
    write(os.path.join(s["dir"], "fake_result.json"), json.dumps({
        "worst": top[1], "dpm": top[0], "total": total, "model": top[5], "viol": nviol}))


def emir_results(S, s):
    e = s["entry"]
    top = str(e.get("Sim_Cell"))
    base = os.path.join(s["dir"], "pwr_sig_sh_em")
    ads = os.path.join(base, "adsRpt")
    viol = S.cfg.get("emir_violation")
    head_dyn = ("# fake totem\n# EM MODE is %s\n# This file reports the EM violations.\n\n"
                "# For wires: #layer #end-to-end_coordinates #EM_Ratio #net #width "
                "#blech_length #current\n# For vias: #via_name #x-y_coordinates #EM_Ratio "
                "#net #blech_length\n\n")
    for sub in ("Dynamic", "SignalEM"):
        for m in ("avg", "rms", "peak"):
            txt = head_dyn % m.upper()
            if viol and sub == "SignalEM" and m == "avg":
                txt += "M2 ( 10.000 20.000 ) ( 12.500 20.000 ) 135.20% net_out 0.100 4.1e-03\n"
                txt += "VIA1 ( 11.000 20.000 ) 112.00% net_out 2.0e-03\n"
            write(os.path.join(ads, sub, "%s.em.worst.%s" % (top, m)), txt)
    pw = (e.get("Supplies") or {}).get("Power") or {"VDD": 0.9}
    lines = ["#fake totem", "#Report locations (x, y) with worst voltage_drops/ground_bounces",
             "#voltage #ideal_volt   #net      #x_y_location     #layer_name"]
    for net, v in pw.items():
        for k in range(30):
            drop = 0.02 * (1 - k / 40.0)
            lines.append("  %.4f   %.4f      %s (    %.3f,  %.3f)  M1" % (
                float(v) - drop, float(v), net, 100 + k, 200 + k))
    write(os.path.join(ads, "Dynamic", "%s.ir.worst" % top), "\n".join(lines) + "\n")
    write(os.path.join(ads, "power_summary.rpt"),
          "\nPower of different Vdd domain in Watt:\n\n"
          "Vdd_domain      total_pwr   leakage_pwr  internal_pwr  switching_pwr   %_total_pwr\n" +
          "".join("%s (%sV)     5.0000e-04  0.0000e+00   5.0000e-04    0.0000e+00      1.0000e+02\n"
                  % (n, v) for n, v in pw.items()) + "\n")
    write(os.path.join(ads, "totem.log"), "INFO(TEC-194): Checking out fake_feature license (Lic-216).\n"
          "fake totem finished\n")
    write(os.path.join(s["dir"], "fake_result.json"), json.dumps({"viol": bool(viol)}))


def report_text(S, title):
    return ("%s\n* Tool Name : Relstudio (FAKE)\n* Module    : %s\n\n1. Design Summary\n"
            "Project_Name : %s\nCell_Name : %s\nWork_Dir : %s\n%s\n" % (
                "*" * 60, TYPE_INFO[S.rs_type]["rel"], S.project, S.cell, S.work_dir, title))


# --------------------------------------------------------------------------
# -m summary / -m report

def _result(s):
    p = os.path.join(s["dir"], "fake_result.json")
    if os.path.isfile(p):
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)
    return None


def do_summary(S):
    log(S.type_dir, "begin relsim summary flow of %s" % S.rs_type)
    rows = []
    ids = []
    for i, s in enumerate(S.sims, 1):
        res = _result(s)
        if res is None:
            continue
        e = s["entry"]
        params = S.params_str(e, ";")
        ids.append("%d: %s" % (i, s["dir"].replace("\\", "/")))
        if S.rs_type == "analog_aging":
            w = res["worst"]
            cell = lambda v: "%.2e#@#%s(%s)#@#%s" % (v, w, res["model"], w)  # noqa: E731
            dids = res["dids"]
            rows.append([i, S.cell, s["mode"], s["test"], S.life(e), s["corner"], s["temp"],
                         "toplevel.scs", params, S.window(e),
                         "Fail" if dids >= 20 else "Pass", cell(dids * 1e-3 + 0.5),
                         cell(dids), cell(dids * 0.7), cell(dids * 0.0025), "NULL",
                         cell(0.0), cell(0.0), cell(0.0), "NULL", cell(dids),
                         cell(dids * 0.7), cell(dids * 0.0025), "NULL"])
        elif S.rs_type == "dynamic_eos":
            w = res["worst"]
            st = "fail" if res["viol"] else "pass"
            t = (e.get("Time_Windows") or [{}])[0].get("State_1", {}).get("Tddb_Temperature", s["temp"])
            rows.append([i, S.cell, s["mode"], s["test"], S.life(e), s["corner"], s["temp"],
                         "toplevel.scs", params, S.window(e), t,
                         "Fail" if res["viol"] else "Pass",
                         "%.2e#@#%s(%s)#@#%s" % (res["dpm"], w, res["model"], w),
                         "%.2e(1)" % res["total"],
                         "%s#@#%s(%s)#@#%s" % (st, w, res["model"], w), "pass",
                         "pass", "pass", "pass", "pass", "pass", "pass", "pass", "pass",
                         "-0.92", "0"])
        else:
            viol = res["viol"]
            pw = (e.get("Supplies") or {}).get("Power") or {}
            gd = (e.get("Supplies") or {}).get("Ground") or {}
            em = lambda pct, n: "%.2f%%#@#Violation_Number:%d#*#limit:100%%#@#(10.000,20.000)" % (pct, n)  # noqa: E731
            row = [i, "Totem", e.get("Sim_Cell"), s["mode"], s["test"], S.life(e), s["corner"],
                   s["temp"], "toplevel.scs", "1P5M_EXAMPLE", e.get("Rc_Corner"), params,
                   "State_1", S.window(e),
                   e["Time_State"]["States"][0]["State_1"]["Em_Temperature"],
                   "Fail" if viol else "Pass", em(45.1, 0), em(6.2, 0), em(5.8, 0),
                   em(135.2 if viol else 53.5, 2 if viol else 0), em(10.9, 0), em(8.6, 0),
                   2 if viol else 0, "2.87", "2.87", "None", "Pass", "100%", "98.10%",
                   "2%(vss)", "0.20%(vdd)"]
            hdr_nets = []
            for n, v in list(pw.items()) + list(gd.items()):
                hdr_nets.append("%s(%s)" % (n, v))
                row.append("%.2fmv#@#limit:41#@#XXI0/XX1/MMP0@1" % (21.3 if n in pw else 3.0))
            rows.append(row)
    if S.rs_type == "analog_aging":
        header = ["Stress_ID", "Cell", "Str_Mode", "Str_Test", "Life_Time", "Str_Corner",
                  "Str_Temp", "SpiceModel", "Str_Params", "Str_Times", "Pass/Fail", "Dtemp",
                  "didsat(HCI+BTI,%)", "didlin(HCI+BTI,%)", "dvtlin_Core(HCI+BTI,V)",
                  "dvtlin_IO(HCI+BTI,V)", "didsat(HCI,%)", "didlin(HCI,%)",
                  "dvtlin_Core(HCI,V)", "dvtlin_IO(HCI,V)", "didsat(BTI,%)", "didlin(BTI,%)",
                  "dvtlin_Core(BTI,V)", "dvtlin_IO(BTI,V)"]
    elif S.rs_type == "dynamic_eos":
        header = ["DEOS_ID", "Cell", "Mode", "Test", "Life_Time", "Corner", "Temp", "SpiceModel",
                  "Params", "Windows", "TDDB_Temp", "Pass/Fail", "Max_Dev_PPM", "Total_PPM",
                  "Vgs/Vgd_Core", "Vgs/Vgd_IO", "Vds_Core", "Vds_IO", "Vdb_Core", "Vdb_IO",
                  "Vbs_Core", "Vbs_IO", "Vgb_Core", "Vgb_IO", "Vgs/Vgd_Core_Limit",
                  "Vgs/Vgd_IO_Limit"]
    else:
        header = ["EM_ID", "Type", "Cell", "Mode", "Test", "Life_Time", "Corner", "Temp",
                  "SpiceModel", "Metal", "RcCorner", "Params", "State", "Windows", "Em_Temp",
                  "Pass/Fail(EM)", "Pwr_AVG", "Pwr_RMS", "Pwr_Peak", "Sig_AVG", "Sig_RMS",
                  "Sig_Peak", "Total_Violations", "Dev_Dtemp(°C)", "Metal_Dtemp(°C)",
                  "Totem_Error", "Pass/Fail(IR)", "Pwr_Mapping", "Sig_Mapping", "P_Diff",
                  "T_Diff"] + (hdr_nets if rows else [])
    sr = os.path.join(S.type_dir, "summary_rpt")
    write(os.path.join(sr, "summary.txt"), fmt_table(header, rows))
    write(os.path.join(sr, "summary_id.yml"), "\n".join(ids) + "\n")
    log(S.type_dir, "end relsim summary flow of %s. The task is success." % S.rs_type)
    return 0


def do_report(S, user, name):
    rel = TYPE_INFO[S.rs_type]["rel"]
    write(os.path.join(S.type_dir, "%s_%s_%s.report" % (S.ip, S.cell, rel)),
          report_text(S, "report by %s (%s)" % (user, name)))
    log(S.type_dir, "report written")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="run_relsim.py (fake)")
    ap.add_argument("-t", dest="type")
    ap.add_argument("-m", dest="mode")
    ap.add_argument("-c", dest="yml")
    ap.add_argument("-u", dest="user")
    ap.add_argument("-n", dest="name")
    ap.add_argument("-w")
    ap.add_argument("-e")
    ap.add_argument("-ct")
    ap.add_argument("--fake-job", action="store_true")
    ap.add_argument("--type", dest="jtype")
    ap.add_argument("--yml", dest="jyml")
    ap.add_argument("--sim")
    a = ap.parse_args(argv)
    if a.fake_job:
        S = Setup(a.jtype, a.jyml)
        return run_job(S, a.sim)
    if a.type not in TYPE_INFO:
        sys.stderr.write("fake run_relsim: unsupported -t %s\n" % a.type)
        return 2
    if not a.yml or not os.path.isfile(a.yml):
        sys.stderr.write("fake run_relsim: yml not found: %s\n" % a.yml)
        return 2
    S = Setup(a.type, a.yml)
    if a.mode == "submit":
        return do_submit(S)
    if a.mode == "start":
        return do_start(S)
    if a.mode == "summary":
        return do_summary(S)
    if a.mode == "report":
        if not a.user or not a.name:
            sys.stderr.write("fake run_relsim: report needs -u and -n\n")
            return 2
        return do_report(S, a.user, a.name)
    sys.stderr.write("fake run_relsim: unsupported -m %s\n" % a.mode)
    return 2


if __name__ == "__main__":
    sys.exit(main())
