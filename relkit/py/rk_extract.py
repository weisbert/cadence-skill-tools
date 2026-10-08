"""rk_extract -- DSPF/GDS extraction chain strmout -> si -> Calibre LVS -> Quantus (plan 4.8).

The method (tool order, command lines, the three option files) is ported from
Auto_ext (github.com/weisbert/Auto_ext, auto_ext/tools/{strmout,si,calibre,
quantus}.py and templates/{si,calibre,quantus}); relkit does not call Auto_ext.
Jinja2 templates became string.Template files in py/templates/ with the few
loops/conditionals pre-rendered here. Jivaro reduction is not part of this flow.

Layout (D17), for DUT cell C under <artifact_root>/C/:

    C.gds  C.dspf               published products (only after a full success)
    extract/
      request.json              everything the worker needs (resolved at start)
      status.json               progress, written atomically by the worker
      extract.log               worker log (step transitions, commands)
      cancel.request            written by extract-cancel
      C.qci  C.dspf.cmd         rendered Calibre runset / Quantus command file
      si/si.env                 rendered si.env (si runs with cwd = si/)
      lvs/                      *lvsRunDir: C.calibre.db (strmout), C.src.net (si),
                                C.lvs.report, query_output/ (Calibre query)
      qrc/C.dspf                Quantus output, moved to ../C.dspf on success
      logs/<step>.log           stdout+stderr of each tool

Chain (cwd = workarea unless noted):
  1. strmout -library L -topCell C -view V -strmFile lvs/C.calibre.db -layerMap M
  2. si -batch -command netlist -cdslib <cds.lib>      (cwd = extract/si)
  3. calibre -gui -lvs -runset C.qci -batch            -> LVS report checked;
     not clean => state lvs_failed, stop; the panel offers the same runset in
     the GUI: calibre -gui -lvs -runset C.qci (no -batch)
  4. qrc -cmd C.dspf.cmd                               -> qrc/C.dspf
  5. publish: copy lvs/C.calibre.db -> C.gds, move qrc/C.dspf -> C.dspf

Parameters (layer map, LVS deck + variant, Quantus deck, tech library and
name, CDL prelude) are derived from the environment by rk_pdk (Auto_ext's
rules); the user chooses LVS variant, RC corner, temperature, the Quantus deck
when several exist, and the LVS power/ground names.

Subcommands: extract-resolve (preview of the derived parameters), extract
(start the detached worker), extract-status, extract-cancel, extract-run
(INTERNAL: the worker itself).

Python 3.8+, stdlib only.
"""

import datetime
import json
import os
import re
import shutil
import signal
import socket
import string
import subprocess
import sys
import time

import rk_common
import rk_pdk
import rk_site

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_DIR = os.path.join(HERE, "templates")

STEPS = ["strmout", "si", "lvs", "qrc"]
FINAL_STATES = ("done", "failed", "lvs_failed", "cancelled")
HEARTBEAT_STALE_SECONDS = 180
POLL_SECONDS = 0.5
LOG_TAIL_LINES = 40

GDS_EXTS = (".gds", ".gds2", ".gdsii", ".gds.gz", ".calibre.db", ".oas", ".oasis")
DSPF_EXTS = (".dspf", ".spf", ".dspf.gz", ".spf.gz")

# Built-in option defaults = Auto_ext's recipe/catalog defaults (options.yaml).
# Site `extract.si_options` / `lvs_options` / `qrc_options` override per key.
SI_DEFAULTS = {
    "sim_simulator": "auCdl",
    "sim_not_incremental": True,
    "sim_renetlist_all": False,
    "sim_view_list": ["auCdl", "schematic"],
    "sim_stop_list": ["auCdl"],
    "short_res": 2000.0,
    "preserve_res": True,
    "check_res_val": True,
    "check_res_size": False,
    "preserve_cap": True,
    "check_cap_val": True,
    "check_cap_area": False,
    "preserve_dio": True,
    "check_dio_area": True,
    "check_dio_peri": True,
    "check_cap_peri": False,
    "sim_print_inh_conn_attributes": False,
    "check_scale": "meter",
    "check_ldd": False,
    "preserve_bang_in_netlist": False,
    "shrink_factor": 0.0,
    "global_power_sig": "",
    "global_gnd_sig": "",
    "display_pin_info": True,
    "preserve_all": True,
}

LVS_DEFAULTS = {
    "device_filter_options_enabled": False,
    "layout_device_filter_options": "AG RC RE RG",
    "source_device_filter_options": "AG RC RE RG",
    "recognize_gates": "NONE",
    "svdb_cci": True,
    "report_options": "S",
    "run_qrc_query": True,
    "abort_on_supply_error": False,
    "connect_by_name": False,
    "license_wait_time": 10,
    "num_turbo": 2,
    "run_mt": True,
    "run_hyper": True,
}

QRC_DEFAULTS = {
    "decoupling_factor": 1.0,
    "extract_rules": [{"selection": "all", "type": "rc_coupled"}],
    "array_vias_spacing": "auto",
    "max_fracture_length": "infinite",
    "max_fracture_length_unit": "MICRONS",
    "max_via_array_size": "auto",
    "parasitic_blocking_device_cells_type": None,
    "extraction_net_name_space": "SCHEMATIC",
    "exclude_self_cap": True,
    "exclude_floating_nets": True,
    "exclude_floating_nets_limit": 5000,
    "coupling_cap_threshold_absolute": 0.01,
    "coupling_cap_threshold_relative": 0.001,
    "merge_parallel_res": True,
    "min_res": 0.001,
    "remove_dangling_res": True,
    "input_db_hierarchy_delimiter": "/",
    "metal_fill_type": "virtual",
    "dspf_subtype": "extended",
    "device_finger_delimiter": "@",
    "busbit_delimiter": "[]",
    "disable_instances": False,
    "output_hierarchy_delimiter": "/",
    "include_cap_model": "false",
    "include_parasitic_cap_model": "false",
    "include_res_model": "false",
    "include_parasitic_res_model": "comment",
    "output_xy": ["CANONICAL_RES", "PARASITIC_RES", "CANONICAL_CAP", "PARASITIC_CAP",
                  "DIODE", "MOS", "BIPOLAR", "GENERIC"],
    "netlist_coupling_values": "double",
    "add_bulk_terminal": False,
    "sub_node_char": "#",
    "output_net_name_space": "SCHEMATIC",
}

