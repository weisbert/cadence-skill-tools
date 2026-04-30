; dgenGui.il -- Step 5+ of Dreg Generator: modeless GUI dialog for picking
; which DUT pins become Dreg parameters and editing defaults
; (target lib/cell, DVDD, defaultMode/Pattern, per-pin enable + default).
;
; Phase B Wave 2 (B1-B5) refactor + Wave 3 callback rewrites:
;   * dgenOpenGUI is now @optional dutLib dutCell. With no args the form
;     opens "DUT-less" (top section only); with both args it renders
;     immediately (old behaviour preserved -- callers like
;     dgenOpenGUI("sim_yusheng" "Test_cell") still work identically).
;   * Top section has 3 linked Lib/Cell/View combo fields
;     (ddHiCreateLibraryComboField + ddHiCreateCellComboField +
;     ddHiCreateViewComboField, linked via ddHiLinkFields after the form
;     is instantiated -- linking REQUIRES instantiation per skuiref
;     p.495) and 3 picker buttons:
;       [Select from Schematic]  [Browse Library...]  [Load Pins]
;   * Three picker mechanisms (Wave 3 UX):
;       1. Manual: type into Lib combo (auto-completion lists libs from
;          cds.lib), pick a Cell (links repopulate it), click [Load Pins].
;       2. Select from Schematic (dgenGui_selSchemCB): interactive pick
;          mode -- click button FIRST, then click an instance in any
;          open schematic. Uses enterPoint async path with doneProc
;          (dgenGui_selSchemDone). Esc cancels. Re-entry guarded via
;          enterFunNestLevel. Form-close cleanup tears down via
;          cancelEnterFun.
;       3. Browse Library (dgenGui_browseCB): links the real Cadence
;          Library Manager into our top-section combos via
;          ddsSyncWithForm (action 'browse, viewTypes filter
;          schematic+symbol). [Load Pins] remains the explicit commit
;          (no auto-trigger). Form-close cleanup ends the link via
;          ddsEndSyncWithForm.
;   * Middle/bottom (target rows + DVDD + mode/pattern + per-pin rows)
;     only built when DUT is loaded; regenerates on DUT change via the
;     close-reopen pattern (B6 land, but the load callback already does
;     this so the structure is in place).
;   * Last-state v2 integration: on no-arg open, lib/cell/view pre-fill
;     from dgen_lastStateDut{Lib,Cell,View} but DON'T auto-trigger pin
;     scan (per PLAN.md s.4 -- user might be opening for a different
;     DUT). On save, the spec's source plist is passed to
;     dgenSaveLastState so the v2 file actually carries lastDutLib/Cell/View.
;
; Buttons (?buttonLayout 'OKCancelDefApply):
;   OK / Apply -> dgenGui_okCB: read fields -> dgenRun -> save last-state
;                 (with v2 source plist) -> hiDisplayAppDBox result line.
;                 OK is no-op when no DUT loaded (warn dialog).
;   Cancel     -> dgenGui_cancelCB: no-op (form auto-closes).
;   Defaults   -> Cadence restores each field's ?defValue (= factory
;                 defaults baked into dgen_buildFields).

; ---------------------------------------------------------------------------
; Module-scope storage
; ---------------------------------------------------------------------------

