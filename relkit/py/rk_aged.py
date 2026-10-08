"""rk_aged -- R1: persist the Stress HRMI files and write the aged include (plan 4.6, D11/D20).

aged-include --run DIR [--stress ID]... [--netlist CURRENT.scs]
aged-delta   --run DIR --tsv DELTA.tsv [--history NAME]

For every Stress of an aging run:
  1. copy simN/<Life>_point/Stress_1/<cell>_Stress_1/<cell>_Stress_1.hrmiage0 and
     .hrmiage0.dat into <run_dir>/hrmi/<stress_id>/;
  2. rewrite the copied .hrmiage0's `age_data_file 1 <abs path>` line to the
     copied .dat (it is an absolute path);
  3. write aged_<stress_id>.scs = the HRMI injection block RelStudio appends
     to the Aged netlist (simulator lang=spectre / include ...AGEING_MACRO /
     option1..4 / simulator lang=spice / .option dagetime=<Life>), taken
     verbatim from the run's own Aged_k netlist tail -- PDK paths are copied,
     never hard-coded -- with hrmiinput= pointing at the copied .hrmiage0.

Files already persisted are reused when the Work_Dir was cleaned meanwhile;
otherwise the Stress is reported under "missing" (rerun the Stress).
--netlist: compare that netlist's instance signature with the one recorded at
submit (out: netlist_match true/false/null).
Every item also carries `corner_def` = the run's own corner entry (sections,
vars, temperature as used by the Stress), so rkAged can rebuild the corner in
Maestro even when the Maestro corner was edited since.

aged-delta: record a fresh/aged delta TSV written by rkAgedDeltaTable (SKILL,
read from a Maestro history) in the run record -- copied to
tables/aged_delta_<history>.tsv, listed in run.json `aged_delta[]` -- and
regenerate aux_report.html so the report shows it.

Python 3.8+, stdlib only.
"""

import glob
import os
import re
import shutil

import rk_common
import rk_yml

TAIL_BYTES = 256 * 1024
AGE_DATA_RE = re.compile(r"^(\s*age_data_file\s+)(\S+)(\s+)(\S+)(.*)$")
HRMIINPUT_RE = re.compile(r'hrmiinput\s*=\s*"[^"]*"')


def posix(p):
    return p.replace("\\", "/") if p else p


def rewrite_hrmiage0(text, new_dat):
    """Point `age_data_file <flag> <path>` at new_dat (flag 1 = absolute)."""
    out = []
    done = False
    for line in text.splitlines(True):
        m = AGE_DATA_RE.match(line.rstrip("\r\n"))
        if m and not done:
            nl = line[len(line.rstrip("\r\n")):]
            line = "%s1%s%s%s%s" % (m.group(1), m.group(3), new_dat, m.group(5), nl)
            done = True
        out.append(line)
    if not done:
        raise rk_common.RkError("no age_data_file line in .hrmiage0")
    return "".join(out)


def read_tail(path, nbytes=TAIL_BYTES):
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - nbytes))
        return f.read().decode("utf-8", errors="replace")


def injection_block(aged_netlist_text):
    """The HRMI block at the end of an Aged netlist (list of lines) or None.

    Starts at the last `simulator lang=spectre` before the `hrmiinput=` option,
    ends after the `.option dagetime=` line."""
    lines = aged_netlist_text.splitlines()
    hi = None
    for i in range(len(lines) - 1, -1, -1):
        if "hrmiinput" in lines[i]:
            hi = i
            break
    if hi is None:
        return None
    start = None
    for i in range(hi, -1, -1):
        if re.match(r"^\s*simulator\s+lang\s*=\s*spectre\b", lines[i]):
            start = i
            break
    if start is None:
        return None
    end = None
    for i in range(hi, len(lines)):
        if re.match(r"^\s*\.option\s+dagetime\s*=", lines[i], re.I):
            end = i
            break
    if end is None:
        return None
    block = [l for l in lines[start:end + 1] if not re.match(r"^\s*\.alter\b", l)]
    return block


