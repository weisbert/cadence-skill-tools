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
  (let (target lib cell view oaPath)
    (setq target (get spec 'target))
    (setq lib   (get target 'lib))
    (setq cell  (get target 'cell))
    (setq view  (or (get target 'view) dgen_mainView))
    (setq oaPath
      (strcat (ddGetObj lib)~>readPath "/" cell "/" view "/netlist.oa"))
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
            ?viewName view
            ?incremental nil)
          t)
        ; Second engine if the first didn't produce netlist.oa.
        (unless (isFile oaPath)
          (warn "dgen_compileVerilogA: amsUpdateTextviews didn't produce netlist.oa; retrying with vmsUpdateCellViews\n")
          (errset
            (vmsUpdateCellViews
              ?lib   lib
              ?cell  cell
              ?view  view
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
            ?view view)
          t)
        (cond
          ((isFile oaPath)
            (printf "[dreg-gen] netlist.oa generated (%s)\n" view)
            t)
          (t
            (warn "dgen_compileVerilogA: neither amsUpdateTextviews nor vmsUpdateCellViews materialized netlist.oa\n")
            nil))))))

; Deselect every selected instance of lib/cell in every open graphic
; window; returns the windows showing the cellviews concerned.
; Regenerating a dreg while one of its instances is selected (always the
; case when editing via q > [Edit timing...]) left that window drawing the
; instance as a bare dashed box for good -- hiRedraw / geRefresh couldn't
; repair it (verified live on IC6.1.8). Deselected first, the instance
; just needs one redraw after the regeneration (dgenRun schedules it).
; Only windows with a cellview are asked: geGetSelSet on the CIW / ADE /
; waveform windows prints GE-2067.
; Ref: skdfref.pdf geGetSelSet, geDeselectFig; skuiref.pdf hiGetWindowList,
;      hiRedraw.
(defun dgen_deselectInstsOf (lib cell "tt")
  (let (gwins sel cvs)
    (setq gwins (setof w (hiGetWindowList) (car (errset w~>cellView nil))))
    (foreach w gwins
      (setq sel (car (errset (geGetSelSet w) nil)))
      (foreach f sel
        (when (and (equal (car (errset f~>objType nil)) "inst")
                   (equal f~>libName lib) (equal f~>cellName cell))
          (when (errset (geDeselectFig f) nil)
            (unless (memq f~>cellView cvs)
              (setq cvs (cons f~>cellView cvs)))))))
    ; The selection belongs to the cellview, so it shows in (and was
    ; cleared for) every window on that cellview -- return them all.
    (setof w gwins (memq (car (errset w~>cellView nil)) cvs))))

(unless (boundp 'dgen_redrawWins) (setq dgen_redrawWins nil))

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
  (let ((tgt (get spec 'target)) wins ok)
    (when tgt
      (setq wins (car (errset (dgen_deselectInstsOf (get tgt 'lib) (get tgt 'cell)) t))))
    (setq ok (dgen_runSteps spec))
    ; Redraw from a timer: a hiRedraw right here comes too early (labels
    ; of the regenerated instance stayed blank; a later one fixes them).
    (when wins
      (setq dgen_redrawWins wins)
      (hiRegTimer "(dgen_redrawPending)" 3))
    ok))

; Redraw the windows the last dgenRun deselected in. The list is kept
; (replaced by the next dgenRun): the GUI fires this again once its OK
; callback has returned -- a tick that lands while the result dialog is
; up, i.e. still inside that callback, is too early as well.
(defun dgen_redrawPending ()
  (foreach w dgen_redrawWins
    (when (car (errset (windowp w) nil))
      (errset (hiRedraw w) t)))
  t)

; The generation steps proper (see dgenRun).
;
; TIMING VIEWS (dgenStore.il). spec's target 'view says which view is being
; saved: the main view "veriloga" (default) or a timing view such as
; "veriloga_RX". Either way every Verilog-A view of the cell is rebuilt
; from the main spec plus that view's timing, all declaring the union of
; the views' timing variables -- so a pin change in the main view reaches
; the timing views, and the shared CDF fits whichever view is netlisted.
; Views whose text didn't change are not rewritten nor recompiled. The
; symbol is only regenerated when the main view is saved.
(defun dgen_runSteps (spec "g")
  (let (tgt lib cell view main variants specs union changed ok err)
    (setq tgt  (get spec 'target))
    (setq lib  (get tgt 'lib))
    (setq cell (get tgt 'cell))
    (setq view (or (get tgt 'view) dgen_mainView))
    (cond
      ((equal view dgen_mainView)
        (setq main spec)
        (setq variants (dgen_dregViewsOf lib cell)))
      (t
        (setq main (dgen_dregConfigOf lib cell))
        (cond
          ((null main)
            (setq err (sprintf nil "%s/%s has no main view made by the Dreg Generator -- generate it first, then add timing views" lib cell)))
          ((setq err (dgen_viewCompatErr spec main)) nil)
          (t
            (setq main (dgen_plistPut main 'target
                         (list nil 'lib lib 'cell cell 'view dgen_mainView)))
            (setq variants (append
              (setof v (dgen_dregViewsOf lib cell) (nequal (get v 'view) view))
              (list (list nil 'view view 'timing (get spec 'timing)
                                       'timingVars (get spec 'timingVars)))))))))
    (when err (error "dgenRun: %s" err))
    ; Every view's full spec, each declaring the union of timing variables.
    (setq specs (cons main (mapcar (lambda (v) (dgen_viewSpec main v)) variants)))
    (foreach s specs
      (foreach v (dgen_tmUsedVars s)
        (unless (member (get v 'name) union)
          (setq union (append union (list (get v 'name)))))))
    (setq specs (mapcar (lambda (s) (dgen_plistPut s 'viewVars union)) specs))
    ; Any view timed -> every view declares the timing_en switch (shared CDF).
    (when (setof s specs (dgen_tmTimedPairs s))
      (setq specs (mapcar (lambda (s) (dgen_plistPut s 'viewTimed t)) specs)))
    (setq main (car specs))
    (setq ok t)
    (when (and (equal view dgen_mainView) (null (dgenWriteSymbol main nil nil)))
      (warn "dgenRun: dgenWriteSymbol failed; aborting before .va\n")
      (setq ok nil))
    (when ok
      (foreach s specs
        (let ((r (dgenWriteVerilogA s nil nil)) (sv (get (get s 'target) 'view)))
          (cond
            ((null r)
              (warn "dgenRun: dgenWriteVerilogA failed for view %s\n" sv)
              (setq ok nil))
            ; The saved view always recompiles (as before timing views).
            ((or (eq r t) (equal sv view))
              (setq changed (append changed (list s))))))))
    (when ok
      ; Soft: compileVA failure (e.g. no AMS license) doesn't abort.
      ; We still write our base CDF afterward so the user gets the
      ; correct defaults even when netlist.oa is missing. The old CDF is
      ; dropped first so the text-view update has nothing to reconcile
      ; (no modal "CDFParamDeleted" -- see dgen_dropBaseCDF).
      (dgen_dropBaseCDF main)
      (foreach s changed
        (dgen_compileVerilogA s))
      (cond
        ((null (dgenWriteCDF (dgen_plistPut main 'viewNames
                               (mapcar (lambda (v) (get v 'view)) variants))
                             nil nil))
          (warn "dgenRun: dgenWriteCDF failed\n")
          (setq ok nil))
        (t
          ; Embed the full spec (incl. timing table) on the dreg's symbol
          ; view so the GUI can reopen + edit this exact dreg later. Soft:
          ; a failure (e.g. symbol locked by another user) leaves a
          ; working dreg that just can't be re-edited from the GUI.
          ; MUST stay after dgenWriteSymbol -- see dgen_saveConfigProp.
          (when (equal view dgen_mainView)
            (dgen_saveConfigProp spec))
          ; Timing views list (also prunes views deleted by hand). Not
          ; touched for a cell that never had timing views.
          (when (or variants
                    (car (errset (dgenLoadPropFromCell lib cell "symbol" "dgenViews") nil)))
            (errset (dgenSavePropOnCell lib cell "symbol" variants "dgenViews") t)))))
    ok))