# Quantus `extract -selection` members that take an operand (Auto_ext ExtractRule).
_SELECTION_TAKES_ARG = {"all": False, "net": True, "nets_file": True,
                        "net_file": True, "layer_file": True}


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------

def _now_iso():
    return rk_common.now_iso()


def _posix(p):
    return p.replace("\\", "/") if p else p


def _join(*parts):
    return _posix(os.path.join(*parts))


def _skill_bool(v):
    return "'t" if v else "'nil"


def _skill_list(items):
    items = list(items or [])
    if not items:
        return "'()"
    return "'(" + " ".join('"%s"' % x for x in items) + ")"


def _qci_bool(v):
    return "1" if v else "0"


def _tcl_bool(v):
    return "true" if v else "false"


def _num(v):
    """Numbers as Auto_ext's Jinja rendered them (2000.0 stays 2000.0)."""
    return str(v)


def _merged(defaults, override):
    out = dict(defaults)
    for k, v in (override or {}).items():
        if v is not None:
            out[k] = v
    return out


def render_template(rel_path, values):
    """Render py/templates/<rel_path>: drop '##' comment lines, then
    string.Template.substitute (a missing value is an error, not a blank)."""
    path = os.path.join(TEMPLATE_DIR, rel_path)
    with open(path, "r", encoding="utf-8") as f:
        lines = [ln for ln in f.read().splitlines(True) if not ln.startswith("##")]
    try:
        return string.Template("".join(lines)).substitute(values)
    except KeyError as e:
        raise rk_common.RkError("template %s: no value for %s" % (rel_path, e))
    except ValueError as e:
        raise rk_common.RkError("template %s: %s" % (rel_path, e))


def _write_text(path, text):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)


def shell_join(argv):
    """POSIX shell command string for display / `sh -c` (SKILL side)."""
    out = []
    for a in argv:
        a = str(a)
        if a and re.match(r"^[A-Za-z0-9_@%+=:,./-]+$", a):
            out.append(a)
        else:
            out.append("'" + a.replace("'", "'\"'\"'") + "'")
    return " ".join(out)


def tool_argv(spec, name):
    """Site `extract.tools.<name>`: a string (one executable) or a list (argv
    prefix, e.g. [python, /path/fake_tool]); null/empty -> the tool name."""
    if spec is None or spec == "" or spec == []:
        return [name]
    if isinstance(spec, (list, tuple)):
        return [str(x) for x in spec]
    return [str(spec)]


# --------------------------------------------------------------------------
# value builders for the three templates (Jinja logic lives here)
# --------------------------------------------------------------------------

def si_env_values(p):
    o = p["si_options"]
    return {
        "library": p["library"], "cell": p["cell"], "source_view": p["source_view"],
        "sim_simulator": o["sim_simulator"],
        "sim_not_incremental": _skill_bool(o["sim_not_incremental"]),
        # Auto_ext quirk kept: bare nil (not 'nil) when false.
        "sim_renetlist_all": "'t" if o["sim_renetlist_all"] else "nil",
        "sim_view_list": _skill_list(o["sim_view_list"]),
        "sim_stop_list": _skill_list(o["sim_stop_list"]),
        "netlist_file_name": "%s.src.net" % p["cell"],
        "output_dir": p["output_dir"],
        "short_res": _num(o["short_res"]),
        "preserve_res": _skill_bool(o["preserve_res"]),
        "check_res_val": _skill_bool(o["check_res_val"]),
        "check_res_size": _skill_bool(o["check_res_size"]),
        "preserve_cap": _skill_bool(o["preserve_cap"]),
        "check_cap_val": _skill_bool(o["check_cap_val"]),
        "check_cap_area": _skill_bool(o["check_cap_area"]),
        "preserve_dio": _skill_bool(o["preserve_dio"]),
        "check_dio_area": _skill_bool(o["check_dio_area"]),
        "check_dio_peri": _skill_bool(o["check_dio_peri"]),
        "check_cap_peri": _skill_bool(o["check_cap_peri"]),
        "sim_print_inh_conn_attributes": _skill_bool(o["sim_print_inh_conn_attributes"]),
        "check_scale": o["check_scale"],
        "check_ldd": _skill_bool(o["check_ldd"]),
        "preserve_bang_in_netlist": _skill_bool(o["preserve_bang_in_netlist"]),
        "shrink_factor": _num(o["shrink_factor"]),
        "global_power_sig": o["global_power_sig"] or "",
        "global_gnd_sig": o["global_gnd_sig"] or "",
        "display_pin_info": _skill_bool(o["display_pin_info"]),
        "preserve_all": _skill_bool(o["preserve_all"]),
        "inc_file": p["cdl_include_file"] or "",
    }


def lvs_rules_file(p):
    return p["lvs_rules_file"]


def qci_values(p):
    o = p["lvs_options"]
    post = "{{rm -rf %d/query_output} process 1} {{mkdir %d/query_output} process 1}"
    if o["run_qrc_query"]:
        post += " {{calibre -query_input %s -query svdb } process 1}" % p["qrc_query_cmd"]
    return {
        "lvs_rules_file": lvs_rules_file(p),
        "output_dir": p["output_dir"],
        "cell": p["cell"], "library": p["library"],
        "layout_view": p["layout_view"], "source_view": p["source_view"],
        "device_filter_options_enabled": _qci_bool(o["device_filter_options_enabled"]),
        "layout_device_filter_options": o["layout_device_filter_options"],
        "source_device_filter_options": o["source_device_filter_options"],
        "power_names": " ".join(p["power_nets"]),
        "ground_names": " ".join(p["ground_nets"]),
        "recognize_gates": o["recognize_gates"],
        "svdb_cci": _qci_bool(o["svdb_cci"]),
        "report_options": o["report_options"],
        "post_triggers": post,
        "abort_on_supply_error": _qci_bool(o["abort_on_supply_error"]),
        "connect_by_name_line": ("*cmnVConnectNamesState: ALL\n"
                                 if o["connect_by_name"] else ""),
        "license_wait_time": _num(o["license_wait_time"]),
        "num_turbo": _num(o["num_turbo"]),
        "run_mt": _qci_bool(o["run_mt"]),
        "run_hyper": _qci_bool(o["run_hyper"]),
    }


