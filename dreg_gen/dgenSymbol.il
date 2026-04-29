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

; Reconstruct the externally-visible terminal name for a pin. Bus pins keep
; Cadence's <hi:lo> syntax in the name; scalar pins are bare.
(defun dgen_pinTerminalName (pin "g")
  (let ((nm (get pin 'name)))
    (cond
      ((get pin 'isBus)
        (sprintf nil "%s<%d:%d>" nm (get pin 'busHi) (get pin 'busLo)))
      (t nm))))

; Build the pinList expected by schPinListToSymbolGen from our spec.
; Format documented in skcompref.pdf p.336-338. Disembodied plist with
; symbol keys (NOT strings); we use 'ports / 'name / 'direction.
; Disabled pins are skipped entirely. Every Dreg pin is direction "output".
(defun dgen_specToPinList (spec "g")
  (let (terms)
    (foreach p (get spec 'pins)
      (when (get p 'enabled)
        (setq terms
          (cons
            (list nil 'name (dgen_pinTerminalName p) 'direction "output")
            terms))))
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
(defun dgenWriteSymbol (spec outputLib outputCell "ggg")
  (let (target libName cellName pinList ok cv terms)
    (setq target (get spec 'target))
    (setq libName  (or outputLib  (get target 'lib)))
    (setq cellName (or outputCell (get target 'cell)))
    (cond
      ((or (null libName) (null cellName))
        (error "dgenWriteSymbol: missing target lib/cell (lib=%L cell=%L)"
          libName cellName))
      (t
        (setq pinList (dgen_specToPinList spec))
        (setq ok (schPinListToSymbolGen libName cellName "symbol" pinList))
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
