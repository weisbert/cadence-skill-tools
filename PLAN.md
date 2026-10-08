# Implementation Plan v2 — MyTool Framework + Dreg-gen GUI Refactor

**Status**: Plan locked 2026-04-29; spike verified for B7. Ready for implementation.

## 1. Goal

Two coordinated SKILL deliverables in `workarea/skill_tools/`:

**(A) MyTool framework** at `mytool/` — top-level "MyTool" pulldown menu on every schematic / Maestro / ADE-XL editor window, with a registration API so future plugins (3-5 planned) each contribute one entry without knowing menu plumbing.

**(B) Dreg-gen GUI overhaul** in `dreg_gen/dgenGui.il` + new netlist.oa auto-generation step in `dreg_gen/dgenRun.il`. GUI opens DUT-less; exposes three pickers (manual / select-from-schematic / browse-library); re-renders pin rows on DUT change via close-reopen. After Apply, `amsUpdateTextviews` materializes `data.dm` + `netlist.oa` so Maestro netlists the cell without manual user save.

## 2. Architecture

### 2.1 MyTool framework

Single load entry from `workarea/.cdsinit` (the active startup file because user runs Virtuoso from `workarea/`; `~/.cdsinit` is empty):
```
load("/home/yusheng/cadence_work/Test/workarea/skill_tools/mytool/mytool.il")
```

File layout:
- `mytool/mytool.il` — sources the other three, calls `mtBootstrap()`
- `mytool/mtCore.il` — registry storage + menu construction
- `mytool/mtInstall.il` — `deRegUserTriggers` (registered for completeness) + `hiRegTimer` poll (the real auto-mount mechanism) + load-time window walk
- `mytool/mtUtil.il` — banner-menu-based window classifier (`mt_isAttachable` / `mt_iterAttachable`)

Registry: `mt_registry` is a list of `(label callbackSym statusTip)` triples. Registration order = menu display order.

**In scope** (per spec iteration 2026-04-29): pure schematic editor, Maestro / ADE Assembler, ADE-XL, hybrid Maestro+schematic-config. **Excluded**: CIW, Library Manager, Hierarchy Editor, Layout, output viewers, dockables.

**Classifier** (`mt_isAttachable`): banner-menu-based via `hiGetBannerMenus` (skuiref.pdf p.1107). A window is attachable iff its menu list contains `'schEditMenu`, `'maestroTools`, or any `axl*` symbol. Banner-menu probing is silent — chosen over `geGetWindowCellView` to avoid GE-2067 UserWarnings and to correctly classify the Maestro+config hybrid (which `geGetWindowCellView` mis-tags as schematic).

**Menu mounting**: rightmost-before-Help via `hiInsertBannerMenu` at index `(plus (hiGetNumMenus w) 1)` (skuiref.pdf p.1110 — Cadence renders Help always-last regardless of banner-list index, so this slot is the conventional plugin position). `mt_attachToWindow` de-dups via `memq` on the existing banner-menu list, so re-running is always safe.

**Auto-mount on new opens — `hiRegTimer` poll** (user-confirmed reproduction 2026-04-29: the post-install trigger registers without complaint under IC6.1.8 but does not actually fire on new-window installs; every freshly-opened schematic / Maestro / ADE-XL required manual `mtBootstrap` until the poll was added). `mtBootstrap` arms a `hiRegTimer` chain whose callback `mt_poll` runs `mt_iterAttachable 'mt_attachToWindow` every 2s and re-arms itself (`hiRegTimer` is one-shot per skuiref.pdf p.84 — `x_tenthsofSeconds`, NOT ms; 2s = 20). The arm is idempotent across reloads via the `(and (boundp 'mt_pollArmed) mt_pollArmed)` guard. Each tick wraps `mt_iterAttachable` in `errset` so a transient single-window failure (e.g. window mid-teardown) doesn't kill the chain. The post-install trigger is still registered in `mtBootstrap` for completeness, on the chance that a future IC version honors it.

### 2.2 Public API
```skill
mtRegister(t_label s_callbackFn [t_statusTip])  ; t / nil — adds entry, refreshes menus
mtUnregister(t_label)                            ; t / nil
mtListRegistered()                               ; list of triples (read-only)
mtBootstrap()                                    ; idempotent; auto-called from mytool.il
mtRefresh()                                      ; force rebuild on every attached window
```

### 2.3 Dreg-gen GUI

