"""rk_parse -- result parsers for aging / DEOS / EMIR (plan 4.4) and `collect`.

collect --run DIR  ->  run_dir/summary.json (== out.json, CONTRACT 5.1) and
                       run_dir/tables/*.tsv (CONTRACT 5.2)

Files read (layout from the real tool, see the module tests' fixtures):
  aging : <type>/summary_rpt/summary.txt (+ summary_id.yml), per Stress
          simN/<Life>y_point/Stress_1/*_Stress_1.hrmideg1.dfr0
  DEOS  : <type>/summary_rpt/summary.txt, simN/eos_spectre/*_eos_full.rpt
          (VIOLATION_<kind> sections, fixed-width rows, TOTAL_DPM),
          simN/eos_spectre/max_voltage.rpt
  EMIR  : <type>/summary_rpt/summary.txt, <cell>/simN/pwr_sig_sh_em/adsRpt/
          {Dynamic,SignalEM}/*.em.worst.{avg,rms,peak} (rows only on violation),
          Dynamic/*.ir.worst (huge: first N rows only), power_summary.rpt

summary.txt is a space-aligned table; cells such as
"9.00e+00#@#I0.X1.M0(pch.1)#@#I0.X1.M0" are value#@#device(model)#@#device.

Python 3.8+, stdlib only.
"""

import glob
import os
import re

import rk_common

AGING_FAIL_PCT = 20.0     # RelStudio's "20% IDS degradation" criterion
AGING_WARN_PCT = 10.0
DFR0_ROWS = 200
IR_ROWS = 50


# --------------------------------------------------------------------------
# generic helpers

