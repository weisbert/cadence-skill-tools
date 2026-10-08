# relkit interface contract

This is the contract every relkit agent/module codes against. If you need to
change it, make the smallest change that works, update this file, and add a
line to the **Change log** at the bottom (date, role, what, why).

Layout reminder (plan section 2):

```
relkit/
  relkit.il  rkSite.il  rkMae.il  rkResults.il  rkAged.il  rkIpc.il  rkGui.il
  site_defaults.json      built-in defaults, read by BOTH SKILL and Python
  site.example.json       example site config (fake values)
  docs/CONTRACT.md        this file
  py/relkit.py            CLI entry (argparse); fixed module registry
  py/rk_common.py         CLI conventions (out.json, errors, TSV writer)
  py/rk_site.py           site lookup/merge/expansion (mirror of rkSite.il)
  py/rk_yml.py rk_submit.py rk_parse.py rk_report.py rk_aged.py rk_extract.py rk_runs.py
  py/templates/           extraction templates (rk_extract)
  py/tests/               unittest; fixtures synthetic only
  py/tests/fake_relstudio/  fake RELSTUDIO_HOME (script/python/run_relsim.py)
  py/tests/fake_tools/      fake strmout/si/calibre/qrc
  tests/                  SKILL smoke tests (skillbridge-driven)
  tools/sync_vm.sh  tools/gate.sh
```

Ownership: each module file belongs to one role (plan section 9). The scaffold
role owns relkit.il, rkSite.il, site_defaults.json, site.example.json,
py/relkit.py, py/rk_common.py, py/rk_site.py, tools/, tests/rk_testlib.il,
tests/run_skill_test.py and this file (shared: append to the change log).

---

## 0. Conventions that apply everywhere

* **Encoding**: every file relkit writes or reads is UTF-8, LF line endings.
  Python opens files with `encoding="utf-8"`; JSON is written with
  `ensure_ascii=False` (so SKILL never needs `\uXXXX` for non-ASCII).
* **Paths**: absolute POSIX paths in every JSON field, never `~`, never `/tmp`
  (company `/tmp` is shared). Scratch files go under `persist_root`/`work_root`
  or the run directory.
* **Booleans in JSON produced by SKILL** must be explicit: write `t` /
  `rkJsonFalse` (use `rkJsonBool(x)`), never nil. In SKILL-produced JSON,
  `null` means "not set -> use the default". Python must treat `null` like
  "absent" everywhere, and like `[]` / `{}` where a list / object is expected.
* **SKILL reading JSON** (`rkJsonRead`): object -> association table with
  string keys (missing key -> nil), array -> list, `true` -> t,
  `false`/`null` -> nil, integer -> fixnum, real -> flonum. Use
  `rkGet(obj "a.b.0.c")` for nested access (list index is 0-based). Never use
  `~>` on these tables' contents.
* **Run types**: relkit names `aging | deos | emir`. RelStudio names:

  | relkit | RelStudio `-t` / type dir | yml file name | `Rel_Type` |
  |---|---|---|---|
  | `aging` | `analog_aging` | `analog_aging.yml` | `AnalogAging` |
  | `deos`  | `dynamic_eos`  | `DEOS.yml`         | `DynamicEOS`  |
  | `emir`  | `emir`         | `EM.yml`           | `EMIR`        |

* **Time stamps**: run ids and file stems use local time `YYYYMMDD-HHMMSS`
  (`rkTimestamp()` in SKILL, `datetime.now().strftime("%Y%m%d-%H%M%S")` in
  Python). JSON time fields use ISO 8601 local time without zone
  (`2026-10-08T10:07:00`).

---

## 1. Site configuration

Lookup (identical in `rkSite.il` and `py/rk_site.py`):

1. `$RELKIT_SITE` (must exist, else error)
2. `<workarea>/.relkit_site.json` (workarea = `$RELKIT_WORKAREA`, else the
   Virtuoso / process working directory)
3. `<relkit>/site.json` (git-ignored)
4. none -> built-in defaults only (warning)

Merge: `site_defaults.json` deep-merged with the site file (objects recurse;
any other value, `null` included, replaces). Expansion: `${NAME}` in every
string, NAME from `{WORKAREA, USER, RELKIT_DIR}` then the environment;
unknown names stay verbatim (warning). A bare `$NAME` is **never** expanded
(RelStudio needs literal `$MODEL_ROOT/...`). `relstudio_home: null` -> the
Virtuoso process' `$RELSTUDIO_HOME` (plan D6); SKILL passes the resolved value
in `ctx.relstudio_home`.

Python subcommands load the site with `rk_site.site_from_ctx(ctx)`, which uses
`ctx.site_path` (the file SKILL resolved; `null` = defaults only),
`ctx.workarea`, `ctx.user`, `ctx.relstudio_home`.

Keys (defaults in `site_defaults.json`, example in `site.example.json`):