def _extract_blocks(rules):
    out = []
    for r in rules:
        sel = r.get("selection") or "all"
        arg = r.get("selection_arg")
        if sel not in _SELECTION_TAKES_ARG:
            raise rk_common.RkError("qrc extract rule: unknown selection %r" % sel)
        if _SELECTION_TAKES_ARG[sel] and not arg:
            raise rk_common.RkError("qrc extract rule: selection %r needs selection_arg" % sel)
        if not _SELECTION_TAKES_ARG[sel] and arg:
            raise rk_common.RkError("qrc extract rule: selection %r takes no argument" % sel)
        line = '"%s"' % sel if not arg else '"%s" "%s"' % (sel, arg)
        out.append('extract \\\n              -selection %s \\\n              -type "%s"\n'
                   % (line, r.get("type") or "rc_coupled"))
    return "".join(out)


def qrc_values(p):
    o = p["qrc_options"]
    rules = o["extract_rules"] or [{"selection": "all", "type": "rc_coupled"}]
    btype = o.get("parasitic_blocking_device_cells_type")
    xy = o.get("output_xy") or []
    xy_block = ""
    if xy:
        xy_block = "              -output_xy \\\n" + "".join(
            '              "%s" \\\n' % x for x in xy)
    return {
        "decoupling_factor": _num(o["decoupling_factor"]),
        "ground_net": p["qrc_ground_net"],
        "extract_blocks": _extract_blocks(rules),
        "array_vias_spacing": o["array_vias_spacing"],
        "max_fracture_length": o["max_fracture_length"],
        "max_fracture_length_unit": o["max_fracture_length_unit"],
        "max_via_array_size": o["max_via_array_size"],
        "preserve_cell_list": p["qrc_preserve_cell_list"] or "",
        "blocking_type_line": ('              -parasitic_blocking_device_cells_type "%s" \\\n'
                               % btype) if btype else "",
        "extraction_net_name_space": o["extraction_net_name_space"],
        "exclude_self_cap": _tcl_bool(o["exclude_self_cap"]),
        "exclude_floating_nets": _tcl_bool(o["exclude_floating_nets"]),
        "exclude_floating_nets_limit": _num(o["exclude_floating_nets_limit"]),
        "coupling_cap_threshold_absolute": _num(o["coupling_cap_threshold_absolute"]),
        "coupling_cap_threshold_relative": _num(o["coupling_cap_threshold_relative"]),
        "merge_parallel_res": _tcl_bool(o["merge_parallel_res"]),
        "min_res": _num(o["min_res"]),
        "remove_dangling_res": _tcl_bool(o["remove_dangling_res"]),
        "output_dir": p["output_dir"],
        "input_db_hierarchy_delimiter": o["input_db_hierarchy_delimiter"],
        "metal_fill_type": o["metal_fill_type"],
        "dspf_subtype": o["dspf_subtype"],
        "device_finger_delimiter": o["device_finger_delimiter"],
        "busbit_delimiter": o["busbit_delimiter"],
        "disable_instances": _tcl_bool(o["disable_instances"]),
        "output_hierarchy_delimiter": o["output_hierarchy_delimiter"],
        "include_cap_model": o["include_cap_model"],
        "include_parasitic_cap_model": o["include_parasitic_cap_model"],
        "include_res_model": o["include_res_model"],
        "include_parasitic_res_model": o["include_parasitic_res_model"],
        "output_xy_block": xy_block,
        "netlist_coupling_values": o["netlist_coupling_values"],
        "add_bulk_terminal": _tcl_bool(o["add_bulk_terminal"]),
        "sub_node_char": o["sub_node_char"],
        "dspf_out_path": p["qrc_dspf"],
        "output_net_name_space": o["output_net_name_space"],
        "technology_corner": p["technology_corner"],
        "technology_library_file": p["technology_library_file"],
        "technology_name": p["technology_name"],
        "temperature": _num(p["temperature"]),
    }


# --------------------------------------------------------------------------
# parameter resolution (ctx + site -> request)
# --------------------------------------------------------------------------

def extract_dirs(artifact_root, cell):
    adir = _join(artifact_root, cell)
    xdir = _join(adir, "extract")
    return {
        "artifact_dir": adir,
        "extract_dir": xdir,
        "si_dir": _join(xdir, "si"),
        "output_dir": _join(xdir, "lvs"),
        "qrc_dir": _join(xdir, "qrc"),
        "logs_dir": _join(xdir, "logs"),
        "status": _join(xdir, "status.json"),
        "request": _join(xdir, "request.json"),
        "log": _join(xdir, "extract.log"),
        "cancel": _join(xdir, "cancel.request"),
        "qci": _join(xdir, "%s.qci" % cell),
        "dspf_cmd": _join(xdir, "%s.dspf.cmd" % cell),
        "si_env": _join(xdir, "si", "si.env"),
        "layout_db": _join(xdir, "lvs", "%s.calibre.db" % cell),
        "src_net": _join(xdir, "lvs", "%s.src.net" % cell),
        "lvs_report": _join(xdir, "lvs", "%s.lvs.report" % cell),
        "qrc_dspf": _join(xdir, "qrc", "%s.dspf" % cell),
        "gds": _join(adir, "%s.gds" % cell),
        "dspf": _join(adir, "%s.dspf" % cell),
    }


def _ctx_cell(ctx):
    dut = (ctx or {}).get("dut") or {}
    cell = dut.get("cell")
    if not cell:
        raise rk_common.RkError("ctx.dut.cell is not set: pick the DUT first (D13)")
    return cell


def dirs_from_ctx(ctx, site=None):
    if site is None:
        site, _p, _w = rk_site.site_from_ctx(ctx)
    root = site.get("artifact_root")
    if not root:
        raise rk_common.RkError("site artifact_root is not set")
    return extract_dirs(_posix(root), _ctx_cell(ctx))


def _env_of(ctx):
    """The environment the rules resolve against: this process (Virtuoso's,
    inherited by the panel's Python child) overlaid by an optional ctx.env
    snapshot."""
    env = dict(os.environ)
    snap = (ctx or {}).get("env")
    if isinstance(snap, dict):
        env.update({str(k): str(v) for k, v in snap.items() if v is not None})
    return env


def _names(v):
    if isinstance(v, str):
        v = re.split(r"[\s,;]+", v)
    return [x for x in (v or []) if x]


def _user_choices(ctx):
    over = ((ctx or {}).get("settings") or {}).get("extract") or {}
    temp = over.get("temperature")
    return {"lvs_variant": over.get("lvs_variant") or None,
            "qrc_deck": over.get("qrc_deck") or None,
            "technology_corner": over.get("technology_corner") or None,
            "temperature": temp if temp not in (None, "") else None,
            "power_names": _names(over.get("power_names")),
            "ground_names": _names(over.get("ground_names"))}