def fnum(s):
    """'9.00e+00' -> 9.0, '71.25%' -> 71.25, '21.30mv' -> 21.3, '3.79e-08(1)' -> 3.79e-08;
    None when not numeric."""
    if s is None:
        return None
    if isinstance(s, (int, float)):
        return float(s)
    m = re.match(r"^\s*([-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?)", str(s))
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def read_lines(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def parse_aligned_table(lines):
    """Space-aligned table -> (header, rows[dict]).

    Rows split on whitespace when that yields exactly one value per header
    column; otherwise cells are cut at the header's column start positions."""
    lines = [l.rstrip("\n") for l in lines if l.strip()]
    if not lines:
        return [], []
    hline = lines[0]
    header = hline.split()
    starts = [m.start() for m in re.finditer(r"\S+", hline)]
    rows = []
    for line in lines[1:]:
        parts = line.split()
        if len(parts) != len(header):
            parts = []
            for i, st in enumerate(starts):
                en = starts[i + 1] if i + 1 < len(starts) else None
                parts.append(line[st:en].strip() if st < len(line) else "")
        rows.append(dict(zip(header, parts)))
    return header, rows


def split_cell(cell):
    """'v#@#dev(model)#@#dev' -> {"value", "raw", "device", "model", "parts"}."""
    out = {"raw": cell, "value": None, "device": None, "model": None, "parts": []}
    if cell is None:
        return out
    parts = str(cell).split("#@#")
    out["parts"] = parts
    out["value"] = fnum(parts[0])
    if len(parts) >= 2:
        m = re.match(r"^(.*)\(([^()]*)\)$", parts[1])
        if m:
            out["device"] = m.group(1)
            out["model"] = m.group(2)
        elif not parts[1].startswith(("limit:", "Violation_Number")):
            out["device"] = parts[1]
    if len(parts) >= 3 and not parts[-1].startswith("("):
        if "/" in parts[-1] or "." in parts[-1] or out["device"] is None:
            if not parts[-1].startswith("limit:"):
                out["device"] = parts[-1]
    return out


def safe_name(s):
    return re.sub(r"[^A-Za-z0-9._+-]", "_", str(s))


def local_sim_dir(type_dir, path_or_sim, sub=None):
    """Map an absolute sim path from summary_id.yml (maybe written on another
    machine) or a simN name to this machine's dir under type_dir."""
    name = os.path.basename(str(path_or_sim).rstrip("/"))
    cands = [os.path.join(type_dir, name)]
    if sub:
        cands.insert(0, os.path.join(type_dir, sub, name))
    cands += glob.glob(os.path.join(type_dir, "*", name))
    for c in cands:
        if os.path.isdir(c):
            return c
    return cands[0]


def read_summary_ids(type_dir):
    p = os.path.join(type_dir, "summary_rpt", "summary_id.yml")
    out = {}
    if os.path.isfile(p):
        for line in read_lines(p):
            m = re.match(r"^\s*(\S+)\s*:\s*(\S.*)$", line)
            if m:
                out[m.group(1)] = m.group(2).strip()
    return out


# --------------------------------------------------------------------------
# aging

def parse_dfr0(path, limit=DFR0_ROWS):
    """-> (header, rows[list]) sorted by |didsat(HCI+BTI,%)| desc, first `limit` rows."""
    lines = read_lines(path)
    if not lines:
        return [], []
    header = lines[0].split()
    rows = []
    for line in lines[1:]:
        p = line.split()
        if len(p) >= len(header):
            rows.append(p[:len(header)])
    key = header.index("didsat(HCI+BTI,%)") if "didsat(HCI+BTI,%)" in header else None
    if key is not None:
        rows.sort(key=lambda r: -abs(fnum(r[key]) or 0.0))
    return header, rows[:limit] if limit else rows


def find_dfr0(sim_dir):
    pats = [os.path.join(sim_dir, "*_point", "Stress_1", "*.hrmideg1.dfr0"),
            os.path.join(sim_dir, "results", "*.dfr0"),
            os.path.join(sim_dir, "*_point", "Stress_*", "*.dfr0")]
    for p in pats:
        hits = sorted(glob.glob(p))
        if hits:
            return hits[0]
    return None


AGING_METRICS = ["Dtemp", "didsat(HCI+BTI,%)", "didlin(HCI+BTI,%)", "dvtlin_Core(HCI+BTI,V)",
                 "dvtlin_IO(HCI+BTI,V)", "didsat(HCI,%)", "didlin(HCI,%)", "dvtlin_Core(HCI,V)",
                 "dvtlin_IO(HCI,V)", "didsat(BTI,%)", "didlin(BTI,%)", "dvtlin_Core(BTI,V)",
                 "dvtlin_IO(BTI,V)"]


def parse_aging(run, tables_dir):
    type_dir = run["type_dir"]
    header, rows = parse_aligned_table(read_lines(os.path.join(type_dir, "summary_rpt",
                                                               "summary.txt")))
    ids = read_summary_ids(type_dir)
    cmap = run_corner_lookup(run)
    out = []
    for r in rows:
        sid = r.get("Stress_ID")
        key = "%s_%s_%s" % (r.get("Str_Mode"), r.get("Str_Test"), r.get("Str_Corner"))
        metrics, worst, wmodel = {}, None, None
        for m in AGING_METRICS:
            if m in r:
                c = split_cell(r[m])
                metrics[m] = c["value"] if c["value"] is not None else (
                    None if r[m] in ("NULL", "") else r[m])
                if m == "didsat(HCI+BTI,%)":
                    worst, wmodel = c["device"], c["model"]
        metrics["Str_Temp"] = fnum(r.get("Str_Temp"))
        pf = (r.get("Pass/Fail") or "").lower()
        sim_dir = local_sim_dir(type_dir, ids.get(sid) or (cmap.get(key) or {}).get("sim") or "")
        table_path = None
        dfr0 = find_dfr0(sim_dir) if os.path.isdir(sim_dir) else None
        if dfr0:
            dh, drows = parse_dfr0(dfr0)
            ii = dh.index("Instance") if "Instance" in dh else 0
            di = dh.index("didsat(HCI+BTI,%)") if "didsat(HCI+BTI,%)" in dh else None
            trows = []
            for d in drows:
                v = abs(fnum(d[di]) or 0.0) if di is not None else 0.0
                sev = "fail" if v >= AGING_FAIL_PCT else ("warn" if v >= AGING_WARN_PCT else "")
                trows.append([d[ii], sev] + d)
            table_path = os.path.join(tables_dir, "aging_%s_S%s.tsv" % (safe_name(key), safe_name(sid)))
            rk_common.write_tsv(table_path, ["_inst", "_sev"] + dh, trows)
        out.append({"key": key, "corner": (cmap.get(key) or {}).get("corner") or r.get("Str_Corner"),
                    "stress_id": sid, "pass": True if pf == "pass" else (False if pf == "fail" else None),
                    "metrics": metrics, "worst_device": worst, "worst_model": wmodel,
                    "temperature": r.get("Str_Temp"), "life": r.get("Life_Time"),
                    "sim_dir": sim_dir.replace("\\", "/"),
                    "dfr0": dfr0.replace("\\", "/") if dfr0 else None,
                    "table_path": table_path.replace("\\", "/") if table_path else None})
    return out


# --------------------------------------------------------------------------
# DEOS

def parse_eos_full(path):
    """cell_eos_full.rpt -> (columns, rows[dict], total_dpm).

    Each row dict also has "Violation" (the section kind, e.g. 'vgs/vgd')."""
    cols = None
    rows = []
    total = None
    kind = None
    for line in read_lines(path):
        s = line.strip()
        if not s:
            continue
        m = re.search(r"VIOLATION_(\S+?):", s)
        if m:
            kind = m.group(1)
            continue
        if s.startswith("---"):
            continue
        if s.startswith("Device_Name"):
            cols = s.split()
            continue
        if s.startswith("TOTAL_DPM"):
            total = fnum(s.split()[1]) if len(s.split()) > 1 else None
            continue
        if cols:
            p = s.split()
            if len(p) == len(cols):
                d = dict(zip(cols, p))
                d["Violation"] = kind
                rows.append(d)
    return cols or [], rows, total


def parse_max_voltage(path):
    out = {}
    for line in read_lines(path):
        m = re.match(r"^\s*([A-Za-z_]+(?:_Number|_Value))\s*:\s*(\S+)", line)
        if m:
            v = fnum(m.group(2))
            out[m.group(1)] = int(v) if v is not None and m.group(1).endswith("_Number") else v
    return out


def eos_row_violates(d):
    mv = d.get("Max_volt")
    dur = fnum(d.get("Durations(s)")) or 0.0
    return (mv not in (None, "", "under_limit", "NULL") and fnum(mv) is not None) or dur > 0


DEOS_STATUS_COLS = ["Vgs/Vgd_Core", "Vgs/Vgd_IO", "Vds_Core", "Vds_IO", "Vdb_Core", "Vdb_IO",
                    "Vbs_Core", "Vbs_IO", "Vgb_Core", "Vgb_IO"]


def parse_deos(run, tables_dir):
    type_dir = run["type_dir"]
    header, rows = parse_aligned_table(read_lines(os.path.join(type_dir, "summary_rpt",
                                                               "summary.txt")))
    ids = read_summary_ids(type_dir)
    cmap = run_corner_lookup(run)
    out = []
    for r in rows:
        did = r.get("DEOS_ID")
        key = "%s_%s_%s" % (r.get("Mode"), r.get("Test"), r.get("Corner"))
        sim_dir = local_sim_dir(type_dir, ids.get(did) or (cmap.get(key) or {}).get("sim") or "")
        md = split_cell(r.get("Max_Dev_PPM"))
        metrics = {"Total_DPM": fnum(r.get("Total_PPM")), "Max_Dev_DPM": md["value"],
                   "TDDB_Temp": fnum(r.get("TDDB_Temp"))}
        for c in DEOS_STATUS_COLS:
            if c in r:
                metrics[c] = split_cell(r[c])["parts"][0] if r[c] else None
        mv = os.path.join(sim_dir, "eos_spectre", "max_voltage.rpt")
        if os.path.isfile(mv):
            mvd = parse_max_voltage(mv)
            for k, name in (("Vgs_Vgd_Violation_Number", "vgs_vgd"), ("Vds_Violation_Number", "vds"),
                            ("Vdb_Violation_Number", "vdb"), ("Vbs_Violation_Number", "vbs"),
                            ("Vgb_Violation_Number", "vgb"), ("Total_Mos_Number", "n_mos")):
                if k in mvd:
                    metrics[name] = mvd[k]
            if metrics.get("Total_DPM") is None:
                metrics["Total_DPM"] = mvd.get("Total_DPM_Value")
        full = sorted(glob.glob(os.path.join(sim_dir, "eos_spectre", "*_eos_full.rpt")))
        table_path = None
        n_viol = 0
        if full:
            cols, erows, total = parse_eos_full(full[0])
            if metrics.get("Total_DPM") is None:
                metrics["Total_DPM"] = total
            erows.sort(key=lambda d: -(fnum(d.get("DPM_EOS")) or 0.0))
            trows = []
            for d in erows:
                v = eos_row_violates(d)
                n_viol += 1 if v else 0
                trows.append([d.get("Device_Name"), "fail" if v else "", d.get("Violation")] +
                             [d.get(c) for c in cols])
            table_path = os.path.join(tables_dir, "deos_%s.tsv" % safe_name(key))
            rk_common.write_tsv(table_path, ["_inst", "_sev", "Violation"] + cols, trows)
        metrics["violations"] = n_viol
        pf = (r.get("Pass/Fail") or "").lower()
        out.append({"key": key, "corner": (cmap.get(key) or {}).get("corner") or r.get("Corner"),
                    "stress_id": None,
                    "pass": True if pf == "pass" else (False if pf == "fail" else None),
                    "metrics": metrics, "worst_device": md["device"], "worst_model": md["model"],
                    "temperature": r.get("Temp"), "life": r.get("Life_Time"),
                    "sim_dir": sim_dir.replace("\\", "/"),
                    "table_path": table_path.replace("\\", "/") if table_path else None})
    return out


# --------------------------------------------------------------------------
# EMIR

def parse_em_worst(path):
    """Data rows of a *.em.worst.* file -> list of dicts (layer, ratio, net, raw)."""
    rows = []
    for line in read_lines(path):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        toks = s.split()
        ratio_i = None
        for i, t in enumerate(toks):
            if t.endswith("%") and fnum(t) is not None:
                ratio_i = i
                break
        net = toks[ratio_i + 1] if ratio_i is not None and ratio_i + 1 < len(toks) else None
        loc = " ".join(toks[1:ratio_i]) if ratio_i else ""
        rows.append({"layer": toks[0], "location": loc,
                     "ratio": fnum(toks[ratio_i]) if ratio_i is not None else None,
                     "net": net, "raw": s})
    return rows


def parse_ir_worst(path, limit=IR_ROWS):
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            m = re.match(r"^([-+\d.eE]+)\s+([-+\d.eE]+)\s+(\S+)\s+\((.*?)\)\s*(\S*)", s)
            if m:
                try:
                    v, ideal = float(m.group(1)), float(m.group(2))
                except ValueError:  # e.g. a stray "e"/"." token; skip, never fail collect
                    continue
                rows.append({"voltage": v, "ideal": ideal, "net": m.group(3),
                             "location": "(%s)" % re.sub(r"\s+", "", m.group(4)),
                             "layer": m.group(5), "drop_mv": round(abs(ideal - v) * 1000.0, 3)})
            if len(rows) >= limit:
                break
    return rows


def parse_power_summary(path):
    """Vdd-domain table -> {"domains": {name: total_W}, "total_W": sum}."""
    doms = {}
    in_tab = False
    for line in read_lines(path):
        if line.strip().startswith("Vdd_domain"):
            in_tab = True
            continue
        if in_tab:
            s = line.strip()
            if not s:
                if doms:
                    break
                continue
            m = re.match(r"^(\S+(?:\s*\([^)]*\))?)\s+([-+\d.eE]+)", s)
            if m and fnum(m.group(2)) is not None:
                doms[m.group(1)] = fnum(m.group(2))
    return {"domains": doms, "total_W": sum(doms.values()) if doms else None}


EMIR_EM_COLS = ["Pwr_AVG", "Pwr_RMS", "Pwr_Peak", "Sig_AVG", "Sig_RMS", "Sig_Peak"]


def parse_emir(run, tables_dir):
    type_dir = run["type_dir"]
    header, rows = parse_aligned_table(read_lines(os.path.join(type_dir, "summary_rpt",
                                                               "summary.txt")))
    ids = read_summary_ids(type_dir)
    cmap = run_corner_lookup(run)
    fixed = set(["EM_ID", "Type", "Cell", "Mode", "Test", "Life_Time", "Corner", "Temp",
                 "SpiceModel", "Metal", "RcCorner", "Params", "State", "Windows", "Em_Temp",
                 "Pass/Fail(EM)", "Total_Violations", "Totem_Error", "Pass/Fail(IR)",
                 "Pwr_Mapping", "Sig_Mapping", "P_Diff", "T_Diff"] + EMIR_EM_COLS)
    out = []
    for r in rows:
        eid = r.get("EM_ID")
        key = "%s_%s_%s_0" % (r.get("Mode"), r.get("Test"), r.get("Corner"))
        cell = r.get("Cell")
        sim_dir = local_sim_dir(type_dir, ids.get(eid) or (cmap.get(key) or {}).get("sim") or "sim%s" % eid,
                                sub=cell)
        metrics = {}
        for c in EMIR_EM_COLS:
            if c in r:
                sc = split_cell(r[c])
                metrics[c + "_pct"] = sc["value"]
                vn = [p for p in sc["parts"] if "Violation_Number:" in p]
                if vn:
                    m = re.search(r"Violation_Number:(\d+)", vn[0])
                    if m:
                        metrics[c + "_violations"] = int(m.group(1))
        metrics["Total_Violations"] = fnum(r.get("Total_Violations"))
        for c in header:
            if c.startswith("Dev_Dtemp") or c.startswith("Metal_Dtemp"):
                metrics[c.split("(")[0]] = fnum(r.get(c))
        ir_worst = []
        for c in header:
            if c in fixed or c.startswith(("Dev_Dtemp", "Metal_Dtemp")):
                continue
            m = re.match(r"^(.+)\(([^()]*)\)$", c)
            if not m:
                continue
            sc = split_cell(r.get(c))
            net = m.group(1)
            metrics["IR_%s_mV" % net] = sc["value"]
            lim = [p for p in sc["parts"] if p.startswith("limit:")]
            ir_worst.append({"net": net, "supply": m.group(2), "mv": sc["value"],
                             "limit": fnum(lim[0][6:]) if lim else None,
                             "device": sc["parts"][-1] if len(sc["parts"]) >= 3 else None})
        em_ok = (r.get("Pass/Fail(EM)") or "").lower()
        ir_ok = (r.get("Pass/Fail(IR)") or "").lower()
        if em_ok == "fail" or ir_ok == "fail":
            passed = False
        elif em_ok == "pass" and ir_ok in ("pass", ""):
            passed = True
        else:
            passed = None
        metrics["EM"] = r.get("Pass/Fail(EM)")
        metrics["IR"] = r.get("Pass/Fail(IR)")
        worst = None
        if ir_worst:
            w = max(ir_worst, key=lambda x: x["mv"] or 0.0)
            worst = w["device"]
        # tables
        trows = []
        ads = os.path.join(sim_dir, "pwr_sig_sh_em", "adsRpt")
        for sub in ("Dynamic", "SignalEM"):
            for mode in ("avg", "rms", "peak"):
                for f in sorted(glob.glob(os.path.join(ads, sub, "*.em.worst.%s" % mode))):
                    for e in parse_em_worst(f):
                        sev = "fail" if (e["ratio"] or 0) > 100.0 else "warn"
                        trows.append(["", sev, "EM", "%s/%s" % (sub, mode), e["layer"],
                                      e["location"], e["ratio"], e["net"], e["raw"]])
        for w in ir_worst:
            sev = "fail" if (w["limit"] and w["mv"] and w["mv"] > w["limit"]) else ""
            trows.append([w["device"] or "", sev, "IR worst", w["net"], "", "", w["mv"],
                          w["net"], "limit %s mV" % (w["limit"],)])
        for f in sorted(glob.glob(os.path.join(ads, "Dynamic", "*.ir.worst"))):
            for e in parse_ir_worst(f):
                trows.append(["", "", "IR", "Dynamic", e["layer"], e["location"], e["drop_mv"],
                              e["net"], "%.4f V of %.4f V" % (e["voltage"], e["ideal"])])
        ps = os.path.join(ads, "power_summary.rpt")
        if os.path.isfile(ps):
            pwr = parse_power_summary(ps)
            metrics["Total_Power_W"] = pwr["total_W"]
        table_path = os.path.join(tables_dir, "emir_%s.tsv" % safe_name(key))
        rk_common.write_tsv(table_path, ["_inst", "_sev", "Kind", "Mode", "Layer", "Location",
                                         "Value", "Net", "Detail"], trows)
        out.append({"key": key, "corner": (cmap.get(key) or {}).get("corner") or r.get("Corner"),
                    "stress_id": None, "pass": passed, "metrics": metrics,
                    "worst_device": worst, "worst_model": None,
                    "temperature": r.get("Temp"), "life": r.get("Life_Time"),
                    "ir_worst": ir_worst, "sim_dir": sim_dir.replace("\\", "/"),
                    "table_path": table_path.replace("\\", "/")})
    return out


# --------------------------------------------------------------------------
# collect

def run_corner_lookup(run):
    return {c.get("key"): c for c in (run.get("corner_map") or [])}


def summary_table(run_type, corners, path):
    if run_type == "aging":
        mcols = ["didsat(HCI+BTI,%)", "didlin(HCI+BTI,%)", "dvtlin_Core(HCI+BTI,V)", "Dtemp"]
    elif run_type == "deos":
        mcols = ["Total_DPM", "Max_Dev_DPM", "violations", "vgs_vgd", "vds", "vdb", "vbs", "vgb"]
    else:
        mcols = sorted(set(k for c in corners for k in c["metrics"]
                           if k.endswith("_pct") or k.startswith("IR_") or k == "Total_Violations"))
    header = ["_key", "_sev", "Corner", "Stress", "Temp", "Pass"] + mcols + ["Worst device", "Model"]
    rows = []
    for c in corners:
        pf = "Pass" if c["pass"] is True else ("Fail" if c["pass"] is False else "?")
        rows.append([c["key"], "fail" if c["pass"] is False else "", c["corner"],
                     c.get("stress_id") or "", c.get("temperature"), pf] +
                    [_fmt(c["metrics"].get(m)) for m in mcols] +
                    [c.get("worst_device"), c.get("worst_model")])
    rk_common.write_tsv(path, header, rows)


def _fmt(v):
    if isinstance(v, float):
        return "%.4g" % v
    return v


def collect(run_dir):
    import rk_submit  # run.json helpers (lazy: avoids an import cycle)
    run_dir = os.path.abspath(run_dir)
    run = rk_submit.load_run(run_dir)
    type_dir = run.get("type_dir")
    summ = os.path.join(type_dir or "", "summary_rpt", "summary.txt")
    old = os.path.join(run_dir, "summary.json")
    if not type_dir or not os.path.isdir(type_dir):
        if os.path.isfile(old):
            res = rk_common.read_json(old)
            res["raw_data_present"] = False
            return res
        raise rk_common.RkError("raw data is gone (%s) and no summary.json was saved" % type_dir)
    if not os.path.isfile(summ):
        raise rk_common.RkError("no RelStudio summary yet: %s" % summ)
    tables = os.path.join(run_dir, "tables")
    os.makedirs(tables, exist_ok=True)
    parser = {"aging": parse_aging, "deos": parse_deos, "emir": parse_emir}[run["type"]]
    corners = parser(run, tables)
    stp = os.path.join(tables, "summary.tsv")
    summary_table(run["type"], corners, stp)
    res = {"ok": True, "error": None, "cmd": "collect", "type": run["type"],
           "run_id": run.get("id"), "summary_table_path": stp.replace("\\", "/"),
           "corners": corners, "raw_data_present": True,
           "pass": (all(c["pass"] is True for c in corners) if corners and
                    all(c["pass"] is not None for c in corners)
                    else (False if any(c["pass"] is False for c in corners) else None))}
    rk_common.write_json(old, res)

    def upd(r):
        r["summary"] = {"pass": res["pass"], "n_corners": len(corners),
                        "corners": [{"key": c["key"], "corner": c["corner"],
                                     "stress_id": c.get("stress_id"), "pass": c["pass"],
                                     "worst_device": c.get("worst_device"),
                                     "metrics": c["metrics"]} for c in corners]}
        r["summary_ready"] = True
    rk_submit.update_run(run_dir, upd)
    return res


def _cmd_collect(args, ctx):
    res = collect(args.run)
    return {k: v for k, v in res.items() if k not in ("ok", "error", "cmd")}


def register(subparsers):
    p = rk_common.add_command(subparsers, "collect", _cmd_collect,
                              "parse a finished run into summary.json + TSV tables",
                              ctx_required=False)
    p.add_argument("--run", required=True, help="run record directory (absolute)")
