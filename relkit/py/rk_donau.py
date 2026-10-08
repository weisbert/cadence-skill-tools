"""Donau settings for RelStudio jobs, taken from Maestro job policies.

Owner rule: do not re-invent the cluster settings -- the user already keeps
them in Maestro job policies (``.cadence/jobpolicy/<name>.jp``). By default a
run uses the job policy Maestro currently uses for the test; the panel may
pick any other policy, or a site ``donau_profiles`` entry (the fallback).

A job policy is a flat key=value table (axlGetJobPolicy / maeGetJobPolicy
return the same keys as a DPL; the .jp file stores them one per line). Only
``distributionmethod=Command`` policies whose ``jobsubmitcommand`` is a
``dsub`` line can be mapped:

    dsub -A <account> -q <queue> -R "cpu=8;mem=8000"
        -A        -> Cluster.Group
        -q        -> Cluster.Queue
        -R cpu=   -> Cluster.CPU
        -R mem=   -> Cluster.Memory  (MB, the unit RelStudio writes back into
                                      its own dsub line: yml Memory 12000 <->
                                      dsub mem=12000)
        -R gpu=   -> Cluster.GPU
Other options (-Kco, -n, -o, -postH ...) are ignored. Keys the policy does not
give (Using_Cluster, Cluster_Type, Machine_Arch, GPU, missing cpu/mem) come
from the site ``cluster`` section.

Choice values (settings.<type>.donau_profile):
    "maestro"         the policy Maestro uses for the test (default)
    "policy:<name>"   a named job policy
    "<name>" / "site:<name>"   a site donau_profiles entry (legacy values are
                      bare site names, so old settings keep working)
"""

import os
import re
import shlex

import rk_common
import rk_site

CLUSTER_KEYS = ["Using_Cluster", "Cluster_Type", "Group", "Queue", "CPU", "Memory", "GPU",
                "Machine_Arch"]
MAESTRO = "maestro"
POLICY_PREFIX = "policy:"
SITE_PREFIX = "site:"


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def parse_jp_text(text):
    """.jp file text -> {key: value} (key=value lines; blank / # lines ignored)."""
    out = {}
    for line in (text or "").splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def read_jp(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return parse_jp_text(f.read())


_MEM_RE = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)\s*([kKmMgGtT]?)[bB]?\s*$")
_MEM_SCALE = {"": 1, "M": 1, "K": 1.0 / 1024, "G": 1024, "T": 1024 * 1024}


def _mem_mb(v):
    m = _MEM_RE.match(v or "")
    if not m:
        raise ValueError("cannot read mem=%r" % v)
    mb = float(m.group(1)) * _MEM_SCALE[m.group(2).upper()]
    return int(round(mb))


def _int(v, what):
    try:
        f = float(v)
    except (TypeError, ValueError):
        raise ValueError("cannot read %s=%r" % (what, v))
    return int(f) if f == int(f) else f


def parse_resources(spec, into):
    """'cpu=8;mem=8000' (';' ',' or blanks between items) -> into{CPU, Memory, GPU}."""
    for item in re.split(r"[;,\s]+", spec or ""):
        if "=" not in item:
            continue
        k, v = item.split("=", 1)
        k = k.strip().lower()
        v = v.strip()
        if k == "cpu":
            into["CPU"] = _int(v, "cpu")
        elif k in ("mem", "memory"):
            into["Memory"] = _mem_mb(v)
        elif k == "gpu":
            into["GPU"] = _int(v, "gpu")
    return into