def dut_supply_ports(ctx, site):
    """DUT ports that look like supplies (rk_yml.classify_port on ctx.dut.terms)."""
    import rk_yml
    pw, gn = [], []
    for t in ((ctx or {}).get("dut") or {}).get("terms") or []:
        k = rk_yml.classify_port(t, site)
        if k == "power":
            pw.append(t)
        elif k == "ground" and t != "0":
            gn.append(t)
    return pw, gn


def _union(a, b):
    out = []
    for x in list(a or []) + list(b or []):
        if x and x not in out:
            out.append(x)
    return out


def _default_supplies(ctx, site, choices):
    """No panel list: the site lists plus the DUT's supply-like ports."""
    if choices["power_names"] or choices["ground_names"]:
        return choices
    pw, gn = dut_supply_ports(ctx, site)
    lists, _w = rk_pdk.migrate_legacy(site.get("extract") or {})
    choices["power_names"] = _union(lists.get("power_names"), pw)
    choices["ground_names"] = _union(lists.get("ground_names"), gn)
    return choices


def resolve_preview(ctx, site):
    """extract-resolve payload: rk_pdk.resolve + DUT-port suggestions."""
    ext = site.get("extract") or {}
    choices = _default_supplies(ctx, site, _user_choices(ctx))
    res = rk_pdk.resolve(ext, _env_of(ctx), choices)
    p = res.pop("params")
    res["suggested"] = {"power_names": list(p.get("power_names") or []),
                        "ground_names": list(p.get("ground_names") or [])}
    return res


def resolve_params(ctx, site):
    """Everything the chain needs, from ctx (DUT, panel choices) and the site
    `extract` rules resolved against the environment (rk_pdk). Raises RkError
    naming every missing environment variable / unresolved choice."""
    ext = site.get("extract") or {}
    dut = ctx.get("dut") or {}
    maestro = ctx.get("maestro") or {}
    over = ((ctx.get("settings") or {}).get("extract") or {})
    cell = _ctx_cell(ctx)
    workarea = _posix(ctx.get("workarea") or rk_site.default_workarea())
    dirs = dirs_from_ctx(ctx, site)
    choices = _default_supplies(ctx, site, _user_choices(ctx))
    r = rk_pdk.resolve(ext, _env_of(ctx), choices)
    rp = r["params"]

    p = dict(dirs)
    p.update({
        "cell": cell,
        "library": over.get("layout_lib") or dut.get("lib") or maestro.get("lib"),
        "layout_view": over.get("layout_view") or ext.get("layout_view") or "layout",
        "source_view": ext.get("source_view") or "schematic",
        "workarea": workarea,
        "cdslib": _posix(ext.get("cdslib") or _join(workarea, "cds.lib")),
        "layer_map": rp.get("layer_map"),
        "calibre_lvs_dir": rp.get("lvs_deck_dir"),
        "calibre_lvs_basename": rp.get("lvs_basename"),
        "lvs_variant": rp.get("lvs_variant"),
        "lvs_rules_file": rp.get("lvs_rules_file"),
        "qrc_deck_dir": rp.get("qrc_deck_dir"),
        "qrc_query_cmd": rp.get("qrc_query_cmd"),
        "qrc_preserve_cell_list": rp.get("qrc_preserve_cell_list"),
        "cdl_include_file": rp.get("cdl_include_file") or "",
        "technology_library_file": rp.get("technology_library_file"),
        "technology_name": rp.get("tech_name"),
        "technology_corner": rp.get("technology_corner"),
        "temperature": rp.get("temperature"),
        "power_nets": list(rp.get("power_names") or []),
        "ground_nets": list(rp.get("ground_names") or []),
        "strmout_args": list(ext.get("strmout_args") or []),
        "si_options": _merged(SI_DEFAULTS, ext.get("si_options")),
        "lvs_options": _merged(LVS_DEFAULTS, ext.get("lvs_options")),
        "qrc_options": _merged(QRC_DEFAULTS, ext.get("qrc_options")),
        "resolve_warnings": list(r["warnings"]),
        "resolved": r["resolved"],
    })
    p["qrc_ground_net"] = (ext.get("qrc_ground_net")
                           or (p["ground_nets"][0] if p["ground_nets"] else "vss"))
    tools = ext.get("tools") or {}
    p["tools"] = {n: tool_argv(tools.get(n), n) for n in ("strmout", "si", "calibre", "qrc")}

    errors = list(r["errors"])
    if p["lvs_options"].get("run_qrc_query") is False:
        errors = [e for e in errors if "query command" not in e]
    if not p["library"]:
        errors.insert(0, "layout library is not set (DUT lib / layout lib field)")
    if errors:
        head = "extraction cannot start: "
        if r["missing_env"]:
            head += ("environment variable(s) %s not set in Virtuoso's environment "
                     "(source the PDK setup before starting Virtuoso, or pin the value "
                     "in the site config); " % ", ".join("$" + m for m in r["missing_env"]))
        raise rk_common.RkError(head + "; ".join(errors), missing=errors,
                                missing_env=r["missing_env"], extract_dir=dirs["extract_dir"])
    return p


def build_commands(p):
    """argv + cwd for each step (exactly the auto_ext command lines)."""
    t = p["tools"]
    return {
        "strmout": {"argv": t["strmout"] + ["-library", p["library"], "-topCell", p["cell"],
                                            "-view", p["layout_view"],
                                            "-strmFile", p["layout_db"],
                                            "-layerMap", p["layer_map"]] + p["strmout_args"],
                    "cwd": p["workarea"]},
        "si": {"argv": t["si"] + ["-batch", "-command", "netlist", "-cdslib", p["cdslib"]],
               "cwd": p["si_dir"]},
        "lvs": {"argv": t["calibre"] + ["-gui", "-lvs", "-runset", p["qci"], "-batch"],
                "cwd": p["workarea"]},
        "qrc": {"argv": t["qrc"] + ["-cmd", p["dspf_cmd"]], "cwd": p["workarea"]},
    }


def calibre_gui_argv(p):
    return p["tools"]["calibre"] + ["-gui", "-lvs", "-runset", p["qci"]]


def render_all(p):
    """Render si.env / qci / dspf.cmd into the extract dir; returns their paths."""
    _write_text(p["si_env"], render_template("si/si.env.tmpl", si_env_values(p)))
    _write_text(p["qci"], render_template("calibre/lvs.qci.tmpl", qci_values(p)))
    _write_text(p["dspf_cmd"], render_template("quantus/dspf.cmd.tmpl", qrc_values(p)))
    return {"si_env": p["si_env"], "qci": p["qci"], "dspf_cmd": p["dspf_cmd"]}