def aged_include_text(block, hrmiage0, run_id, stress_id):
    body = []
    for l in block:
        if "hrmiinput" in l:
            l = HRMIINPUT_RE.sub('hrmiinput="%s"' % hrmiage0, l)
        body.append(l)
    head = ["// relkit aged include (R1) -- run %s, Stress %s" % (run_id, stress_id),
            "// HRMI block copied from the run's Aged netlist; hrmiinput points at the",
            "// persisted .hrmiage0. Attach as a corner model file without a section."]
    return "\n".join(head + body + ["simulator lang=spectre", ""])


def stress_sources(run):
    """[{stress_id, key, corner, sim_dir, eval_temperatures}] for an aging run."""
    import rk_parse
    import rk_submit
    type_dir = run["type_dir"]
    out = []
    ids = rk_parse.read_summary_ids(type_dir) if os.path.isdir(type_dir) else {}
    cmap = {c.get("key"): c for c in run.get("corner_map") or []}
    by_sim = {}
    if os.path.isdir(type_dir):
        for s in rk_submit.sim_dirs(run):
            by_sim[s["sim"]] = s
    if ids:
        for sid, p in sorted(ids.items(), key=lambda kv: (len(kv[0]), kv[0])):
            sim = os.path.basename(p.rstrip("/"))
            key = (by_sim.get(sim) or {}).get("key")
            c = cmap.get(key) or {}
            out.append({"stress_id": str(sid), "key": key, "corner": c.get("corner"), "sim": sim,
                        "sim_dir": posix(os.path.join(type_dir, sim)),
                        "eval_temperatures": c.get("eval_temperatures") or
                        ([c.get("temperature")] if c.get("temperature") else [])})
        return out
    # no summary_id.yml: Stress id = order of sims (RelStudio numbers them that way)
    summ = run.get("summary") or {}
    known = {c.get("key"): c.get("stress_id") for c in summ.get("corners") or []}
    sims = list(by_sim.values()) or [{"sim": c.get("sim"), "key": c.get("key")}
                                     for c in run.get("corner_map") or []]
    for i, s in enumerate(sims, 1):
        c = cmap.get(s.get("key")) or {}
        out.append({"stress_id": str(known.get(s.get("key")) or i), "key": s.get("key"),
                    "corner": c.get("corner"), "sim": s.get("sim"),
                    "sim_dir": posix(os.path.join(type_dir, s.get("sim") or "")),
                    "eval_temperatures": c.get("eval_temperatures") or
                    ([c.get("temperature")] if c.get("temperature") else [])})
    return out


def _find_one(pattern):
    hits = sorted(glob.glob(pattern))
    return hits[0] if hits else None


