# relkit

Run the RelStudio reliability flow (aging / DEOS / EMIR) from a Maestro
window. **MyTool > RelStudio...** opens one panel that:

* reads the current Maestro test, its design (config views included) and the
  corners checked in Maestro (swept corners are expanded);
* exports the Maestro netlist next to the other products of the DUT;
* writes RelStudio's upper-level yml (the same keys, order and tags as the
  RelStudio GUI) and submits it with `run_relsim` in the background;
* follows the run (queued / running / waiting for a Totem license / done),
  waits and resubmits when Totem has no license;
* shows RelStudio's **official** report plus relkit's own self-contained HTML
  report, and result tables where a double-click jumps to the device in the
  schematic;
* extracts DSPF + GDS for EMIR (strmout -> si -> Calibre LVS -> Quantus);
* keeps a persistent history of every run (list, notes, compare, rerun);
* R1: turns an aging run into **aged corners in Maestro**, so Maestro itself
  simulates the aged circuit next to a fresh twin and relkit tabulates the
  fresh/aged delta.

relkit is SKILL plus Python standard library only. Loading it never needs
Python; Python 3.8+ runs as a subprocess when you press a button.

---

## Contents

1. [Install](#install)
2. [Site configuration](#site-configuration)
3. [Using the panel](#using-the-panel)
4. [Run history](#run-history)
5. [R1: aged corners in Maestro](#r1-aged-corners-in-maestro)
6. [DSPF / GDS extraction](#dspf--gds-extraction)
7. [Where files go](#where-files-go)
8. [Limitations and things to know](#limitations-and-things-to-know)
9. [Acceptance checklist for a new site](#acceptance-checklist-for-a-new-site)
10. [Development](#development)

---

## Install

relkit is loaded by the repository's umbrella loader. If your `.cdsinit`
already loads `skill_tools.il`, nothing else is needed:

```skill
load("/abs/path/to/skill_tools/skill_tools.il")   ; loads mytool, dreg_gen, ..., relkit
```

To load relkit alone (the MyTool menu entry is added only when the `mytool`
framework is loaded first):

```skill
load("/abs/path/to/skill_tools/relkit/relkit.il")
```

The CIW prints `[relkit] v0.1.0 loaded from ...`. The menu entry is
**MyTool > RelStudio...**; `rkOpenPanel()` in the CIW does the same.

Requirements:

| what | why |
|---|---|
| Virtuoso IC6.1.8 with ADE Assembler / Explorer (Maestro) | developed and tested there |
| python3 >= 3.8 on the machine running Virtuoso | the `site.python` key; stdlib only, no pip |
| RelStudio with `run_relsim` | `$RELSTUDIO_HOME` of the Virtuoso process, or `relstudio_home` in the site file |
| `strmout`, `si`, `calibre`, `qrc` on `PATH` (or full paths in the site file) | only for one-click extraction |

---

## Site configuration

Everything that depends on your site (paths, cluster account, PDK files)
lives in a **site file that is never committed**. relkit looks for it in this
order and uses the first one found:

1. `$RELKIT_SITE` (must exist)
2. `<workarea>/.relkit_site.json` (workarea = `$RELKIT_WORKAREA`, else the
   Virtuoso working directory)
3. `relkit/site.json` (git-ignored)
4. none: built-in defaults only (a warning is shown)

The site file is deep-merged over `site_defaults.json`, so it only needs the
keys you change. `${WORKAREA}`, `${USER}`, `${RELKIT_DIR}` and `${ANY_ENV_VAR}`
are expanded; a bare `$NAME` is left alone on purpose (RelStudio needs the
literal `$MODEL_ROOT/...`). Start from `site.example.json`:

```sh
cp skill_tools/relkit/site.example.json <workarea>/.relkit_site.json
```

The keys you will normally set:

| key | meaning |
|---|---|
| `python` | python3 used to run `py/relkit.py` |
| `relstudio_home` | RelStudio install; `null` = `$RELSTUDIO_HOME` of Virtuoso |
| `work_root` | RelStudio Work_Dir root: `<work_root>/<IP>/<Cell>/<Project>/<History>` (same layout as the GUI) |
| `artifact_root` | netlist / DSPF / GDS products: `<artifact_root>/<DUT cell>/` (default `${WORKAREA}/Reliability`) |
| `persist_root` | run records (default `${WORKAREA}/relkit_runs`) |
| `project_name` | yml `Common.Project_Name` (default `relsim1`) |
| `submit_strategy` | `start` (`run_relsim -m start`) or `submit_batch` (`-m submit`, then each line of `batch_submit_list.txt`) |
| `dry_run` | `true`: only `run_relsim -m submit` (scripts generated, nothing submitted) |
| `model_file_map` | regex rules mapping a Maestro corner model file to the yml `Model_File` (e.g. `.../toplevel.scs` -> `$MODEL_ROOT/alps/toplevel.scs`) |
| `tech` | `Foundry, Technology, Tech_Voltage, Tech_Layout, Rel_Tech_Dir` |
| `cluster` | yml `Cluster` block (type, group, queue, CPU, memory ...) |
| `simulator` | yml `Simulator` block (name, accuracy, threads, options) |
| `aging_model` | aging `Model_File`, `Relxpert_Uri_Libs` |
| `emir.*` | `gds_map_file`, `rc_corner`, license policy defaults, `license_keywords` / `license_ignore`, `totem_flow` overrides |
| `extract.*` | tool paths and PDK files for extraction (see below) |
| `defaults.aging/deos/emir` | default values of the panel fields |
| `gui.*` | panel poll period, `open_dir_cmd` (default `xdg-open`), `relstudio_cmd` |

`docs/CONTRACT.md` section 1 is the complete key reference. Check what relkit
resolved with:

```sh
python3 skill_tools/relkit/py/relkit.py site --workarea <workarea> --out /path/site_out.json
```

---

## Using the panel

Open a Maestro view, then **MyTool > RelStudio...**. The panel has a top bar,
a corners table shared by all pages, and four pages.

### Top bar

* **Test**: the Maestro test (default: the first enabled test).
* **Design** (read only): the test's design; for a config view also the top
  cell that is really simulated.
* **RelStudio**: which RelStudio installation will be used.
* **DUT**: the instance in the testbench that RelStudio analyses. Choose it
  from the drop-down (top-level instances bound to a schematic) or with
  **Pick from schematic** (select or click the instance). The DUT decides the
  yml `Cell_Name`, the EMIR `Sim_Cell` / `Instance_Name`, what is extracted,
  and where products go.
* **IP_Name**: default = Maestro cell name.
* **Reload from Maestro**: re-read tests, corners and variables.

The DUT, IP_Name and page fields are saved per Maestro cell (see
[Where files go](#where-files-go)) and restored the next time.

### Corners

One row per corner after sweep expansion (a corner sweeping temperature
`-40 125` becomes `SS_t-40`, `SS_t125`), with sections, temperature and
overridden variables. The **Use** column starts as checked in Maestro.
Double-click a row or use **Toggle selected / All / None / As in Maestro** to
change it for this panel only: relkit never writes corner selection back to
Maestro.

### Aging / DEOS / EMIR pages

Each page has its settings (defaults come from RelStudio's own defaults and
your site file), a status line, a results table and these buttons:

* **Submit**: exports the netlist from Maestro, writes the yml, creates a run
  record and starts RelStudio in the background. You can close the panel or
  even Virtuoso; the run goes on, and the next panel picks it up.
* **Cancel run**, **Official report** (RelStudio's report), **Aux report**
  (relkit's HTML report).
* Results: one row per corner (aging: per Stress). **Open device table** (or
  double-click) shows the per-device table: aging degradation (dfr0), DEOS
  violations sorted by DPM with failing rows flagged, EMIR EM/IR worst
  points. Double-click a device row, or **Jump to worst device**, to open the
  testbench schematic descended to that instance, selected and highlighted.

Page specifics:

* **Aging**: life time + unit (default 10 years), stress window
  (Start/Stop), evaluation temperatures (empty = each corner's temperature).
  Plus the R1 buttons **Create aged corners (R1)** and **Delta table
  (fresh/aged)**.
* **DEOS**: life time, window and `Simulation_Time`, TDDB temperature (empty =
  corner temperature).
* **EMIR**: DSPF and GDS (**Extract DSPF + GDS**, or **Use existing
  (detect)** / browse), layout lib/view, RC corner and extraction temperature;
  power and ground nets as `NET=V` lists (**Fill from DUT ports** prefills
  them from the DUT ports and the testbench's DC sources; a power net without
  a voltage blocks Submit until you type it); EM temperature (110), Run_Type
  (`DYN SEM`), self-heating; **Totem license policy**: *wait forever*
  (default), *wait N hours*, or *fail*. While waiting the status line says
  `waiting for a Totem license (retry N at hh:mm)` and the whole EMIR run is
  resubmitted every `emir.license_retry_minutes`.

### Runs page

See [Run history](#run-history).

---

## Run history

Every submit is a run record in `<persist_root>/<maestro lib>/<maestro cell>/<YYYYMMDD-HHMMSS>_<type>/`:

```
run.json          settings, corners, DUT, Work_Dir, state timeline, license retries, ...
note.json         your note and tags
input/            netlist copy + sha1, yml copy, DSPF/GDS path + hashes (files.json)
summary.json      parsed results; tables/*.tsv  result tables
reports/          text copies of RelStudio's official reports (PDFs: path only)
aux_report.html   relkit's report (self-contained, opens offline)
hrmi/<stress>/    R1 files (see below)
logs/             supervisor and run_relsim logs
```

A record is a few kB to about 1 MB. It stays readable after the RelStudio
Work_Dir has been cleaned up (the list then shows the raw data as
"cleaned").

The **Runs** page lists the records of the current Maestro cell (or all, with
filters by type, test and date). Actions: **Show results**, **Official
report**, **Aux report**, **Open Work_Dir**, **RelStudio GUI**, **Refresh
status**, **Rerun with these settings** (fills the panel with the old run's
settings and corners; review and Submit), **Compare two** (condition diff +
metric diff, e.g. before/after a circuit change, or FF vs SS), **Cancel run**,
**Save note** (note + tags such as `sign-off`), **Delete record** (click twice
within 15 s; deletes the record only, never the RelStudio Work_Dir).

The same operations are available from a shell:

```sh
py=skill_tools/relkit/py/relkit.py
python3 $py runs list --persist-root <persist_root> --all --out /path/o.json
python3 $py runs compare --run <run dir A> --run2 <run dir B> --out /path/o.json
python3 $py status --run <run dir> --out /path/o.json
```

Every command writes `{"ok": ..., "error": ..., ...}` to `--out` and exits 0
only when ok; logs go to stderr.

---

## R1: aged corners in Maestro

Maestro cannot import RelStudio's aged waveforms, so relkit lets Maestro
simulate the aged circuit itself:

1. Run an **aging** job and wait until it is done.
2. Press **Create aged corners (R1)** on the Aging page. relkit
   * copies each Stress's `.hrmiage0` and `.hrmiage0.dat` into the run record
     (`hrmi/<stress>/`) and points the copied `.hrmiage0` at the copied data,
     so the corners keep working after the Work_Dir is cleaned;
   * writes `aged_<stress>.scs`, the HRMI block RelStudio adds to its aged
     netlists (copied from that run's own aged netlist, so no PDK path is
     hard-coded);
   * creates, for each Stress corner and evaluation temperature, a Maestro
     corner `<corner>_aged<Life>_T<temp>_<MMDDHHMM>` = the Stress corner's
     model sections and variables, the evaluation temperature, plus
     `aged_<stress>.scs` as an extra model file, and a fresh twin
     `<corner>_fresh_T<temp>_<MMDDHHMM>` without it. Both are enabled only for
     the run's test. (`-` in names becomes `m`, `.` becomes `p`.)
   * warns when the current Maestro netlist no longer matches the one the
     Stress ran on (instance names), because the aging data might then not
     apply to every device.
3. Run those corners in Maestro (with the ALPS simulator the HRMI options
   need).
4. Press **Delta table (fresh/aged)**: relkit reads the outputs of the newest
   history and writes a table output x corner with Fresh / Aged / Delta /
   Delta %, stored in the run record and added to its aux report.

The corner name carries the run's time stamp, so a Maestro result can always
be traced back to its Stress run. Delete the corners in Maestro when you no
longer need them.

---

## DSPF / GDS extraction

EMIR needs a DSPF and a GDS of the DUT. **Extract DSPF + GDS** runs, on the
login machine in the background (same method as Auto_ext, ported; Auto_ext
itself is not needed):

1. `strmout` the DUT layout to GDS;
2. `si` netlists the schematic (source netlist for LVS);
3. `calibre -lvs` with a rendered runset. **If LVS is not clean, the chain
   stops**: the status shows the report and **Open Calibre GUI** opens the
   same runset interactively;
4. `qrc` (Quantus) writes the DSPF.

Only after all four succeed are `<DUT cell>.gds` and `<DUT cell>.dspf`
published together in `<artifact_root>/<DUT cell>/`, so a failed run never
leaves a mismatched pair. Intermediate files stay in `extract/` below it.
**Use existing (detect)** fills the fields with files already there and warns
when the DSPF is older than the GDS. The panel can change the RC corner
(`technology_corner`) and the extraction temperature; everything else comes
from the site file's `extract` section:

| key | meaning |
|---|---|
| `tools.strmout/si/calibre/qrc` | executables (string, or an argv list) |
| `pdk_layer_map` | strmout layer map |
| `calibre_lvs_dir`, `calibre_lvs_basename`, `lvs_variant` | LVS rule file = `<dir>/<basename>.<variant>.qcilvs` (pattern in `lvs_options.rules_file_pattern`) |
| `qrc_query_cmd` | PDK query command file run as LVS post-trigger |
| `technology_library_file`, `technology_name`, `technology_corner`, `temperature` | Quantus technology |
| `power_nets`, `ground_nets`, `qrc_ground_net` | supply names for LVS / Quantus |
| `qrc_preserve_cell_list`, `cdl_include_file`, `strmout_args`, `cdslib`, `source_view` | optional |
| `si_options`, `lvs_options`, `qrc_options` | per-key overrides of the built-in recipe |

Extraction refuses to start while a required key is unset and lists the
missing ones.

---

## Where files go

| what | where |
|---|---|
| exported netlist | `<artifact_root>/<DUT cell>/<maestro cell>_<test>.scs` (+ `.rewrite.log`: relative includes made absolute) |
| DSPF / GDS | `<artifact_root>/<DUT cell>/<DUT cell>.dspf/.gds`, intermediates in `extract/` |
| RelStudio Work_Dir | `<work_root>/<IP>/<DUT cell>/<project>/<History>/<type>/` (aging, DEOS and EMIR of the same design share a History, like the GUI) |
| run records | `<persist_root>/<lib>/<cell>/<run id>/` |
| per-cell panel settings | `<maestro lib>/<maestro cell>/relkit/relkit_settings.json` (a directory, so a Library Manager copy of the cell carries it; Library Manager shows it as a view named `relkit`) |
| IPC scratch | `<persist_root>/_ipc/` (one small ctx/out/log set per button press; files older than 14 days are deleted automatically) |

relkit never writes to `/tmp`.

---

## Limitations and things to know

* **Netlist source**: IC6.1.8 has no per-corner netlist API, so relkit takes
  the netlist of the newest Maestro history that has one for the test.
  **Simulate the test once in Maestro first**, and again after changing the
  schematic (the copy's source is listed in `<netlist>.rewrite.log` and in the
  run record). RelStudio rewrites sections,
  temperature and parameters itself, so one netlist serves every corner.
* **`run_relsim -m start`**: whether it blocks until the jobs end differs
  between installations; relkit handles both. If submission does not work
  with `start`, set `submit_strategy` to `submit_batch`.
* **Cancel** stops relkit's supervisor and `run_relsim`. Jobs already handed
  to the cluster keep running; kill them with your cluster's tools.
* **Totem license detection** uses `emir.license_keywords` (minus
  `emir.license_ignore`). When a failed EMIR job matches nothing, the end of
  its log is stored in run.json (`license.unmatched_tail`) so the keywords
  can be extended.
* **EM worst-file rows** are parsed best effort (layer, location, ratio,
  net); the raw line is always kept in the table.
* **Schematic jump** works on dotted instance paths (`I0.X1.M3`, config
  bindings and buses included). DSPF-style EMIR names
  (`XXI0/XX2/MMP1@1`) are tried after stripping the `X`/`M` prefixes and
  `@n`; if a level cannot be matched the window stops at the deepest level
  found and says which segment failed.
* The test selected in the Maestro GUI cannot be read through SKILL: the panel
  starts on the first enabled test.
* A corner without a temperature uses the test temperature (read with an
  undocumented call; 27 if it is unavailable).
* Several evaluation temperatures in one aging run are written as one
  `Aged_k` entry per temperature; set `aging_eval_layout` to
  `temperature_list` for a single `Aged_1` listing them all, if your RelStudio
  expects that.
* `Rc_Temperature` follows the corner temperature (no panel field).
* Extraction: `si` runs in `extract/si/` with `-cdslib <workarea>/cds.lib`
  (so no `si.env` is written into the workarea); the GDS exists twice (the
  LVS layout database and the published copy).
* Maestro deletes old histories beyond `saveLastNHistoryEntries` when a run
  starts; running the R1 corners in Maestro is an ordinary Maestro run and
  follows your Maestro settings.

---

## Acceptance checklist for a new site

Run these once on the target machine after copying `relkit/` and creating
the real site file. Steps 1-3 need no cluster time.

1. **Deploy**: copy `relkit/` (with the rest of `skill_tools/`) and put the
   site file in place. If `.cdsinit` already loads `skill_tools.il`, nothing
   else changes. Check the CIW for `[relkit] ... loaded` and the MyTool entry.
2. **Corners**: on a real testbench, check FF/SS x -40/125 in Maestro; the
   panel's corners table must show the same corners, expanded, with the same
   sections, temperatures and variables.
3. **Dry run**: set `"dry_run": true`, submit aging, DEOS and EMIR. Compare
   the generated ymls (`<run dir>/input/*.yml`) with ymls written by the
   RelStudio GUI for the same setup: only Work_Dir, time, machine, tool
   versions and `Cell_Name` (relkit uses the DUT cell) should differ.
4. **Real runs**: set `dry_run` back to false and submit aging, DEOS and EMIR
   once each on a small cell. Note whether `run_relsim -m start` blocks (see
   `logs/relsim_start.log` and the state timeline), and check that the state
   goes to `done`, the summary table fills and the official reports appear.
5. **R1**: from the aging run of step 4, create aged corners, run them in
   Maestro with ALPS, and compare with RelStudio's own Aged result for the same
   corner (agreement = R1 works). Check in the ALPS log how many instances got
   aging applied.
6. **Totem license**: when a real license shortage happens, take the end of
   the EMIR job log (`run.json` `license.unmatched_tail` / `failure_tail`) and
   add keywords to `emir.license_keywords` if it was not recognised.
7. **Extraction**: fill the `extract` section from a known-good Auto_ext run
   (its rendered `si.env`, Calibre runset, Quantus command file and strmout
   options), extract one DUT, and diff the DSPF with Auto_ext's.
8. **RelStudio GUI history**: open the RelStudio GUI on the same
   `<work_root>/<IP>/<Cell>/<Project>` and check that relkit's runs appear in
   its history list.

---

## Development

* Interface contract between all parts: `docs/CONTRACT.md`.
* Python tests (Windows and Linux): `python3 -m unittest discover -s relkit/py/tests`.
  They use a fake RelStudio (`py/tests/fake_relstudio/`) and fake extraction
  tools (`py/tests/fake_tools/`), synthetic names only.
* SKILL smoke tests, in a live Virtuoso through skillbridge (`$SB_ID` selects
  the server): `python3 relkit/tests/run_skill_test.py relkit/tests/<test>.il`,
  `python3 relkit/tests/rkGui_smoke.py` (whole panel, headless, end to end
  against the fakes) and `python3 relkit/tests/rkAged_vm_test.py [--sim]`
  (R1 against a real Maestro view; backs up and restores the view).
* `tools/sync_vm.sh` copies `relkit/` to a dev VM; `tools/gate.sh` is the
  public-repository isolation check (keyword list kept outside the repo) and
  must pass before every commit.
