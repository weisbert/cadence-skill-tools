; dgenGui.il -- Step 5 of Dreg Generator: modeless GUI dialog that lets the
; engineer pick which DUT pins become Dreg parameters and edit defaults
; (target lib/cell, DVDD, defaultMode/Pattern, per-pin enable + default).
;
; Public entry point: dgenOpenGUI(dutLib dutCell)
;   1. dgenScanPins on the source -> list of pin plists
;   2. resolve factory + last-state into a "currentSpec" (factory drives
;      Defaults-button restore via ?defValue; current drives initial
;      display via ?value -- pins matched by name, so a different DUT
;      just falls back to factory defaults)
;   3. build a one-column form (source RO, target editable, defaults, then
;      one row per pin: enable boolean-button + default string)
;   4. hiCreateAppForm + hiDisplayForm; modeless
;
; Buttons (?buttonLayout 'OKCancelDefApply):
;   OK / Apply -> dgenGui_okCB: read fields -> dgenRun -> save last-state
;                 -> hiDisplayAppDBox with success or failure line.
;   Cancel     -> dgenGui_cancelCB: no-op (form auto-closes).
;   Defaults   -> Cadence restores each field's ?defValue (= factory
;                 defaults baked into dgen_buildFields). Last-state is
;                 only applied at GUI-open time, NOT on Defaults click.
;
; Form symbol is the fixed 'dgen_form. Re-opening rebuilds via hiCreateAppForm.

; ---------------------------------------------------------------------------
; Private helpers
; ---------------------------------------------------------------------------