def parse_submit_command(cmd):
    """jobsubmitcommand -> {Group, Queue, CPU, Memory, GPU} (only keys present).

    Raises ValueError with a readable reason when it is not a dsub line."""
    if not cmd or not cmd.strip():
        raise ValueError("jobsubmitcommand is empty")
    try:
        toks = shlex.split(cmd, posix=True)
    except ValueError as e:
        raise ValueError("cannot split jobsubmitcommand (%s)" % e)
    i = 0
    # leading VAR=value assignments and `env` are allowed before the tool
    while i < len(toks) and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[i]) or toks[i] == "env"):
        i += 1
    if i >= len(toks):
        raise ValueError("jobsubmitcommand has no command")
    tool = os.path.basename(toks[i])
    if tool != "dsub":
        raise ValueError("jobsubmitcommand is not a dsub command (%s)" % tool)
    out = {}
    j = i + 1
    while j < len(toks):
        t = toks[j]
        nxt = toks[j + 1] if j + 1 < len(toks) else None
        if t in ("-A", "-q", "-R") and nxt is not None:
            if t == "-A":
                out["Group"] = nxt
            elif t == "-q":
                out["Queue"] = nxt
            else:
                parse_resources(nxt, out)
            j += 2
            continue
        if t.startswith("-R") and len(t) > 2:          # -Rcpu=8;mem=8000
            parse_resources(t[2:], out)
        j += 1
    return out


# ---------------------------------------------------------------------------
# Policies from ctx.job_policy (written by rkMae)
# ---------------------------------------------------------------------------

def _props_of(entry):
    """Policy entry {name, path, props} -> props (read the .jp when SKILL gave none)."""
    props = entry.get("props") if isinstance(entry, dict) else None
    if isinstance(props, dict) and props:
        return dict((str(k), "" if v is None else str(v)) for k, v in props.items())
    path = entry.get("path") if isinstance(entry, dict) else None
    if path and os.path.isfile(path):
        return read_jp(path)
    return None


def policies(ctx):
    """ctx.job_policy -> (current_name, current_props, {name: entry}) with entry
    = {name, path, mtime, props}."""
    jp = (ctx or {}).get("job_policy")
    if not isinstance(jp, dict):
        return None, None, {}
    avail = {}
    for e in jp.get("available") or []:
        if not isinstance(e, dict) or not e.get("name"):
            continue
        name = str(e["name"])
        if name in avail:
            continue
        path = e.get("path")
        mtime = None
        if path and os.path.isfile(path):
            mtime = os.path.getmtime(path)
        avail[name] = {"name": name, "path": path, "mtime": mtime, "props": _props_of(e)}
    cur = jp.get("current")
    cur = dict((str(k), "" if v is None else str(v)) for k, v in cur.items()) \
        if isinstance(cur, dict) and cur else None
    cur_name = jp.get("current_name") or (cur or {}).get("name")
    if cur is None and cur_name and cur_name in avail:
        cur = avail[cur_name]["props"]
    return cur_name, cur, avail


def policy_cluster(props, site):
    """Job policy props -> (Cluster block, notes) or raise ValueError(reason)."""
    if not props:
        raise ValueError("job policy properties unavailable")
    method = (props.get("distributionmethod") or "").strip()
    if method != "Command":
        raise ValueError("distributionmethod is %s, not Command" % (method or "empty"))
    got = parse_submit_command(props.get("jobsubmitcommand"))
    base = rk_site.get(site, "cluster") or {}
    block = {}
    for k in CLUSTER_KEYS:
        block[k] = base.get(k)
    notes = []
    for k in ("Group", "Queue", "CPU", "Memory"):
        if k in got:
            block[k] = got[k]
        else:
            notes.append("%s not in the policy (site value %s)" % (k, block.get(k)))
    if "GPU" in got:
        block["GPU"] = got["GPU"]
    block["Using_Cluster"] = True
    if not block.get("Cluster_Type"):
        block["Cluster_Type"] = "donau"
    return block, notes


# ---------------------------------------------------------------------------
# Site profiles (fallback)
# ---------------------------------------------------------------------------

def site_profiles(site):
    """{name: cluster dict}: site donau_profiles merged over `cluster`; without
    profiles the single `cluster` section is the profile "default"."""
    base = rk_site.get(site, "cluster") or {}
    prof = rk_site.get(site, "donau_profiles")
    out = {}
    if isinstance(prof, dict) and prof:
        for name in sorted(prof):
            p = prof[name]
            if name.startswith("_") or not isinstance(p, dict):
                continue
            out[name] = rk_site.deep_merge(base, p)
    if not out:
        out["default"] = dict(base)
    return out


