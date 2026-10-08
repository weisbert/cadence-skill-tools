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
| `cluster` | base of the yml `Cluster` block (type, group, queue, CPU, memory, GPU, arch); fills whatever a job policy does not say |
| `job_policy_dirs` | extra directories with Maestro job policy `.jp` files (only needed with a customised `setup.loc`) |
| `donau_profiles` | FALLBACK Donau settings when no Maestro job policy applies, each listing only what differs from `cluster`, e.g. `{"std": {"Queue": "normal"}, "emir": {"Queue": "long", "CPU": 16, "Memory": 64000}}`; offered as `site: <name>` |
| `donau_default` | fallback profile per run type, e.g. `{"aging": "std", "deos": "std", "emir": "emir"}` |
| `donau_query_cmd` | optional command that reports a cluster job (`{job_id}` is replaced), shown in the progress window; `null` = not queried |
| `donau_job_id_regex` | how to read the job id from the submit output (default: dsub's `Job <123> ...`) |
| `simulator` | yml `Simulator` block (name, accuracy, options); `Sim_Mt` null = follow the Donau CPU count |
| `aging_model` | aging `Model_File`, `Relxpert_Uri_Libs` |
| `emir.*` | `gds_map_file`, `rc_corner`, license policy defaults, `license_keywords` / `license_ignore`, `totem_flow` overrides |
| `extract.*` | extraction tools, and the rules that derive the PDK files from the environment (see below) |
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
Double-click a row or use **Toggle Use / All / None / As in Maestro** to
change it for this panel only: relkit never writes corner selection back to
Maestro. The **Corners** drop-down above the table filters what is shown:
*All*, *Selected only* or *Unselected only* (display only; the choice is
remembered per cell), next to the count `N of M selected`.

### Aging / DEOS / EMIR pages

Each page has its settings (defaults come from RelStudio's own defaults and
your site file), a status line, a results table and these buttons:

* **Submit**: exports the netlist from Maestro, writes the yml, creates a run
  record and starts RelStudio in the background. You can close the panel or
  even Virtuoso; the run goes on, and the next panel picks it up.
* **Cancel run**, **Official report** (RelStudio's report), **Aux report**
  (relkit's HTML report), **Progress...** (the [progress window](#progress-window)
  of the page's run; also on a right-click of the results table).
* **Donau**: which cluster settings RelStudio's jobs use. relkit does not keep
  its own copy: it takes them from your **Maestro job policies**. The default
  is `Maestro current (<policy>)` -- the job policy Maestro uses for the test;
  the drop-down also lists every other job policy found (the `.cadence/jobpolicy`
  directories of the Cadence search path) and the site fallback profiles
  (`site: <name>`). The one-line summary shows Group / Queue / CPU / Mem /
  Sim_Mt and where they come from. Mapping of the policy's `jobsubmitcommand`
  (`distributionmethod=Command`): `dsub -A <account>` -> Group, `-q` -> Queue,
  `-R "cpu=8;mem=8000"` -> CPU and Memory (MB), `gpu=` -> GPU; other options are
  ignored and missing keys come from the site `cluster`. A Local / LBS / non-dsub
  policy is listed as *not usable* and the site profile is used instead.
  **Sim_Mt** (blank = the CPU count) overrides the simulator threads. The choice
  is saved per cell and recorded in the run (policy name, file, and the
  resolved Cluster block); **Rerun with these settings** reuses the policy the
  run actually used, even if Maestro's current one changed since.
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
* **EMIR**: the DSPF and GDS are **automatic**: **Submit EMIR** checks
  `<artifact_root>/<DUT>/<DUT>.dspf/.gds` and, when they are missing or stale,
  extracts them first and then submits EMIR, all in the background (see
  [extraction](#dspf--gds-extraction)). The line next to the check box says
  whether they are *FRESH*, *STALE* (and why) or *MISSING*. Tick **Use my own
  DSPF/GDS files** to give your own files instead (browse or **Use existing
  (detect)**). Also: layout lib/view, RC corner, extraction temperature,
  LVS variant, Quantus deck and LVS power/ground names (the PDK paths come
  from the environment);
  power and ground nets as `NET=V` lists (**Fill from DUT ports** prefills
  them from the DUT ports and the testbench's DC sources; a power net without
  a voltage blocks Submit until you type it); EM temperature (110), Run_Type
  (`DYN SEM`), self-heating; **Totem license policy**: *wait forever*
  (default), *wait N hours*, or *fail*. While waiting the status line says
  `waiting for a Totem license (retry N at hh:mm)` and the whole EMIR run is
  resubmitted every `emir.license_retry_minutes`.

### Runs page

See [Run history](#run-history).

### Progress window

**Progress...** (on each page, on the Runs page, or **Show progress** in the
right-click menu) opens a window with one row per step of the run: the
extraction steps (`strmout`, `si`, `lvs`, `qrc`) when an EMIR run extracts
first, then one row per RelStudio job (`sim1`, `sim2`, ...) with its corner /
mode, state (queued, running, done, failed, waiting for a license), cluster
job id when known, start time, elapsed time and the last line of its log.
It refreshes every `gui.status_poll_seconds` while open and the run is not
finished; closing it stops the refresh. **Open log of the row** (or
double-click) opens that job's `job.out` / that step's log.

**Right-click menus**: the results table of each page (acts on that page's
run) and the Runs list (acts on the selected run: click it first, a
right-click does not change the selection) have a menu **Show progress /
Refresh status / Open log / Open Work_Dir / Cancel run**.

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
within 15 s; deletes the record only, never the RelStudio Work_Dir),
**Progress...** and the right-click menu (see [Progress window](#progress-window)).

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

EMIR needs a DSPF and a GDS of the DUT; relkit makes them. **Submit EMIR**
first checks whether `<artifact_root>/<DUT>/<DUT>.dspf` and `.gds` are a fresh
extraction of the current design: both files exist, the record
`<DUT>.extract.json` written by the extraction exists, the layout and the
source schematic cellviews are unchanged (their `.oa` file: size, time, md5),
the extraction settings (LVS variant and rules file, RC corner, temperature,
Quantus deck, layer map, tech library, LVS power/ground names) are the same,
and nobody replaced the files. If so EMIR reuses them; if not, the extraction
runs first and EMIR follows automatically, inside the same background
supervisor (closing the panel or Virtuoso does not stop it). The run record's
timeline shows the extraction steps, then the EMIR states; if LVS is not
clean the run ends `lvs_failed` and the EMIR page offers **Open Calibre GUI**
and **LVS report**. **Extract only** runs the same chain without EMIR.

The chain runs on the login machine in the background (same method as
Auto_ext, ported; Auto_ext itself is not needed):

1. `strmout` the DUT layout to GDS;
2. `si` netlists the schematic (source netlist for LVS);
3. `calibre -lvs` with a rendered runset. **If LVS is not clean, the chain
   stops**: the status shows the report and **Open Calibre GUI** opens the
   same runset interactively;
4. `qrc` (Quantus) writes the DSPF.

Only after all four succeed are `<DUT cell>.gds` and `<DUT cell>.dspf`
published together in `<artifact_root>/<DUT cell>/` (with `<DUT
cell>.extract.json`), so a failed run never leaves a mismatched pair.
Intermediate files stay in `extract/` below it. With **Use my own DSPF/GDS
files**, **Use existing (detect)** fills the fields with files already there
and warns when the DSPF is older than the GDS.

From a shell: `python3 relkit.py extract-check --ctx <ctx.json> --out o.json`
reports `fresh` / `stale` (with the reasons) / `missing`.

### Where the PDK values come from

The PDK paths change from project to project, but the PDK setup script
exports them as environment variables. relkit derives them the way Auto_ext
does, from **Virtuoso's environment** (start Virtuoso from a shell that sourced
the PDK setup):

| parameter | rule (site `extract.*` key, default) |
|---|---|
| strmout layer map | `layer_map` = `$PDK_LAYER_MAP_FILE` |
| Calibre LVS deck directory | `lvs_deck_dir` = `$calibre_source_added_place|parent` |
| LVS rules file | `<deck dir>/<basename>.<variant>.qcilvs`; basename = the deck directory name; the variants are the files found there |
| CDL prelude (si.env `incFILE`) | `cdl_include_file` = `$calibre_source_added_place` |
| Quantus technology library | `technology_library_file` = `$SETUP_ROOT/assura_tech.lib` |
| Quantus technology name | parent directory name of `$PDK_TECH_FILE` (else `$PDK_LAYER_MAP_FILE`, `$PDK_DISPLAY_FILE`) |
| Quantus (QCI) deck, `query_cmd`, `preserveCellList.txt` | `qrc_deck_glob` = `$VERIFY_ROOT/runset/Calibre_QRC/QRC/*/*/QCI_deck` |

So the variables that must be set are `PDK_LAYER_MAP_FILE`,
`calibre_source_added_place`, `SETUP_ROOT`, `PDK_TECH_FILE` (or one of the two
alternatives) and `VERIFY_ROOT`. A value without `$` is a literal: to pin
something for a project, write the path in the site file (for example
`"qrc_deck_dir": "/path/to/QCI_deck"`). Expressions accept `$X`, `${X}`,
`$env(X)` and `|parent` (prefer `$X`: the site loader expands `${X}` itself).

**What you choose in the EMIR page**: the **LVS variant** (`(auto)` = `wodio`
when present, else the only one), the **RC corner** (from `extract.corners`,
the Quantus RuleSet names; default `typical`), the **extraction temperature**,
the **QRC deck** when the glob finds several releases, and the **LVS power /
ground names** (prefilled from `extract.power_names` / `ground_names` plus the
DUT ports that look like supplies).

**Resolve / preview** runs automatically when the panel opens, when the DUT
or a choice changes, and on demand. The status line says *ready* (tech name,
rules file, corner, QRC deck) or names what is missing; **Show resolved**
opens the full list with the source of every value. While a variable is
missing, **Extract only** is disabled and **Submit EMIR** refuses (as do
`extract` and `submit` themselves, before they create anything).

Other `extract` keys:

| key | meaning |
|---|---|
| `tools.strmout/si/calibre/qrc` | executables (string, or an argv list) |
| `qrc_ground_net`, `strmout_args`, `cdslib`, `source_view`, `layout_view` | optional |
| `si_options`, `lvs_options`, `qrc_options` | per-key overrides of the built-in recipe |
| `check_files` | `false` skips the existence checks of the resolved files |

The fixed-value keys of relkit 0.1 (`pdk_layer_map`, `calibre_lvs_dir`,
`qrc_query_cmd`, ...) are still honoured, with a warning.

---

## Where files go

| what | where |
|---|---|
| exported netlist | `<artifact_root>/<DUT cell>/<maestro cell>_<test>.scs` (+ `.rewrite.log`: relative includes made absolute) |
| DSPF / GDS | `<artifact_root>/<DUT cell>/<DUT cell>.dspf/.gds` + `<DUT cell>.extract.json` (what they were extracted from), intermediates in `extract/` |
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
* **Cancel** stops relkit's supervisor and `run_relsim` (and a running
  extraction). Jobs already handed to the cluster keep running; kill them
  with your cluster's tools.
* **DSPF/GDS freshness** compares the TOP layout and schematic cellviews only:
  an edit inside a sub-cell is not seen. After such an edit press **Extract
  only** (or change a setting) before Submit EMIR.
* **Cluster job ids** are known when `submit_strategy` is `submit_batch`
  (relkit runs the submit lines and reads `Job <id>` from their output); with
  `start` RelStudio submits itself and the progress window shows no id.
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
7. **Extraction**: open the panel from a Virtuoso started with the PDK
   setup sourced, press **Resolve / preview** and check that every value is
   resolved (**Show resolved**) and matches what Auto_ext uses; then extract
   one DUT and diff the DSPF with Auto_ext's. Submit EMIR on a DUT without
   DSPF/GDS and check that the run extracts first (timeline / **Progress...**),
   then that a second Submit EMIR reports the pair FRESH and skips it.
9. **Donau from job policies**: open the panel from a Maestro whose test uses
   a dsub job policy; check that each page shows `Maestro current (<policy>)`
   with the policy's account / queue / cpu / mem, that the other `.jp`
   policies are listed, and the yml `Cluster` blocks + `Sim_Mt` of an aging and
   an EMIR run (`<run dir>/input/*.yml`); pick another policy for EMIR (e.g. a
   big-memory one) and check its yml. With `submit_strategy: submit_batch`, check that
   the progress window shows the cluster job ids; set `donau_query_cmd` if
   you want their cluster state there.
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
