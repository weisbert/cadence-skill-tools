; dgenCDF.il -- Step 4 of Dreg Generator: attach a cell-level base CDF so the
; instance Properties dialog (`q`) shows DVDD + per-pin d_<PIN> input fields
; without the user having to select a view from a dropdown.
;
; CDF FLAVOR. We use cell-level base CDF (cdfCreateBaseCellCDF), not the
; view-level CDF that Cadence's VA-import flow generates. Cell-level applies
; regardless of which view is being used; it's cleaner for single-purpose
; cells like Dreg where symbol + veriloga share the same parameter set.
; Trade-off: if a future variant of this cell needs view-specific params,
; this base CDF will conflict with it -- not a concern for Dreg.

; Build the prompt string shown next to a parameter in the Properties dialog.
; Kept terse on purpose: the prompt is the LEFT-side label of the form row,
; and a verbose label crowds the dialog. For scalars the prompt is just the
; param name "d_<PIN>". For buses we append the <hi:lo> bit range so the
; user knows the input is multi-bit -- otherwise seeing just "d_D" they
; might not realize they can enter integers up to 2^N-1.
(defun dgen_pinPrompt (pin "g")
  (cond
    ((get pin 'isBus)
      (sprintf nil "d_%s<%d:%d>"
        (get pin 'name) (get pin 'busHi) (get pin 'busLo)))
    (t (sprintf nil "d_%s" (get pin 'name)))))

; Substitute every '*' in a pattern with pinName. Returns pattern unchanged
; if no '*' is present. Walks char-by-char rather than using parseString
; (which drops empty tokens around leading/trailing '*' so "*_ls" becomes
; "_ls" instead of "<pin>_ls") or rex (whose patternIndex API is awkward).
; Ref: sklangref.pdf strlen, substring, strcat.
(defun dgen_substStar (pattern pinName "tt")
  (let ((i 0) (n (strlen pattern)) (out "") ch)
    (while (lessp i n)
      (setq ch (substring pattern (add1 i) 1))
      (cond
        ((equal ch "*") (setq out (strcat out pinName)))
        (t              (setq out (strcat out ch))))
      (setq i (add1 i)))
    out))

; Resolve the defValue string for one CDF parameter under the configured
; defaultMode. paramName is "DVDD" or "d_<PIN>"; pinName is the underlying
; DUT pin name (or "DVDD" for the DVDD param). isDVDD is t for DVDD.
; literalDefault is the numeric literal used when mode="literal".
;   "empty"        -> ""
;   "literal"      -> literalDefault
;   "variable"     -> paramName (DVDD, d_EN, d_D, ...)
;   "variable_pin" -> pinName for d_<PIN>; "DVDD" for DVDD
;   "custom"       -> "DVDD" for DVDD; pattern with * replaced by pinName
;                     for d_<PIN>. Errors if pattern is nil under "custom".
;   anything else  -> falls through to literal (back-compat).
(defun dgen_resolveDefValue (mode pattern paramName pinName isDVDD literalDefault "ggttgg")
  (cond
    ((equal mode "empty")        "")
    ((equal mode "variable")     paramName)
    ((equal mode "variable_pin")
      (cond (isDVDD "DVDD") (t pinName)))
    ((equal mode "custom")
      (cond
        (isDVDD "DVDD")
        ((null pattern)
          (error "dgen_resolveDefValue: defaultMode='custom' but spec~>defaultPattern is missing"))
        (t (dgen_substStar pattern pinName))))
    (t literalDefault)))

; Read the v1 default for a pin's drive value. Spec stores it as a string;
; "DVDD"/non-numeric falls back to "0" (the spec doc says v1 expects a
; numeric string).
(defun dgen_pinDefaultStr (pin "g")
  (let ((d (get pin 'default)))
    (cond
      ((null d) "0")
      ((stringp d)
        (cond ((rexMatchp "^-?[0-9]+$" d) d)
              (t "0")))
      ((integerp d) (sprintf nil "%d" d))
      (t "0"))))

; Public entry point.
;   spec       -- plist as produced by step 1 (see README)
;   outputLib  -- string, overrides spec~>target~>lib if non-nil
;   outputCell -- string, overrides spec~>target~>cell if non-nil
;
; defaultMode (read from spec~>defaultMode):
;   "empty"        -- DVDD and all d_<PIN> defValue = "". User must type
;                     a value when adding the instance.
;   "literal"      -- DVDD = spec~>dvddDefault (e.g. "0.9");
;                     d_<PIN> = pin's `default` field (e.g. "0").
;   "variable"     -- DVDD = "DVDD"; d_<PIN> = "d_<PIN>". Cadence treats
;                     these as design-variable references at netlist time.
;                     Caveat: if the variable is undefined upstream, sim
;                     fails with "undefined variable".
;   "variable_pin" -- DVDD = "DVDD"; d_<PIN> = "<PIN>" (no d_ prefix).
;                     Same caveat as "variable". Useful when TB already
;                     uses pin names directly as design variables.
;   "custom"       -- DVDD = "DVDD"; d_<PIN> = spec~>defaultPattern with
;                     '*' replaced by the pin name. E.g. pattern "d_*_ls"
;                     gives d_EN -> "d_EN_ls", d_D -> "d_D_ls".
;                     spec~>defaultPattern is REQUIRED in this mode.
;   missing/unknown -- treated as "literal" for backwards compat.
;
; Side effect: replaces the cell's base CDF with one that exposes
;   - DVDD          : string, default per defaultMode
;   - d_<PIN>       : string, default per defaultMode, one per ENABLED pin
; If a base CDF already exists on the cell, it is deleted first so this
; function is idempotent across regenerations.
; Returns t on success, nil on failure.
;
; Ref: skartistref.pdf p.952 (cdfCreateBaseCellCDF), p.955 (cdfCreateParam),
;      p.963 (cdfSaveCDF), p.964 (cdfDeleteCDF), p.957 (?display/?editable),
;      p.1760 (ddGetObj).
(defun dgenWriteCDF (spec outputLib outputCell "ggg")
  (let (target libName cellName cellId existing cdfId
        modeStr pattern dvddDefVal pinDefVal pinName paramName)
    (setq target (get spec 'target))
    (setq libName  (or outputLib  (get target 'lib)))
    (setq cellName (or outputCell (get target 'cell)))

    ; Resolve defaultMode + optional pattern.
    (setq modeStr (or (get spec 'defaultMode) "literal"))
    (setq pattern (get spec 'defaultPattern))

    (cond
      ((or (null libName) (null cellName))
        (error "dgenWriteCDF: missing target lib/cell (lib=%L cell=%L)"
          libName cellName))
      (t
        (setq cellId (ddGetObj libName cellName))
        (cond
          ((null cellId)
            (error "dgenWriteCDF: cell %s/%s does not exist; create symbol/veriloga first"
              libName cellName))
          (t
            (setq existing (cdfGetBaseCellCDF cellId))
            (when existing (cdfDeleteCDF existing))

            (setq cdfId (cdfCreateBaseCellCDF cellId))
            (unless cdfId (error "dgenWriteCDF: cdfCreateBaseCellCDF returned nil"))

            ; DVDD parameter.
            (setq dvddDefVal
              (dgen_resolveDefValue modeStr pattern "DVDD" "DVDD" t
                (or (get spec 'dvddDefault) "0.9")))
            (cdfCreateParam cdfId
              ?name     "DVDD"
              ?type     "string"
              ?defValue dvddDefVal
              ?prompt   "DVDD"
              ?display  "t"
              ?editable "t")

            ; One d_<PIN> param per enabled pin.
            (foreach p (get spec 'pins)
              (when (get p 'enabled)
                (setq pinName   (get p 'name))
                (setq paramName (sprintf nil "d_%s" pinName))
                (setq pinDefVal
                  (dgen_resolveDefValue modeStr pattern paramName pinName nil
                    (dgen_pinDefaultStr p)))
                (cdfCreateParam cdfId
                  ?name     paramName
                  ?type     "string"
                  ?defValue pinDefVal
                  ?prompt   (dgen_pinPrompt p)
                  ?display  "t"
                  ?editable "t")))

            (cdfSaveCDF cdfId)))))))
