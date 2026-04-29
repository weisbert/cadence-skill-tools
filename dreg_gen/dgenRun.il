; dgenRun.il -- Step 7 of Dreg Generator: end-to-end orchestrator that
; sequences the three generators (symbol -> Verilog-A -> CDF) in the only
; correct order. Each substep already validates its own inputs and prints
; its own diagnostics; this wrapper stays dumb on purpose.
;
; ORDERING NOTE. schPinListToSymbolGen creates 0 terminals when the cell
; already has a veriloga view (see dgenSymbol.il header). Symbol therefore
; MUST come before .va. CDF order is flexible but keeps the natural
; "shape -> behavior -> parameters" reading.
;
; FAIL-FAST. dgenWriteSymbol can silently fail when the cell's symbol view
; is held by an open editor window -- it returns nil after its own
; post-condition check. We abort there rather than letting dgenWriteVerilogA
; happen, because a freshly-written .va alongside a stale/empty symbol is
; harder to recover from than a clean re-run.
;
; No outputLib/outputCell overrides on this layer by design: callers wanting
; a custom destination should set spec~>target accordingly. Keeps the
; orchestrator's surface area as small as possible.

; Public entry point.
;   spec -- plist as produced by step 1 (see README), with target, pins,
;           defaultMode, dvddDefault populated.
; Returns t on success, nil if any of the three substeps fails.
; Side effects: creates symbol/, veriloga/, and CDF on the target cell.
(defun dgenRun (spec "g")
  (cond
    ((null (dgenWriteSymbol spec nil nil))
      (warn "dgenRun: dgenWriteSymbol failed; aborting before .va\n")
      nil)
    ((null (dgenWriteVerilogA spec nil nil))
      (warn "dgenRun: dgenWriteVerilogA failed; aborting before CDF\n")
      nil)
    ((null (dgenWriteCDF spec nil nil))
      (warn "dgenRun: dgenWriteCDF failed\n")
      nil)
    (t t)))
