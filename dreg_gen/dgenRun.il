; dgenRun.il -- Step 7 of Dreg Generator: end-to-end orchestrator that
; sequences the four generators (symbol -> Verilog-A -> CDF -> compileVA)
; in the only correct order. Each substep already validates its own inputs
; and prints its own diagnostics; this wrapper stays dumb on purpose.
;
; ORDERING NOTE. schPinListToSymbolGen creates 0 terminals when the cell
; already has a veriloga view (see dgenSymbol.il header). Symbol therefore
; MUST come before .va. CDF order is flexible but keeps the natural
; "shape -> behavior -> parameters" reading. compileVA must come last
; because amsUpdateTextviews needs the symbol+veriloga views already on
; disk to materialize netlist.oa.
;
; FAIL-FAST. dgenWriteSymbol can silently fail when the cell's symbol view
; is held by an open editor window -- it returns nil after its own
; post-condition check. We abort there rather than letting dgenWriteVerilogA
; happen, because a freshly-written .va alongside a stale/empty symbol is
; harder to recover from than a clean re-run.
;
; SOFT FAILURE for compileVA. Per spec, if dgen_compileVerilogA fails (no
; AMS license, or amsUpdateTextviews didn't materialize netlist.oa), the
; cell itself is still valid -- only Maestro netlisting is blocked. The
; user can hand-save netlist.oa or re-run with the AMS license enabled.
; So compileVA failure is warn-only and does NOT make dgenRun return nil.
;
; No outputLib/outputCell overrides on this layer by design: callers wanting
; a custom destination should set spec~>target accordingly. Keeps the
; orchestrator's surface area as small as possible.

; Auto-generates the on-disk artifacts that Maestro/ADE-XL's OSS netlister
; needs to consume a freshly-written Verilog-A view. Two distinct
; artifacts, both required, produced by two different SKILL functions:
;
;   1. <lib>/<cell>/veriloga/netlist.oa  (and data.dm)
;      Created by amsUpdateTextviews. Without it: OSSHNL-381 "Missing or
;      corrupt .oa file in cellview".
;
;   2. View-specific simulation data (CDF parameters parsed from the .va).
;      Created by ahdlUpdateViewInfo. Without it: netlist error "The HDL
;      cell-view ... does not have view-specific simulation data. To
;      create the data please open and save the view." Cadence's error
;      message itself names ahdlUpdateViewInfo as the SKILL fix.
;
; SIDE EFFECT TO BE AWARE OF.  Both calls overwrite the cell's BASE CDF
; with parameter defaults derived from the .va literals (e.g. DVDD=0.9,
; d_EN=0). dgenRun must call dgenWriteCDF AFTER this function so our
; variable-mode defaults end up final.
;
; Why ?incremental nil. amsUpdateTextviews defaults to ?incremental t,
; which only regenerates the OA database when the .va file's mtime is
; newer than the existing DB. dgenRun rewrites .va and immediately calls
; this — within sub-second resolution the timestamps can compare equal
; and the regen is silently skipped, leaving a STALE netlist.oa (or none
; if a prior run never produced one). Forcing ?incremental nil makes the
; call always re-translate.
;
; Two-engine fallback for netlist.oa. amsUpdateTextviews and
; vmsUpdateCellViews live in the same AMS Designer SKILL surface but
; exercise different code paths; if the first doesn't materialize
; netlist.oa, try the second before giving up.
;
; Returns t when netlist.oa is on disk after the call, nil otherwise.
; ahdlUpdateViewInfo's success is best-effort — it returns no useful
; signal, so we just call it and hope; netlist.oa presence is the only
; programmatic post-condition we can check here.
;
; Ref: amsskillref.pdf p.18 (amsIsPresent), p.25 (amsUpdateTextviews),
;      p.30 (vmsUpdateCellViews); skartistref.pdf p.600 (ahdlUpdateViewInfo);
;      skdfref.pdf p.1760 (ddGetObj); sklangref.pdf p.428 (isFile),
;      p.555 (errset).
(defun dgen_compileVerilogA (spec "g")
  ; NB: spec is a hand-built plist (list nil 'target ...), NOT a db object
  ; or a "real" DPL. `~>` expands to `getSGq` which silently errors on this
  ; shape; the older form `spec~>target~>lib` blew up at the let binding,
  ; got swallowed by dgenRun's errset, and the function returned early
  ; before ever reaching amsUpdateTextviews. Use explicit `get` like the
  ; other dgenWrite* functions in this project. Keep `~>` only for db
  ; objects (ddGetObj's return below is fine).
  (let (target lib cell oaPath)
    (setq target (get spec 'target))
    (setq lib   (get target 'lib))
    (setq cell  (get target 'cell))
    (setq oaPath
      (strcat (ddGetObj lib)~>readPath "/" cell "/veriloga/netlist.oa"))
    (cond
      ; AMS license absent -- can't auto-compile. User must save manually.
      ((null (amsIsPresent))
        (warn "dgen_compileVerilogA: amsIsPresent=nil; netlist.oa needs manual save\n")
        nil)
      (t
        ; First engine: amsUpdateTextviews. errset so a license/parser
        ; blip in the AMS module can't take down dgenRun -- the
        ; post-condition check below decides success.
        (errset
          (amsUpdateTextviews lib
            ?cellName cell
            ?viewName "veriloga"
            ?incremental nil)
          t)
        ; Second engine if the first didn't produce netlist.oa.
        (unless (isFile oaPath)
          (warn "dgen_compileVerilogA: amsUpdateTextviews didn't produce netlist.oa; retrying with vmsUpdateCellViews\n")
          (errset
            (vmsUpdateCellViews
              ?lib   lib
              ?cell  cell
              ?view  "veriloga"
              ?viewt "text.veriloga")
            t))
        ; Independent step: parse the .va and create view-specific
        ; simulation data. Without this, the OSS netlister fails with
        ; "does not have view-specific simulation data" even when
        ; netlist.oa is present. Cadence's own error message names this
        ; SKILL function as the fix.
        (errset
          (ahdlUpdateViewInfo lib
            ?cell cell
            ?view "veriloga")
          t)
        (cond
          ((isFile oaPath)
            (printf "[dreg-gen] netlist.oa generated\n")
            t)
          (t
            (warn "dgen_compileVerilogA: neither amsUpdateTextviews nor vmsUpdateCellViews materialized netlist.oa\n")
            nil))))))

; Public entry point.
;   spec -- plist as produced by step 1 (see README), with target, pins,
;           defaultMode, dvddDefault populated.
; Returns t on success, nil if any of the required substeps fails.
; Side effects: creates symbol/, veriloga/, netlist.oa, and CDF on the
; target cell.
;
; ORDERING NOTE 2 (2026-05-08).  amsUpdateTextviews rewrites the cell's
; BASE CDF as a side effect (verified via skillbridge sequence probe):
; it derives parameter defaults from the .va's `parameter integer d_X = 0`
; declarations, clobbering whatever variable-mode defaults dgenWriteCDF
; just installed AND re-adding entries for pins the user disabled.
; Therefore dgenWriteCDF MUST run AFTER dgen_compileVerilogA, not before.
; compileVA stays soft-fail (no AMS license is non-fatal — the cell is
; still valid, only Maestro netlisting is blocked) but its CDF side
; effect makes the order non-negotiable.
(defun dgenRun (spec "g")
  (cond
    ((null (dgenWriteSymbol spec nil nil))
      (warn "dgenRun: dgenWriteSymbol failed; aborting before .va\n")
      nil)
    ((null (dgenWriteVerilogA spec nil nil))
      (warn "dgenRun: dgenWriteVerilogA failed; aborting before compileVA\n")
      nil)
    (t
      ; Soft: compileVA failure (e.g. no AMS license) doesn't abort.
      ; We still write our base CDF afterward so the user gets the
      ; correct defaults even when netlist.oa is missing.
      (dgen_compileVerilogA spec)
      (cond
        ((null (dgenWriteCDF spec nil nil))
          (warn "dgenRun: dgenWriteCDF failed\n")
          nil)
        (t t)))))