New signature: `dgenOpenGUI(@optional dutLib dutCell)` — both args optional. Old callers (e.g. `dgenOpenGUI("sim_yusheng" "Test_cell")`) keep working: pre-fill the lib/cell fields and trigger an immediate scan-and-render.

**Top section** (built once, never re-rendered):
- 3 linked combo fields: Lib / Cell / View (via `ddHiCreateLibraryComboField` + `ddHiLinkFields`, skuiref.pdf p.484, p.495)
- 3 buttons: `[Select from Schematic]` `[Browse Library...]` `[Load Pins]`

**Middle/bottom section** (regenerates on DUT change): target rows, DVDD, defaultMode, defaultPattern, per-pin rows. Same widgets/layout as today.

**Bottom buttons**: OK / Cancel / Defaults / Apply (`'OKCancelDefApply` layout, unchanged).

**DUT-change strategy: close-reopen.** When user commits a new DUT, save current state via existing last-state mechanism, call `hiCloseForm`, then re-`dgenOpenGUI(newLib newCell)`. **Do NOT use `hiAddField`/`hiDeleteField`** — historically flaky on IC6.1.8 (the existing dgenGui.il header comment mentions form-construction fragility).

### 2.4 Three picker mechanisms

**Manual**: type into combo fields directly; combo's auto-completion lists libs/cells/views from cds.lib. Click `[Load Pins]` to commit.

**Select from Schematic**: Form stays modeless. User clicks an instance in any open schematic, then clicks `[Select from Schematic]` button. Callback walks `hiGetWindowList('window)`, filters to schematic windows, calls `geGetSelSet(w)` (skdfref.pdf p.183) on each. Reads `inst~>master~>libName` / `inst~>master~>cellName` from the selection; populates form fields; immediately calls render.
- 0 selected anywhere → warn dialog "No instance selected. Click an instance in a schematic, then press the button again."
- >1 selected → use first, warn "Multiple selected — using the first."
- Non-instance selection (wire/pin) → error dialog
- Do **not** use `enterPoint` — historically interferes with modeless form event loop.

**Browse Library**: Click button → opens a small modal sub-form `dgen_dutChooser` with three linked combo fields + OK/Cancel. On OK, copies selection to parent form fields and triggers render. Do **not** use `ddsOpenLibManager` — doesn't return synchronously.

### 2.5 netlist.oa auto-generation (verified by spike 2026-04-29)

Add Step 5 to `dgenRun` after CDF:

```skill
defun( dgen_compileVerilogA (spec)
  let( (lib  spec~>target~>lib
        cell spec~>target~>cell
        oaPath)
    oaPath = strcat( (ddGetObj lib)~>readPath "/" cell "/veriloga/netlist.oa" )
    unless( amsIsPresent()
      warn("amsIsPresent=nil; netlist.oa needs manual save\n")
      return(t))
    errset( amsUpdateTextviews(lib ?cellName cell ?viewName "veriloga" ?incremental t) t )
    if( isFile(oaPath)
      then printf("[dreg-gen] netlist.oa generated\n") t
      else warn("amsUpdateTextviews didn't materialize netlist.oa\n") nil)))
```

`dgenRun` order (existing 3 + new): symbol → veriloga → CDF → **compileVA**.

**Preconditions**:
1. Cell must have symbol view — auto-satisfied by step 1 of `dgenRun` ordering. Add an assertion in code.
2. `amsIsPresent()` must return t — verified on user's IC6.1.8 + TSMC18rf install.

If `amsIsPresent()` returns nil OR `amsUpdateTextviews` fails to produce netlist.oa, **warn but don't abort** — the cell itself is valid; only Maestro netlisting is blocked. User can still manually save via Library Manager as fallback.

Spike-verified call signature (see `project_dreg_gen.md` "Hard-won facts" entry):
```
amsUpdateTextviews("<lib>" ?cellName "<cell>" ?viewName "veriloga" ?incremental t)
```
Effect: silently creates `<lib>/<cell>/veriloga/{data.dm, netlist.oa}` when symbol view exists.

## 3. File changes summary

**New files**:
```
workarea/skill_tools/mytool/mytool.il
workarea/skill_tools/mytool/mtCore.il
workarea/skill_tools/mytool/mtInstall.il
workarea/skill_tools/mytool/mtUtil.il
workarea/skill_tools/mytool/README.md
```