def prepare(run_dir, stress_ids=None, current_netlist=None):
    import rk_submit
    run_dir = os.path.abspath(run_dir)
    run = rk_submit.load_run(run_dir)
    if run.get("type") != "aging":
        raise rk_common.RkError("aged-include needs an aging run (this is %s)" % run.get("type"))
    st = run.get("settings") or {}
    life = rk_yml.life_suffix(st.get("life_time") or "10", st.get("life_time_unit") or "years")
    items, missing = [], []
    cdefs = {c.get("name"): c for c in run.get("corners") or [] if isinstance(c, dict)}
    hrmi_root = os.path.join(run_dir, "hrmi")
    want = set(str(s) for s in stress_ids) if stress_ids else None
    for src in stress_sources(run):
        sid = src["stress_id"]
        if want is not None and sid not in want:
            continue
        dst = os.path.join(hrmi_root, safe(sid))
        sim_dir = src["sim_dir"]
        h0 = _find_one(os.path.join(sim_dir, "*_point", "Stress_1", "*_Stress_1", "*_Stress_1.hrmiage0"))
        dat = (h0 + ".dat") if h0 and os.path.isfile(h0 + ".dat") else None
        aged_nl = _find_one(os.path.join(sim_dir, "*_point", "Aged_1", "*_Aged_1.scs")) or \
            _find_one(os.path.join(sim_dir, "*_point", "Aged_*", "*_Aged_*.scs"))
        inc = os.path.join(dst, "aged_%s.scs" % safe(sid))
        if h0 and dat and aged_nl:
            block = injection_block(read_tail(aged_nl))
            if not block:
                missing.append({"stress_id": sid, "reason": "no HRMI block found in %s" % posix(aged_nl)})
                continue
            os.makedirs(dst, exist_ok=True)
            new_h0 = os.path.join(dst, os.path.basename(h0))
            new_dat = os.path.join(dst, os.path.basename(dat))
            shutil.copyfile(dat, new_dat)
            with open(h0, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
            with open(new_h0, "w", encoding="utf-8", newline="\n") as f:
                f.write(rewrite_hrmiage0(text, posix(new_dat)))
            with open(inc, "w", encoding="utf-8", newline="\n") as f:
                f.write(aged_include_text(block, posix(new_h0), run.get("id"), sid))
            m = re.search(r"dagetime\s*=\s*(\S+)", "\n".join(block))
            life_used = m.group(1) if m else life
        else:
            prev_h0 = _find_one(os.path.join(dst, "*.hrmiage0"))
            if prev_h0 and os.path.isfile(prev_h0 + ".dat") and os.path.isfile(inc):
                new_h0, new_dat, life_used = prev_h0, prev_h0 + ".dat", life
            else:
                why = []
                if not h0:
                    why.append(".hrmiage0")
                elif not dat:
                    why.append(".hrmiage0.dat")
                if not aged_nl:
                    why.append("Aged netlist")
                raw = os.path.isdir(sim_dir)
                missing.append({"stress_id": sid, "key": src.get("key"),
                                "reason": ("Work_Dir cleaned; rerun Stress" if not raw else
                                           "missing in Work_Dir: %s; rerun Stress" % ", ".join(why))})
                continue
        items.append({"stress_id": sid, "key": src.get("key"), "corner": src.get("corner"),
                      "corner_def": corner_def(cdefs.get(src.get("corner")), src),
                      "eval_temperatures": [str(t) for t in src.get("eval_temperatures") or []],
                      "life": life_used,
                      "hrmi_dir": posix(dst), "hrmiage0": posix(new_h0), "dat": posix(new_dat),
                      "include_path": posix(inc)})
    sig = (run.get("netlist") or {}).get("signature")
    cur_sig, match = None, None
    if current_netlist:
        if os.path.isfile(current_netlist):
            cur_sig = rk_yml.netlist_signature(current_netlist)
            match = (cur_sig == sig) if sig else None
        else:
            raise rk_common.RkError("--netlist not found: %s" % current_netlist)

    def upd(r):
        # merge: `--stress 2` must not drop the Stress 1 files persisted earlier
        hrmi = dict(r.get("hrmi") or {})
        hrmi.update({i["stress_id"]: {k: i[k] for k in ("hrmiage0", "dat", "include_path",
                                                         "key", "corner")} for i in items})
        for m in missing:
            hrmi.pop(m["stress_id"], None)
        r["hrmi"] = hrmi
    rk_submit.update_run(run_dir, upd)
    return {"run_id": run.get("id"), "run_dir": posix(run_dir), "test": run.get("test"),
            "maestro": run.get("maestro"), "life": life,
            "netlist_sha1": (run.get("netlist") or {}).get("sha1"),
            "netlist_signature": sig, "current_signature": cur_sig, "netlist_match": match,
            "items": items, "missing": missing}


def safe(s):
    return re.sub(r"[^A-Za-z0-9._+-]", "_", str(s))


def corner_def(c, src):
    """The corner as the Stress simulated it: {name, base_name, sections[], temperature,
    vars{}}, or None when run.json has no such corner (rkAged then looks the corner up
    in the current Maestro ctx)."""
    if c:
        return {"name": c.get("name"), "base_name": c.get("base_name"),
                "sections": [{"model_file": x.get("model_file"), "section": x.get("section")}
                             for x in c.get("sections") or [] if isinstance(x, dict)],
                "temperature": None if c.get("temperature") is None else str(c.get("temperature")),
                "vars": {k: ("" if v is None else str(v)) for k, v in (c.get("vars") or {}).items()}}
    return None


# --------------------------------------------------------------------------
# aged-delta: fresh/aged delta table from Maestro (written by SKILL) -> run record

DELTA_COLS = ("Output", "Fresh corner", "Aged corner", "Fresh", "Aged", "Delta", "Delta %")


def read_delta_tsv(path):
    """(header, rows) of a delta TSV; checks the columns rkAgedDeltaTable writes."""
    with open(path, "r", encoding="utf-8") as f:
        lines = [l.rstrip("\r\n") for l in f]
    lines = [l for l in lines if l.strip()]
    if not lines:
        raise rk_common.RkError("empty delta table: %s" % path)
    header = lines[0].split("\t")
    miss = [c for c in DELTA_COLS if c not in header]
    if miss:
        raise rk_common.RkError("not a relkit delta table (missing columns %s): %s"
                                % (", ".join(miss), path))
    return header, [l.split("\t") for l in lines[1:]]


def _num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def record_delta(run_dir, tsv, history=None):
    import rk_report
    import rk_submit
    import datetime
    run_dir = os.path.abspath(run_dir)
    run = rk_submit.load_run(run_dir)
    if not os.path.isfile(tsv):
        raise rk_common.RkError("delta table not found: %s" % tsv)
    header, rows = read_delta_tsv(tsv)
    hist = history or "history"
    dst = os.path.join(run_dir, "tables", "aged_delta_%s.tsv" % safe(hist))
    if os.path.abspath(tsv) != os.path.abspath(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(tsv, dst)
    i_d = header.index("Delta")
    numeric = sum(1 for r in rows if i_d < len(r) and _num(r[i_d]) is not None)
    entry = {"history": history, "table_path": posix(dst), "rows": len(rows),
             "numeric_rows": numeric,
             "created": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")}

    def upd(r):
        lst = [e for e in r.get("aged_delta") or [] if e.get("table_path") != entry["table_path"]]
        r["aged_delta"] = lst + [entry]
    rk_submit.update_run(run_dir, upd)
    rep = rk_report.make_report(run_dir)
    return {"run_id": run.get("id"), "table_path": posix(dst), "rows": len(rows),
            "numeric_rows": numeric, "html_path": rep.get("html_path")}


def _cmd_aged_include(args, ctx):
    return prepare(args.run, args.stress, args.netlist)


def _cmd_aged_delta(args, ctx):
    return record_delta(args.run, args.tsv, args.history)


def register(subparsers):
    p = rk_common.add_command(subparsers, "aged-include", _cmd_aged_include,
                              "prepare persistent HRMI files + aged include per Stress",
                              ctx_required=False)
    p.add_argument("--run", required=True, help="run record directory (absolute)")
    p.add_argument("--stress", action="append", help="Stress id (repeatable; default: all)")
    p.add_argument("--netlist", help="current Maestro netlist: compare its instance signature "
                                     "with the one recorded at submit")
    p = rk_common.add_command(subparsers, "aged-delta", _cmd_aged_delta,
                              "record a fresh/aged delta TSV (from rkAgedDeltaTable) in the run "
                              "record and refresh the aux report", ctx_required=False)
    p.add_argument("--run", required=True, help="aging run record directory (absolute)")
    p.add_argument("--tsv", required=True, help="delta TSV written by rkAgedDeltaTable")
    p.add_argument("--history", help="Maestro history the values were read from")
