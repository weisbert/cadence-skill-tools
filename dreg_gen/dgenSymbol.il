; dgenSymbol.il -- Step 3 of Dreg Generator: build a symbol view for a Dreg cell
; using Cadence's built-in schPinListToSymbolGen. Every Dreg pin is an output
; (driven by the .va), so all pins land on the right edge by Cadence's default
; auto-placement -- which keeps symbol style consistent with each project's
; environment defaults.
;
; ORDERING NOTE. schPinListToSymbolGen creates terminal records ONLY when the
; cell has no other view. If you write the .va first, the function still draws
; pin shapes but registers 0 terminals -- the symbol becomes graphically right
; but functionally inert. Therefore the orchestrator (step 7) MUST call
; dgenWriteSymbol BEFORE dgenWriteVerilogA.

; Build the pinList expected by schPinListToSymbolGen from our spec.
; Format documented in skcompref.pdf p.336-338. Disembodied plist with
; symbol keys (NOT strings); we use 'ports / 'name / 'direction.
;
; Iterates dgen_specEmitList (dgenStore.il) so the symbol picks up BOTH
; auto-discovered pins (filtered to enabled) AND user-added customVars
; (digital + analog) in one pass. Every Dreg pin -- including analog
; customVars driving a fixed voltage -- is direction "output", because the
; cell is a source of stimulus, not a sink.
(defun dgen_specToPinList (spec "g")
  (let (terms)
    (foreach item (dgen_specEmitList spec)
      (setq terms
        (cons
          (list nil 'name (dgen_emitTermName item) 'direction "output")
          terms)))
    (list nil 'ports (reverse terms))))

; Public entry point.
;   spec       -- plist as produced by step 1 (see README)
;   outputLib  -- string, overrides spec~>target~>lib if non-nil
;   outputCell -- string, overrides spec~>target~>cell if non-nil
; Side effect: creates <outputLib>/<outputCell>/symbol/{master.tag,symbol.oa,
;              thumbnail_128x128.png} via Cadence's standard symbol generator.
; Returns t on success, nil on failure.
;
; Post-condition check: schPinListToSymbolGen returns t even when its on-disk
; write was blocked (e.g., user had the cell's symbol view open in a Virtuoso
; editor window, holding a write lock). After the call we re-resolve the cell
; via ddGetObj and verify the symbol view exists with at least one terminal.
; If not, return nil so the orchestrator stops before writing the .va.
;
; Ref: skcompref.pdf p.337 (schPinListToSymbolGen), p.1760 (ddGetObj),
;      skdfref.pdf p.900 (dbOpenCellViewByType), p.873 (dbClose).
;
; Mode restore. When the symbol is ALREADY open read-only -- left open by
; the previous generation's compile step, or as the master of an open
; testbench -- schPinListToSymbolGen upgrades that shared handle to "a"
; and leaves it there (verified live 2026-10-06), so the dreg would stay
; write-locked for the rest of the session. Re-editing a dreg makes
; regenerating it in the same session routine, so put the mode back.
; Ref: skdfref.pdf p.881 (dbFindOpenCellView), p.917 (dbReopen).
(defun dgenWriteSymbol (spec outputLib outputCell "ggg")
  (let (target libName cellName pinList ok cv terms libObj prior priorMode)
    (setq target (get spec 'target))
    (setq libName  (or outputLib  (get target 'lib)))
    (setq cellName (or outputCell (get target 'cell)))
    (cond
      ((or (null libName) (null cellName))
        (error "dgenWriteSymbol: missing target lib/cell (lib=%L cell=%L)"
          libName cellName))
      (t
        (setq pinList (dgen_specToPinList spec))
        (setq libObj (ddGetObj libName))
        (setq prior (and libObj (dbFindOpenCellView libObj cellName "symbol")))
        (setq priorMode (and prior prior~>mode))
        (setq ok (schPinListToSymbolGen libName cellName "symbol" pinList))
        (when (and priorMode (dbValidP prior)
                   (nequal prior~>mode priorMode)
                   (null prior~>modifiedButNotSaved))
          (errset (dbReopen prior priorMode) t))
        (cond
          ((null ok) nil)
          (t
            ; Verify symbol actually got terminals (write lock detection).
            (setq cv (dbOpenCellViewByType libName cellName "symbol" nil "r"))
            (cond
              ((null cv)
                (warn "dgenWriteSymbol: schPinListToSymbolGen reported success but symbol view %s/%s is unreadable -- likely a write-lock from an open editor window"
                  libName cellName)
                nil)
              (t
                (setq terms cv~>terminals)
                (dbClose cv)
                (cond
                  ((null terms)
                    (warn "dgenWriteSymbol: schPinListToSymbolGen reported success but symbol view %s/%s has 0 terminals -- likely a write-lock from an open editor window"
                      libName cellName)
                    nil)
                  (t t))))))))))