**Modified files**:
```
workarea/skill_tools/dreg_gen/dgenGui.il   # major rewrite: new top section, 3 pickers, close-reopen
workarea/skill_tools/dreg_gen/dgenRun.il   # add dgen_compileVerilogA step
workarea/skill_tools/dreg_gen/dgenStore.il # last-state schema v2 fields
workarea/skill_tools/dreg_gen/README.md    # update public function table + MyTool integration note
workarea/.cdsinit                           # add load() line for mytool (NOT ~/.cdsinit — that file is empty)
```

## 4. Last-state schema migration (v1 → v2)

New fields appended to `~/.skill_tools/dreg_gen.last`:
```
schemaVersion  2
lastDutLib     "sim_yusheng"
lastDutCell    "Test_cell"
lastDutView    "symbol"
```

**Migration policy: silent forward-only.**
- Legacy file (no `schemaVersion`) → treat as v1; Source-Lib/Cell/View fields open empty; rest restored as before. First save writes v2.
- v2 file → all fields restored. Source fields pre-fill but **don't** auto-trigger pin scan (user might be opening for a different DUT).
- Future v3+ → unknown fields ignored; missing fields fall back to factory defaults.

Implementation sits in `dgenStore.il`; the file is already format-agnostic so only field additions needed.

## 5. Implementation phases & checkpoints

### Phase A — MyTool framework

**Status: complete and live-tested 2026-04-29.** Spec drifted from the table below during implementation — see §2.1 for the as-built description (banner-menu classifier instead of cellview; rightmost-before-Help instead of pos 0; schematic+Maestro+ADE-XL instead of CIW+schematic; `workarea/.cdsinit` instead of `~/.cdsinit`; `hiRegTimer` poll added because user-confirmed reproduction showed the post-install trigger does not fire on IC6.1.8 — see §2.1 last paragraph). Original-plan table kept below for reference.

| Step | Work | Checkpoint |
|------|------|-----------|
| A1 | `mtCore.il` skeleton: `mt_registry` global + `mtRegister`/`mtUnregister`/`mtListRegistered`; empty `mt_buildMenu` stub | `load(mtCore.il); mtRegister("test1" 'println); mtListRegistered()` returns 1-element list |
| A2 | `mt_buildMenu` via `hiCreateMenuItem` (skuiref.pdf p.200) + `hiCreatePulldownMenu` (p.204); empty-registry returns disabled placeholder | `mt_buildMenu()` returns non-nil menu struct |
| A3 | `mtUtil.il`: ~~`mt_isCIW(w)` via `hiGetCIWindow`; `mt_isSchematic(w)` via `geGetWindowCellView`+`cellViewType=="schematic"`~~ → as built: banner-menu classifier (`'schEditMenu` / `'maestroTools` / `axl*`), silent on non-graph windows | **As-built check**: with CIW + LM + a schematic + Maestro all open, `mt_iterAttachable` skips CIW/LM and hits the schematic + Maestro. |
| A4 | `mtInstall.il`: `mt_attachToWindow` (de-dups via `hiGetBannerMenus` then `hiInsertBannerMenu` at ~~pos 0~~ → `(plus (hiGetNumMenus w) 1)`); `mt_userPostInstallTrigger`; `mtBootstrap` (idempotent: `deRegUserTriggers` + window walk + `hiRegTimer` poll arm) | `mtBootstrap()`; visually verify MyTool appears rightmost-before-Help on every attached window; CIW/LM untouched; close+reopen a schematic — auto-attaches within 2s |
| A5 | `mytool.il` loader; add `load(...)` line to ~~`~/.cdsinit`~~ → `workarea/.cdsinit` | Full Virtuoso restart; menu auto-appears |

### Phase B — Dreg-gen GUI refactor

| Step | Work | Checkpoint |
|------|------|-----------|
| B1 | `dgenGui.il`: refactor `dgenOpenGUI` to `@optional`; build top section (3 linked combo fields + 3 buttons); skip middle/bottom if no DUT | `dgenOpenGUI()` opens empty form; typing Lib repopulates Cell choices |
| B2 | `dgenGui_loadCB`: read combo values, call new `dgen_renderPinsForDut(form lib cell view)` | Type sim_yusheng/Test_cell/symbol → click Load → 11 pin rows appear |
| B3 | `dgenGui_selSchemCB`: walk schematic windows, `geGetSelSet`, populate fields | Open form; select instance in schematic; click button → fields populate, pins render |
| B4 | `dgenGui_browseCB`: build `dgen_dutChooser` modal sub-form with linked combos + OK/Cancel | Click button → sub-form opens → pick → parent populates |
| B5 | `dgenStore.il`: add v2 fields to `dgen_specToLastState` writer; v1-tolerant reader in `dgen_resolveCurrentSpec` | Apply + close + reopen → Source fields pre-fill from last state |
| B6 | `dgen_renderPinsForDut`: close-reopen rebuild pattern. Saves transient state, calls `hiCloseForm`, re-`dgenOpenGUI(lib cell)` | Change DUT, click Load → form closes/reopens with new pins; target/DVDD/mode/pattern preserved |
| B7 | `dgenRun.il`: add `dgen_compileVerilogA` per §2.5; assert symbol view exists | End-to-end Apply on a fresh test cell → `<lib>/<cell>/veriloga/netlist.oa` exists; Maestro netlists without OSSHNL-381 |

