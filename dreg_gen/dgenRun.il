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

; Auto-generates <lib>/<cell>/veriloga/netlist.oa for the freshly-created
; Verilog-A view. Maestro/ADE-XL's OSS netlister wraps Spectre and refuses
; to run without netlist.oa even for pure-Spectre flows (OSSHNL-381).
; Verified spike on 2026-04-29: amsUpdateTextviews materializes both
; data.dm and netlist.oa silently when the symbol view exists.
;
; Returns t when netlist.oa is on disk after the call, nil otherwise. Per
; orchestrator policy, callers treat nil as warn-only, not fail-fast.
;
; Ref: amsskillref.pdf p.18 (amsIsPresent), p.25 (amsUpdateTextviews);
;      skdfref.pdf p.1760 (ddGetObj); sklangref.pdf p.428 (isFile),
;      p.555 (errset).
(defun dgen_compileVerilogA (spec "g")
  (let ((lib  spec~>target~>lib)
        (cell spec~>target~>cell)
        (oaPath nil))
    (setq oaPath
      (strcat (ddGetObj lib)~>readPath "/" cell "/veriloga/netlist.oa"))
    (cond
      ; AMS license absent -- can't auto-compile. User must save manually.
      ((null (amsIsPresent))
        (warn "dgen_compileVerilogA: amsIsPresent=nil; netlist.oa needs manual save\n")
        nil)
      (t
        ; errset wraps amsUpdateTextviews so a license/parser blip in the
        ; AMS module can't take down dgenRun -- the post-condition check
        ; below decides success.
        (errset
          (amsUpdateTextviews lib
            ?cellName cell
            ?viewName "veriloga"
            ?incremental t)
          t)
        (cond
          ((isFile oaPath)
            (printf "[dreg-gen] netlist.oa generated\n")
            t)
          (t
            (warn "dgen_compileVerilogA: amsUpdateTextviews didn't materialize netlist.oa\n")
            nil))))))

; Public entry point.
;   spec -- plist as produced by step 1 (see README), with target, pins,
;           defaultMode, dvddDefault populated.
; Returns t on success, nil if any of the first three substeps fails.
; compileVA failure does NOT cause an overall nil return (see header).
; Side effects: creates symbol/, veriloga/, CDF, and netlist.oa on the
; target cell.
(defun dgenRun (spec "g")
  (cond
    ((null (dgenWriteSymbol spec nil nil))
      (warn "dgenRun: dgenWriteSymbol failed; aborting before .va\n")
      nil)
    ((null (dgenWriteVerilogA spec nil nil))
      (warn "dgenRun: dgenWriteVerilogA failed; aborting before CDF\n")
      nil)
    ((null (dgenWriteCDF spec nil nil))
      (warn "dgenRun: dgenWriteCDF failed; aborting before compileVA\n")
      nil)
    (t
      ; Soft step: warn-only on failure. Cell itself is valid; only
      ; Maestro/ADE-XL netlisting is impacted.
      (dgen_compileVerilogA spec)
      t)))