; Pin list captured at GUI-open time. Callbacks receive only the form, so
; they re-read this to know how many pin rows exist and what each pin's
; metadata is. Reset on every dgenOpenGUI call. nil when DUT-less.
(unless (boundp 'dgen_currentPins) (setq dgen_currentPins nil))
(unless (boundp 'dgen_currentDutCell) (setq dgen_currentDutCell nil))
(unless (boundp 'dgen_currentDutLib) (setq dgen_currentDutLib nil))
(unless (boundp 'dgen_currentDutView) (setq dgen_currentDutView nil))

; ---------------------------------------------------------------------------
; Private helpers (pin metadata + pin field id mapping)
; ---------------------------------------------------------------------------

; Power rails (inputOutput) and outputs default disabled; only true inputs
; are factory-enabled.
(defun dgen_factoryEnabledP (pin "g")
  (equal (get pin 'srcDirection) "input"))

(defun dgen_pinDisplayName (pin "g")
  (let ((nm (get pin 'name)))
    (cond
      ((get pin 'isBus)
        (sprintf nil "%s<%d:%d>" nm (get pin 'busHi) (get pin 'busLo)))
      (t nm))))

; Per-pin field ids. Stable so dgen_readForm can index by pin index without
; parsing names. Index is 0-based.
(defun dgen_pinEnableId (idx "n")
  (concat 'dgen_pin_en_ idx))

(defun dgen_pinDefaultId (idx "n")
  (concat 'dgen_pin_def_ idx))

; ---------------------------------------------------------------------------
; Spec resolution (factory + last-state -> currentSpec)
; ---------------------------------------------------------------------------

; Resolve a "current" spec by overlaying lastState onto factorySpec.
; pinStates is a list of ("PIN_NAME" enabled defaultStr) tuples; pin
; absent from lastState retains factory defaults; entries for pins
; not in current scan are silently dropped.
;
; targetCellTpl: pattern with optional "*" placeholder for the DUT cell
; name. Default factory tpl is "dreg_*".
(defun dgen_resolveCurrentSpec (factorySpec lastState dutCell "ggt")
  (let (src tgt curPins tpl tplApplied factoryPins pinStates match)
    (setq src (get factorySpec 'source))
    (setq tgt (get factorySpec 'target))
    (setq factoryPins (get factorySpec 'pins))
    (cond
      ((null lastState)
        factorySpec)
      (t
        (setq tpl (or (get lastState 'targetCellTpl) "dreg_*"))
        (cond
          ((rexMatchp "\\*" tpl)
            (rexCompile "\\*")
            (setq tplApplied (rexReplace tpl dutCell 0)))
          (t (setq tplApplied tpl)))
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

; Helper: read (key value) pair from spec-pin-list at given pin name.
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

; ---------------------------------------------------------------------------
; Top-section field builders (built unconditionally on every form open)
; ---------------------------------------------------------------------------

; Build the Lib/Cell/View combo fields + 3 buttons in a row. Returns the
; field list ready to be (cons-prefixed onto) the rest of the form's
; ?fields entries.
;
; preLib/preCell/preView (any may be ""): initial values for the combos.
; rowH: row pixel height (matches dgen_buildFields convention = 25).
; baseY: y origin for the combo rows; topmost combo lands at baseY.
;
; Layout:
;   row 0 (y=baseY)              Lib combo  240x25, label slot 130
;   row 1 (y=baseY+rowH)         Cell combo
;   row 2 (y=baseY+2*rowH)       View combo
;   row 3 (y=baseY+3*rowH)       3 buttons in a row, ~140px each
;
; Returns: (list-of-field-entries, nextY) -- nextY is where the caller
; should start placing the middle/bottom rows. For the no-DUT case,
; caller can ignore nextY.
;
; Ref: skuiref.pdf p.484 (ddHiCreateLibraryComboField),
;      p.481 (ddHiCreateCellComboField),
;      p.487 (ddHiCreateViewComboField),
;      p.524 (hiCreateButton).
(defun dgen_buildTopFields (preLib preCell preView baseY rowH "tttng")
  (let (fields y libF cellF viewF btnSel btnBrowse btnLoad fieldW promptW
        sizePt btnW btnH btnY)
    (setq fieldW 240)
    (setq promptW 130)
    (setq sizePt (list fieldW rowH))
    (setq btnW 140)
    (setq btnH rowH)
    (setq fields nil)
    (setq y baseY)
    ; Lib combo (linked later, after form is instantiated -- ddHiLinkFields
    ; requires instantiation per skuiref p.495).
    (setq libF (ddHiCreateLibraryComboField
                 ?name 'dgen_srcLib
                 ?prompt "Source Lib"
                 ?defValue (or preLib "")
                 ?value    (or preLib "")))
    (setq fields (cons (list libF (list 0 y) sizePt promptW) fields))
    (setq y (plus y rowH))
    (setq cellF (ddHiCreateCellComboField
                  ?name 'dgen_srcCell
                  ?prompt "Source Cell"
                  ?defValue (or preCell "")
                  ?value    (or preCell "")))
    (setq fields (cons (list cellF (list 0 y) sizePt promptW) fields))
    (setq y (plus y rowH))
    (setq viewF (ddHiCreateViewComboField
                  ?name 'dgen_srcView
                  ?prompt "Source View"
                  ?defValue (or preView "symbol")
                  ?value    (or preView "symbol")))
    (setq fields (cons (list viewF (list 0 y) sizePt promptW) fields))
    (setq y (plus y rowH))
    ; Three buttons in a row. Use individual hiCreateButton (no prompt
    ; column) so the layout positions are explicit. Stringly-typed
    ; callbacks reference dgen_form (the global symbol).
    (setq btnY y)
    (setq btnSel (hiCreateButton
                   ?name 'dgen_btnSelSchem
                   ?buttonText "Select from Schematic"
                   ?callback "(dgenGui_selSchemCB dgen_form)"))
    (setq fields (cons (list btnSel (list 0 btnY) (list btnW btnH) 0) fields))
    (setq btnBrowse (hiCreateButton
                      ?name 'dgen_btnBrowse
                      ?buttonText "Browse Library..."
                      ?callback "(dgenGui_browseCB dgen_form)"))
    (setq fields (cons (list btnBrowse (list (plus btnW 10) btnY) (list btnW btnH) 0) fields))
    (setq btnLoad (hiCreateButton
                    ?name 'dgen_btnLoad
                    ?buttonText "Load Pins"
                    ?callback "(dgenGui_loadCB dgen_form)"))
    (setq fields (cons (list btnLoad (list (plus (times 2 btnW) 20) btnY) (list btnW btnH) 0) fields))
    (setq y (plus y rowH))
    (list (reverse fields) y)))

; Build the middle/bottom field entries (target rows, DVDD, mode, pattern,
; per-pin rows). Only called when a DUT is loaded.
;
; Returns: list of field entries (already in display order; caller
; appends them after the top-section field list).
;
; Ref: skuiref.pdf p.502 (hiCreateAppForm), p.650 (hiCreateStringField),
;      p.521 (hiCreateBooleanButton), p.536 (hiCreateCyclicField).
(defun dgen_buildMiddleFields (factorySpec currentSpec startY rowH "ggng")
  (let (fTgt cTgt pins cPins fields i y fieldW promptW sizePt)
    (setq fTgt (get factorySpec 'target))
    (setq cTgt (get currentSpec 'target))
    (setq pins  (get factorySpec 'pins))
    (setq cPins (get currentSpec 'pins))
    (setq fieldW 240)
    (setq promptW 130)
    (setq fields nil)
    (setq y startY)
    (setq sizePt (list fieldW rowH))
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
    ; Per-pin rows.
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

; Compatibility wrapper kept so test_step5_auto.il (and any external
; caller) still constructs identical fields. The DUT-loaded form emits
; the same widget set as before; only the source rows changed (combo
; boxes instead of read-only string fields) plus 3 buttons added.
;
; baseY for top section = 0; middle starts at baseY + 4*rowH (3 combos +
; button row).
(defun dgen_buildFields (factorySpec currentSpec "gg")
  (let (rowH fSrc preLib preCell preView topResult topFields nextY midFields)
    (setq rowH 25)
    (setq fSrc (get factorySpec 'source))
    (setq preLib  (or (get fSrc 'lib) ""))
    (setq preCell (or (get fSrc 'cell) ""))
    (setq preView (or (get fSrc 'view) "symbol"))
    (setq topResult (dgen_buildTopFields preLib preCell preView 0 rowH))
    (setq topFields (car topResult))
    (setq nextY (cadr topResult))
    (setq midFields (dgen_buildMiddleFields factorySpec currentSpec nextY rowH))
    (append topFields midFields)))

; ---------------------------------------------------------------------------
; Form-state I/O
; ---------------------------------------------------------------------------

; Dynamic field-value reader. The form->fieldName->value chain only parses
; with a literal symbol at parse time, so for runtime ids (per-pin fields
; keyed by index) we route through (get form fieldSym) -- works on form
; structs because SKILL exposes named field slots through `get`.
(defun dgen_fieldVal (form fieldSym "gs")
  (let ((rec (get form fieldSym)))
    (and rec rec->value)))

; Read all fields back into a fully-built spec plist suitable for dgenRun.
; pins is the original scan list (in scan order, same indexing used at
; build time). Caller MUST guarantee pins is non-nil (i.e. DUT loaded);
; with no DUT there are no pin fields and dgen_readForm has nothing to do.
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

; ---------------------------------------------------------------------------
; Callbacks
; ---------------------------------------------------------------------------

; OK / Apply callback. Reads fields, runs the orchestrator, saves last-state
; (with v2 source plist), pops a result dialog. Returns t/nil but Cadence
; ignores it.
;
; If no DUT is loaded yet (top section only), pop a warn dialog and return.
;
; Ref: skuiref.pdf p.309 (hiDisplayAppDBox).
(defun dgenGui_okCB (form "g")
  (cond
    ((null dgen_currentPins)
      (hiDisplayAppDBox
        ?name 'dgen_resultDBox
        ?dboxBanner "Dreg Generator"
        ?dboxText "No DUT loaded. Pick a Lib/Cell and click [Load Pins] first."
        ?dialogType hicWarningDialog
        ?buttonLayout 'Close)
      nil)
    (t
      (let (spec ok msg srcPlist)
        (setq spec (dgen_readForm form dgen_currentPins))
        (setq ok (errset (dgenRun spec) t))
        (cond
          ((and ok (car ok))
            ; B5 integration: pass current source plist so the saved file
            ; gets v2 lastDutLib/Cell/View. The source plist shape is
            ; (nil 'lib X 'cell Y 'view Z) -- matches dgenStore.il's
            ; sourcePlist contract.
            (setq srcPlist (get spec 'source))
            (errset (dgenSaveLastState
                      (dgen_specToLastState spec dgen_currentDutCell)
                      srcPlist) t)
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
            nil))))))

; Cancel callback. Form auto-closes; nothing else to do.
(defun dgenGui_cancelCB (form "g")
  t)

; defaultMode-change callback. Per-pin "value" fields only used when
; mode = "literal"; disable them under other modes. Cyclic-field
; callback signature (field scope item) per skuiref.pdf p.538.
;
; Ref: skuiref.pdf p.806 (hiSetFieldEnabled). We use the dedicated
; setter rather than slot assignment because Lisp-form
; (setq rec->enabled v) is rejected (setq's first arg must be a symbol).
(defun dgenGui_modeCB (field scope item "ggg")
  (let ((isLit (equal item "literal")) i rec)
    (setq i 0)
    (foreach p dgen_currentPins
      (setq rec (get dgen_form (dgen_pinDefaultId i)))
      (when rec (hiSetFieldEnabled rec isLit))
      (setq i (add1 i)))
    t))

; -------- Picker callbacks ---------------------------------------------

; B2: [Load Pins] button callback. Reads the three top-section combo
; values, validates, saves transient state, closes the form, and
; re-opens it with the new DUT. The reopen path runs the full
; dgen_buildFields again so per-pin rows reflect the new DUT.
;
; Validation rules:
;   * lib non-empty (else warn)
;   * cell non-empty (else warn)
;   * view defaults to "symbol" if blank
;
; The save-before-close protects the user's transient edits to
; target/DVDD/mode/pattern (per-pin rows are tied to the current DUT and
; naturally don't restore).
(defun dgenGui_loadCB (form "g")
  (let (lib cell view spec srcPlist)
    (setq lib  (dgen_fieldVal form 'dgen_srcLib))
    (setq cell (dgen_fieldVal form 'dgen_srcCell))
    (setq view (dgen_fieldVal form 'dgen_srcView))
    (when (or (null view) (equal view "")) (setq view "symbol"))
    (cond
      ((or (null lib) (equal lib ""))
        (hiDisplayAppDBox
          ?name 'dgen_loadWarnDBox
          ?dboxBanner "Dreg Generator"
          ?dboxText "Source Lib is empty. Pick a library first."
          ?dialogType hicWarningDialog
          ?buttonLayout 'Close)
        nil)
      ((or (null cell) (equal cell ""))
        (hiDisplayAppDBox
          ?name 'dgen_loadWarnDBox
          ?dboxBanner "Dreg Generator"
          ?dboxText "Source Cell is empty. Pick a cell first."
          ?dialogType hicWarningDialog
          ?buttonLayout 'Close)
        nil)
      (t
        ; Save transient state ONLY when a DUT is currently loaded
        ; (otherwise dgen_currentPins is nil and there's nothing
        ; meaningful to read from per-pin rows).
        (when dgen_currentPins
          (errset
            (let (sp src)
              (setq sp (dgen_readForm form dgen_currentPins))
              (setq src (get sp 'source))
              (dgenSaveLastState
                (dgen_specToLastState sp dgen_currentDutCell)
                src))
            t))
        ; Close current form, then reopen targeting the new DUT.
        ; hiFormCancel takes the form RECORD (not the symbol).
        (errset (hiFormCancel form) t)
        (dgenOpenGUI lib cell view)))))

; Wave 3 [Select from Schematic]: interactive-pick mode. User clicks
; the button FIRST, then clicks an instance in any open schematic.
; The form stays open (modeless). enterPoint async path -- doneProc
; fires when the user clicks (g_done=t) or hits Esc (g_done=nil).
;
; Ref: skuiref.pdf p.1197-1200 (enterPoint), p.1184 (enterFunNestLevel),
;      p.1229 (cancelEnterFun).
;
; Re-entry guard: if user double-clicks the button, ignore the second
; invocation (enterFunNestLevel > 0 means an enter-function is already
; pending).
(defun dgenGui_selSchemCB (form "g")
  (cond
    ((greaterp (enterFunNestLevel) 0)
      (warn "[dreg-gen] Already in pick mode. Click an instance, or press Esc to cancel.\n")
      nil)
    (t
      ; Async enterPoint: registers doneProc, returns immediately so
      ; the form's event loop continues. The doneProc symbol is
      ; resolved at fire-time, so dgenGui_selSchemDone must be a
      ; top-level defun (which it is, below).
      (enterPoint
        ?prompts (list "Click an instance in a schematic. Esc to cancel.")
        ?cmdName "dgenSelInst"
        ?doneProc "dgenGui_selSchemDone")
      t)))

; doneProc for dgenGui_selSchemCB. Signature per skuiref.pdf p.1197:
;   (window done points)
; - window : the graphics window where the click happened (nil on Esc)
; - done   : t if user clicked, nil if Esc / cancel
; - points : list of picked points (we don't use them; we read the
;            window's selection set after the click)
;
; The pick on a schematic instance updates the window's selection set;
; we read it back via geGetSelSet and dispatch into the same
; combo-population / loadCB path that the old retroactive callback
; used.
(defun dgenGui_selSchemDone (w done pts "ggg")
  (cond
    ((null done) nil)        ; Esc / cancel -- silent no-op
    ((null w)    nil)        ; defensive
    ; If the user X-closed the dreg form mid-pick, dgen_form is unbound
    ; (or rebound to garbage). Bail silently rather than crash on the
    ; combo-write evalstrings further down.
    ((or (null (boundp 'dgen_form)) (null dgen_form))
      (printf "[dreg-gen] pick fired but dreg form is gone -- ignoring.\n")
      nil)
    (t
      (let (cvOk cv selOk sel)
        ; Defensive cellview check: enterPoint should only fire on
        ; graphics windows, but some non-schematic windows (layout,
        ; symbol editor, etc.) also have CVs -- gate on schematic.
        (setq cvOk (errset (geGetWindowCellView w) t))
        (cond
          ((or (null cvOk) (null (car cvOk)))
            (hiDisplayAppDBox
              ?name 'dgenSelEmpty
              ?dboxBanner "Select from Schematic"
              ?dboxText "Pick window has no cellview. Try again -- click in a schematic."
              ?dialogType hicWarningDialog
              ?buttonLayout 'Close))
          (t
            (setq cv (car cvOk))
            (cond
              ((not (equal cv~>cellViewType "schematic"))
                (hiDisplayAppDBox
                  ?name 'dgenSelEmpty
                  ?dboxBanner "Select from Schematic"
                  ?dboxText "Pick window is not a schematic. Try again."
                  ?dialogType hicWarningDialog
                  ?buttonLayout 'Close))
              (t
                (setq selOk (errset (geGetSelSet w) t))
                (cond
                  ((or (null selOk) (null (car selOk)))
                    (hiDisplayAppDBox
                      ?name 'dgenSelEmpty
                      ?dboxBanner "Select from Schematic"
                      ?dboxText "No instance was picked. Try again -- click directly on an instance body."
                      ?dialogType hicWarningDialog
                      ?buttonLayout 'Close))
                  (t
                    (setq sel (car selOk))
                    (dgen_applyPickedSelection 'dgen_form sel)))))))))))

; Helper: validate the picked selection set, populate the top-section
; combos with the first instance's master lib/cell, and trigger the
; load flow. Lifted from the OLD dgenGui_selSchemCB body so the same
; edge-case handling (non-instance, missing master, multi-select warn)
; is preserved.
;
; formSym is the form's symbol (e.g. 'dgen_form) so the evalstring
; combo-write lines match the rest of the codebase.
(defun dgen_applyPickedSelection (formSym selSet "sl")
  (let (chosen master lib cell)
    (cond
      ((null selSet)
        (hiDisplayAppDBox
          ?name 'dgenSelEmpty
          ?dboxBanner "Select from Schematic"
          ?dboxText "No instance was picked. Try again -- click directly on an instance body."
          ?dialogType hicWarningDialog
          ?buttonLayout 'Close)
        nil)
      (t
        (setq chosen (car selSet))
        (when (greaterp (length selSet) 1)
          (hiDisplayAppDBox
            ?name 'dgen_selWarnDBox
            ?dboxBanner "Dreg Generator"
            ?dboxText "Multiple objects selected -- using the first."
            ?dialogType hicInformationDialog
            ?buttonLayout 'Close))
        (cond
          ((not (equal chosen~>objType "inst"))
            (hiDisplayAppDBox
              ?name 'dgen_selErrDBox
              ?dboxBanner "Dreg Generator"
              ?dboxText (strcat "Selected object is not an instance "
                                "(got " (or chosen~>objType "?")
                                "). Click an instance and try again.")
              ?dialogType hicErrorDialog
              ?buttonLayout 'Close)
            nil)
          (t
            (setq master chosen~>master)
            (setq lib    (and master master~>libName))
            (setq cell   (and master master~>cellName))
            (cond
              ((or (null lib) (null cell))
                (hiDisplayAppDBox
                  ?name 'dgen_selErrDBox
                  ?dboxBanner "Dreg Generator"
                  ?dboxText "Selected instance has no master lib/cell."
                  ?dialogType hicErrorDialog
                  ?buttonLayout 'Close)
                nil)
              (t
                ; Populate combos via infix `=` (setq cannot write
                ; through ~> per skill-gotchas). evalstring strings
                ; MUST be one-liners (per reference_skillbridge_evalstring).
                (evalstring (sprintf nil "dgen_form->dgen_srcLib->value = \"%s\"" lib))
                (evalstring (sprintf nil "dgen_form->dgen_srcCell->value = \"%s\"" cell))
                (evalstring "dgen_form->dgen_srcView->value = \"symbol\"")
                ; Trigger load flow. dgen_form is a top-level symbol
                ; bound to the live form record by hiCreateAppForm
                ; (?name 'dgen_form), so evaluating it yields the
                ; record dgenGui_loadCB expects.
                (dgenGui_loadCB dgen_form)
                t))))))))

; Wave 3 [Browse Library...]: link the existing Library Manager into
; "linked" mode against our form's top-section combos. User browses
; the real Cadence tree; their pick updates dgen_srcLib/Cell/View
; directly. Load Pins remains the explicit commit (per director
; decision #3 -- no auto-trigger).
;
; If Library Manager isn't open, ddsSyncWithForm opens it. If it IS
; open it gets re-routed into linked mode (per director decision #2 --
; matches Cadence's own dialog behavior).
;
; Ref: skdfref.pdf p.1904-1907 (ddsSyncWithForm),
;      p.1875 (ddsEndSyncWithForm).
(defun dgenGui_browseCB (form "g")
  (let (rc)
    ; Signature (skdfref.pdf p.1904):
    ;   ddsSyncWithForm(g_form s_action s_libField
    ;                   [s_cellField] [s_viewField] [l_viewTypes])
    ; Returns t/nil. We pass the form symbol, action 'browse, the three
    ; field name symbols, and a viewTypes filter so the tree only shows
    ; schematic/symbol leaves (matches the dgen DUT-pick semantics).
    (setq rc (errset
               (ddsSyncWithForm
                 'dgen_form
                 'browse
                 'dgen_srcLib
                 'dgen_srcCell
                 'dgen_srcView
                 (list "schematic" "symbol"))
               t))
    (cond
      ((or (null rc) (null (car rc)))
        (hiDisplayAppDBox
          ?name 'dgenBrowseFail
          ?dboxBanner "Browse Library"
          ?dboxText "Library Browser link failed. See CIW for details."
          ?dialogType hicWarningDialog
          ?buttonLayout 'Close)
        nil)
      (t
        (printf "[dreg-gen] Library Browser linked. Pick a view in the tree, then click [Load Pins].\n")
        t))))

; Wave 3 form-close cleanup. Wired into dgen_form's ?closeCallback so
; orphaned enterPoint or ddsSyncWithForm linkage gets torn down on
; ANY form-close path (OK / Cancel / window-close button).
;
; - cancelEnterFun: cancels a pending [Select from Schematic] pick if
;   the user closed the form before clicking an instance.
; - ddsEndSyncWithForm: tears down [Browse Library] linked-mode so the
;   Library Manager goes back to its standalone behavior.
;
; Both wrapped in errset since either may be a no-op (no pending pick,
; no active sync) and we never want close to fail.
(defun dgenGui_closeCleanupCB (form "g")
  (when (greaterp (enterFunNestLevel) 0)
    (errset (cancelEnterFun) t))
  (errset (ddsEndSyncWithForm) t)
  t)

; ---------------------------------------------------------------------------
; Public entry point
; ---------------------------------------------------------------------------

; Open the Dreg-Generator form.
;
; With no args (dgenOpenGUI()): opens "DUT-less" -- only the top section
; is built (Lib/Cell/View combos + 3 picker buttons + OK/Cancel/Defaults/
; Apply). If the saved last-state file is v2 (carries lastDutLib/Cell/
; View per dgenStore.il), the combos pre-fill with those values but pin
; scan is NOT auto-triggered (per PLAN.md s.4 -- the user might be
; opening for a different DUT).
;
; With both dutLib + dutCell args: opens fully rendered (legacy
; behaviour). Old callers like dgenOpenGUI("sim_yusheng" "Test_cell")
; work identically -- the form pre-fills lib/cell/view, scans pins, and
; lays out per-pin rows immediately.
;
; The optional dutView arg defaults to "symbol".
;
; Ref: skuiref.pdf p.502 (hiCreateAppForm), p.688 (hiDisplayForm),
;      p.495 (ddHiLinkFields -- requires post-instantiation), p.767
;      (hiInstantiateForm).
(defun dgenOpenGUI (@optional dutLib dutCell dutView)
  (let (pins factorySpec lastState currentSpec fields preLib preCell preView
        topResult topFields rowH form title dutMode)
    (setq rowH 25)
    (setq dutMode (and dutLib dutCell))
    (cond
      (dutMode
        ; Old-behaviour path: scan pins, build full form.
        (unless dutView (setq dutView "symbol"))
        (setq pins (dgenScanPins dutLib dutCell dutView))
        (cond
          ((null pins)
            (warn "dgenOpenGUI: no pins scanned for %s/%s\n" dutLib dutCell)
            nil)
          (t
            (setq dgen_currentPins pins)
            (setq dgen_currentDutCell dutCell)
            (setq dgen_currentDutLib  dutLib)
            (setq dgen_currentDutView dutView)
            (setq factorySpec (list nil
              'source         (list nil 'lib dutLib 'cell dutCell 'view dutView)
              'target         (list nil 'lib dutLib 'cell (strcat "dreg_" dutCell) 'view "veriloga")
              'dvddDefault    "0.9"
              'defaultMode    "literal"
              'defaultPattern "*_ls"
              'pins           pins))
            (setq lastState (dgenLoadLastState))
            (setq currentSpec (dgen_resolveCurrentSpec factorySpec lastState dutCell))
            (setq fields (dgen_buildFields factorySpec currentSpec))
            (setq title (sprintf nil "Dreg Generator -- %s/%s" dutLib dutCell))
            ; OK/Cancel callbacks wrap the cleanup via progn so any
            ; pending enterPoint pick or ddsSyncWithForm linkage gets
            ; torn down before the form goes away. (hiRegCloseProc
            ; would also catch the X-button close path but it requires
            ; a window object that hiCreateAppForm/hiInstantiateForm
            ; don't make available -- form record fails its type check.
            ; The doneProc and applyPickedSelection use boundp guards
            ; to bail safely if the user X-closes mid-pick.)
            (setq form (hiCreateAppForm
              ?name 'dgen_form
              ?formTitle title
              ?fields fields
              ?callback (list "(progn (dgenGui_closeCleanupCB dgen_form) (dgenGui_okCB dgen_form))"
                              "(progn (dgenGui_closeCleanupCB dgen_form) (dgenGui_cancelCB dgen_form))")
              ?buttonLayout 'OKCancelDefApply))
            (hiInstantiateForm form)
            (errset (ddHiLinkFields form->dgen_srcLib form->dgen_srcCell form->dgen_srcView) t)
            (hiDisplayForm 'dgen_form)
            'dgen_form)))
      (t
        ; DUT-less path. Reset per-pin state. Pre-fill combos from v2
        ; last-state when present (don't auto-render -- wait for user
        ; to confirm via [Load Pins] / [Select from Schematic] / [Browse]).
        (setq dgen_currentPins nil)
        (setq dgen_currentDutCell nil)
        (setq dgen_currentDutLib nil)
        (setq dgen_currentDutView nil)
        (setq lastState (dgenLoadLastState))
        (cond
          ((dgen_lastStateIsV2P lastState)
            (setq preLib  (or (dgen_lastStateDutLib  lastState) ""))
            (setq preCell (or (dgen_lastStateDutCell lastState) ""))
            (setq preView (or (dgen_lastStateDutView lastState) "symbol")))
          (t
            (setq preLib "")
            (setq preCell "")
            (setq preView "symbol")))
        (setq topResult (dgen_buildTopFields preLib preCell preView 0 rowH))
        (setq topFields (car topResult))
        (setq title "Dreg Generator -- pick a DUT")
        (setq form (hiCreateAppForm
          ?name 'dgen_form
          ?formTitle title
          ?fields topFields
          ?callback (list "(progn (dgenGui_closeCleanupCB dgen_form) (dgenGui_okCB dgen_form))"
                          "(progn (dgenGui_closeCleanupCB dgen_form) (dgenGui_cancelCB dgen_form))")
          ?buttonLayout 'OKCancelDefApply))
        (hiInstantiateForm form)
        (errset (ddHiLinkFields form->dgen_srcLib form->dgen_srcCell form->dgen_srcView) t)
        (hiDisplayForm 'dgen_form)
        'dgen_form))))