def site_default(site, run_type, profiles=None):
    profiles = profiles if profiles is not None else site_profiles(site)
    want = rk_site.get(site, "donau_default") or {}
    want = want.get(run_type) if isinstance(want, dict) else None
    if want in profiles:
        return want
    if "default" in profiles:
        return "default"
    return sorted(profiles)[0]


def site_block(site, name, profiles=None):
    profiles = profiles if profiles is not None else site_profiles(site)
    if name not in profiles:
        raise rk_common.RkError("unknown Donau profile %r (site donau_profiles: %s)"
                                % (name, ", ".join(sorted(profiles))))
    c = profiles[name]
    out = {}
    for k in CLUSTER_KEYS:
        out[k] = c.get(k)
    if out["Using_Cluster"] is None:
        out["Using_Cluster"] = True
    return out


# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

def sim_mt(site, block, override=None):
    """Simulator thread count: panel override, else site simulator.Sim_Mt when
    it is a number, else the cluster CPU, else 8."""
    for v in (override, (rk_site.get(site, "simulator") or {}).get("Sim_Mt")):
        if v is None or (isinstance(v, str) and v.strip().lower() in ("", "auto", "cpu")):
            continue
        try:
            return int(v)
        except (TypeError, ValueError):
            continue
    cpu = (block or {}).get("CPU")
    try:
        return int(cpu) if cpu not in (None, "") else 8
    except (TypeError, ValueError):
        return 8


def _site_choice(site, run_type, name, profiles, reason=None):
    return {"value": name, "kind": "site", "name": name, "path": None, "mtime": None,
            "block": site_block(site, name, profiles), "ok": True, "reason": reason,
            "notes": []}


def _policy_choice(value, name, entry_props, path, mtime, site):
    try:
        block, notes = policy_cluster(entry_props, site)
        return {"value": value, "kind": "policy", "name": name, "path": path, "mtime": mtime,
                "block": block, "ok": True, "reason": None, "notes": notes}
    except ValueError as e:
        return {"value": value, "kind": "policy", "name": name, "path": path, "mtime": mtime,
                "block": None, "ok": False, "reason": str(e), "notes": []}


def evaluate(ctx, site, value, run_type):
    """One choice value -> choice dict (block None + ok False when unusable)."""
    profiles = site_profiles(site)
    cur_name, cur, avail = policies(ctx)
    v = (value or "").strip()
    if v == MAESTRO:
        if cur is None and not cur_name:
            return {"value": v, "kind": "policy", "name": None, "path": None, "mtime": None,
                    "block": None, "ok": False, "notes": [],
                    "reason": "Maestro reports no job policy for this test"}
        e = avail.get(cur_name) or {}
        return _policy_choice(v, cur_name, cur or e.get("props"), e.get("path"),
                              e.get("mtime"), site)
    if v.startswith(POLICY_PREFIX):
        name = v[len(POLICY_PREFIX):]
        e = avail.get(name)
        if e is None:
            return {"value": v, "kind": "policy", "name": name, "path": None, "mtime": None,
                    "block": None, "ok": False, "notes": [],
                    "reason": "job policy %s is not available" % name}
        return _policy_choice(v, name, e.get("props"), e.get("path"), e.get("mtime"), site)
    name = v[len(SITE_PREFIX):] if v.startswith(SITE_PREFIX) else v
    if name in profiles:
        return _site_choice(site, run_type, name, profiles)
    return {"value": v, "kind": "site", "name": name, "path": None, "mtime": None,
            "block": None, "ok": False, "notes": [],
            "reason": "Donau profile %s is not in the site config" % name}


def default_value(ctx, site, run_type):
    """'maestro' when Maestro's policy maps to dsub, else the site default."""
    if evaluate(ctx, site, MAESTRO, run_type)["ok"]:
        return MAESTRO
    return site_default(site, run_type)