### Phase C — Wire-up & polish

C1. At end of `dgenGui.il`, register with MyTool:
```skill
when( getd('mtRegister)
  mtRegister("Dreg Generator" 'dgenOpenGUI "Open the Dreg-Generator GUI"))
```
**Use `getd`, NOT `functionp`** — `functionp` on a symbol is unreliable.
- Checkpoint: full restart → MyTool → Dreg Generator → form opens → end-to-end works

C2. README updates: `mytool/README.md` (new) + `dreg_gen/README.md` (refreshed signature/MyTool note).

C3. Memory updates: `project_dreg_gen.md` reflects v2 schema + closed netlist.oa issue.

## 6. SKILL gotchas (enforced — verified in dreg-gen development)

See `feedback_skill_gotchas.md` for full list. Critical for this work:

- **No `let*`** — use nested `let` or `let` + `setq` for sequential bindings
- **No `*foo*` identifiers** — parser splits on `*`. Use `mt_foo` / `dgen_foo` (snake_case) for module globals; `mtFoo` / `dgenFoo` (camelCase) for public functions
- **No prefix arithmetic** — `(+ a b)` syntax-errors; use `(plus a b)`, `difference`, `times`, `quotient`, `greaterp`, `lessp`
- **`setq` cannot take `~>` LHS** — use C-style infix `=` (e.g. `form->field->enabled = v`) or `hiSetFieldEnabled`
- **No `defvar`** — use `(unless (boundp 'foo) (setq foo X))` for module globals
- **Type-template chars limited to `t s n l g d f b ?`** — cellviews are `d`, never `t`

For any Cadence API call: grep `~/.claude/skills/virtuoso-skill/assets/function_index.tsv` first, then read the PDF page (5-7 pages around the indexed page). Cite inline as `; Ref: <pdf> p.NNN`.

## 7. Verification artifacts & reference

**Spike test cell**: `sim_yusheng/dreg_spike_1777471020` has working `data.dm` + `netlist.oa` from `amsUpdateTextviews` verification. Useful as ground truth for Phase B7. Can be deleted once B7 lands.

**Skillbridge** (live debug bridge from Bash to running Virtuoso):
- Connect: `/usr/bin/python3 -c "from skillbridge import Workspace; ws = Workspace.open(); ..."`
- Recovery if dies: in CIW run `load("/home/yusheng/cadence_work/Test/workarea/MyRunner/start_skillbridge.il")`. **Never** call bare `pyStartServer()` — system has no `python`, only `python3`
- GUI gotcha: calling `hiCreateAppForm` + `hiDisplayForm` over the bridge BLOCKS the bridge until form closes. For headless tests, skip `hiDisplayForm` (see pattern in `dreg_gen/test_step5_auto.il`)
- Multi-line `evalstring` silently swallows errors → use one-line probes or `load(.il)` files

**Test DUT for B-phase verification**: `sim_yusheng/Test_cell` — 11 pins (6 input, 2 output, 3 power), already wired into a Maestro TB.

## 8. Out of scope

- Step-6 bindkey (Ctrl+Shift+D) — dropped permanently; MyTool menu replaces it
- Step-8 packaging / GitHub push (`weisbert/cadence-skill-tools`) — separate exercise after Phase B verified
- AMS Designer simulator integration — pure-Spectre flow only
- CIW menu integration — dropped 2026-04-29; in-scope editors are schematic + Maestro/ADE-Assembler + ADE-XL + hybrid Maestro+config
- Layout window menu integration — Layout editor remains excluded
- Multi-entry plugins — each gets exactly one MyTool entry; sub-operations via plugin's own internal selector
- GUI for managing MyTool registrations — registration is API-only; introspect via `mtListRegistered`
- "DUT pin auto-update" — when user changes DUT pins after generation, they re-run dgenOpenGUI manually (decision 2026-04-29: not worth the complexity)