# --------------------------------------------------------------------------
# LVS report check (port of Auto_ext core/checks.py, strict criterion)
# --------------------------------------------------------------------------

_RE_CORRECT = re.compile(r"(?<![A-Z])CORRECT(?![A-Z])")
_RE_INCORRECT = re.compile(r"(?<![A-Z])INCORRECT(?![A-Z])")
_RE_DISCREPANCIES = re.compile(r"DISCREPANCIES\s*=\s*(\d+)", re.IGNORECASE)
_RE_CELL_SUMMARY_HEADER = re.compile(r"CELL\s+SUMMARY", re.IGNORECASE)
_RE_CELL_ROW = re.compile(r"^[ \t]*(CORRECT|INCORRECT)[ \t]+(\S+)[ \t]+(\S+)[ \t\r]*$",
                          re.IGNORECASE | re.MULTILINE)


def parse_lvs_report(path):
    """-> {passed, banner, discrepancies, cells[{result,layout,source}],
    incorrect_cells[], error}. INCORRECT banner = fail; CORRECT + 0
    discrepancies = pass; CORRECT + N>0 = fail; CORRECT without a count =
    pass only if the CELL SUMMARY rows are all CORRECT; no banner = error."""
    res = {"passed": False, "banner": None, "discrepancies": None, "cells": [],
           "incorrect_cells": [], "error": None, "report": path}
    if not os.path.isfile(path):
        res["error"] = "LVS report missing: %s" % path
        return res
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    if _RE_INCORRECT.search(text):
        res["banner"] = "INCORRECT"
    elif _RE_CORRECT.search(text):
        res["banner"] = "CORRECT"
    m = _RE_DISCREPANCIES.search(text)
    if m:
        res["discrepancies"] = int(m.group(1))
    h = _RE_CELL_SUMMARY_HEADER.search(text)
    if h:
        for r in _RE_CELL_ROW.finditer(text, h.end()):
            res["cells"].append({"result": r.group(1).upper(), "layout": r.group(2),
                                 "source": r.group(3)})
    res["incorrect_cells"] = [c["layout"] for c in res["cells"] if c["result"] != "CORRECT"]
    if res["banner"] is None:
        res["error"] = "no LVS banner found; report truncated? %s" % path
    elif res["banner"] == "INCORRECT":
        res["passed"] = False
    elif res["discrepancies"] is None:
        res["passed"] = bool(res["cells"]) and not res["incorrect_cells"]
    else:
        res["passed"] = res["discrepancies"] == 0
    return res


# --------------------------------------------------------------------------
# artifact detection ("use existing" mode)
# --------------------------------------------------------------------------