| key | type | meaning |
|---|---|---|
| `python` | str | python3 used for `relkit.py` (company: 3.11) |
| `relstudio_home` | str/null | RelStudio install; null = `$RELSTUDIO_HOME` |
| `work_root` | str | RelStudio Work_Dir root: `<work_root>/<IP>/<Cell>/<Project>/<History>` |
| `artifact_root` | str | netlist/DSPF/GDS products: `<artifact_root>/<DUT cell>/` (D17) |
| `persist_root` | str | run records: `<persist_root>/<lib>/<cell>/<run id>/`; IPC scratch `<persist_root>/_ipc/` (files older than 14 days are pruned by relkit.py) |
| `project_name` | str | `Common.Project_Name` (default `relsim1`) |
| `submit_strategy` | `start`/`submit_batch` | `run_relsim -m start`, or `-m submit` + run each line of `batch_submit_list.txt` |
| `dry_run` | bool | true: `-m submit` only (generates scripts, submits nothing); state `dry_run_done` |
| `supervise_poll_seconds` | num | supervisor polling period (default 30; tests use < 1) |
| `start_wait_minutes` | num | after all jobs are done, how long to wait for a still-running `run_relsim -m start` before summarizing ourselves (default 60) |
| `aging_eval_layout` | `entries`/`temperature_list` | several evaluation temperatures: one `Aged_k` entry per temperature (default, plan 4.2) or one `Aged_1` whose `Temperature` lists them all (to be confirmed on the company machine) |
| `simulator.Simulation_Cmd` | str/obj/null | yml `Simulation_Cmd`; null = computed like the GUI (aging/DEOS `alps -errpreset <acc> +mt <n> -lqtimeout -closelink -d`, EMIR `alps input.scs -format fsdb -ade -o SIM_DIR/psf -p <n> -errpreset <acc> `); an object maps run type -> string |
| `model_root_var` | str | name of the model root variable (default `MODEL_ROOT`) |
| `model_file_map` | list | `[{"match": <python regex, full path>, "replace": <re.sub replacement>}]`, first match wins; no match -> path unchanged. Maps a Maestro corner model file to the yml `Corner_Group.*.Model_File` entry |
| `tool_version_names` | list | executables for `Common.ToolVersion` (`which`; missing ones omitted + warning) |
| `tech` | obj | `Foundry, Technology, Tech_Voltage, Tech_Layout, Rel_Tech_Dir` (yml `Common`) |
| `cluster` | obj | yml `Cluster` block: `Using_Cluster, Cluster_Type, Group, Queue, CPU, Memory, GPU, Machine_Arch`; the base of every Donau profile, and the single profile `default` when `donau_profiles` is not set |
| `donau_profiles` | obj/null | `{name: {cluster keys...}}`, each deep-merged over `cluster` (keys starting with `_` and non-object values ignored); names are offered sorted (rk_yml.donau_profiles, rkGui rk_guiDonauTable) |
| `donau_default` | obj/null | `{aging|deos|emir: name}`; missing/unknown -> `default` if present, else the first name (rk_yml.donau_default) |
| `donau_job_id_regex` | str | regex reading the cluster job id from a submit command's output (first non-empty group; default dsub `Job <123>`) |
| `donau_query_cmd` | str/null | `progress` runs it per known job id (`{job_id}` replaced, 10 s timeout) and shows its last output line; null = off |
| `simulator` | obj | yml `Simulator` block: `Name, Simulator_Accuracy, Sim_Mt, Simulation_Options, Flag_Is_Delete_Simulation_Data, Flag_Is_Save_Final_Result` |
| `aging_model` | obj | `Model_File, Relxpert_Uri_Libs` (aging yml) |
| `emir.gds_map_file` | str | yml `Gds_Map_File` |
| `emir.rc_corner` | str | default `Rc_Corner` |
| `emir.license_policy` | `wait_forever`/`wait_hours`/`fail` | default of the EMIR page drop-down (D18) |
| `emir.license_wait_hours` | num | for `wait_hours` |
| `emir.license_retry_minutes` | num | resubmit interval while waiting for a license |
| `emir.license_keywords` | list | case-insensitive regexes; only evaluated on a FAILED EMIR job |
| `emir.license_tail_lines` | int | log tail stored in run.json when no keyword matched |
| `emir.license_ignore` | list | case-insensitive regexes; a keyword hit on a line matching one of these is ignored (successful checkouts like `Checking out ... license (Lic-216)` appear in every Totem log) |
| `emir.totem_flow` | obj/null | deep-merged over the GUI default `Advance.Totem_Flow` block |
| `extract.tools` | obj | executables `strmout, si, calibre, qrc`; each a string (one executable) or a list (argv prefix, e.g. `[python, fake_tool]`) |
| `extract.*` rules | str | **Derived from the environment** (rk_pdk, port of Auto_ext's rules R1-R8). A value is an expression `<head>[|parent]*` with `$X` / `${X}` / `$env(X)` references (`$$` = literal `$`), resolved against the environment of the Python child, i.e. Virtuoso's (plus an optional ctx `env` snapshot); a value without references is a literal, so pinning a value per project = writing the path. Prefer `$X` to `${X}` in site files (the site loader expands `${X}` itself and warns when unset). An unset/empty variable makes the value unresolved and is reported by name (`missing_env`) |
| `extract.layer_map` | str | `$PDK_LAYER_MAP_FILE` (strmout `-layerMap`) |
| `extract.lvs_deck_dir` | str | `$calibre_source_added_place|parent` (R1) |
| `extract.lvs_basename` | str/null | null = last segment of `lvs_deck_dir` (R2) |
| `extract.lvs_filename_pattern` | str | `{basename}.{variant}.qcilvs` (R3); variants = files matching it in the deck dir |
| `extract.lvs_variant` / `lvs_default_variant` | str/null / str | pinned variant / default when present (`wodio`); else the only one found; else the user chooses |
| `extract.cdl_include_file` | str | `$calibre_source_added_place` (si.env `incFILE`; missing file = warning) |
| `extract.technology_library_file` | str | `$SETUP_ROOT/assura_tech.lib` |
| `extract.tech_name` / `tech_name_env_vars` | str/null / list | null = parent dir name of the first set variable of `["PDK_TECH_FILE","PDK_LAYER_MAP_FILE","PDK_DISPLAY_FILE"]` (R8) |
| `extract.qrc_deck_dir` / `qrc_deck_glob` | str/null / str | pinned Quantus (QCI) deck dir, else glob `$VERIFY_ROOT/runset/Calibre_QRC/QRC/*/*/QCI_deck` (R5): one hit = automatic, several = narrowed by the LVS basename else the user chooses, none = error |
| `extract.qrc_query_cmd_name` / `qrc_preserve_cell_list_name` | str | `query_cmd` / `preserveCellList.txt` inside the QRC deck (missing query_cmd = error, missing preserve list = warning) |
| `extract.corners` / `default_corner` / `technology_corner` | list / str / str-null | RC corners offered (`[{name, technology_corner}]`, default the 9 generic Quantus names typical..rcworst_t), default pick; the user's pick (name or token) maps to Quantus `-technology_corner` |
| `extract.temperature` | num | default extraction temperature (25) |
| `extract.power_names` / `ground_names` | list | global LVS supply names (PDK data, empty in the public defaults); the panel default = these + DUT ports that look like supplies |
| `extract.check_files` | bool | true: resolved files/dirs must exist (tests with fake paths set false) |
| legacy keys | | `pdk_layer_map, calibre_lvs_dir, calibre_lvs_basename, technology_name, power_nets, ground_nets` are still honoured as literal overrides of the new keys; `qrc_query_cmd` / `qrc_preserve_cell_list` pin `qrc_deck_dir` to their directory (each with a warning) |
| `extract.layout_view` | str | layout view for strmout (`layout`) |
| `extract.source_view` | str | schematic view for `si` / LVS source (default `schematic`) |
| `extract.cdslib` | str/null | cds.lib passed to `si -cdslib` (null = `<workarea>/cds.lib`) |
| `extract.qrc_ground_net` | str/null | Quantus `capacitance -ground_net` (null = first ground name, else `vss`) |
| `extract.strmout_args` | list | extra strmout arguments appended to the command line |
| `extract.si_options` / `lvs_options` / `qrc_options` | obj | per-key overrides of the Auto_ext recipe defaults in `rk_extract.SI_DEFAULTS` / `LVS_DEFAULTS` / `QRC_DEFAULTS` (e.g. `qrc_options.extract_rules: [{selection, selection_arg, type}]`) |
| `gui.status_poll_seconds` | int | panel status polling period (run pages; extraction polls every min(5, this)) |
| `gui.open_dir_cmd` | str | command the Runs page uses to open a Work_Dir (default `xdg-open`; the quoted dir is appended) |
| `gui.relstudio_cmd` | str/null | command for [RelStudio GUI] (null = `<relstudio_home>/bin/relstudio` if it exists, else `relstudio`; run in the workarea) |

---

## 2. ctx.json (written by SKILL, read by every subcommand)

Produced by `rkMaeGetContext(sess test)` (Maestro part) and completed by the
panel (dut, settings, run_type, netlist). Written by `rkIpcNewCtxFile(ctx tag)`
to `<persist_root>/_ipc/<user>_<YYYYMMDD-HHMMSS>_<n>_<tag>_ctx.json`.

### 2.1 Example

```json
{
  "schema": 1,
  "relkit_version": "0.1.0",
  "created": "2026-10-08T10:07:00",
  "user": "jdoe",
  "host": "host01",
  "workarea": "/proj/wa",
  "site_path": "/proj/wa/.relkit_site.json",
  "relstudio_home": "/opt/relstudio",
  "relkit_dir": "/proj/wa/skill_tools/relkit",

  "maestro": {"lib": "mylib", "cell": "tb_top", "view": "maestro",
              "session": "fnxSession0", "view_dir": "/proj/wa/mylib/tb_top/maestro"},
  "test": "test0",
  "tests": ["test0", "test1"],
  "design": {"lib": "mylib", "cell": "tb_top", "view": "config", "is_config": true,
             "top": {"lib": "mylib", "cell": "tb_top", "view": "schematic"}},
  "history": {"name": "Interactive.3",
              "dir": "/proj/sim/tb_top/maestro/results/maestro/Interactive.3",
              "netlist_dir": "/proj/sim/tb_top/maestro/results/maestro/Interactive.3/psf/test0/netlist",
              "netlist_mtime": 1791432000},
  "netlist": {"source": "/proj/sim/.../netlist/input.scs",
              "path": "/proj/wa/Reliability/amp_core/tb_top_test0.scs",
              "map_dir": "/proj/sim/.../netlist/map",
              "rewrites": [{"line": 12, "orig": "include \"./sub.scs\"",
                            "new": "include \"/proj/sim/.../netlist/sub.scs\""}],
              "kept": [{"line": 9, "orig": "include \"../toplevel.scs\" section=TOP_TT",
                        "reason": "toplevel.scs is rewritten by RelStudio per Corner_Group"}],
              "log": "/proj/wa/Reliability/amp_core/tb_top_test0.rewrite.log",
              "parameters": {"VDD": "0.9", "vin": "0.2"}},
  "warnings": [],
  "dut": {"inst": "I0", "lib": "mylib", "cell": "amp_core", "view": "schematic",
          "terms": ["VDD", "VSS", "IN", "OUT"]},
  "ip_name": "tb_top",
  "project_name": "relsim1",

  "global_vars": {"VSET": "10", "vin": "0.2"},
  "corners": [
    {"name": "FF125", "base_name": "FF125", "enabled": true, "selected": true,
     "sections": [{"model_file": "/proj/model/toplevel.scs", "section": "TOP_FF"},
                  {"model_file": "/proj/model/toplevel.scs", "section": "pre_sim"}],
     "temperature": "125", "vars": {"VSET": "12"}, "sweep": {}},
    {"name": "SS_t-40", "base_name": "SS", "enabled": true, "selected": false,
     "sections": [{"model_file": "/proj/model/toplevel.scs", "section": "TOP_SS"}],
     "temperature": "-40", "vars": {}, "sweep": {"temperature": "-40"}}
  ],

  "run_type": "aging",
  "settings": {
    "aging": {"life_time": "10", "life_time_unit": "years",
              "start_time": "0n", "stop_time": "20n", "eval_temperatures": null},
    "deos":  {"life_time": "10", "life_time_unit": "years", "start_time": "0n",
              "stop_time": "20n", "simulation_time": "20n", "tddb_temperature": null},
    "emir":  {"run_type": "DYN SEM", "selfheat": true, "em_temperature": 110,
              "rc_corner": "typical", "rc_temperature": null,
              "start_time": "0n", "stop_time": "20n", "dynamic_time_step": "20p",
              "life_time": "10", "life_time_unit": "years", "method": "iterated",
              "dspf_file": "/proj/wa/Reliability/amp_core/amp_core.dspf",
              "gds_file": "/proj/wa/Reliability/amp_core/amp_core.gds",
              "layout_lib": "mylib", "layout_view": "layout",
              "supplies": {"power": {"VDD": "0.9"}, "ground": {"VSS": "0"}},
              "limits": null,
              "license_policy": "wait_forever", "license_wait_hours": 8},
    "extract": {"layout_lib": "mylib", "layout_view": "layout",
                "technology_corner": "typical", "temperature": 25}
  }
}
```

### 2.2 Field rules

| field | rule |
|---|---|
| `workarea`, `user`, `site_path`, `relstudio_home`, `relkit_dir` | from rkSite (`rkWorkarea`, `rkUser`, `rkSitePath`, `rkRelstudioHome`, `rkRelkitDir` without trailing `/`) |
| `maestro` | the Maestro cellview the panel was opened from; `view_dir` = its directory on disk (per-cell settings live there, see 2.5) |
| `test` | the test this run is for; `tests` = all tests of the session |
| `design` | the test's design; `is_config` true when `view` is a config view; `top` = the cellview really simulated (config: its top cell, via hdb / `expand.cfg`; else = lib/cell/view) |
| `history` | the Maestro history whose netlist was used (`null` before export): the newest one (by `input.scs` mtime) holding a netlist for `test`, or the one the caller names. IC6.1.8 has no per-corner netlist API. `netlist_dir` = the top-level (`psf/<test>/netlist`) dir, else the lowest point dir; `netlist_mtime` = epoch seconds (stale-netlist hint for the panel) |
| `netlist` | filled by `rkMaeExportNetlist(ctx)`; `path` = `<artifact_root>/<DUT cell>/<maestro cell>_<test>.scs` (D17); `rewrites` = relative `include` / `ahdl_include` / `.include` / `.inc` / `.lib` / `.hdl` paths made absolute (relative to the source netlist dir); `kept` = `toplevel.scs` includes left alone (RelStudio rewrites them per Corner_Group); `log` = line-level original-vs-rewritten log next to `path`; `parameters` = top-level `parameters` / `.param` of the netlist (outside subckts), values verbatim strings; Python computes hashes itself |
| `warnings` | rkMae warnings while reading Maestro (strings), e.g. swept global variable, unknown test temperature |
| `dut` | from the panel (D13). `inst` = instance name in the TB top; `terms` optional |
| `ip_name` | default = Maestro cell name; `project_name` from site |
| `global_vars` | test design variables, values as strings |
| `corners` | ALL corners of the test after sweep expansion (2.3) |
| `run_type` | `aging`/`deos`/`emir`; build-yml/submit act on `settings[run_type]` |
| `settings` | see 2.4; `null` fields = use `site.defaults.<type>` then RelStudio defaults |

### 2.3 Corners after sweep expansion

* One entry per (Maestro corner x combination of its multi-valued sweeps).
  Maestro stores multi-values space-separated; expand the cartesian product.
  Temperature variable name in Maestro: `temperature`.
* `name`: `base_name` when nothing is swept; else `base_name` + for each swept
  key, in order temperature first then variable names sorted:
  `_` + (`t` for temperature, else the variable name) + value, with characters
  outside `[A-Za-z0-9.+-]` replaced by `_`. Examples: `SS_t-40`,
  `FF_t125_VSET12`. A swept model **section** (Maestro stores `"tt" "ss"`)
  is a dimension too: it comes after temperature and before the variables,
  suffix `_` + section name, `sweep` key `section` (`section1`, `section2`...
  when several model files of one corner are swept). Example:
  `PVT_t-40_ss_VDD2.8`.
* Model file `""` in a Maestro corner (= "the test's model file") resolves to
  the test's model file when the test uses exactly one; a corner without any
  model entry uses the test's model selections (file, section) unchanged.
  A corner without `temperature` uses the test temperature.
* `enabled`: corner enabled in Maestro AND not disabled for this test.
  `selected`: the panel checkbox for this run (defaults to `enabled`, D3).
  Python uses only `selected: true` corners (and fails if none).
* `sections`: Maestro order; `model_file` absolute when resolvable, else as in
  Maestro. One entry per (model file, section).
* `temperature`, `vars`: single values (strings) after expansion; `vars` = only
  the variables the corner overrides; `sweep` = the swept key -> value that
  produced this entry (`{}` if none).
* The nominal corner (Maestro "Nominal") is included only if it is enabled
  for the test; `base_name` = `Nominal`.

### 2.4 Settings per run type

| type | key | type | default (site `defaults.*`) | yml target |
|---|---|---|---|---|
| aging | `life_time` | str | `"10"` | `Time_Windows[].State_1.Life_Time: [!!str]` |
| aging | `life_time_unit` | str | `years` | `Life_Time_Unit` |
| aging | `start_time`, `stop_time` | str | `0n`, `20n` | `Start_Time`, `Stop_Time` |
| aging | `eval_temperatures` | list/null | null = each corner's own temperature | one `Aged_k` per temperature |
| deos | `life_time`, `life_time_unit` | | `10`, `years` | `Life_Time` (plain), `Life_Time_Unit` |
| deos | `start_time`, `stop_time`, `simulation_time` | str | `0n`, `20n`, `20n` | `Time_Windows[].State_1` |
| deos | `tddb_temperature` | num/null | null = corner temperature | `Tddb_Temperature` |
| emir | `run_type` | str | `DYN SEM` | `Run_Type` |
| emir | `selfheat` | bool | true | `Is_Run_Selfheat` |
| emir | `em_temperature` | num | 110 | `Time_State.States[].Em_Temperature` |
| emir | `rc_corner` | str | site `emir.rc_corner` | `Rc_Corner` |
| emir | `rc_temperature` | num/null | null = corner temperature | `Rc_Temperature` |
| emir | `start_time`, `stop_time`, `dynamic_time_step` | str | `0n`, `20n`, `20p` | `Time_State.States[].State_1` |
| emir | `life_time`, `life_time_unit`, `method` | | `10`, `years`, `iterated` | |
| emir | `dspf_file`, `gds_file` | str | required | `Dspf_File`, `Gds_File` |
| emir | `layout_lib`, `layout_view` | str | maestro lib, `layout` | (extraction) |
| emir | `supplies` | obj | from `emir-inputs` | `Supplies{Power{net: V}, Ground{net: 0}}` |
| emir | `limits` | obj/null | null = RelStudio GUI defaults (rk_yml) | `Limits` |
| emir | `license_policy`, `license_wait_hours` | | site `emir.*` | (relkit only, D18) |
| emir | `auto_extract` | bool/null | null | true: relkit uses/makes `<artifact_root>/<DUT>/<DUT>.dspf/.gds` (freshness check, extract first when missing/stale; `dspf_file`/`gds_file` are overwritten with the canonical pair); false: `dspf_file`/`gds_file` are the user's own files; null (CLI callers) = auto unless both files are given. The panel always sends true/false |
| aging/deos/emir | `donau_profile` | str/null | site `donau_default.<type>` | the yml `Cluster` blocks (rk_yml.resolve_donau; unknown name -> default + warning); recorded in run.json settings |
| extract | `layout_lib`, `layout_view`, `technology_corner` (corner name), `temperature`, `lvs_variant`, `qrc_deck` (null = automatic), `power_names`, `ground_names` (lists; empty = site lists + DUT supply ports) | | site `extract.*` / environment | (rk_extract, rk_pdk) |
| extract | `layout_dir`, `schematic_dir` | str/null | null = from cds.lib (`rk_extract.cdslib_libs`) | on-disk view directories of the layout / source schematic (panel: ddGetObjReadPath), for the freshness check |

`Sim_Cell` / `Instance_Name` come from `dut.cell` / `dut.inst`; EMIR corner keys
get the `_0` suffix (GUI behaviour).

### 2.5 Per-cell saved settings

`<cell dir>/relkit/relkit_settings.json` (`relkit_settings_<view>.json` for a
Maestro view not named `maestro`). Read/write with `rkMaeSettingsPath` /
`rkMaeReadSettings` / `rkMaeWriteSettings` (rkMae); rkGui decides the content.
Verified on IC6.1.8 (VM, 2026-10-08): a Library-Manager-style `ccpCopy` of the
cell with `CCP_EXPAND_COMANAGED` does NOT carry an extra file in the maestro
view dir (only maestro's co-managed files) nor plain cell-level files, but DOES
carry a cell-level directory (dd sees it as a view named `relkit`, so Library
Manager lists a `relkit` view); `CCP_EXPAND_ALL` carries everything. The old
`<maestro.view_dir>/relkit_settings.json` is still read as a fallback.

```json
{"schema": 1, "dut": {"inst": "I0", "lib": "mylib", "cell": "amp_core", "view": "schematic"},
 "ip_name": "tb_top", "settings": {"aging": {}, "deos": {}, "emir": {}, "extract": {}}}
```

---

## 3. Python CLI

```
<site.python> <relkit>/py/relkit.py <subcommand> --ctx <ctx.json> --out <out.json> [options]
```

### 3.0 Common rules

* Every subcommand accepts `--ctx` and `--out` (`--out` required). The result
  is written atomically to `--out`:
  `{"ok": true|false, "error": null|"message", "cmd": "<subcommand>", ...}`.
  Exit code 0 iff `ok` is true. Logs go to stderr only.
* rkIpc runs `/bin/sh -c 'exec [env NAME=V...] <python> relkit.py ... 2><out stem>.log'`
  (works whatever the login shell; `exec` makes python the child that
  `ipcKillProcess` reaches), and calls the callback with ONE argument: the parsed
  out.json table plus `_exit` (int), `_out` (out path), `_log` (log path), and
  `_timeout` / `_cancelled` t when it was killed. If out.json is missing or
  invalid the table has `ok` nil and `error` text. A stale out.json is deleted
  before the run.
* Long-running work (`submit`, `extract`) starts a **detached** background
  process (own session, survives Virtuoso) and returns immediately; progress is
  polled with `status` / `extract-status`.
* Handlers: `def handler(args, ctx) -> dict` registered with
  `rk_common.add_command(subparsers, name, handler, help, ctx_required)`;
  raise `rk_common.RkError(msg, **fields)` for clean failures.

### 3.1 Module registry (fixed in relkit.py)

`rk_yml, rk_submit, rk_parse, rk_report, rk_aged, rk_extract, rk_runs`; each
exposes `register(subparsers)`. Built-ins in relkit.py: `site`, `version`.

### 3.2 Subcommands

| subcommand | module | args | out.json extra fields |
|---|---|---|---|
| `site` | relkit.py | `[--ctx]` `[--workarea]` | `site`, `site_path`, `warnings` |
| `version` | relkit.py | | `version`, `python`, `modules` |
| `build-yml` | rk_yml | `--ctx` `[--type T]` `[--yml PATH]` `[--work-dir DIR]` | `yml_path`, `rs_type`, `yml_name`, `work_dir`, `rs_history`, `corner_keys[]`, `corner_map[]`, `warnings[]` |
| `emir-inputs` | rk_yml | `--ctx` | `dut_ports[]{name,net,kind(power/ground/signal),voltage}`, `supplies{power{net: V or null},ground{net: "0"}}`, `unresolved[]` (power ports without a voltage), `dspf_candidates[]`, `gds_candidates[]`, `warnings[]` |
| `submit` | rk_submit | `--ctx` | `run_id`, `run_dir`, `work_dir`, `rs_history`, `type_dir`, `yml_path`, `state` (normally `submitting`: the supervisor takes it on; `extracting` for an EMIR run whose DSPF/GDS are being made first), `supervisor_pid`, `dry_run`, `extract` (EMIR: run.json `extract`), `warnings[]`; an EMIR auto-extract that cannot run fails with `missing_env[]` / `extract` (the freshness result) |
| `status` | rk_submit | `--run DIR` | see 3.3 |
| `cancel` | rk_submit | `--run DIR` | `run_id`, `state` |
| `supervise` | rk_submit | `--run DIR` | INTERNAL (started by submit) |
| `collect` | rk_parse | `--run DIR` | parsed results, section 5.1 |
| `report` | rk_report | `--run DIR` | `html_path`, `official_reports[]` |
| `aged-include` | rk_aged | `--run DIR` `[--stress ID]...` `[--netlist CURRENT.scs]` | section 5.3 (+ `netlist_signature`, `current_signature`, `netlist_match` true/false/null when `--netlist` is given) |
| `aged-delta` | rk_aged | `--run DIR --tsv DELTA.tsv` `[--history NAME]` | `run_id`, `table_path` (copy at `tables/aged_delta_<history>.tsv`), `rows`, `numeric_rows`, `html_path` (aux report regenerated with the delta); run.json `aged_delta[]{history,table_path,rows,numeric_rows,created}` |
| `extract-resolve` | rk_extract | `--ctx` `[--text FILE]` | preview, never fails for an unresolved value: `resolved{key: {value, source (rule/literal/derived/default/user/unset), expr, missing[]}}`, `choices{variants[], qrc_decks[], corners[{name, technology_corner}]}`, `selected{lvs_variant, qrc_deck, corner, temperature}`, `suggested{power_names[], ground_names[]}`, `missing_env[]`, `errors[]`, `warnings[]`, `ready`, `text` (human-readable preview written with `--text`) |
| `extract` | rk_extract | `--ctx` `[--sync]` | `extract_dir`, `status_path`, `pid`, `gds`, `dspf` (expected product paths), `state`, `log`, `qci`, `dspf_cmd`, `si_env`, `calibre_gui_cmd`, `calibre_gui_cwd`, `commands{step: cmd}`, `resolved{key: value}`, `warnings[]`; fails up front (nothing created) with `missing[]` (every error) and `missing_env[]` when the rules do not resolve |
| `extract-status` | rk_extract | `--ctx` or `--dir DIR` | section 5.4 |
| `extract-check` | rk_extract | `--ctx` | `state` (`fresh`/`stale`/`missing`/`running`/`unresolved`), `reasons[]`, `gds`, `dspf`, `manifest`, `extract_dir`, `extracted` (manifest time), `layout`, `schematic` (current view identities `{dir,file,size,mtime,md5}`), `missing_env[]` (unresolved), `warnings[]` (section 5.5) |
| `progress` | rk_submit | `--run DIR` | `run_id`, `type`, `state`, `state_since`, `message`, `final`, `now`, `rows[]{stage (extract/job), name (strmout/si/lvs/qrc or simN), corner, mode, state, exit_code, job_id, started, elapsed (h:mm:ss), last (last non-empty log line), log, donau}`, `timeline[]` (last 8), `extract` (brief) |
| `extract-cancel` | rk_extract | `--ctx` or `--dir DIR` | `state` |
| `extract-run` | rk_extract | `--dir DIR` | INTERNAL (the detached worker started by `extract`) |
| `runs list` | rk_runs | `--ctx` `[--type T]` `[--test X]` `[--since YYYYMMDD]` `[--until YYYYMMDD]` `[--all]` (or `--persist-root DIR` without ctx) | `runs[]` (4.3), `table_path` (`<out stem>_runs.tsv`), `persist_root`, `warnings[]` |
| `runs show` | rk_runs | `--run DIR` | `run` (run.json), `summary` (or null), `note` |
| `runs note` | rk_runs | `--run DIR --note TEXT [--tags a,b]` | `run_id`, `note`, `tags[]` |
| `runs delete` | rk_runs | `--run DIR` `[--force]` | `deleted` (record dir only; never touches Work_Dir; refuses a non-final run without `--force`) |
| `runs compare` | rk_runs | `--run A --run2 B` | `a`, `b` (list rows), `conditions[]{key,a,b,same}`, `metrics[]{corner,metric,a,b,delta,delta_pct}`, `table_path` (metrics TSV, `<out stem>_metrics.tsv`), `conditions_table_path`. Corners pair by name, the rest in order (FF run vs SS run) |
| `runs settings-for-rerun` | rk_runs | `--run DIR` | `run_type`, `test`, `dut`, `ip_name`, `corners[]` (names that were selected), `settings`, + `run_id`, `maestro`, `design`, `project_name`, `corner_details[]`, `netlist` |
| `runs copy-reports` | rk_runs | `--run DIR` `[--file F]...` | `report_copies[]{path,kind(text/pdf/other),copy,size,note}`: text reports copied to `reports/`, PDFs referenced only |

Example (`submit` success):

```json
{"ok": true, "error": null, "cmd": "submit",
 "run_id": "20261008-100700_aging",
 "run_dir": "/proj/wa/relkit_runs/mylib/tb_top/20261008-100700_aging",
 "work_dir": "/scratch/jdoe/reliability/tb_top/amp_core/relsim1/3",
 "rs_history": 3, "type_dir": "/scratch/jdoe/reliability/tb_top/amp_core/relsim1/3/analog_aging",
 "yml_path": "/scratch/jdoe/reliability/tb_top/amp_core/relsim1/3/analog_aging/analog_aging.yml",
 "state": "queued", "supervisor_pid": 12345, "dry_run": false}
```

### 3.3 Run state machine (`status`)

`created -> [extracting ->] submitting -> queued -> running -> summarizing -> done`;
any step -> `failed`; `running`/`queued` -> `waiting_license` -> `queued` (EMIR resubmit
every `license_retry_minutes`, D18); EMIR auto-extract with LVS not clean ->
`lvs_failed`; user -> `cancelled` (also stops a running extraction); dry run ->
`dry_run_done`. `done`, `failed`, `cancelled`, `dry_run_done`, `lvs_failed` are final.
`extracting`: submit prepared the extraction (rk_extract.prepare) and started its
detached worker; the supervisor follows `<extract dir>/status.json`, copies the
steps into run.json `extract`, and submits EMIR (`submit_flow`) when the worker
published a fresh pair.
`status` also returns `raw_data_present`, `aux_report`, `failure_tail[]`; it
restarts the supervisor of a non-final run whose heartbeat
(`logs/supervisor.heartbeat`) is stale and whose pid is gone.

```json
{"ok": true, "error": null, "cmd": "status",
 "run_id": "20261008-100700_emir", "run_dir": "...", "type": "emir",
 "state": "waiting_license", "state_since": "2026-10-08T10:40:00", "final": false,
 "message": "Totem license unavailable; retry 2 at 10:50",
 "jobs": [{"sim": "sim1", "key": "FF125_test0_FF125_0", "state": "failed", "exit_code": 1}],
 "license": {"waiting": true, "retries": 2, "next_retry": "2026-10-08T10:50:00",
             "policy": "wait_forever", "deadline": null},
 "work_dir": "...", "official_reports": [], "summary_ready": false}
```

---

## 4. Run record (persistent, small; plan 2.3 / 4.9)

`<persist_root>/<maestro lib>/<maestro cell>/<run id>/`, run id =
`<YYYYMMDD-HHMMSS>_<type>` (collision in the same second: append `_2`, `_3`).

```
run.json          written by rk_submit (supervisor updates it atomically)
note.json         {"note": "...", "tags": [...]}   written only by `runs note`
input/            netlist copy (<name>.scs), netlist.sha1, yml copy, dspf/gds paths+sha1 (input/files.json)
summary.json      parsed results (section 5.1), written by `collect`
tables/*.tsv      SKILL tables (section 5.2)
reports/          RelStudio official report TEXT copies (*.report); PDFs only referenced
aux_report.html   rk_report (self-contained)
hrmi/<stress_id>/ R1 files: *.hrmiage0 (rewritten), *.hrmiage0.dat, aged_<stress_id>.scs
logs/             submit.log, supervise.log, relsim_<mode>.log
```

### 4.1 run.json

```json
{
  "schema": 1, "id": "20261008-100700_aging", "type": "aging", "rs_type": "analog_aging",
  "created": "2026-10-08T10:07:00", "user": "jdoe", "host": "host01",
  "maestro": {"lib": "mylib", "cell": "tb_top", "view": "maestro"}, "test": "test0",
  "design": {"lib": "mylib", "cell": "tb_top", "view": "config", "is_config": true},
  "history": {"name": "Interactive.3", "dir": "..."},
  "dut": {"inst": "I0", "lib": "mylib", "cell": "amp_core", "view": "schematic"},
  "ip_name": "tb_top", "project_name": "relsim1", "cell_name": "amp_core",
  "corners": [ {"...": "ctx corners with selected=true, verbatim"} ],
  "settings": {"...": "settings[type] after defaults were applied"},
  "site_path": "/proj/wa/.relkit_site.json", "relstudio_home": "/opt/relstudio",
  "submit_strategy": "start", "dry_run": false,
  "work_dir": "/scratch/jdoe/reliability/tb_top/amp_core/relsim1/3", "rs_history": 3,
  "type_dir": ".../relsim1/3/analog_aging", "yml": ".../analog_aging/analog_aging.yml",
  "corner_map": [{"key": "FF125_test0_FF125", "corner": "FF125", "sim": "sim1",
                  "temperature": "125", "mode": "Stress_1"}],
  "netlist": {"path": "...", "sha1": "...", "copy": "input/tb_top_test0.scs"},
  "state": "running",
  "timeline": [{"t": "2026-10-08T10:07:00", "state": "created", "msg": ""}],
  "jobs": [{"sim": "sim1", "key": "FF125_test0_FF125", "state": "running", "job_id": null, "exit_code": null}],
  "supervisor_pid": 12345,
  "license": {"retries": 0, "log": []},
  "official_reports": [], "aux_report": null, "summary": null,
  "raw_data_present": true
}
```

Also written by rk_submit: `cluster` (the yml Cluster block of the run's Donau
profile), `donau_jobs[]{cmd, sim, job_id, t}` (submit_batch: one per submit line,
id read with `donau_job_id_regex`), `extract` (EMIR: `{"mode": "own"}`, or `{mode:
"auto", check (fresh/stale/missing at submit), reasons[], dir, gds, dspf, extracted,
state (fresh/running/done/failed/lvs_failed/cancelled), steps[]{name,state,started,
ended,exit_code,log}, step, message, lvs_report, lvs, log_tail[], pid,
calibre_gui_cmd, calibre_gui_cwd}`), `jobs[].started` / `jobs[].ended` (first poll
that saw the job running-or-finished / finished; reset by a license retry),
`workarea`, `run_dir`, `message`, `state_since`,
`start_pid`, `attempt_started` (epoch s of the current submit attempt; Totem logs
older than it are ignored by the license check), `failure_tail[]` (last
`emir.license_tail_lines` lines of the failed job.out / relsim log), `warnings[]`,
`summary_ready`, `netlist.signature` (instance-name signature, see rk_yml),
`corner_map[].sim_dir` (from mapping.txt) and, for aging, `corner_map[].eval_temperatures`;
`license{retries, log[{t, retry, matches[]}], waiting, next_retry, policy, deadline,
first_wait, unmatched_tail[]}`. Job states: `queued`/`running`/`done`/`failed`, and
`prepared` after a dry run. rk_aged writes `aged_delta[]` (aged-delta) and `hrmi{<stress_id>: {hrmiage0, dat,
include_path, key, corner}}`. A license retry renames `simN/job.out|job.err` to
`job.out.try<N>` before resubmitting the same yml.

The Work_Dir History dir created by relkit holds `.relkit_history.json`
(Maestro lib/cell, test, DUT cell, netlist sha1, types): a later submit of another
run type for the same design reuses that History (GUI behaviour), any other submit
takes max+1.

### 4.2 Rules

* run.json is written only by rk_submit (submit + supervise) and rk_parse /
  rk_report / rk_aged (their own keys: `summary`, `aux_report`,
  `official_reports`, `hrmi`, `aged_delta`). Always read-modify-write with the atomic writer
  (`rk_common.write_json`). Notes/tags never go into run.json (note.json).
* `raw_data_present` is recomputed by `status` / `runs list` (Work_Dir/type_dir
  still exists). `runs list/show` write it back (plus `raw_data_cleaned` =
  first time seen gone) only for runs in a final state, so they never race a
  live supervisor.
* rk_runs also writes `report_copies` (`runs copy-reports`). Its library API
  for other modules (writes locked via `<run_dir>/.run.json.lock` + atomic
  replace): `create_run(ctx, site, run_type, settings, extra)` -> `(run_dir, run)`
  (record dir with collision suffix, input/ netlist copy + `netlist.sha1`,
  `input/files.json` with path/sha1/sha256 of netlist, dspf, gds; run.json in
  the 4.1 shape, state `created`), `load_run`, `update_run(run_dir, fields, fn)`,
  `set_state(run_dir, state, msg, **fields)`, `add_input_file(run_dir, path, kind)`,
  `copy_reports(run_dir, paths)`, `refresh_raw_data(run_dir)`. rk_submit
  currently creates run.json with its own (compatible) code; rk_runs reads
  either shape.
* Nothing under `run_dir` is deleted except by `runs delete`.

### 4.3 `runs list` row

`{"id", "type", "test", "dut", "n_corners", "life", "state", "pass" (true/false/null),
"key_metric", "note", "tags", "created", "run_dir", "raw_data_present"}`; the same
rows go to `table_path` (TSV) with `_run_dir` as the first column.

---

## 5. Results

### 5.1 Parsed results (`collect` out.json == run_dir/summary.json)

```json
{"ok": true, "error": null, "cmd": "collect",
 "type": "deos", "run_id": "20261008-101500_deos",
 "summary_table_path": "/.../tables/summary.tsv",
 "corners": [
   {"key": "FF125_test0_FF125", "corner": "FF125", "stress_id": null,
    "pass": false,
    "metrics": {"Total_DPM": 12.5, "vgs": 3, "vds": 0},
    "worst_device": "I0.X1.M3", "worst_model": "nch.1",
    "table_path": "/.../tables/deos_FF125_test0_FF125.tsv"}
 ]}
```

* `key` = RelStudio corner key (`<Mode>_<Test>_<CornerGroup>`, EMIR + `_0`);
  `corner` = ctx corner `name`; aging: one entry per Stress (`stress_id` =
  summary `Stress_ID`).
* `pass`: true / false / null (unknown). `metrics`: numbers where parseable,
  else strings. `worst_device`: instance path as reported (aging/DEOS
  `I0.X.Y.M3`; EMIR may be DSPF style `XXI_a/XI_b/MPM1@1`).
* aging tables: dfr0 rows (first 200); DEOS: `cell1_eos_full.rpt` rows sorted
  by DPM desc; EMIR: worst EM/IR rows.

### 5.2 TSV table format (Python writes with `rk_common.write_tsv`, SKILL reads with `rkTsvRead`)

* UTF-8, LF, first line = header, cells separated by one TAB, no quoting;
  TAB/CR/LF inside a cell become spaces; None -> empty cell.
* Reserved leading columns (shown hidden or narrow by SKILL):
  `_inst` = instance path for schematic jump (rkResultsJumpToInstance);
  `_sev` = `fail` / `warn` / empty (red / yellow row);
  `_key` = corner key (summary tables: double-click opens that corner's table);
  `_run_dir` (runs list).
* Remaining columns are display columns, header text = column title.

### 5.3 `aged-include` out.json (R1)

```json
{"ok": true, "error": null, "cmd": "aged-include", "run_id": "20261008-100700_aging",
 "run_dir": "/proj/wa/relkit_runs/mylib/tb_top/20261008-100700_aging", "test": "test0",
 "maestro": {"lib": "mylib", "cell": "tb_top", "view": "maestro"},
 "life": "10y", "netlist_sha1": "...",
 "items": [{"stress_id": "1", "key": "FF125_test0_FF125", "corner": "FF125",
            "corner_def": {"name": "FF125", "base_name": "FF125", "temperature": "125",
                           "sections": [{"model_file": "/proj/model/toplevel.scs", "section": "TOP_FF"}],
                           "vars": {"VSET": "12"}},
            "eval_temperatures": ["125"], "life": "10y",
            "hrmi_dir": "/.../hrmi/1",
            "hrmiage0": "/.../hrmi/1/cell1_Stress_1.hrmiage0",
            "dat": "/.../hrmi/1/cell1_Stress_1.hrmiage0.dat",
            "include_path": "/.../hrmi/1/aged_1.scs"}],
 "missing": [{"stress_id": "2", "reason": "Work_Dir cleaned; rerun Stress"}]}
```

`corner_def` = the run's own corner entry (null when run.json has none; rkAged
then looks the corner up in the current ctx). Aged corner name (rkAged):
`<corner>_aged<Life>_T<temp>_<run short id>`, fresh twin `<corner>_fresh_T<temp>_<run short id>`;
in corner and temperature `-` -> `m`, `.` -> `p`, anything else outside
`[A-Za-z0-9_]` -> `_`; run short id = `MMDDHHMM` of the run id (`_2` collision
suffix -> `s2`), e.g. run `20261008-100700_aging` -> `SS_aged10y_Tm40_10081007`.
Corner content: the Stress corner's model files + sections (Maestro quoting) and
variables, `temperature` = the evaluation temperature, plus one extra model file
`aged_<id>.scs` without a section (aged corner only); enabled for the run's test
only. Delta TSV (rkAgedDeltaTable): header
`_key _sev Output Test Point "Fresh corner" "Aged corner" Fresh Aged Delta "Delta %"`
(`_key` = aged corner, `_sev` = `warn` when the fresh value is numeric and the
aged one is missing); pairs = each aged corner with its fresh twin, else the
source corner, or explicit `ctx.aged_pairs`.

### 5.4 `extract-status` out.json

```json
{"ok": true, "error": null, "cmd": "extract-status",
 "extract_dir": "/proj/wa/Reliability/amp_core/extract",
 "state": "lvs_failed", "step": "lvs",
 "steps": [{"name": "strmout", "state": "done", "started": "...", "ended": "...", "log": "..."},
           {"name": "si", "state": "done"}, {"name": "lvs", "state": "failed"},
           {"name": "qrc", "state": "pending"}],
 "gds": "/proj/wa/Reliability/amp_core/amp_core.gds", "dspf": null,
 "lvs_report": "/.../extract/lvs/amp_core.lvs.report",
 "calibre_gui_cmd": "calibre -gui -lvs -runset /.../extract/amp_core.qci",
 "log_tail": ["..."]}
```

`state`: `running | done | failed | lvs_failed | cancelled`, or `none` when no
extraction was ever started in that dir (then only `existing` is meaningful).
Extra fields: `final` (bool), `message`, `started`, `ended`, `pid`, `host`,
`child_pid`, `heartbeat`, `layout_db`, `src_net`, `qci`, `dspf_cmd`, `si_env`,
`lvs{passed,banner,discrepancies,cells[],incorrect_cells[]}`, `calibre_gui_cwd`,
`log` (extract.log), per-step `log`/`cmd`/`cwd`/`exit_code`, and `existing`
(`rk_extract.find_artifacts`: `gds`, `dspf` = canonical `<cell>.gds/.dspf`
info or null, `gds_candidates[]`, `dspf_candidates[]` each `{path,size,mtime}`,
`warning` when the DSPF is older than the GDS) -- the "use existing" mode.
`gds`/`dspf` are set only after a fully successful run: both products are
published together at the end (intermediates stay in `extract/`), so a failed
run never leaves a mismatched pair. A worker that died is reported `failed`.
Layout of `<artifact_root>/<cell>/extract/`: `request.json`, `status.json`,
`extract.log`, `worker.log`, `<cell>.qci`, `<cell>.dspf.cmd`, `si/si.env`
(si runs with cwd `si/` and `-cdslib`), `lvs/` (= `*lvsRunDir`: `<cell>.calibre.db`,
`<cell>.src.net`, `<cell>.lvs.report`, `query_output/`), `qrc/`, `logs/<step>.log`.

---

### 5.5 Freshness of the published DSPF/GDS (`extract-check`, EMIR auto-extract)

A successful extraction writes `<artifact_root>/<cell>/<cell>.extract.json`:
`{schema, created, cell, layout, schematic, settings, gds, dspf, extract_dir}` where
`layout` / `schematic` = the identity of the cellview read at the START of the
run (`{dir, file (layout.oa / sch.oa / the only .oa), size, mtime, md5}`; md5 up to
256 MB), `settings` = `rk_extract.FINGERPRINT_KEYS` of the resolved parameters
(library, cell, layout_view, source_view, layer_map, lvs_rules_file, lvs_variant,
technology_corner (Quantus token), temperature, technology_library_file,
qrc_deck_dir, power_nets, ground_nets; lists sorted), `gds` / `dspf` = `{path, size,
mtime}` as published. `fresh` = both files + manifest exist, the current
identities equal the recorded ones (md5 when both have one, else size+mtime), the
fingerprint is equal and the files were not replaced; otherwise `stale` with one
reason per difference. `missing` = a file is absent; `running` = a live worker in
the extract dir; `unresolved` = the rules do not resolve (nothing can be checked).
Only the top cellviews are compared (README limitation).

## 6. SKILL public functions (per module)

All modules: prefix `rk` public / `rk_` private; globals guarded with
`(unless (boundp 'x) ...)`; SKILL rules in section 9.

**rkSite.il** (scaffold): `rkSiteLoad([workarea] [force])`, `rkSiteGet(key [default])`,
`rkSitePath()`, `rkSiteWarnings()`, `rkWorkarea()`, `rkUser()`, `rkRelkitDir()`,
`rkRelstudioHome()`, `rkJsonRead(path)`, `rkJsonParse(text)`, `rkJsonWrite(v path)`,
`rkJsonToString(v)`, `rkJsonBool(x)`, `rkJsonFalse`, `rkJsonEmptyArray`, `rkMakeObj()`,
`rkGet(obj "a.b.0" [default])`, `rkPut(tbl key v)`, `rkKeys(tbl)`, `rkTsvRead(path)`
-> `(header rows)`, `rkReadFileText(path)`, `rkExpandVars(s [vars])`, `rkMkdirs(dir)`,
`rkTimestamp()`, `rkPathJoin(a b)`, `rkShellQuote(s)`.

**rkMae.il** (SKILL Maestro): `rkMaeCurrentSession([win])` -> session string
(window's session; else current window's; else the only Maestro window
session; else the only `maeGetSessions` session; else nil);
`rkMaeListSessions()` -> list of `{session lib cell view has_window}`;
`rkMaeListTests(sess)`; `rkMaeEnabledTests(sess)`; `rkMaeDefaultTest(sess)` (first
enabled, else first); `rkMaeGetDesign(sess test)` -> table `{lib cell view is_config top}`;
`rkMaeGetGlobalVars(sess test)` -> table (test design variables overridden by
enabled Maestro global variables); `rkMaeTestModels(sess test)` -> list of
`(file section)`; `rkMaeGetCorners(sess test)` -> list of corner tables (2.3);
`rkMaeGetContext(sess [test])` -> ctx table (section 2 minus dut/settings/netlist;
sess nil = `rkMaeCurrentSession()`); `rkMaeWarnings()`;
`rkMaeFindHistory(sess test [histName])` -> `{name dir netlist_dir source mtime}` / nil;
`rkMaeExportNetlist(ctx [histName])` -> netlist path, fills `ctx["netlist"]`, `ctx["history"]`
(needs `ctx["dut"]["cell"]` for the artifact dir; clear error when no history has a netlist);
`rkMaeCopyNetlist(src dest [log])` -> `{rewrites kept log}`; `rkMaeParseNetlistParams(path)`
-> table; `rkMaeListTopInstances(sess test)` / `rkMaeTopInstancesOf(lib cell view [bindings])`
-> list of `{inst lib cell view master_view terms is_primitive has_schematic}`
(config-aware: the config top cell; `view` = config binding, else `schematic` if it
exists, else the master view; DUT candidates first). `rkResultsListTopInstances`
may simply call `rkMaeTopInstancesOf`. `rkMaeSettingsPath(ctx)`,
`rkMaeReadSettings(ctx)` -> table / nil, `rkMaeWriteSettings(ctx settings)` -> path (2.5).

**rkResults.il** (SKILL results & jump):
* Tables (a table = `(header rows)`, rows = lists of strings, as `rkTsvRead`):
  `rkResultsReadTable(tsv)`; `rkResultsLoadResults(pathOrTable)` (summary.json /
  collect out.json, read with `rkJsonReadKeepFalse` so `pass:false` != `null`);
  `rkResultsSummaryTable(results)` -> one row per corner (aging: per Stress) with
  hidden `_key _inst _sev _table` + `Corner [Stress] Pass <metrics...> Worst device
  Worst model` (`_table` = the corner's `table_path`, SKILL-only, never in a TSV;
  `_inst` = `worst_device`; deos metrics start with `Total_DPM`);
  `rkResultsDeviceTable(tsvOrTable)` (sorted by `DPM_EOS`/`DPM`/`Total_DPM`/`DPM*`
  descending when such a column exists, `_sev` kept); `rkResultsSortRows(table col [desc])`
  (numeric-aware); `rkResultsColIndex(header col)`; `rkResultsCell(table row col)`;
  `rkResultsReportSpec(table)` -> `(headers choices)` for `hiCreateReportField`
  (reserved columns width 0, `_sev` shown as `Flag` FAIL/WARN, numeric columns
  sort by value); `rkResultsListBoxItems(table)` -> strings (`"! "` prefix = fail);
  `rkResultsShowTable(title src ctx [noDisplay])` (src = summary.json path / results
  table -> summary rows, or a TSV path / `(header rows)`) -> form (modeless,
  `?dontBlock t`; double-click / [Open]: a row with `_table` opens that device
  table, else jumps to `_inst`; buttons Jump / Highlight all on page / Clear).
* Jump: `rkResultsParsePath(path)` -> `(style segs)`; `rkResultsResolveInstance(path ctx)`
  -> table `{ok matched total levels[{seg name item bit lib cell view bound descend}]
  top config message prefixed}` (DB only, no window); `rkResultsJumpToInstance(instPath ctx)`
  -> t/nil (t only when the full path was found; otherwise the window shows the
  deepest level and `rkResultsLastMessage()` says why); `rkResultsHighlightAll(paths ctx)`
  -> count (paths whose prefix is the current page: the instance on this page is
  haloed); `rkResultsClearHighlight()` -> count; `rkResultsWindow()`,
  `rkResultsCloseWindow()` (relkit reuses ONE read-only design window).
  Uses ctx `design{lib cell view is_config}` (else `maestro` + schematic),
  `dut.inst` (paths relative to the DUT are retried with it prefixed),
  `history.netlist_dir` / `netlist.map_dir` (map files: every `("sch" "net")`
  string pair in `ihnl/*/map` and `map/*`).
* DUT: `rkResultsListTopInstances(lib cell view [skipLibs])` -> DUT candidates only
  (`{inst lib cell view terms}`, view = exact `hdbBind` result incl. instance
  bindings, only instances bound to a schematic, libs basic/analogLib/... skipped);
  `rkMaeTopInstancesOf` is the unfiltered list. `rkResultsOpenTop(ctx)` -> window;
  `rkResultsPickDut(ctx doneFn)`: one selected instance (or the top-level instance
  of a descended window) -> calls `(doneFn dut)` at once and returns dut; else
  starts `enterPoint` in the TB window and returns t, calling `(doneFn dut|nil)`
  when the user clicks / cancels. NOTE: `enterPoint` called from a callback does
  not return until the point is entered (the GUI stays live), so call
  `rkResultsPickDut` last in a callback. `rkResultsDutFromInst(inst ctx)`.
* `rkResultsOpenFile(path)` -> html: `hiLaunchBrowser`, else / fallback: `view`.

**rkAged.il** (R1): `rkAgedCreateCorners(sess ctx agedOut [withFresh])` -> created
corner names (agedOut = aged-include out.json path or table; sess nil -> ctx
`maestro.session`, else `rkMaeCurrentSession()`; an existing corner of the same
name is replaced); `rkAgedDeleteCorners(sess names)` -> t when all removed;
`rkAgedListCorners(sess [shortId])`; `rkAgedPrepare(runDir [netlist stressIds])`
-> aged-include result (runs `relkit.py aged-include` synchronously);
`rkAgedDeltaTable(sess ctx historyName [outPath])` -> TSV path (default
`<run_dir>/tables/aged_delta_<history>.tsv`; run_dir = `ctx.run_dir`, else the
aging run whose short id the aged corner names carry, under
`<persist_root>/<maestro lib>/<maestro cell>/`; when found, `relkit.py aged-delta`
records it and refreshes the aux report); `rkAgedDeltaRows(sess history [pairs])`
-> `(header rows)`; `rkAgedReadResults(sess history)` -> `(point corner test output value)`
list (maeReadResDB); `rkAgedLastDelta()`; `rkAgedMessages()` (warnings of the last
call: netlist mismatch, "re-run Stress", unpaired corners); name helpers
`rkAgedShortId rkAgedTempLabel rkAgedSafeName rkAgedCornerName rkAgedFreshName rkAgedParseName`.

**rkIpc.il** (panel & IPC): `rkIpcCommandLine(subcmd ctxFile outFile [extraArgs])`
-> python argv string; `rkIpcShellCommand(...)` -> the full `/bin/sh -c` command;
`rkIpcNewCtxFile(ctx tag)` / `rkIpcNewOutFile(tag)` -> path under `<persist_root>/_ipc/`;
`rkIpcRun(subcmd ctxFile outFile callback [extraArgs timeoutSec])` -> handle
(async; callback = symbol, function object or function-name string, called once
with the result of section 3.0; errors inside it are caught and printed);
`rkIpcRunSync(subcmd ctxFile outFile [extraArgs timeoutSec])` -> result table
(blocks: tests/scripts only); `rkIpcCancel(handle)`; `rkIpcBusy(handle)`;
`rkIpcActive()`; `rkIpcSetEnv(list "NAME=value" ...)` (prefix for every command,
tests); `rkIpcLaunch(shellCmd [logFile])` (fire-and-forget: RelStudio GUI, file
browser, Calibre GUI). `ctxFile` may be nil for commands without ctx
(`status --run`, `extract-status --dir`...). Pollers:
`rkIpcPollStart(name subcmd ctxFile extraArgs intervalSec callback)` runs the
subcommand now and then every intervalSec; the callback returns non-nil to keep
polling; `rkIpcPollStop(name)`, `rkIpcPollNow(name)`, `rkIpcPollActive([prefix])`,
`rkIpcPollStopAll([prefix])`. Timer safety: each poller has a generation number
carried by its armed `hiRegTimer`; stale ticks (old generation, stopped poller,
request in flight) do nothing; a poller re-arms only from its own result, and an
in-flight request is killed after max(120, 2*interval+60) s. SKILL lambdas do
not close over locals, so callbacks get data through globals / symbols, never
closures.

**rkGui.il** (panel & IPC): `rkOpenPanel([sess])` (MyTool callback: raises a
displayed panel, else builds a new one and displays it), `rkGuiBuild([sess] [test])`
(build + instantiate + load Maestro, not displayed), `rkGuiCurrentForm()`,
`rkGuiClose()` (also stops the panel pollers; runs go on, a new panel resumes
them: newest run per type is followed if active, else its results are shown;
once the panel is closed no new poller is started for it -- an IPC result that
arrives later only records the run dir -- and the close callback
`rk_guiClosedCB('rk_panel_<n>)` is ignored unless it names the current panel;
a poller stops after `rk_guiPollMaxFails` (20) failed status calls in a row),
`rkGuiField(sym)` / `rkGuiGet(sym)` / `rkGuiSet(sym value)` (fields of the top
bar and of the tab pages, reached as form->rk_gTabs->pageN->field),
`rkGuiSubmit(type)` -> t / nil, `rkGuiRunCtx(type)` -> the ctx a submit sends,
`rkGuiState()`, `rkGuiMessage()`, `rkGuiSiteWorkarea` (nil = site from the real
workarea; tests point it at a scratch dir). Form lifecycle Pattern A: fresh form
name per build (`rk_panel_<n>`), the previous panel is cancelled, callbacks reach
the live form via `rk_guiForm`, `?dontBlock t`. Pollers are named
`gui:run:<type>` and `gui:extract`. Round 2: `rkGuiShowProgress(runDir)` -> the
progress form (`rk_prog_<n>`, fields `rk_pHead rk_pRows rk_pMsg`, poller
`rkprog:progress` -- independent of the panel, stops when the run is final or the
window closes; `rk_guiProgRes` = last `progress` result), `rkGuiCloseProgress()`;
context menus (`rk_guiAttachMenus`: `field->hiContextMenu` = `hiCreateSimpleMenu`
menus `rk_guiCtxMenu_<runs|aging|deos|emir>` on `rk_grList` / `rk_g?Res`, items
-> `rk_guiCtxMenuCB(where action)`, actions progress/status/log/workdir/cancel);
corners `Show` filter `rk_gCornerShow` (All / Selected only / Unselected only;
rows keep the full-list index in the hidden first column; per-cell setting
`corner_show`); Donau cyclic + summary per page (`rk_gaDonau rk_gaDonauInfo`,
`rk_gd...`, `rk_ge...`); EMIR `rk_geOwn` (own files) + `rk_geAuto` (freshness line,
from `extract-check`, run on resolve / DUT change / extraction done). QRC deck
choices are short labels (`<version>/<deck>`) mapped to the deck path
(`rk_guiQrcLabel` / `rk_guiQrcPath`). Per-cell settings content (2.5): `dut`,
`ip_name`, `settings.{aging,deos,emir,extract}` from the page fields; written on
DUT choice and on submit, read when a panel is built. Corner selection is never
saved (D3). Field symbols are listed in the rkGui.il header (tests drive them).

MyTool: `relkit.il` registers `"RelStudio..."` -> `rkOpenPanel`.

---

## 7. Fake RelStudio and fake tools (tests)

* `py/tests/fake_relstudio/` is laid out as a RELSTUDIO_HOME:
  `fake_relstudio/script/python/run_relsim.py` (owner: Python core).
* **Adapter rule** (rk_submit): run `<relstudio_home>/script/python/run_relsim.pyc`;
  if absent, `run_relsim.py`. Command:
  `[site.python, <script>, "-t", rs_type, "-m", mode, "-c", <yml>]`
  (+ `-u <user> -n <name>` for `report`), cwd = `type_dir`, stdout/stderr to
  `run_dir/logs/relsim_<mode>.log`.
* `submit_strategy`: `start` -> `-m start`; `submit_batch` -> `-m submit` then
  each non-empty line of `type_dir/batch_submit_list.txt` via `/bin/sh -c`.
  `dry_run: true` -> `-m submit` only.
* The fake builds the same tree as the real tool (shape from the probes'
  Work_Dir listing): `mapping.txt`, `simN/job.out` (`-STATUS-`, `EXIT_CODE`,
  `Program succeed|failed`), `summary_rpt/summary.txt`, per-type result files,
  `*.report`; Stress `.hrmiage0` + `.dat` for aging. Synthetic names only.
* Fake behaviour switch: JSON file from `$RELKIT_FAKE_RS_CONFIG`, else
  `fake_relstudio/fake_config.json` (git-ignored; written by tests), e.g.
  `{"mode": "ok"|"fail"|"license_fail", "license_fail_times": 2, "job_seconds": 2}`.
  Default (no file): success. Each `batch_submit_list.txt` line prints
  `Job <420N> is submitted to queue <fake>.` like dsub (job id tests).
* `py/tests/fake_tools/` (owner: extract & history): executables `strmout`,
  `si`, `calibre`, `qrc`; switch from `$RELKIT_FAKE_TOOLS_CONFIG`, else
  `fake_tools/fake_config.json`, e.g. `{"lvs": "pass"|"fail", "fail_step": null}`.
* VM dev site (`/home/yusheng/cadence_work/Test/workarea/.relkit_site.json`,
  outside the repo) points `relstudio_home` and `extract.tools.*` at the synced
  copies of these directories.

---

## 8. Tests and isolation

* Python: `py -3 -m unittest discover -s relkit/py/tests` (Windows) and
  `python3 -m unittest discover -s relkit/py/tests` (VM). Each test file starts
  with `sys.path.insert(0, <py dir>)`. Fixtures under `py/tests/fixtures/<area>/`,
  synthetic names only (`tb_top`, `amp_core`, `I0.X1.M3`, `/opt/relstudio`,
  `/proj/model`, Foundry `x`, Technology `999`).
* skillbridge reports a call as FAILED whenever `errset.errset` is set after
  it, and that property keeps the last error caught by ANY inner `errset`
  (even one the code handles on purpose). `run_skill_test.py` therefore clears
  it (`putprop 'errset nil 'errset`) after each load / report; do the same in
  any other bridge driver.
* SKILL: `python3 relkit/tests/run_skill_test.py relkit/tests/test_<area>.il`
  on the VM (after `bash relkit/tools/sync_vm.sh`). `run_skill_test.py`,
  `rkAged_vm_test.py` and `rkGui_smoke.py` use the skillbridge id in `$SB_ID`
  (default `default`), so all of them can run against a private Virtuoso
  (own `.cdsinit` with the sbStart.il axl-worker guard and `pyStartServer(?id ...)`). Test files use
  `rkTestBegin` / `rkCheck` / `rkCheckEqual` from `tests/rk_testlib.il`; scratch
  under `<workarea>/relkit_dev/tmp/`. Never display a form over the bridge.
* Executables (fake tools, scripts): the Windows clone has `core.filemode`
  off, so set the bit in the index: `git update-index --chmod=+x <path>`, then
  commit with ONLY that staged (a pathspec commit re-reads the working tree and
  drops the mode change). `sync_vm.sh` also chmods fake tools on the VM.
* Isolation gate: `bash relkit/tools/gate.sh` must print PASS before every
  commit. Real-value checks live only in
  `Circuit_helper/private/references/relstudio/relkit_golden/`.

## 9. SKILL rules (read the memories before writing SKILL)

OpenViking (actual URIs):
`viking://resources/projects/eda-test-workarea/memory/feedback_skill_form_lifecycle/feedback_skill_fo_7more_906609d4_1.md`,
`.../feedback_skill_gotchas/feedback_skill_gotchas_1.md` + `_2.md`,
`.../feedback_skill_loader_patterns/feedback_skill_lo_8more_9fd20daf_1.md`,
`.../reference_skillbridge_evalstring/reference_skillbridge_evalstring.md`,
`.../reference_skillbridge/reference_skillbridge.md`,
`.../reference_cadence_form_headless_test/reference_cadence_form_headless_test.md`.

Short list: no `let*`; no prefix `+ - * / < >` (use `plus`, `lessp`...); no
`defvar`; identifiers `[A-Za-z0-9_]` only; `setq` never on `x[k]`/`x->y`
(`setarray`, infix `=`); `~>` only on db objects; `stringToSymbol` not
`intern`; type templates `t s n l g d f b ?` only; no `?closeCallback`.
Verified in this build (scaffold smoke test): `getchar`, `charToInt`,
`intToChar` (bytes > 127 OK), `buildString(l "")`, `makeTable` default,
`foreach` over tables, `createDirHier`, `ipcBeginProcess` + `ipcWait` +
`ipcGetExitStatus`, `hiCreateAppForm ?buttonLayout 'Close`, `pcreReplace`
replacement strings DROP backslashes (use `rkShellQuote`, not regex, for quoting).
Verified by the results agent (IC6.1.8, VM): **`hiDisplayForm` of an app form
BLOCKS its caller until the form is closed unless the form was created with
`?dontBlock t`** (seen from a `hiRegTimer` callback; the GUI stays live, but the
code after `hiDisplayForm` waits) -- give modeless windows `?dontBlock t`.
`append` takes exactly two lists. `deOpen` with `configL (list lib cell "config" "r")`
+ `hierarchy "/I0(schematic):r/..."` attaches the config to the window
(`deGetConfigId`); `putpropq hl t enable` enables a highlight set;
`geGetInstHierPath` gives `(inst memInst row col)` with memInst = the BIT
NUMBER of an iterated instance; `dbClose` of a cellview that is also shown in a
window does not disturb the window; `hdbClose` of a config opened separately
does not close the window's config. To try GUI calls that might block, run them
from `hiRegTimer "(fn)" 1` and poll globals over the bridge.
Verified by the panel agent (IC6.1.8, VM): **writing a field's `value` with
`putprop` runs that field's `?callback` synchronously** (seen on a cyclic field);
a callback that writes its own field therefore recurses until Virtuoso dies (no
crash report is written). rkGui binds `rk_guiMute` around every programmatic
write and its callbacks return while it is set. `hiReportSelectItems` /
`hiReportGetSelectedItems` / `choices` work on a form that was never displayed.
`maeOpenSetup` (even `?mode "r"`) starts a Maestro axl worker Virtuoso that runs
the `.cdsinit` of the launching directory: a test Virtuoso with its own
skillbridge id must guard `pyStartServer` the way `skillbridge/sbStart.il` does
(`-axlChildIdFlag` in the parent cmdline), or the worker takes over its socket.
Verified by the R1 agent (IC6.1.8, VM): `maeReadResDB(?historyName h ?session s)`
works on a `maeOpenSetup` session; walk it with infix calls `rdb->points()` /
`pt->outputs()` (Lisp-form `(rdb->points)` returns the funobj, not the list); an
output has `->cornerName ->testName ->name ->value` (value: float, `"wave"` or nil);
result corner names of swept Maestro corners are `<corner>_<n>`. `axlPutModel` +
`axlSetModelFile` + `axlSetModelSection` (section stored quoted: `"\"tt\""`) on a
new corner gives `include "<file>" section=tt` in the point netlist; a model file
without a section gives `include "<file>"`. `maeRunSimulation ?callback
"(setq flag t)"` fires when the run ends (poll the flag). **Maestro deletes
histories -- the rdb in the view AND the simulation data in the results
location -- beyond `adexl.simulation saveLastNHistoryEntries` (default 10) when a
run starts**: a test that simulates on a shared Maestro view must raise it first
(`envSetVal`) and back up the results location as well as the view.

---

Verified by the SKILL reviewer (IC6.1.8, VM): `ipcWait(cid interval timeout)`:
the 2nd argument is the period of the "Waiting for ... to terminate" CIW
message (skipcref), not a poll period -- `rkIpcRunSync` passes
`max(30, timeout)`. Opening a Maestro view in a FRESH Virtuoso process and
reading its histories (rkMae smoke Part B) was seen to rewrite every history
`.rdb` file under `<view>/results/maestro/` (content and mtime change within
seconds, and empty `.<history>.rdb.crash.handle.done` marker files appear
next to them -- Maestro's crash handling of history databases; maestro.sdb,
active.state and data.dm do not change; a second open in the same process
changed nothing; the exact call was not isolated). Terminating that
Virtuoso rewrites them once more (seen at kill time) -- so restore `results/`
only after the test Virtuoso has exited -- a "view unchanged" check must cover
`results/` too, and restoring means restoring those files.

Verified in round 2 (IC6.1.8, private Virtuoso on Xvfb, real X events through
XTest): `putprop field menu 'hiContextMenu` attaches a `hiCreateSimpleMenu` menu
to a report field and a real right-click shows it; **a right-click does NOT change
the report field's selection** (the menu must act on the existing selection, or
on the page's run). A cyclic field grows to its longest choice regardless of the
2-D width (long DUT labels / QRC deck paths ran over the fields to their right:
put cyclics last in a row and keep their choices short). The window width is the
widest field's right edge (the `?initialSize` width did not widen it), so a
field reaching x=995 keeps a 975-wide tab field's right border inside.
`hiDisplayForm(form (list 0 0))` places the window.

## Change log

| date | role | change |
|---|---|---|
| 2026-10-08 | scaffold | initial contract |
| 2026-10-08 | extract & history | section 1: extract keys `source_view, cdslib, qrc_query_cmd, qrc_preserve_cell_list, qrc_ground_net, cdl_include_file, strmout_args, si_options, lvs_options, qrc_options` (added to site_defaults.json + site.example.json); tools may be argv lists (Windows tests run the fakes through python) |
| 2026-10-08 | extract & history | section 3.2: `extract --sync`, internal `extract-run`; `runs list --since/--until/--persist-root`, `runs delete --force`, new `runs copy-reports`; extra out fields of compare / settings-for-rerun |
| 2026-10-08 | extract & history | section 4.2: rk_runs library API + its own run.json writes (`raw_data_present`/`raw_data_cleaned` for final runs only, `report_copies`) |
| 2026-10-08 | extract & history | section 5.4: state `none`, extra status fields, `existing` (use-existing detection), products published only after full success, extract dir layout |
| 2026-10-08 | SKILL Maestro | 2.1/2.2: `design.top`, `history.netlist_mtime`, `netlist.kept/log/parameters`, ctx `warnings`; 2.3: swept model sections are a naming dimension + rules for `""` model file / corner without models / without temperature; 2.5: settings moved to `<cell dir>/relkit/` after the VM copy test, read/write in rkMae; 6: full rkMae API; 8: skillbridge `errset.errset` note + `run_skill_test.py` fix (minimal edit of a scaffold file) |
| 2026-10-08 | SKILL results & jump | 6: full rkResults API (tables from summary.json + TSV, SKILL-only hidden column `_table`, resolve/jump/highlight, DUT pick semantics); 9: verified facts (`?dontBlock t`, deOpen configL, memInst = bit, ...); rkSite.il minimal edit: `rkJsonParseKeepFalse` / `rkJsonReadKeepFalse` (JSON false -> `rkJsonFalse`; default reader unchanged) so tables can tell pass false from null |
| 2026-10-08 | Python core | 1: site keys `supervise_poll_seconds`, `start_wait_minutes`, `aging_eval_layout`, `simulator.Simulation_Cmd`, `emir.license_ignore`, `emir.totem_flow` (added to site_defaults.json; the first three also to site.example.json); 3.2: `aged-include --netlist` + signature fields, extra out fields of build-yml / emir-inputs / submit; 3.3: status extras + supervisor restart; 4.1: extra run.json fields, job state `prepared`, `.relkit_history.json` History sharing |
| 2026-10-08 | R1 aged corners | 3.2: new subcommand `aged-delta` (rk_aged); 5.3: aged-include out gains `run_dir`, `test`, `maestro`, per-item `corner_def`; aged/fresh corner naming (run short id = MMDDHHMM, `.` -> `p`), corner content, delta TSV columns; 6: full rkAged API; 9: verified maeReadResDB / model-file / history-purge facts. rk_report.py (Python core's file): minimal addition of an "Aged corners in Maestro (R1)" section (hrmi items + `aged_delta[]` tables) |
| 2026-10-08 | SKILL panel & IPC | 1: site keys `gui.open_dir_cmd`, `gui.relstudio_cmd` (added to site_defaults.json + site.example.json); 3.0: exact rkIpc command shape (`/bin/sh -c 'exec ...'`, `env` prefix, `_timeout`/`_cancelled`); 6: full rkIpc API (pollers with generation-guarded timers, `rkIpcLaunch`, `rkIpcSetEnv`) and rkGui API (field access, resume, per-cell settings content, `rkGuiSiteWorkarea`); 9: verified facts (putprop `value` fires the field callback, axl worker runs the launching dir's `.cdsinit`) |
| 2026-10-08 | SKILL reviewer | 6: rkGui closed-panel rules (no poller after close, stale close callback of a replaced panel ignored, poll-failure limit); 8: `$SB_ID` for every SKILL test driver (`run_skill_test.py`, `rkAged_vm_test.py`: minimal edits); 9: verified `ipcWait` interval meaning and the history `.rdb` rewrite on first open. Code fixes (no API change): rkGui R1 callback re-reads aged-include out.json keeping JSON false; `rk_agedRunPy` goes through `rkIpcRunSync`; `rkIpcRunSync` ipcWait interval; rkResults walk guards hdbPushCell / hdbIsAtStopPoint / sub-config top; rkSite `rkJsonParseKeepFalse` keeps the parser message; rkGui string/combo/file fields coerce site values to strings, `rk_guiPageOf` survives a reload, extract cancel keeps the last good extract dir |
| 2026-10-08 | env-derived extraction | section 1: extract parameters are RULES resolved against Virtuoso's environment (new py/rk_pdk.py, Auto_ext R1-R8): new keys `layer_map, lvs_deck_dir, lvs_basename, lvs_filename_pattern, lvs_default_variant, tech_name, tech_name_env_vars, qrc_deck_dir, qrc_deck_glob, qrc_query_cmd_name, qrc_preserve_cell_list_name, corners, default_corner, power_names, ground_names, check_files`; old fixed-value keys are legacy overrides; `lvs_options.rules_file_pattern` removed (use `lvs_filename_pattern`). 2.4: extract settings gain `lvs_variant, qrc_deck, power_names, ground_names`; `technology_corner` is a corner name. 3.2: new `extract-resolve`; `extract` out gains `resolved`, failure gains `missing_env`. rk_yml.classify_port reads `power_names/ground_names` (legacy names as fallback). rkGui EMIR page: RC corner / LVS variant / QRC deck cyclics, LVS power/ground fields, [Resolve / preview] (auto on load, DUT change, choice change; stale results ignored by out-file), [Show resolved]; [Extract] disabled while variables are missing. Top-bar corners table 118 px, tab area 597 px. Test helper `py/tests/fake_pdk.py` (synthetic PDK tree + its variables) |
| 2026-10-08 | Python review + E2E | Fixes, no API change: `submit` validates the whole yml before it creates the run record / History dir; the supervisor never dies in `submitting` and retries unexpected step errors (5 in a row -> `failed`); `aged-include --stress N` merges into run.json `hrmi` (missing Stress entries dropped) instead of replacing it; `extract-status` re-reads status.json before declaring a gone worker `failed` (race with a worker that just finished); `parse_ir_worst`/`parse_power_summary` skip unparsable numbers. relkit.py + rk_common.py (scaffold files, minimal): `rk_common.prune_ipc_dir` -- after each command whose `--out` is in a dir named `_ipc`, files older than 14 days there are deleted (at most once a day, marker `.pruned`); `write_json` retries the final rename on Windows while a reader holds the file (sharing violation; the cause of the earlier flaky Windows extract test). Test fixtures: measured values / layout coordinates copied from the real probes replaced by synthetic numbers (gate keywords extended) |
| 2026-10-08 | owner feedback round 2 | 1: `donau_profiles`, `donau_default`, `donau_job_id_regex`, `donau_query_cmd`; 2.4: emir `auto_extract`, per-type `donau_profile`, extract `layout_dir`/`schematic_dir`; 3.2: new `extract-check`, `progress`; `submit` out `extract`; 3.3: `extracting`, `lvs_failed` (final; also in rk_runs); 4.1: `cluster`, `donau_jobs`, `extract`, `jobs[].started/ended`; 5.5 freshness manifest `<cell>.extract.json` (rk_extract writes it at publish; `prepare` records the source identities); 6: rkGui progress window, context menus, corners Show filter, Donau rows, EMIR own-files check box + freshness line, QRC labels; panel top bar re-laid out (Pick button before the DUT cyclic; filter + count + selection buttons above the corners table); EMIR page: power/ground on one row, "Extract only"; 7: fake dsub job ids; 9: verified UI facts. rk_yml: `donau_profiles/donau_default/resolve_donau`, `cluster_block(site, profile)`, `build_doc` info `cluster`. rk_submit: auto-extract flow (`auto_extract_check`, `use_auto_extract`, `Supervisor.step_extract`), `merge_job_times`, `job_id_of`, `sim_of_line`, `progress` |
