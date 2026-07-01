# note-helper — JOURNAL (session history, newest first)

**Append-only archive, out of the resume-here hot path.** Read `HANDOFF.md` for current state,
`REQUIREMENTS.md` for design + API citations. Older session narratives live here so they stop
piling up at the top of HANDOFF. Append new closes at the TOP.

---

## SESSION 2026-06-21 — M5-UX: live drag-ghost placement + Table/SVG tabs + file Browse

**M5-UX: live drag-ghost placement + Table/SVG tabs + file Browse — committed
& pushed to `main` (`39433e6`).** This session reworked the GUI/placement after
the user hit four issues testing the form live. All fixes verified
non-interactively via skillbridge, AND the **interactive drag-ghost +
click-to-drop is user-confirmed working live (2026-06-21)** for all Output
modes (loose flatten / symbol / resizable). All four issues closed.

Four issues → fixes:
1. **"click in schematic does nothing"** — `enterPoint` started SYNCHRONOUSLY
   from a form button callback never arms. Now the callback only ARMS (stash
   `nh_pl*` globals) and DEFERS the launch to `hiRegTimer("nh_launchPlace()" 1)`;
   the timer makes the schematic window current (`hiSetCurrentWindow` of the
   window from `hiGetWindowList` matching `w~>cellView`) then runs the command.
2. **no cursor preview** — `enterPoint` draws nothing. Replaced with
   `schHiCreateInst(?libraryName ?cellName ?viewName "symbol")` = native ghost
   that drags with the cursor, one click drops. Used for ALL three Output modes.
   Loose mode: build a throwaway temp note-symbol, drag-drop it, then
   `dbFlattenInst(inst 1 nil)` the dropped instance into LOOSE note shapes and
   delete the temp cell (poll via self-re-registering `hiRegTimer` since
   schHiCreateInst has no done callback; flattened shapes stay non-electrical on
   `("text" "drawing")`). symbol/resizable leave the instance.
3. **no Table/SVG separation + no field show/hide** — top `hiCreateTabField`
   with **Table** / **SVG** pages; shared styling+Output below. Output cyclic
   `?callback 'nh_guiOnMode` → `nh_guiSyncFields` greys out Symbol library/cell
   via `hiSetFieldEnabled` unless a symbol mode.
4. follow-ups: added a **Symbol library** field (blank = schematic's lib;
   cross-lib place is fine); fixed the SVG width field sliver (promptWidth was ≥
   field width); made **SVG file + Table file** fields `hiCreateFileSelectorField`
   with a **Browse** button defaulting to `$WORK_ROOT2` (the workarea), absolute
   path returned (`hiSimplifyFilename=t`).

**Two new gotchas (now in auto-memory — [[reference_skill_tabfield_access]],
[[reference_skill_interactive_defer]]):**
- **Fields inside a tab page are NOT reachable as `form->name`** (returns nil!).
  The GUI stashes the four tab-page handles in globals (`nh_fInput`, `nh_fMdPath`,
  `nh_fSvg`, `nh_fVecW`) and callbacks read/write them directly (`handle->value`,
  or `nh_setHandleVal` for writes). Shared (non-tab) fields still use `form->name`.
- **`hiCreateAppForm` can't replace a MAPPED same-name form** — after a reload,
  the user must CLOSE the open Note Helper window before reopening to get the new
  layout. `nhOpenGUI` was split into `nh_guiBuild` (build+instantiate, returns
  form, no display — used for headless skillbridge verify) + `nhOpenGUI`
  (build + `hiDisplayForm`).

Test fixtures (NOT committed, untracked): `naoda.jpg` (Kobe photo the user
dropped in) + `naoda.svg` (traced with `img2svg --mode threshold --levels 5
--rmbg`; parses to 100 note shapes). **README + REQUIREMENTS updated** for the
tabs/ghost/Browse rework (REQUIREMENTS §6/§7/§8 carry dated supersede notes;
original spec kept as design history).

---

## SESSION 2026-06-20 — M4 + img2svg + toolbox + Markdown file I/O

**M4 + img2svg + toolbox + Markdown file I/O — DONE, live-verified, committed &
pushed to `main`.** This batch added: SVG vector import (Feature A); the
`img2svg` raster→SVG tracer (with `--levels` detail + `--rmbg`); the `toolbox`
unified Tkinter GUI (Image→SVG + Table→Markdown tabs); and symmetric Markdown
file import/export on BOTH sides (Python `Open file`/`Save .md` + tsv2md
`--in/--out`; SKILL form `Load file`/`Save .md` via `nh_readFile`/`nh_writeFile`
/`nhTextToMarkdown`). Prior committed work: M3b `f2bbd38`. Repo convention =
direct to main. Next up: **M5** (Excel) / DXF input.

**Env (done this batch, permanent):** `sudo dnf install python3.11-tkinter`
gave `/usr/bin/python3` (3.11, has PIL/numpy) a working tkinter; `Xvfb`
installed for headless GUI verification. See [[reference_python_tkinter_env]].