def _file_info(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return {"path": _posix(path), "size": st.st_size,
            "mtime": datetime.datetime.fromtimestamp(int(st.st_mtime)).isoformat()}


def find_artifacts(artifact_dir, cell):
    """Existing products in <artifact_root>/<cell>/: the canonical
    <cell>.gds / <cell>.dspf (or null) plus every candidate file, newest
    first, canonical one first. rk_yml's emir-inputs may reuse this."""
    res = {"artifact_dir": _posix(artifact_dir), "gds": None, "dspf": None,
           "gds_candidates": [], "dspf_candidates": []}
    if not os.path.isdir(artifact_dir):
        return res
    gds, dspf = [], []
    for name in os.listdir(artifact_dir):
        full = os.path.join(artifact_dir, name)
        if not os.path.isfile(full):
            continue
        low = name.lower()
        if low.endswith(GDS_EXTS):
            gds.append(full)
        elif low.endswith(DSPF_EXTS):
            dspf.append(full)

    def order(paths, canonical):
        infos = [_file_info(x) for x in paths]
        infos = [i for i in infos if i]
        infos.sort(key=lambda i: i["mtime"], reverse=True)
        infos.sort(key=lambda i: os.path.basename(i["path"]) != canonical)
        return infos

    res["gds_candidates"] = order(gds, cell + ".gds")
    res["dspf_candidates"] = order(dspf, cell + ".dspf")
    for kind in ("gds", "dspf"):
        cands = res[kind + "_candidates"]
        if cands and os.path.basename(cands[0]["path"]) == "%s.%s" % (cell, kind):
            res[kind] = cands[0]
    if res["gds"] and res["dspf"] and res["dspf"]["mtime"] < res["gds"]["mtime"]:
        res["warning"] = "%s.dspf is older than %s.gds" % (cell, cell)
    return res


# --------------------------------------------------------------------------
# status file
# --------------------------------------------------------------------------

def read_status(xdir):
    path = os.path.join(xdir, "status.json")
    if not os.path.isfile(path):
        return None
    try:
        return rk_common.read_json(path)
    except (ValueError, OSError):
        return None


def write_status(xdir, st):
    rk_common.write_json(os.path.join(xdir, "status.json"), st)


def _pid_alive(pid):
    if not pid:
        return False
    if os.name == "nt":
        try:
            import ctypes
            from ctypes import wintypes
            k = ctypes.WinDLL("kernel32", use_last_error=True)
            k.OpenProcess.restype = wintypes.HANDLE
            k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
            k.WaitForSingleObject.restype = wintypes.DWORD
            k.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
            k.CloseHandle.argtypes = [wintypes.HANDLE]
            h = k.OpenProcess(0x1000 | 0x00100000, False, int(pid))  # QUERY_LIMITED | SYNCHRONIZE
            if not h:
                return False
            try:
                return k.WaitForSingleObject(h, 0) == 0x102  # WAIT_TIMEOUT = still running
            finally:
                k.CloseHandle(h)
        except Exception:
            return True
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def worker_alive(st):
    """True/False when it can be decided; heartbeat age decides across hosts."""
    if not st or st.get("state") in FINAL_STATES:
        return False
    pid = st.get("pid")
    if st.get("host") == socket.gethostname() and pid:
        return _pid_alive(pid)
    hb = st.get("heartbeat") or st.get("started")
    if not hb:
        return True
    try:
        t = datetime.datetime.strptime(hb[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return True
    return (datetime.datetime.now() - t).total_seconds() < HEARTBEAT_STALE_SECONDS


def _tail(path, n=LOG_TAIL_LINES):
    if not path or not os.path.isfile(path):
        return []
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 64 * 1024))
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return []
    return data.splitlines()[-n:]


def _initial_status(p, cmds):
    return {
        "schema": 1, "state": "running", "step": None, "message": "starting",
        "cell": p["cell"], "library": p["library"],
        "extract_dir": p["extract_dir"], "artifact_dir": p["artifact_dir"],
        "started": _now_iso(), "ended": None, "heartbeat": _now_iso(),
        "pid": None, "host": socket.gethostname(),
        "steps": [{"name": s, "state": "pending", "started": None, "ended": None,
                   "exit_code": None, "log": _join(p["logs_dir"], s + ".log"),
                   "cmd": shell_join(cmds[s]["argv"]), "cwd": cmds[s]["cwd"]}
                  for s in STEPS],
        "gds": None, "dspf": None,
        "layout_db": p["layout_db"], "src_net": p["src_net"],
        "lvs_report": None, "lvs": None,
        "qci": p["qci"], "dspf_cmd": p["dspf_cmd"], "si_env": p["si_env"],
        "calibre_gui_cmd": shell_join(calibre_gui_argv(p)),
        "calibre_gui_cwd": p["workarea"],
        "log": p["log"],
        "settings": {"technology_corner": p["technology_corner"],
                     "temperature": p["temperature"], "layout_view": p["layout_view"],
                     "library": p["library"]},
    }


# --------------------------------------------------------------------------
# the worker (runs detached; also callable inline for tests: run_worker(xdir))
# --------------------------------------------------------------------------

class _Cancelled(Exception):
    pass


class _Worker(object):
    def __init__(self, xdir):
        self.xdir = xdir
        self.req = rk_common.read_json(os.path.join(xdir, "request.json"))
        self.p = self.req["params"]
        self.cmds = self.req["commands"]
        self.st = read_status(xdir) or _initial_status(self.p, self.cmds)

    # -- bookkeeping
    def log(self, msg):
        line = "[%s] %s\n" % (_now_iso(), msg)
        with open(self.p["log"], "a", encoding="utf-8", newline="\n") as f:
            f.write(line)

    def save(self, **fields):
        self.st.update(fields)
        self.st["heartbeat"] = _now_iso()
        write_status(self.xdir, self.st)

    def step(self, name):
        for s in self.st["steps"]:
            if s["name"] == name:
                return s
        raise KeyError(name)

    def cancel_requested(self):
        return os.path.exists(self.p["cancel"])

    # -- one tool
    def run_step(self, name):
        if self.cancel_requested():
            raise _Cancelled()
        c = self.cmds[name]
        s = self.step(name)
        s.update(state="running", started=_now_iso())
        self.save(step=name, message="%s running" % name)
        self.log("%s: cd %s && %s" % (name, c["cwd"], shell_join(c["argv"])))
        logf = open(s["log"], "w", encoding="utf-8", newline="\n")
        try:
            kw = {}
            if os.name == "posix":
                kw["start_new_session"] = True
            try:
                proc = subprocess.Popen(c["argv"], cwd=c["cwd"], stdout=logf,
                                        stderr=subprocess.STDOUT,
                                        stdin=subprocess.DEVNULL, **kw)
            except OSError as e:
                logf.write("relkit: cannot start %s: %s\n" % (c["argv"][0], e))
                s.update(state="failed", ended=_now_iso(), exit_code=None)
                raise rk_common.RkError("%s: cannot start %s: %s" % (name, c["argv"][0], e))
            self.save(child_pid=proc.pid)
            last_hb = time.time()
            while True:
                rc = proc.poll()
                if rc is not None:
                    break
                if self.cancel_requested():
                    self._kill(proc)
                    s.update(state="cancelled", ended=_now_iso())
                    raise _Cancelled()
                if time.time() - last_hb > 10:
                    self.save()
                    last_hb = time.time()
                time.sleep(POLL_SECONDS)
        finally:
            logf.close()
        s.update(exit_code=rc, ended=_now_iso())
        self.log("%s: exit %s" % (name, rc))
        return rc

    def _kill(self, proc):
        try:
            if os.name == "posix":
                os.killpg(proc.pid, signal.SIGTERM)
            else:
                proc.terminate()
        except OSError:
            pass
        try:
            proc.wait(timeout=10)
        except Exception:
            try:
                if os.name == "posix":
                    os.killpg(proc.pid, signal.SIGKILL)
                else:
                    proc.kill()
            except OSError:
                pass

    def fail(self, name, msg, state="failed"):
        s = self.step(name)
        if s["state"] in ("running", "pending"):
            s["state"] = "failed"
        self.log("FAILED at %s: %s" % (name, msg))
        self.save(state=state, step=name, message=msg, ended=_now_iso(), child_pid=None,
                  log_tail=_tail(s["log"]))
        return self.st

    # -- the chain
    def run(self):
        p = self.p
        self.save(pid=os.getpid(), host=socket.gethostname(), state="running")
        self.log("extraction of %s/%s/%s started (pid %s)"
                 % (p["library"], p["cell"], p["layout_view"], os.getpid()))
        try:
            # 1. strmout
            rc = self.run_step("strmout")
            if rc != 0 or not os.path.isfile(p["layout_db"]):
                return self.fail("strmout", "strmout failed (exit %s); no %s"
                                 % (rc, p["layout_db"]) if rc != 0 else
                                 "strmout wrote no %s" % p["layout_db"])
            self.step("strmout")["state"] = "done"
            # 2. si (it refuses to start while a stale .running exists)
            for d in (p["si_dir"], p["output_dir"]):
                try:
                    os.remove(os.path.join(d, ".running"))
                except OSError:
                    pass
            rc = self.run_step("si")
            if rc != 0 or not os.path.isfile(p["src_net"]):
                return self.fail("si", "si netlisting failed (exit %s); no %s"
                                 % (rc, p["src_net"]))
            self.step("si")["state"] = "done"
            # 3. Calibre LVS
            rc = self.run_step("lvs")
            lvs = parse_lvs_report(p["lvs_report"])
            self.st["lvs"] = lvs
            self.st["lvs_report"] = p["lvs_report"] if os.path.isfile(p["lvs_report"]) else None
            if lvs["error"]:
                return self.fail("lvs", "Calibre LVS (exit %s): %s" % (rc, lvs["error"]))
            if not lvs["passed"]:
                msg = "LVS %s" % lvs["banner"]
                if lvs["discrepancies"]:
                    msg += ", %d discrepancies" % lvs["discrepancies"]
                if lvs["incorrect_cells"]:
                    msg += ", incorrect cells: %s" % " ".join(lvs["incorrect_cells"][:10])
                msg += "; report %s" % p["lvs_report"]
                return self.fail("lvs", msg, state="lvs_failed")
            if rc != 0:
                self.log("lvs: calibre exit %s but the report is CORRECT; continuing" % rc)
            self.step("lvs")["state"] = "done"
            # 4. Quantus
            rc = self.run_step("qrc")
            dspf_ok = os.path.isfile(p["qrc_dspf"]) and os.path.getsize(p["qrc_dspf"]) > 0
            if rc != 0 or not dspf_ok:
                return self.fail("qrc", "Quantus failed (exit %s)%s"
                                 % (rc, "" if dspf_ok else "; no %s" % p["qrc_dspf"]))
            self.step("qrc")["state"] = "done"
            # 5. publish both products together
            tmp = p["gds"] + ".relkit_tmp"
            shutil.copyfile(p["layout_db"], tmp)
            os.replace(tmp, p["gds"])
            shutil.move(p["qrc_dspf"], p["dspf"])
            self.log("done: %s, %s" % (p["gds"], p["dspf"]))
            self.save(state="done", step=None, message="done", ended=_now_iso(),
                      gds=p["gds"], dspf=p["dspf"], child_pid=None,
                      log_tail=_tail(self.step("qrc")["log"]))
        except _Cancelled:
            for s in self.st["steps"]:
                if s["state"] == "running":
                    s["state"] = "cancelled"
            self.log("cancelled")
            self.save(state="cancelled", message="cancelled by user", ended=_now_iso(),
                      child_pid=None)
        except rk_common.RkError as e:
            self.fail(self.st.get("step") or "strmout", str(e))
        except Exception as e:  # never leave a "running" status behind
            self.fail(self.st.get("step") or "strmout", "%s: %s" % (type(e).__name__, e))
        return self.st


def run_worker(xdir):
    return _Worker(xdir).run()


# --------------------------------------------------------------------------
# start / status / cancel
# --------------------------------------------------------------------------

def _clean_previous(p):
    for d in (p["si_dir"], p["output_dir"], p["qrc_dir"], p["logs_dir"]):
        if os.path.isdir(d):
            shutil.rmtree(d)
    for f in (p["cancel"], p["log"], p["status"]):
        try:
            os.remove(f)
        except OSError:
            pass


def prepare(ctx, site=None):
    """Resolve, render and write request.json + the initial status.json.
    Returns (params, commands). Refuses while another worker is alive."""
    if site is None:
        site, _path, _w = rk_site.site_from_ctx(ctx)
    p = resolve_params(ctx, site)
    old = read_status(p["extract_dir"])
    if old and old.get("state") not in FINAL_STATES and worker_alive(old):
        raise rk_common.RkError("an extraction of %s is already running (pid %s); "
                                "cancel it first" % (p["cell"], old.get("pid")),
                                extract_dir=p["extract_dir"], state=old.get("state"))
    _clean_previous(p)
    for d in (p["extract_dir"], p["si_dir"], p["output_dir"], p["qrc_dir"], p["logs_dir"]):
        if not os.path.isdir(d):
            os.makedirs(d)
    render_all(p)
    cmds = build_commands(p)
    rk_common.write_json(p["request"], {"schema": 1, "created": _now_iso(),
                                        "params": p, "commands": cmds})
    write_status(p["extract_dir"], _initial_status(p, cmds))
    return p, cmds


def spawn_worker(xdir, python=None):
    """Start `relkit.py extract-run --dir xdir` detached (own session; survives
    Virtuoso). stdout/stderr -> extract/worker.log. Returns the pid."""
    python = python or sys.executable
    argv = [python, os.path.join(HERE, "relkit.py"), "extract-run", "--dir", xdir,
            "--out", os.path.join(xdir, "worker_out.json")]
    logf = open(os.path.join(xdir, "worker.log"), "w", encoding="utf-8")
    kw = {}
    if os.name == "posix":
        kw["start_new_session"] = True
    else:
        kw["creationflags"] = 0x00000008 | 0x00000200  # DETACHED_PROCESS | NEW_PROCESS_GROUP
    try:
        proc = subprocess.Popen(argv, cwd=xdir, stdout=logf, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, close_fds=True, **kw)
    finally:
        logf.close()
    _SPAWNED.append(proc)  # keep a reference: no "still running" warning at GC
    return proc.pid


_SPAWNED = []


def status_out(xdir, cell=None):
    """extract-status payload (CONTRACT 5.4) for an extract dir."""
    xdir = _posix(xdir.rstrip("/\\"))
    st = read_status(xdir)
    adir = os.path.dirname(xdir)
    cell = cell or (st or {}).get("cell") or os.path.basename(adir)
    existing = find_artifacts(adir, cell)
    if st is None:
        return {"extract_dir": xdir, "state": "none", "step": None, "steps": [],
                "gds": None, "dspf": None, "lvs_report": None, "calibre_gui_cmd": None,
                "log_tail": [], "message": "no extraction has been run here",
                "existing": existing, "final": True}
    if st.get("state") not in FINAL_STATES and not worker_alive(st):
        # The worker may have written its final state and exited between our
        # read and the liveness check: once it is gone, a re-read is authoritative.
        st = read_status(xdir) or st
    if st.get("state") not in FINAL_STATES and not worker_alive(st):
        st.update(state="failed", ended=_now_iso(),
                  message="extraction worker (pid %s) is gone" % st.get("pid"))
        for s in st.get("steps", []):
            if s.get("state") == "running":
                s["state"] = "failed"
        write_status(xdir, st)
    cur = None
    for s in st.get("steps", []):
        if s.get("name") == st.get("step"):
            cur = s
    tail_src = (cur or {}).get("log")
    if not tail_src:
        done = [s for s in st.get("steps", []) if s.get("started")]
        tail_src = done[-1]["log"] if done else st.get("log")
    out = dict(st)
    out.update({
        "extract_dir": xdir,
        "final": st.get("state") in FINAL_STATES,
        "log_tail": _tail(tail_src),
        "existing": existing,
    })
    out.pop("schema", None)
    return out


def cancel(xdir, wait_seconds=15):
    st = read_status(xdir)
    if st is None:
        raise rk_common.RkError("no extraction in %s" % xdir)
    if st.get("state") in FINAL_STATES:
        return st.get("state")
    _write_text(os.path.join(xdir, "cancel.request"), _now_iso() + "\n")
    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        st = read_status(xdir) or st
        if st.get("state") in FINAL_STATES:
            return st.get("state")
        if not worker_alive(st):
            break
        time.sleep(POLL_SECONDS)
    # Worker did not react (dead or wedged): kill what we know and mark it.
    for pid in (st.get("child_pid"), st.get("pid")):
        if pid and st.get("host") == socket.gethostname() and _pid_alive(pid):
            try:
                if os.name == "posix":
                    os.killpg(int(pid), signal.SIGTERM)
                else:
                    os.kill(int(pid), signal.SIGTERM)
            except OSError:
                pass
    st = read_status(xdir) or st
    if st.get("state") not in FINAL_STATES:
        for s in st.get("steps", []):
            if s.get("state") == "running":
                s["state"] = "cancelled"
        st.update(state="cancelled", ended=_now_iso(), message="cancelled by user")
        write_status(xdir, st)
    return st.get("state")


# --------------------------------------------------------------------------
# subcommand handlers
# --------------------------------------------------------------------------

def _xdir_from_args(args, ctx):
    if getattr(args, "dir", None):
        return _posix(os.path.abspath(args.dir))
    if ctx is None:
        raise rk_common.RkError("give --dir or --ctx")
    return dirs_from_ctx(ctx)["extract_dir"]


def _cmd_extract(args, ctx):
    site, _path, warnings = rk_site.site_from_ctx(ctx)
    p, cmds = prepare(ctx, site)
    out = {"extract_dir": p["extract_dir"], "status_path": p["status"],
           "log": p["log"], "gds": p["gds"], "dspf": p["dspf"],
           "qci": p["qci"], "dspf_cmd": p["dspf_cmd"], "si_env": p["si_env"],
           "calibre_gui_cmd": shell_join(calibre_gui_argv(p)),
           "calibre_gui_cwd": p["workarea"],
           "commands": {k: shell_join(v["argv"]) for k, v in cmds.items()},
           "warnings": warnings}
    out["warnings"].extend(p.get("resolve_warnings") or [])
    out["resolved"] = {k: v.get("value") for k, v in (p.get("resolved") or {}).items()}
    if getattr(args, "sync", False):
        st = run_worker(p["extract_dir"])
        out.update({"pid": os.getpid(), "state": st.get("state"),
                    "message": st.get("message")})
        return out
    out["pid"] = spawn_worker(p["extract_dir"])
    out["state"] = "running"
    return out


def _cmd_extract_resolve(args, ctx):
    site, _path, warnings = rk_site.site_from_ctx(ctx)
    out = resolve_preview(ctx, site)
    out["warnings"] = list(warnings) + out["warnings"]
    if getattr(args, "text", None):
        _write_text(args.text, preview_text(out))
        out["text"] = _posix(args.text)
    return out


def preview_text(res):
    """Human-readable preview (the panel's [Show resolved] window)."""
    lines = ["relkit extraction parameters (resolved %s)" % _now_iso(), ""]
    if res.get("missing_env"):
        lines.append("MISSING environment variables: %s"
                     % " ".join("$" + m for m in res["missing_env"]))
        lines.append("  -> source the PDK setup in the shell that starts Virtuoso, or pin")
        lines.append("     the value in the site config (extract.<key>).")
        lines.append("")
    resolved = res.get("resolved") or {}
    w = max([len(k) for k in resolved] + [8])
    for k, v in resolved.items():
        val = v.get("value")
        if isinstance(val, list):
            val = " ".join(val)
        lines.append("%-*s  %-8s %s" % (w, k, v.get("source") or "", "" if val is None else val))
        if v.get("expr") and v.get("expr") != val:
            lines.append("%-*s  %-8s   <- %s" % (w, "", "", v["expr"]))
    ch = res.get("choices") or {}
    lines += ["", "LVS variants found : %s" % (" ".join(ch.get("variants") or []) or "-"),
              "Quantus decks found: %d" % len(ch.get("qrc_decks") or [])]
    lines += ["  " + d for d in ch.get("qrc_decks") or []]
    lines.append("RC corners         : %s" % " ".join(c["name"] for c in ch.get("corners") or []))
    sg = res.get("suggested") or {}
    lines += ["", "LVS power names : %s" % " ".join(sg.get("power_names") or []),
              "LVS ground names: %s" % " ".join(sg.get("ground_names") or [])]
    if res.get("errors"):
        lines += ["", "ERRORS (extraction cannot start):"] + ["  - " + e for e in res["errors"]]
    if res.get("warnings"):
        lines += ["", "Warnings:"] + ["  - " + e for e in res["warnings"]]
    return "\n".join(lines) + "\n"


def _cmd_extract_run(args, ctx):
    st = run_worker(_posix(os.path.abspath(args.dir)))
    return {"state": st.get("state"), "message": st.get("message")}


def _cmd_extract_status(args, ctx):
    xdir = _xdir_from_args(args, ctx)
    return status_out(xdir, cell=((ctx or {}).get("dut") or {}).get("cell"))


def _cmd_extract_cancel(args, ctx):
    xdir = _xdir_from_args(args, ctx)
    return {"extract_dir": xdir, "state": cancel(xdir)}


def register(subparsers):
    p = rk_common.add_command(subparsers, "extract-resolve", _cmd_extract_resolve,
                              "preview the extraction parameters derived from the environment",
                              ctx_required=True)
    p.add_argument("--text", help="also write a human-readable preview to this file")
    p = rk_common.add_command(subparsers, "extract", _cmd_extract,
                              "start the extraction chain in the background",
                              ctx_required=True)
    p.add_argument("--sync", action="store_true",
                   help="run the chain in the foreground (debug/tests)")
    p = rk_common.add_command(subparsers, "extract-status", _cmd_extract_status,
                              "report extraction progress",
                              ctx_required=False)
    p.add_argument("--dir", help="extract dir (default: from ctx: <artifact_root>/<DUT cell>/extract)")
    p = rk_common.add_command(subparsers, "extract-cancel", _cmd_extract_cancel,
                              "cancel a running extraction",
                              ctx_required=False)
    p.add_argument("--dir", help="extract dir (default: from ctx)")
    p = rk_common.add_command(subparsers, "extract-run", _cmd_extract_run,
                              "INTERNAL: the background extraction worker",
                              ctx_required=False)
    p.add_argument("--dir", required=True, help="extract dir prepared by `extract`")