def resolve(ctx, site, run_type, wanted=None, warnings=None):
    """-> choice dict with a usable block. An unusable pick falls back to the
    Maestro policy, then the site default, with a warning."""
    value = wanted if wanted else default_value(ctx, site, run_type)
    ch = evaluate(ctx, site, value, run_type)
    if ch["ok"]:
        return ch
    fb = default_value(ctx, site, run_type)
    if fb == value:
        fb = site_default(site, run_type)
    fch = evaluate(ctx, site, fb, run_type)
    if not fch["ok"]:
        fb = site_default(site, run_type)
        fch = evaluate(ctx, site, fb, run_type)
    fch = dict(fch)
    fch["reason"] = "%s not usable (%s); using %s" % (_label_value(value), ch["reason"],
                                                      _label_value(fch["value"]))
    if warnings is not None:
        warnings.append("Donau: " + fch["reason"])
    return fch


def _label_value(value):
    if value == MAESTRO:
        return "the Maestro job policy"
    if value.startswith(POLICY_PREFIX):
        return "job policy " + value[len(POLICY_PREFIX):]
    return "site profile " + (value[len(SITE_PREFIX):] if value.startswith(SITE_PREFIX) else value)


def summary(ch, site, override=None):
    b = ch.get("block")
    if not b:
        return "not usable: %s" % ch.get("reason")
    # file name only (the panel line is short); run.json keeps the full path
    src = os.path.basename(ch["path"]) if ch.get("path") else \
        ("Maestro setup" if ch.get("kind") == "policy" else "site config")
    txt = "Group %s, Queue %s, CPU %s, Mem %s, Sim_Mt %s -- %s" % (
        b.get("Group"), b.get("Queue"), b.get("CPU"), b.get("Memory"),
        sim_mt(site, b, override), src)
    if b.get("Using_Cluster") is False:
        txt += "  (cluster OFF: local run)"
    return txt


def choices(ctx, site, run_type):
    """Cyclic entries for one page: Maestro current, every policy, site profiles."""
    cur_name, cur, avail = policies(ctx)
    out = []
    if cur is not None or cur_name:
        ch = evaluate(ctx, site, MAESTRO, run_type)
        ch["label"] = "Maestro current (%s)" % (cur_name or "?")
        out.append(ch)
    for name in sorted(avail):
        ch = evaluate(ctx, site, POLICY_PREFIX + name, run_type)
        ch["label"] = name
        out.append(ch)
    for name in sorted(site_profiles(site)):
        ch = evaluate(ctx, site, name, run_type)
        ch["label"] = SITE_PREFIX + " " + name
        out.append(ch)
    for ch in out:
        ch["summary"] = summary(ch, site)
        ch["sim_mt"] = sim_mt(site, ch.get("block")) if ch.get("block") else None
    return out


def record(ch, site, override=None):
    """What run.json keeps about the resolved Donau settings."""
    return {"value": ch.get("value"), "kind": ch.get("kind"), "name": ch.get("name"),
            "path": ch.get("path"), "mtime": ch.get("mtime"), "reason": ch.get("reason"),
            "notes": ch.get("notes") or [], "sim_mt": sim_mt(site, ch.get("block"), override)}


def pin_for_rerun(value, rec):
    """A run that used 'maestro' reruns with the policy it actually used."""
    if value == MAESTRO and isinstance(rec, dict) and rec.get("kind") == "policy" \
            and rec.get("name"):
        return POLICY_PREFIX + rec["name"]
    return value


# ---------------------------------------------------------------------------
# CLI: donau (choices for the panel)
# ---------------------------------------------------------------------------

def _cmd_donau(args, ctx):
    site, _p, site_warn = rk_site.site_from_ctx(ctx)
    cur_name, _cur, avail = policies(ctx)
    out = {"current_name": cur_name, "policies": sorted(avail), "types": {},
           "warnings": list(site_warn)}
    for t in ("aging", "deos", "emir"):
        out["types"][t] = {"choices": choices(ctx, site, t),
                           "default": default_value(ctx, site, t)}
    return out


def register(subparsers):
    rk_common.add_command(subparsers, "donau", _cmd_donau,
                          "Donau choices per run type (Maestro job policies + site profiles)",
                          ctx_required=True)