; Power rails (inputOutput) and outputs default disabled; only true inputs
; are factory-enabled. Rationale: VDD/VSS/VPP rarely want a digital driver,
; and outputs are sourced by the DUT itself.
(defun dgen_factoryEnabledP (pin "g")
  (equal (get pin 'srcDirection) "input"))

; Mirror of dgen_pinTerminalName from dgenSymbol.il -- duplicated locally
; per the brief (avoid cross-file refactor for a 4-line helper).
(defun dgen_pinDisplayName (pin "g")
  (let ((nm (get pin 'name)))
    (cond
      ((get pin 'isBus)
        (sprintf nil "%s<%d:%d>" nm (get pin 'busHi) (get pin 'busLo)))
      (t nm))))

; Per-pin field ids. Keep them stable so dgen_readForm can index by pin
; index without parsing names. Index is 0-based.
(defun dgen_pinEnableId (idx "n")
  (concat 'dgen_pin_en_ idx))

(defun dgen_pinDefaultId (idx "n")
  (concat 'dgen_pin_def_ idx))

; Resolve a "current" spec by overlaying lastState onto factorySpec. The
; resolved spec drives ?value of each field; factorySpec drives ?defValue
; (= what the Defaults button restores). Pin overlay is by-name: lastState
; pinStates is a list of ("PIN_NAME" enabled defaultStr) tuples; a pin is
; matched only when its name appears in pinStates. Pins absent from
; lastState retain factory values; saved entries for pins not in the
; current scan are silently dropped.
;
; targetCellTpl: pattern with optional "*" placeholder for the DUT cell
; name. Default factory tpl is "dreg_*". This is the only field where the
; saved value isn't applied verbatim -- we substitute the current DUT.
(defun dgen_resolveCurrentSpec (factorySpec lastState dutCell "ggt")
  (let (src tgt curPins tpl tplApplied factoryPins pinStates match)
    (setq src (get factorySpec 'source))
    (setq tgt (get factorySpec 'target))
    (setq factoryPins (get factorySpec 'pins))
    (cond
      ((null lastState)
        ; No last-state -- current spec equals factory spec.
        factorySpec)
      (t
        ; Top-level overlay.
        (setq tpl (or (get lastState 'targetCellTpl) "dreg_*"))
        (cond
          ((rexMatchp "\\*" tpl)
            (rexCompile "\\*")
            (setq tplApplied (rexReplace tpl dutCell 0)))
          (t (setq tplApplied tpl)))
        ; Per-pin overlay (by name).
        (setq pinStates (get lastState 'pinStates))
        (setq curPins
          (mapcar
            (lambda (p)
              (setq match nil)
              (foreach tup pinStates
                (when (and (null match) (equal (car tup) (get p 'name)))
                  (setq match tup)))
              (cond
                (match
                  (append p (list 'enabled  (cadr  match)
                                  'default  (caddr match))))
                (t
                  (append p (list 'enabled (dgen_factoryEnabledP p)
                                  'default "0")))))
            factoryPins))
        (list nil
          'source       src
          'target       (list nil
                          'lib  (or (get lastState 'targetLib) (get tgt 'lib))
                          'cell tplApplied
                          'view (get tgt 'view))
          'dvddDefault    (or (get lastState 'dvddDefault)    (get factorySpec 'dvddDefault))
          'defaultMode    (or (get lastState 'defaultMode)    (get factorySpec 'defaultMode))
          'defaultPattern (or (get lastState 'defaultPattern) (get factorySpec 'defaultPattern))
          'pins           curPins)))))

; Helper to read a (key value) pair from spec-pin-list at given pin name.
; Returns the value, or fallback if pin or key missing.
(defun dgen_pinFieldOr (pins pinName key fallback "ltsg")
  (let (found val)
    (foreach p pins
      (when (and (null found) (equal (get p 'name) pinName))
        (setq found p)))
    (cond
      (found
        (setq val (get found key))
        (cond ((null val) fallback) (t val)))
      (t fallback))))

; Build the l_fieldEntries list passed to hiCreateAppForm via ?fields.
; Each entry is a 4-tuple (fieldStruct origin:point size:point labelOffset).
; Empirically verified on IC6.1.8: the shorter (sym pos size labelOff) tuple
; works while the longer (list-with-prompt-pair, struct) form is rejected
; with "not all fields have 2D attributes specified".
;
; factorySpec drives ?defValue (Defaults button restores to these);
; currentSpec drives ?value (initial display, after last-state overlay).
;
; Layout grid: every row is 25px tall, fields 240px wide, label slot 130px.
; Per-pin rows: enable boolean (left, 200x25) + default string (right, 160x25).
;
; NOTE on widget choice: per-pin enable uses hiCreateBooleanButton
; (single checkbox with t/nil), NOT hiCreateToggleField (which is the
; older multi-choice toggle group whose ?defValue must be a list of
; booleans matching ?choices). Empirically verified on IC6.1.8.
;
; Ref: skuiref.pdf p.502 (hiCreateAppForm), p.650 (hiCreateStringField),
;      p.521 (hiCreateBooleanButton), p.536 (hiCreateCyclicField).
(defun dgen_buildFields (factorySpec currentSpec "gg")
  (let (fSrc fTgt cTgt pins cPins fields i y rowH fieldW promptW
        sizePt)
    (setq fSrc (get factorySpec 'source))
    (setq fTgt (get factorySpec 'target))
    (setq cTgt (get currentSpec 'target))
    (setq pins  (get factorySpec 'pins))
    (setq cPins (get currentSpec 'pins))
    (setq rowH 25)
    (setq fieldW 240)
    (setq promptW 130)
    (setq fields nil)
    (setq y 0)
    (setq sizePt (list fieldW rowH))
    ; Source rows (read-only). Factory == current for these (DUT identity
    ; is fixed at GUI-open time and not editable).
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgen_srcLib  ?prompt "Source Lib"
              ?defValue (or (get fSrc 'lib) "")
              ?value    (or (get fSrc 'lib) "")
              ?editable nil)
            (list 0 y) sizePt promptW)
      fields))
    (setq y (plus y rowH))
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgen_srcCell ?prompt "Source Cell"
              ?defValue (or (get fSrc 'cell) "")
              ?value    (or (get fSrc 'cell) "")
              ?editable nil)
            (list 0 y) sizePt promptW)
      fields))
    (setq y (plus y rowH))
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgen_srcView ?prompt "Source View"
              ?defValue (or (get fSrc 'view) "symbol")
              ?value    (or (get fSrc 'view) "symbol")
              ?editable nil)
            (list 0 y) sizePt promptW)
      fields))
    (setq y (plus y rowH))
    ; Target rows (editable).
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgen_tgtLib ?prompt "Target Lib"
              ?defValue (or (get fTgt 'lib) "")
              ?value    (or (get cTgt 'lib) ""))
            (list 0 y) sizePt promptW)
      fields))
    (setq y (plus y rowH))
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgen_tgtCell ?prompt "Target Cell"
              ?defValue (or (get fTgt 'cell) "")
              ?value    (or (get cTgt 'cell) ""))
            (list 0 y) sizePt promptW)
      fields))
    (setq y (plus y rowH))
    ; Defaults section.
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgen_dvdd ?prompt "DVDD default"
              ?defValue (or (get factorySpec 'dvddDefault) "0.9")
              ?value    (or (get currentSpec 'dvddDefault) "0.9"))
            (list 0 y) sizePt promptW)
      fields))
    (setq y (plus y rowH))
    (setq fields (cons
      (list (hiCreateCyclicField ?name 'dgen_mode ?prompt "defaultMode"
              ?choices  '("literal" "empty" "variable" "variable_pin" "custom")
              ?defValue (or (get factorySpec 'defaultMode) "literal")
              ?value    (or (get currentSpec 'defaultMode) "literal")
              ?callback 'dgenGui_modeCB)
            (list 0 y) sizePt promptW)
      fields))
    (setq y (plus y rowH))
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgen_pattern ?prompt "defaultPattern"
              ?defValue (or (get factorySpec 'defaultPattern) "*_ls")
              ?value    (or (get currentSpec 'defaultPattern) "*_ls"))
            (list 0 y) sizePt promptW)
      fields))
    (setq y (plus y rowH))
    ; Per-pin rows: enable boolean (with pin name as button text) +
    ; default string. Factory ?defValue from heuristics; ?value from
    ; currentSpec (which already has last-state merged in). Default-string
    ; fields are only meaningful under defaultMode="literal" (other modes
    ; derive the CDF defValue from the pin name); they get greyed out at
    ; build time and toggled live by dgenGui_modeCB.
    (let ((litMode (equal (or (get currentSpec 'defaultMode) "literal") "literal")))
      (setq i 0)
      (foreach p pins
        (let ((enId (dgen_pinEnableId i))
              (defId (dgen_pinDefaultId i))
              (display (dgen_pinDisplayName p))
              (factoryEn (dgen_factoryEnabledP p))
              (curEn  (dgen_pinFieldOr cPins (get p 'name) 'enabled (dgen_factoryEnabledP p)))
              (curDef (dgen_pinFieldOr cPins (get p 'name) 'default "0")))
          (setq fields (cons
            (list (hiCreateBooleanButton
                    ?name enId
                    ?buttonText display
                    ?defValue factoryEn
                    ?value    curEn)
                  (list 0 y) (list 200 rowH) 0)
            fields))
          (setq fields (cons
            (list (hiCreateStringField
                    ?name defId
                    ?prompt "value"
                    ?defValue "0"
                    ?value    curDef
                    ?enabled  litMode)
                  (list 210 y) (list 160 rowH) 50)
            fields))
          (setq y (plus y rowH)))
        (setq i (add1 i))))
    (reverse fields)))

; Dynamic field-value reader. The form->fieldName->value chain only parses
; with a literal symbol at parse time, so for runtime ids (per-pin fields
; keyed by index) we route through (get form fieldSym) -- which works on
; form structs because SKILL exposes named field slots through `get`.
(defun dgen_fieldVal (form fieldSym "gs")
  (let ((rec (get form fieldSym)))
    (and rec rec->value)))

; Read all fields back into a fully-built spec plist suitable for dgenRun.
; pins is the original scan list (in scan order, same indexing used at
; build time).
(defun dgen_readForm (form pins "gl")
  (let (srcLib srcCell srcView tgtLib tgtCell dvdd mode pattern outPins i pin enabled deflt)
    (setq srcLib   (dgen_fieldVal form 'dgen_srcLib))
    (setq srcCell  (dgen_fieldVal form 'dgen_srcCell))
    (setq srcView  (dgen_fieldVal form 'dgen_srcView))
    (setq tgtLib   (dgen_fieldVal form 'dgen_tgtLib))
    (setq tgtCell  (dgen_fieldVal form 'dgen_tgtCell))
    (setq dvdd     (dgen_fieldVal form 'dgen_dvdd))
    (setq mode     (dgen_fieldVal form 'dgen_mode))
    (setq pattern  (dgen_fieldVal form 'dgen_pattern))
    (setq outPins nil)
    (setq i 0)
    (foreach pin pins
      (setq enabled (dgen_fieldVal form (dgen_pinEnableId i)))
      (setq deflt   (dgen_fieldVal form (dgen_pinDefaultId i)))
      (setq outPins (cons
        (append pin (list 'enabled enabled 'default deflt))
        outPins))
      (setq i (add1 i)))
    (list nil
      'source       (list nil 'lib srcLib 'cell srcCell 'view srcView)
      'target       (list nil 'lib tgtLib 'cell tgtCell 'view "veriloga")
      'dvddDefault  dvdd
      'defaultMode  mode
      'defaultPattern pattern
      'pins         (reverse outPins))))

; Build a last-state plist from current spec + form. The targetCellTpl
; reverses the DUT-cell substitution: if tgtCell starts with "dreg_" + dutCell,
; collapse to "dreg_*"; otherwise save literally.
(defun dgen_specToLastState (spec dutCell "gt")
  (let (tgt tgtCell tpl pinStates)
    (setq tgt (get spec 'target))
    (setq tgtCell (get tgt 'cell))
    (cond
      ((and tgtCell dutCell
            (progn
              (rexCompile (strcat "^\\(.*\\)" dutCell "\\(.*\\)$"))
              (rexExecute tgtCell)))
        (setq tpl (strcat (rexSubstitute "\\1") "*" (rexSubstitute "\\2"))))
      (t (setq tpl (or tgtCell ""))))
    (foreach p (get spec 'pins)
      (setq pinStates (cons
        (list (get p 'name) (get p 'enabled) (or (get p 'default) "0"))
        pinStates)))
    (list nil
      'targetLib       (get tgt 'lib)
      'targetCellTpl   tpl
      'dvddDefault     (get spec 'dvddDefault)
      'defaultMode     (get spec 'defaultMode)
      'defaultPattern  (get spec 'defaultPattern)
      'pinStates       (reverse pinStates))))

; Module-scope storage: pin list captured at GUI-open time. Callbacks
; receive only the form, so they re-read this to know how many pin rows
; exist and what each pin's metadata is. Reset on every dgenOpenGUI call.
(unless (boundp 'dgen_currentPins) (setq dgen_currentPins nil))
(unless (boundp 'dgen_currentDutCell) (setq dgen_currentDutCell nil))

; ---------------------------------------------------------------------------
; Callbacks
; ---------------------------------------------------------------------------

; OK / Apply callback. Reads fields, runs the orchestrator, saves last-state,
; and pops a result dialog. Returns t/nil but Cadence ignores it.
;
; Ref: skuiref.pdf p.309 (hiDisplayAppDBox).
(defun dgenGui_okCB (form "g")
  (let (spec ok msg)
    (setq spec (dgen_readForm form dgen_currentPins))
    (setq ok (errset (dgenRun spec) t))
    (cond
      ((and ok (car ok))
        ; Save last-state on success.
        (errset (dgenSaveLastState (dgen_specToLastState spec dgen_currentDutCell)) t)
        (setq msg (sprintf nil "Generated %s/%s successfully."
          (get (get spec 'target) 'lib)
          (get (get spec 'target) 'cell)))
        (hiDisplayAppDBox
          ?name 'dgen_resultDBox
          ?dboxBanner "Dreg Generator"
          ?dboxText msg
          ?dialogType hicInformationDialog
          ?buttonLayout 'Close)
        t)
      (t
        (setq msg (sprintf nil "Failed to generate %s/%s. See CIW for details."
          (get (get spec 'target) 'lib)
          (get (get spec 'target) 'cell)))
        (hiDisplayAppDBox
          ?name 'dgen_resultDBox
          ?dboxBanner "Dreg Generator"
          ?dboxText msg
          ?dialogType hicWarningDialog
          ?buttonLayout 'Close)
        nil))))

; Cancel callback. Form auto-closes; nothing else to do.
(defun dgenGui_cancelCB (form "g")
  t)

; defaultMode-change callback. Per-pin "value" text fields are only used
; when mode = "literal" (other modes derive the CDF defValue from the
; pin name). Disable those fields visually so the user sees they're
; inert under the chosen mode. Cyclic-field symbol callback signature
; is (field scope item) per skuiref.pdf p.538. We use hiSetFieldEnabled
; (p.806) rather than slot assignment because Lisp-form `(setq rec->enabled v)`
; is rejected (setq's first arg must be a symbol -- the C-style infix
; `rec->enabled = v` is the only assignment shape SKILL accepts here).
(defun dgenGui_modeCB (field scope item "ggg")
  (let ((isLit (equal item "literal")) i rec)
    (setq i 0)
    (foreach p dgen_currentPins
      (setq rec (get dgen_form (dgen_pinDefaultId i)))
      (when rec (hiSetFieldEnabled rec isLit))
      (setq i (add1 i)))
    t))

; ---------------------------------------------------------------------------
; Public entry point
; ---------------------------------------------------------------------------

; Open a modeless Dreg-Generator form for the given DUT.
;   dutLib  -- string, source library name
;   dutCell -- string, source cell name (view always "symbol")
; Returns the form symbol on success, nil if the pin scan fails.
;
; Ref: skuiref.pdf p.502 (hiCreateAppForm), p.688 (hiDisplayForm).
(defun dgenOpenGUI (dutLib dutCell "tt")
  (let (pins factorySpec lastState currentSpec fields)
    (setq pins (dgenScanPins dutLib dutCell "symbol"))
    (cond
      ((null pins)
        (warn "dgenOpenGUI: no pins scanned for %s/%s\n" dutLib dutCell)
        nil)
      (t
        (setq dgen_currentPins pins)
        (setq dgen_currentDutCell dutCell)
        ; factorySpec defines what Defaults restores to. Per-pin enable
        ; comes from heuristics (input-direction pins enabled, others not),
        ; resolved later inside dgen_buildFields via dgen_factoryEnabledP.
        (setq factorySpec (list nil
          'source         (list nil 'lib dutLib 'cell dutCell 'view "symbol")
          'target         (list nil 'lib dutLib 'cell (strcat "dreg_" dutCell) 'view "veriloga")
          'dvddDefault    "0.9"
          'defaultMode    "literal"
          'defaultPattern "*_ls"
          'pins           pins))
        ; currentSpec = factory + last-state overlay. Drives ?value at
        ; field construction time. Defaults button still restores factory
        ; ?defValue, NOT last-state.
        (setq lastState (dgenLoadLastState))
        (setq currentSpec (dgen_resolveCurrentSpec factorySpec lastState dutCell))
        (setq fields (dgen_buildFields factorySpec currentSpec))
        ; Callbacks are passed as strings; Cadence evals them when a
        ; button is clicked, with `dgen_form` (the global symbol naming
        ; the form struct) accessible at that time. Stringly-typed
        ; callbacks let us reload dgenGui.il without re-creating the form.
        (hiCreateAppForm
          ?name 'dgen_form
          ?formTitle (sprintf nil "Dreg Generator -- %s/%s" dutLib dutCell)
          ?fields fields
          ?callback (list "(dgenGui_okCB dgen_form)"
                          "(dgenGui_cancelCB dgen_form)")
          ?buttonLayout 'OKCancelDefApply)
        (hiDisplayForm 'dgen_form)
        'dgen_form))))
