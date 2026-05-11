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
;          ddsSyncWithForm (action 'browse, NO viewTypes filter so the
;          tree shows all views). [Load Pins] remains the explicit
;          commit (no auto-trigger). Form-close cleanup ends the link
;          via ddsEndSyncWithForm.
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

; CustomVars list captured at GUI-open time. Parallel to dgen_currentPins:
; callbacks index into this for per-row field IDs. Empty list when
; DUT-less or no customVars defined.
;
; A "customVar" is a user-added entry: (nil 'name N 'kind "digital"|"analog"
; 'isBus t/nil 'busHi int 'busLo int 'default "0"|"1.8"). See dgenStore.il
; SPEC SHAPE comment for the field-by-field contract.
;
; PERSISTENCE POLICY. customVars are session-transient by design -- pin
; configuration is DUT-derived and worth keeping across opens, but
; customVars are user-typed for a specific generation run and resetting
; on every user-initiated open is the desired UX. The list survives ONLY
; the internal close-reopen triggered by [+ Digital] / [+ Analog] /
; [Delete] (those callbacks set dgen_preserveCvs to t). Every other path
; -- user clicks OK / Cancel / X-close / Load Pins for a new DUT, or
; reopens via the MyTool menu -- starts with an empty list.
;
; dgen_preserveCvs is a one-shot flag: set by add/del callbacks before
; the deferred reopen, consumed (and cleared) at the start of the next
; dgenOpenGUI invocation. So even Cancel + reopen-via-menu gives a clean
; slate -- the flag was consumed by the deferred-reopen that came before
; the Cancel.
(unless (boundp 'dgen_currentCustomVars) (setq dgen_currentCustomVars nil))
(unless (boundp 'dgen_preserveCvs)       (setq dgen_preserveCvs       nil))

; Pending form geometry to apply on the next dgenOpenGUI call. One-shot:
; consumed (and cleared) at form display. Set by dgen_captureFormGeometry
; which is called inside dgenGui_deferredReopen just before hiFormCancel,
; so that any user drag/resize done before clicking [Load Pins] /
; [+ Digital] / [+ Analog] / [Delete] survives the close-reopen.
;
; Both stay nil on first dgenOpenGUI in a session -> form opens at the
; default position/size, matching pre-feature behaviour.
;
; Ref: skuiref.pdf p.719 (hiGetFormLocation), p.720 (hiGetFormSize),
;      p.688 (hiDisplayForm with location arg), p.813 (hiSetFormSize).
;      Slot-level introspection failed live (form->x etc. all nil); only
;      the four functions above expose form geometry — see memory
;      reference_skill_form_runtime.md for the IC6.1.8 spike record.
(unless (boundp 'dgen_pendingFormLoc)  (setq dgen_pendingFormLoc  nil))
(unless (boundp 'dgen_pendingFormSize) (setq dgen_pendingFormSize nil))

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

; Pin row label with category prefix. 'power -> "[PWR] ...", 'dreg ->
; "[DREG] ...", everything else is unprefixed (avoiding visual noise on
; pins the classifier could not place). Used by dgen_buildMiddleFields
; to make the auto-categorization visible without changing the prompt
; column width or row geometry.
(defun dgen_pinButtonText (display cat "tg")
  (cond
    ((equal cat 'power) (sprintf nil "[PWR] %s"  display))
    ((equal cat 'dreg)  (sprintf nil "[DREG] %s" display))
    (t                  display)))

; Per-pin field ids. Stable so dgen_readForm can index by pin index without
; parsing names. Index is 0-based.
(defun dgen_pinEnableId (idx "n")
  (concat 'dgen_pin_en_ idx))

(defun dgen_pinDefaultId (idx "n")
  (concat 'dgen_pin_def_ idx))

; Per-customVar field ids. Parallel to dgen_pin*Id. Kind is not stored in
; a per-row widget -- it lives in dgen_currentCustomVars[idx]['kind] and is
; fixed at row creation time (clicking [+ Digital] vs [+ Analog]).
(defun dgen_cvNameId    (idx "n") (concat 'dgen_cv_name_ idx))
(defun dgen_cvDefaultId (idx "n") (concat 'dgen_cv_def_  idx))

; Validate the customVars list against the enabled pin list. Returns nil
; on success, or an error-message string on the first problem found
; (one-at-a-time so the user fixes them sequentially; dialog box is
; clearer than a multi-error dump).
;
; Checks:
;   1. name non-empty
;   2. name is a legal Verilog identifier (alnum + underscore, not
;      starting with a digit) -- the .va port list and CDF parameter
;      both need this
;   3. analog default is one of: real literal (1.8), integer literal (0),
;      or Verilog identifier (VDDA) for a CEL variable reference. Empty
;      / garbage rejected so the user can't silently end up with 0V
;      where they meant 1.8V. Digital default is NOT validated at this
;      layer -- dgen_emitDefaultStr accepts int/identifier and falls
;      back to "0" for anything else, preserving the legacy permissive
;      behavior for digital pins.
;   4. no collision with another customVar's name
;   5. no collision with an ENABLED DUT pin's name (disabled pins are
;      filtered out of the .va port list so they can be safely shadowed)
;
; All regex uses pcreMatchp (sklangref.pdf p.186), not rexMatchp -- see
; dgen_emitDefaultStr in dgenStore.il for the rex quirks that motivated
; this. The prior rex form rejected legitimate analog values like "1.8".
(defun dgen_validateCustomVars (spec "g")
  (let (cvs pins names cv nm kind dflt msg seen pinName seenAlready)
    (setq cvs  (or (get spec 'customVars) nil))
    (setq pins (get spec 'pins))
    (setq names nil)
    (setq msg nil)
    (foreach cv cvs
      (when (null msg)
        (setq nm   (or (get cv 'name) ""))
        (setq kind (or (get cv 'kind) "digital"))
        (setq dflt (or (get cv 'default) ""))
        (cond
          ((equal nm "")
            (setq msg "Custom variable has an empty name. Fill it in or delete the row."))
          ((null (pcreMatchp "^[A-Za-z_][A-Za-z0-9_]*$" nm))
            (setq msg (sprintf nil
              "Custom variable name '%s' is not a legal Verilog identifier (use letters/digits/underscore, no whitespace, no leading digit)."
              nm)))
          ((and (equal kind "analog")
                (null (pcreMatchp "^-?[0-9]+(\\.[0-9]+)?$" dflt))
                (null (pcreMatchp "^[A-Za-z_][A-Za-z0-9_]*$" dflt)))
            (setq msg (sprintf nil
              "Analog custom variable '%s' default '%s' is neither a real literal nor a legal identifier. Use a number (e.g. 1.8) or a variable name (e.g. VDDA)."
              nm dflt)))
          (t
            ; Collision detection.
            (setq seenAlready nil)
            (foreach prior names
              (when (equal prior nm) (setq seenAlready t)))
            (cond
              (seenAlready
                (setq msg (sprintf nil
                  "Two custom variables named '%s'. Rename one." nm)))
              (t
                (foreach p pins
                  (when (and (null msg)
                             (get p 'enabled)
                             (equal (get p 'name) nm))
                    (setq msg (sprintf nil
                      "Custom variable '%s' shadows enabled DUT pin '%s'. Rename or delete the custom variable."
                      nm nm))))
                (setq names (cons nm names))))))))
    msg))

; List-mutation helper: return a copy of `lst` with the element at 0-based
; `idx` removed. Used by dgenGui_delCvCB to drop one customVar from the
; current list before the deferred reopen rebuilds the form.
(defun dgen_listRemoveAt (lst idx "ln")
  (let (out (i 0))
    (foreach el lst
      (unless (equal i idx) (setq out (cons el out)))
      (setq i (add1 i)))
    (reverse out)))

; Return a copy of `spec` with its 'customVars slot replaced by `cvs`.
; SKILL has no plist-put; we rebuild from the known spec field set. Used
; by the add/del callbacks before save+reopen so the new customVars list
; round-trips through dgenSaveLastState.
(defun dgen_specWithCustomVars (spec cvs "gl")
  (list nil
    'source         (get spec 'source)
    'target         (get spec 'target)
    'dvddDefault    (get spec 'dvddDefault)
    'defaultMode    (get spec 'defaultMode)
    'defaultPattern (get spec 'defaultPattern)
    'pins           (get spec 'pins)
    'customVars     cvs))

; Build a fresh customVar plist for [+ Digital] / [+ Analog]. Initial name
; is empty (user types it next); default value matches kind convention
; (digital 0/1 -> "0"; analog volts -> "1.8" as a reasonable rail).
(defun dgen_cvFactoryEntry (kind "t")
  (list nil
    'name    ""
    'kind    kind
    'isBus   nil
    'default (cond ((equal kind "analog") "1.8") (t "0"))))

; ---------------------------------------------------------------------------
; Mode <-> label translation + legacy mode migration
; ---------------------------------------------------------------------------
;
; Internal canonical modes (4): "literal", "empty", "variable_pin", "custom".
; UI labels are plain English so users don't have to memorize what
; "variable_pin" means. The cyclic field's ?choices stores labels (per
; skuiref.pdf p.537 -- ?choices IS the value, no separate label/value
; mapping), so dgen_buildMiddleFields / dgen_readForm / dgen_updatePreview
; all translate at the GUI boundary using these helpers.
;
; Legacy "variable" (= d_<PIN> auto-prefix) is collapsed into "custom" with
; pattern "d_*" -- equivalent behavior, one fewer concept for users to
; learn. dgen_resolveCurrentSpec migrates lastState files silently;
; dgen_resolveDefValue in dgenCDF.il keeps a "variable" branch as a
; defensive back-compat fallback for any spec that bypasses the GUI.

(defun dgen_modeToLabel (mode "g")
  (cond
    ((equal mode "literal")      "Hard-coded number")
    ((equal mode "empty")        "Leave empty")
    ((equal mode "variable_pin") "Variable = pin name")
    ((equal mode "custom")       "Variable, custom pattern")
    (t                           "Hard-coded number")))

(defun dgen_labelToMode (label "g")
  (cond
    ((equal label "Hard-coded number")        "literal")
    ((equal label "Leave empty")              "empty")
    ((equal label "Variable = pin name")      "variable_pin")
    ((equal label "Variable, custom pattern") "custom")
    (t                                        "literal")))

; Returns (modeOut patternOut). Maps legacy "variable" -> "custom" + "d_*"
; (only sets the pattern when caller didn't supply one). Anything else
; passes through unchanged.
(defun dgen_migrateModePattern (mode pattern "gg")
  (cond
    ((equal mode "variable")
      (list "custom" (or pattern "d_*")))
    (t (list mode pattern))))

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
  (let (src tgt curPins tpl tplApplied factoryPins pinStates match
        rawMode rawPat migrated curCvs)
    (setq src (get factorySpec 'source))
    (setq tgt (get factorySpec 'target))
    (setq factoryPins (get factorySpec 'pins))
    (cond
      ((null lastState)
        ; No saved state: factory pins + empty customVars list.
        (append factorySpec (list 'customVars nil)))
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
        ; Migrate legacy "variable" mode silently (see dgen_migrateModePattern
        ; header). lastState wins over factorySpec only when lastState
        ; actually has a value for the field.
        (setq rawMode (or (get lastState 'defaultMode)    (get factorySpec 'defaultMode)))
        (setq rawPat  (or (get lastState 'defaultPattern) (get factorySpec 'defaultPattern)))
        (setq migrated (dgen_migrateModePattern rawMode rawPat))
        ; CustomVars are NOT pulled from lastState -- they're session-
        ; transient by design (see dgen_currentCustomVars header comment
        ; for the policy). resolveCurrentSpec always returns customVars=nil;
        ; dgenOpenGUI splices in dgen_currentCustomVars after this call
        ; depending on dgen_preserveCvs.
        (list nil
          'source       src
          'target       (list nil
                          'lib  (or (get lastState 'targetLib) (get tgt 'lib))
                          'cell tplApplied
                          'view (get tgt 'view))
          'dvddDefault    (or (get lastState 'dvddDefault)    (get factorySpec 'dvddDefault))
          'defaultMode    (car  migrated)
          'defaultPattern (cadr migrated)
          'pins           curPins
          'customVars     nil)))))

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
; Preview helpers
; ---------------------------------------------------------------------------

; Build a one-line example of how the chosen defaultMode + pattern will
; resolve into CDF defValue strings at instantiation. Read-only string
; shown in the "Preview" row below the pattern field. Pure function --
; takes a spec plist, returns a string.
;
; Pin substitution: pick the FIRST scalar pin (isBus = nil) for a clean
; example. Falls back to first pin overall, then to literal "<pin>" if
; spec has no pins yet (DUT-less form mode).
(defun dgen_renderPreview (spec "g")
  (let (mode pattern dvdd pins examplePin pinName customResolved)
    (setq mode    (or (get spec 'defaultMode)    "literal"))
    (setq pattern (or (get spec 'defaultPattern) ""))
    (setq dvdd    (or (get spec 'dvddDefault)    "0.9"))
    (setq pins    (get spec 'pins))
    (setq examplePin nil)
    (foreach p pins
      (when (and (null examplePin) (null (get p 'isBus)))
        (setq examplePin p)))
    (when (and (null examplePin) pins)
      (setq examplePin (car pins)))
    (setq pinName (cond
                    (examplePin (get examplePin 'name))
                    (t          "<pin>")))
    (cond
      ((equal mode "literal")
        (sprintf nil "Example: DVDD=\"%s\", d_%s=(from per-pin row below)"
                 dvdd pinName))
      ((equal mode "empty")
        "All defValues empty -- user fills at instantiation")
      ((equal mode "variable")
        (sprintf nil "Example: DVDD=\"DVDD\", d_%s=\"d_%s\"" pinName pinName))
      ((equal mode "variable_pin")
        (sprintf nil "Example: DVDD=\"DVDD\", d_%s=\"%s\"" pinName pinName))
      ((equal mode "custom")
        (cond
          ((or (null pattern) (equal pattern ""))
            "Example: pattern required (defaultPattern field above)")
          (t
            (rexCompile "\\*")
            (setq customResolved (rexReplace pattern pinName 0))
            (sprintf nil "Example: DVDD=\"DVDD\", d_%s=\"%s\""
                     pinName customResolved))))
      (t (sprintf nil "Example: (unknown mode %s)" mode)))))

; Re-render the Preview row from the live form's current field values.
; Called from dgenGui_modeCB and dgenGui_patternCB. Defensive: errset
; around the slot write so a missing form (X-closed) doesn't crash the
; callback chain.
;
; setq cannot write through ~> so we route the slot assignment through
; evalstring with infix `=`. We stage the rendered text in a global
; symbol (dgen_tmpPreviewTxt) and have evalstring reference that symbol,
; rather than splicing the text into a string literal -- the text itself
; contains embedded double quotes (e.g. "Example: DVDD=\"0.9\", ...")
; which would terminate the literal early and cause a SKILL parse error
; (caught in dev). Symbol-reference path sidesteps quote-escaping
; entirely.
(defun dgen_updatePreview ()
  (let (mode pattern dvdd minSpec txt)
    (when (and (boundp 'dgen_form) dgen_form)
      ; Cyclic field stores labels; translate back to canonical mode
      ; token before feeding dgen_renderPreview (which compares against
      ; canonical tokens, not labels).
      (setq mode    (dgen_labelToMode (dgen_fieldVal dgen_form 'dgen_mode)))
      (setq pattern (dgen_fieldVal dgen_form 'dgen_pattern))
      (setq dvdd    (dgen_fieldVal dgen_form 'dgen_dvdd))
      (setq minSpec (list nil
        'defaultMode    (or mode    "literal")
        'defaultPattern (or pattern "")
        'dvddDefault    (or dvdd    "0.9")
        'pins           dgen_currentPins))
      (setq txt (dgen_renderPreview minSpec))
      (setq dgen_tmpPreviewTxt txt)
      (errset
        (evalstring "dgen_form->dgen_preview->value = dgen_tmpPreviewTxt")
        t))
    t))

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
    (setq fieldW 360)
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
  (let (fTgt cTgt pins cPins fields i y fieldW promptW sizePt previewTxt pats)
    (setq fTgt (get factorySpec 'target))
    (setq cTgt (get currentSpec 'target))
    (setq pins  (get factorySpec 'pins))
    (setq cPins (get currentSpec 'pins))
    ; Load pin-classification dictionary once per form build; pin rows
    ; below read it to attach [PWR]/[DREG] prefixes to buttonText.
    (setq pats (dgenPatternsLoad))
    (setq fieldW 360)
    (setq promptW 130)
    (setq fields nil)
    (setq y startY)
    (setq sizePt (list fieldW rowH))
    ; Target rows (editable). Use lib/cell combo dropdowns to mirror the
    ; Source-section pattern (skuiref.pdf p.484, p.481). The ddHiLinkFields
    ; call that wires lib->cell filtering lives in dgenOpenGUI's DUT-mode
    ; path, after hiInstantiateForm (skuiref.pdf p.495).
    (setq fields (cons
      (list (ddHiCreateLibraryComboField ?name 'dgen_tgtLib ?prompt "Target Lib"
              ?defValue (or (get fTgt 'lib) "")
              ?value    (or (get cTgt 'lib) ""))
            (list 0 y) sizePt promptW)
      fields))
    (setq y (plus y rowH))
    (setq fields (cons
      (list (ddHiCreateCellComboField ?name 'dgen_tgtCell ?prompt "Target Cell"
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
    ; Cyclic field shows 4 plain-English labels (see dgen_modeToLabel
    ; header for the rationale). ?choices stores labels directly --
    ; dgen_readForm translates back to canonical mode tokens.
    (setq fields (cons
      (list (hiCreateCyclicField ?name 'dgen_mode ?prompt "Default values"
              ?choices  '("Hard-coded number" "Leave empty"
                          "Variable = pin name" "Variable, custom pattern")
              ?defValue (dgen_modeToLabel (or (get factorySpec 'defaultMode) "literal"))
              ?value    (dgen_modeToLabel (or (get currentSpec 'defaultMode) "literal"))
              ?callback 'dgenGui_modeCB)
            (list 0 y) sizePt promptW)
      fields))
    (setq y (plus y rowH))
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgen_pattern ?prompt "Variable name"
              ?defValue (or (get factorySpec 'defaultPattern) "d_*")
              ?value    (or (get currentSpec 'defaultPattern) "d_*")
              ?enabled  (equal (or (get currentSpec 'defaultMode) "literal") "custom")
              ?callback 'dgenGui_patternCB)
            (list 0 y) sizePt promptW)
      fields))
    (setq y (plus y rowH))
    ; Preview row -- read-only one-line example of how defValue strings
    ; will be emitted given the current mode/pattern/dvdd. Updated live
    ; on mode/pattern change via dgenGui_modeCB / dgenGui_patternCB.
    (setq previewTxt (dgen_renderPreview currentSpec))
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgen_preview ?prompt "Preview"
              ?defValue ""
              ?value    previewTxt
              ?editable nil)
            (list 0 y) sizePt promptW)
      fields))
    (setq y (plus y rowH))
    ; Mode-button toolbar: a row of one-click prefill actions sitting
    ; right above the per-pin rows. All four are stringly-typed callbacks
    ; (defun bodies live further down in the Callbacks section). Buttons
    ; are no-ops when no DUT is loaded; in that state we render nothing.
    (when pins
      (setq fields (cons
        (list (hiCreateButton ?name 'dgen_btnAllPins
                ?buttonText "All Pins"
                ?callback "(dgenGui_modeAllCB dgen_form)")
              (list 0 y) (list 85 rowH) 0)
        fields))
      (setq fields (cons
        (list (hiCreateButton ?name 'dgen_btnNoPins
                ?buttonText "No Pins"
                ?callback "(dgenGui_modeNoneCB dgen_form)")
              (list 90 y) (list 85 rowH) 0)
        fields))
      (setq fields (cons
        (list (hiCreateButton ?name 'dgen_btnOnlyDreg
                ?buttonText "Only DREG"
                ?callback "(dgenGui_modeOnlyDregCB dgen_form)")
              (list 180 y) (list 95 rowH) 0)
        fields))
      (setq fields (cons
        (list (hiCreateButton ?name 'dgen_btnAutoSuggest
                ?buttonText "Auto Suggest"
                ?callback "(dgenGui_modeAutoSuggestCB dgen_form)")
              (list 280 y) (list 105 rowH) 0)
        fields))
      ; Edit Patterns opens the secondary keyword-dictionary editor.
      ; Lives on the same toolbar row so the toolbar reads as one
      ; coherent "act on classification" group.
      (setq fields (cons
        (list (hiCreateButton ?name 'dgen_btnEditPatterns
                ?buttonText "Edit Patterns..."
                ?callback "(dgenGui_editPatternsCB dgen_form)")
              (list 395 y) (list 115 rowH) 0)
        fields))
      (setq y (plus y rowH)))
    ; Per-pin rows.
    (let ((litMode (equal (or (get currentSpec 'defaultMode) "literal") "literal")))
      (setq i 0)
      (foreach p pins
        (let ((enId (dgen_pinEnableId i))
              (defId (dgen_pinDefaultId i))
              (display (dgen_pinDisplayName p))
              (cat (dgenPatternsClassify p pats))
              (factoryEn (dgen_factoryEnabledP p))
              (curEn  (dgen_pinFieldOr cPins (get p 'name) 'enabled (dgen_factoryEnabledP p)))
              (curDef (dgen_pinFieldOr cPins (get p 'name) 'default "0")))
          (setq fields (cons
            (list (hiCreateBooleanButton
                    ?name enId
                    ?buttonText (dgen_pinButtonText display cat)
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

    ; Custom Variables section. Header label, one row per customVar (name
    ; field + default field + Delete button), then [+ Digital] / [+ Analog]
    ; at the bottom. Iterates dgen_currentCustomVars (set by dgenOpenGUI
    ; from currentSpec~>customVars) so the per-row field IDs match what
    ; dgen_readForm later indexes on. cv-row default field is NOT gated by
    ; defaultMode the way per-pin rows are -- customVars sit alongside the
    ; auto-mode pin defaults but the user-typed analog literal (e.g. 1.8)
    ; is meaningful even in variable_pin / custom modes (the parameter
    ; emitted into the .va is `parameter real v_X = 1.8;` regardless).
    (let ((cvs (or (get currentSpec 'customVars) nil))
          (header "Custom Variables"))
      (setq fields (cons
        (list (hiCreateStringField
                ?name 'dgen_cvHeader
                ?prompt header
                ?defValue ""
                ?value (cond
                  ((null cvs) "(none) -- click [+ Digital] or [+ Analog] below to add")
                  (t (sprintf nil "%d defined" (length cvs))))
                ?editable nil)
              (list 0 y) (list 360 rowH) 130)
        fields))
      (setq y (plus y rowH))
      (setq i 0)
      (foreach cv cvs
        (let ((nameId (dgen_cvNameId i))
              (defId  (dgen_cvDefaultId i))
              (kindTag (cond ((equal (get cv 'kind) "analog") "[A]")
                             (t                                "[D]")))
              (curName (or (cond
                             ; Re-emit digital bus syntax so the user sees
                             ; the same string they typed (XX_ctrl<3:0>),
                             ; not the parsed base name.
                             ((and (get cv 'isBus) (nequal (get cv 'kind) "analog"))
                               (sprintf nil "%s<%d:%d>"
                                 (get cv 'name) (get cv 'busHi) (get cv 'busLo)))
                             (t (get cv 'name)))
                           ""))
              (curDef  (or (get cv 'default) "")))
          ; Name field. Prompt is "[D]" or "[A]" so the kind is obvious
          ; without a separate cyclic widget. Digital accepts XX<hi:lo>
          ; bus syntax; analog accepts a bare name (bus syntax is ignored
          ; at read time -- see dgen_readForm).
          (setq fields (cons
            (list (hiCreateStringField
                    ?name nameId
                    ?prompt kindTag
                    ?defValue ""
                    ?value curName)
                  (list 0 y) (list 200 rowH) 30)
            fields))
          ; Default field.
          (setq fields (cons
            (list (hiCreateStringField
                    ?name defId
                    ?prompt "value"
                    ?defValue ""
                    ?value curDef)
                  (list 210 y) (list 100 rowH) 50)
            fields))
          ; Delete button. Stringly callback embeds idx so the click
          ; fires (dgenGui_delCvCB dgen_form <idx>).
          (setq fields (cons
            (list (hiCreateButton
                    ?name (concat 'dgen_cv_del_ i)
                    ?buttonText "Delete"
                    ?callback (sprintf nil "(dgenGui_delCvCB dgen_form %d)" i))
                  (list 320 y) (list 60 rowH) 0)
            fields))
          (setq y (plus y rowH)))
        (setq i (add1 i)))
      ; [+ Digital] / [+ Analog] buttons.
      (setq fields (cons
        (list (hiCreateButton
                ?name 'dgen_btnAddDigital
                ?buttonText "+ Digital"
                ?callback "(dgenGui_addCvCB dgen_form \"digital\")")
              (list 0 y) (list 100 rowH) 0)
        fields))
      (setq fields (cons
        (list (hiCreateButton
                ?name 'dgen_btnAddAnalog
                ?buttonText "+ Analog"
                ?callback "(dgenGui_addCvCB dgen_form \"analog\")")
              (list 110 y) (list 100 rowH) 0)
        fields))
      (setq y (plus y rowH)))
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
    (setq rowH 30)
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
  (let (srcLib srcCell srcView tgtLib tgtCell dvdd mode pattern outPins
        i pin enabled deflt outCvs cv cvName cvDef cvKind parsed)
    (setq srcLib   (dgen_fieldVal form 'dgen_srcLib))
    (setq srcCell  (dgen_fieldVal form 'dgen_srcCell))
    (setq srcView  (dgen_fieldVal form 'dgen_srcView))
    (setq tgtLib   (dgen_fieldVal form 'dgen_tgtLib))
    (setq tgtCell  (dgen_fieldVal form 'dgen_tgtCell))
    (setq dvdd     (dgen_fieldVal form 'dgen_dvdd))
    ; Cyclic field stores labels; translate back to canonical mode token.
    (setq mode     (dgen_labelToMode (dgen_fieldVal form 'dgen_mode)))
    (setq pattern  (dgen_fieldVal form 'dgen_pattern))
    ; Auto-fill pattern when user picked custom-pattern mode but left the
    ; field empty. "d_*" matches the legacy "variable" semantics so the
    ; common case stays one-click.
    (when (and (equal mode "custom") (or (null pattern) (equal pattern "")))
      (setq pattern "d_*"))
    (setq outPins nil)
    (setq i 0)
    (foreach pin pins
      (setq enabled (dgen_fieldVal form (dgen_pinEnableId i)))
      (setq deflt   (dgen_fieldVal form (dgen_pinDefaultId i)))
      (setq outPins (cons
        (append pin (list 'enabled enabled 'default deflt))
        outPins))
      (setq i (add1 i)))
    ; Read customVars rows. dgen_currentCustomVars holds the kind for
    ; each idx (set at row creation); we only re-read user-editable
    ; fields (name + default). For digital rows, run the name through
    ; dgenParseBusName so "XX_ctrl<3:0>" comes back split into name +
    ; bus dims (matching how dgenScanPins handles auto-discovered bus
    ; pins). For analog rows, take the name literally -- the GUI prompt
    ; tag "[A]" tells the user not to type bus syntax, and the emitter
    ; defensively drops 'isBus on analog anyway.
    (setq outCvs nil)
    (setq i 0)
    (foreach cv dgen_currentCustomVars
      (setq cvKind (or (get cv 'kind) "digital"))
      (setq cvName (or (dgen_fieldVal form (dgen_cvNameId i)) ""))
      (setq cvDef  (or (dgen_fieldVal form (dgen_cvDefaultId i)) ""))
      (cond
        ((equal cvKind "analog")
          (setq outCvs (cons
            (list nil 'name cvName 'kind "analog" 'isBus nil 'default cvDef)
            outCvs)))
        (t
          (setq parsed (dgenParseBusName cvName))
          (setq outCvs (cons
            (append parsed (list 'kind "digital" 'default cvDef))
            outCvs))))
      (setq i (add1 i)))
    (list nil
      'source       (list nil 'lib srcLib 'cell srcCell 'view srcView)
      'target       (list nil 'lib tgtLib 'cell tgtCell 'view "veriloga")
      'dvddDefault  dvdd
      'defaultMode  mode
      'defaultPattern pattern
      'pins         (reverse outPins)
      'customVars   (reverse outCvs))))

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
    ; CustomVars are session-transient (see dgen_currentCustomVars
    ; header). They are NOT written to lastState -- the file only
    ; carries persistent DUT/pin configuration so reopening across
    ; Virtuoso sessions gives the user a clean customVars slate.
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
      (let (spec msg srcPlist tgtLib tgtCell cellOk oaPath oaOk libObj cvErr)
        (setq spec (dgen_readForm form dgen_currentPins))
        ; CustomVars validation happens BEFORE dgenRun so a bad name /
        ; empty value / collision halts at the GUI boundary rather than
        ; producing a broken cellview that the user has to delete by
        ; hand. dgen_validateCustomVars returns nil on success or an
        ; error string on the first problem; surface it in a warning
        ; dialog and bail without touching disk.
        ;
        ; SKILL has no defun-level early-return; we gate the rest of the
        ; body on cvErr being nil rather than calling (return ...) which
        ; only works inside prog / loop constructs.
        (setq cvErr (dgen_validateCustomVars spec))
        (cond
          (cvErr
            (hiDisplayAppDBox
              ?name 'dgen_cvErrDBox
              ?dboxBanner "Dreg Generator -- Custom Variables"
              ?dboxText cvErr
              ?dialogType hicWarningDialog
              ?buttonLayout 'Close)
            nil)
          (t
        (setq tgtLib  (get (get spec 'target) 'lib))
        (setq tgtCell (get (get spec 'target) 'cell))
        ; Run the orchestrator -- errset suppresses the inner-error
        ; cascade so the form callback context survives, but we do NOT
        ; trust its return value as a success/failure signal. Site-level
        ; cellview-save hooks (e.g. Calibre RT save messenger fired by
        ; schPinListToSymbolGen / amsUpdateTextviews) may raise on every
        ; save, which errset captures as nil despite the cell having
        ; landed cleanly on disk. The ground-truth check below is the
        ; actual success criterion.
        (errset (dgenRun spec) t)
        ; Ground-truth: did both required views materialize?
        ; ddGetObj returns nil for missing lib/cell/view (non-throwing
        ; per skdfref.pdf p.1760), so a plain (and ...) suffices.
        (setq cellOk
          (and (ddGetObj tgtLib tgtCell "symbol")
               (ddGetObj tgtLib tgtCell "veriloga")))
        ; Independent post-condition for the netlist.oa step. Without
        ; this file Maestro/ADE-XL fail with OSSHNL-381 even though the
        ; symbol+veriloga views are present. Surface this distinctly
        ; rather than reporting plain success — otherwise users hit
        ; the netlist err and resort to manual Check&Save, which
        ; clobbers our CDF defaults via auto-CDF.
        (setq libObj (ddGetObj tgtLib))
        (setq oaPath
          (when libObj
            (strcat libObj~>readPath "/" tgtCell "/veriloga/netlist.oa")))
        (setq oaOk (and oaPath (isFile oaPath)))
        (cond
          ((and cellOk oaOk)
            (setq srcPlist (get spec 'source))
            (errset (dgenSaveLastState
                      (dgen_specToLastState spec dgen_currentDutCell)
                      srcPlist) t)
            (setq msg (sprintf nil "Generated %s/%s successfully."
              tgtLib tgtCell))
            (hiDisplayAppDBox
              ?name 'dgen_resultDBox
              ?dboxBanner "Dreg Generator"
              ?dboxText msg
              ?dialogType hicInformationDialog
              ?buttonLayout 'Close)
            t)
          (cellOk
            ; Cellviews landed but netlist.oa is missing. Maestro will
            ; fail with OSSHNL-381. Most common cause is the AMS license
            ; not being available — see CIW for the dgen_compileVerilogA
            ; warn line for details.
            (setq srcPlist (get spec 'source))
            (errset (dgenSaveLastState
                      (dgen_specToLastState spec dgen_currentDutCell)
                      srcPlist) t)
            (setq msg (sprintf nil
              "Generated %s/%s, but netlist.oa was NOT produced.\n\nMaestro/ADE-XL will fail with OSSHNL-381 until this is fixed.\n\nLikely cause: AMS Designer license not available (amsIsPresent=nil) or amsUpdateTextviews/vmsUpdateCellViews failed. See CIW for the warn from dgen_compileVerilogA."
              tgtLib tgtCell))
            (hiDisplayAppDBox
              ?name 'dgen_resultDBox
              ?dboxBanner "Dreg Generator"
              ?dboxText msg
              ?dialogType hicWarningDialog
              ?buttonLayout 'Close)
            nil)
          (t
            (setq msg (sprintf nil "Failed to generate %s/%s. See CIW for details."
              tgtLib tgtCell))
            (hiDisplayAppDBox
              ?name 'dgen_resultDBox
              ?dboxBanner "Dreg Generator"
              ?dboxText msg
              ?dialogType hicWarningDialog
              ?buttonLayout 'Close)
            nil))))))))   ; close inner-cond t-branch + inner-cond + cvErr-cond t-branch + cvErr-cond + let + outer-cond t-branch + outer-cond + defun

; Cancel callback. Form auto-closes; nothing else to do.
(defun dgenGui_cancelCB (form "g")
  t)

; [+ Digital] / [+ Analog] callback. Reads current form state, appends a
; fresh customVar of the requested kind, persists via dgenSaveLastState,
; and schedules the same deferred close+reopen pattern that [Load Pins]
; uses so the new row renders without any "Cannot delete a form from
; within the form's callback" warning. Same DUT -- we pass
; dgen_currentDut{Lib,Cell,View} to the reopen.
;
; No-op + warn dialog when DUT-less (consistent with dgenGui_okCB).
(defun dgenGui_addCvCB (form kind "gt")
  (cond
    ((null dgen_currentPins)
      (hiDisplayAppDBox
        ?name 'dgen_cvWarnDBox
        ?dboxBanner "Dreg Generator"
        ?dboxText "Load a DUT first. Custom Variables are stored alongside the DUT's pin selections."
        ?dialogType hicWarningDialog
        ?buttonLayout 'Close)
      nil)
    (t
      (let (sp newCvs src updated)
        (setq sp     (dgen_readForm form dgen_currentPins))
        (setq newCvs (append (get sp 'customVars) (list (dgen_cvFactoryEntry kind))))
        (setq dgen_currentCustomVars newCvs)
        ; Raise the preserve flag so the deferred reopen below keeps the
        ; new cv list across the form rebuild. dgenOpenGUI consumes
        ; (clears) this flag, so a subsequent user-initiated open won't
        ; see it.
        (setq dgen_preserveCvs t)
        (setq updated (dgen_specWithCustomVars sp newCvs))
        (setq src    (get updated 'source))
        (errset (dgenSaveLastState
                  (dgen_specToLastState updated dgen_currentDutCell) src) t)
        (hiRegTimer
          (sprintf nil "(dgenGui_deferredReopen \"%s\" \"%s\" \"%s\")"
            dgen_currentDutLib dgen_currentDutCell dgen_currentDutView)
          1)
        t))))

; [Delete] per-row callback. Drops customVar at 0-based idx, persists,
; deferred reopen. idx is embedded into the stringly callback at form-
; build time (see dgen_buildMiddleFields).
(defun dgenGui_delCvCB (form idx "gn")
  (cond
    ((null dgen_currentPins) nil)  ; DUT-less -> no customVar rows exist
    (t
      (let (sp newCvs src updated)
        (setq sp     (dgen_readForm form dgen_currentPins))
        (setq newCvs (dgen_listRemoveAt (get sp 'customVars) idx))
        (setq dgen_currentCustomVars newCvs)
        ; Same one-shot preserve flag as dgenGui_addCvCB -- the reduced
        ; cv list (after deletion) survives the form rebuild but does
        ; NOT leak into the next user-initiated open.
        (setq dgen_preserveCvs t)
        (setq updated (dgen_specWithCustomVars sp newCvs))
        (setq src    (get updated 'source))
        (errset (dgenSaveLastState
                  (dgen_specToLastState updated dgen_currentDutCell) src) t)
        (hiRegTimer
          (sprintf nil "(dgenGui_deferredReopen \"%s\" \"%s\" \"%s\")"
            dgen_currentDutLib dgen_currentDutCell dgen_currentDutView)
          1)
        t))))

; defaultMode-change callback. Per-pin "value" fields only used when
; mode = "literal"; disable them under other modes. Cyclic-field
; callback signature (field scope item) per skuiref.pdf p.538.
;
; `item` is the cyclic field's LABEL string (since ?choices stores
; labels directly per skuiref.pdf p.537), so we compare against the
; user-facing strings rather than canonical mode tokens.
;
; Ref: skuiref.pdf p.806 (hiSetFieldEnabled). We use the dedicated
; setter rather than slot assignment because Lisp-form
; (setq rec->enabled v) is rejected (setq's first arg must be a symbol).
(defun dgenGui_modeCB (field scope item "ggg")
  (let (isLit isCustom i rec patRec)
    (setq isLit    (equal item "Hard-coded number"))
    (setq isCustom (equal item "Variable, custom pattern"))
    (setq i 0)
    (foreach p dgen_currentPins
      (setq rec (get dgen_form (dgen_pinDefaultId i)))
      (when rec (hiSetFieldEnabled rec isLit))
      (setq i (add1 i)))
    ; Pattern field is only meaningful when mode = "custom"; gray it
    ; out otherwise so the user isn't tempted to type a pattern that
    ; will be ignored.
    (when (and (boundp 'dgen_form) dgen_form)
      (setq patRec (get dgen_form 'dgen_pattern))
      (when patRec (hiSetFieldEnabled patRec isCustom)))
    ; Live-update the Preview row to match the new mode.
    (dgen_updatePreview)
    t))

; defaultPattern-edit callback. String-field callback signature is
; (field scope newValue) per skuiref.pdf p.650. We just refresh the
; preview -- the actual pattern value is stored in the field itself
; and read at OK time by dgen_readForm.
(defun dgenGui_patternCB (field scope newValue "ggg")
  (dgen_updatePreview)
  t)

; -------- Mode-button callbacks (toolbar above pin rows) ---------------
;
; Four one-click buttons let the user prefill the pin enable column
; without clicking each row:
;   [All Pins]     -> every enable -> t
;   [No Pins]      -> every enable -> nil
;   [Only DREG]    -> enable iff dgenPatternsClassify returns 'dreg
;   [Auto Suggest] -> 'dreg -> t, 'power -> nil, 'other -> factory
;                     default (direction-based via dgen_factoryEnabledP)
;
; Each callback walks dgen_currentPins and writes
; dgen_form->dgen_pin_en_<i>->value via evalstring. The form-> ->value
; chain only parses with literal symbols, so when the field name is
; constructed at runtime evalstring is the documented escape hatch --
; same pattern used at line ~417 (preview update) and ~1367-1369
; (Select-from-Schematic picker fill).
;
; All four are no-ops when no DUT is loaded (dgen_currentPins is nil)
; and likewise no-op if the corresponding form field record is missing
; (defensive against close-reopen races).

(defun dgenGui_modeAllCB (form "g")
  (when dgen_currentPins
    (let ((i 0))
      (foreach _p dgen_currentPins
        (evalstring (sprintf nil
          "dgen_form->%s->value = t" (dgen_pinEnableId i)))
        (setq i (add1 i)))))
  t)

(defun dgenGui_modeNoneCB (form "g")
  (when dgen_currentPins
    (let ((i 0))
      (foreach _p dgen_currentPins
        (evalstring (sprintf nil
          "dgen_form->%s->value = nil" (dgen_pinEnableId i)))
        (setq i (add1 i)))))
  t)

(defun dgenGui_modeOnlyDregCB (form "g")
  (when dgen_currentPins
    (let ((pats (dgenPatternsLoad)) (i 0))
      (foreach p dgen_currentPins
        (let ((on (equal (dgenPatternsClassify p pats) 'dreg)))
          (evalstring (sprintf nil
            "dgen_form->%s->value = %s"
            (dgen_pinEnableId i) (if on "t" "nil"))))
        (setq i (add1 i)))))
  t)

; Auto Suggest: best-guess classifier-driven prefill.
;   'dreg  -> t   (digital control input -- the whole point of dreg_gen)
;   'power -> nil (rail; user shouldn't drive it)
;   'other -> dgen_factoryEnabledP (input -> t, otherwise nil)
; 'other falls back to direction so unclassified inputs still default
; on, matching the pre-feature behavior the user had before this
; classifier existed -- a tactical "do no harm" default.
(defun dgenGui_modeAutoSuggestCB (form "g")
  (when dgen_currentPins
    (let ((pats (dgenPatternsLoad)) (i 0))
      (foreach p dgen_currentPins
        (let ((cat (dgenPatternsClassify p pats)) on)
          (setq on
            (cond
              ((equal cat 'dreg)  t)
              ((equal cat 'power) nil)
              (t                  (dgen_factoryEnabledP p))))
          (evalstring (sprintf nil
            "dgen_form->%s->value = %s"
            (dgen_pinEnableId i) (if on "t" "nil"))))
        (setq i (add1 i)))))
  t)

; -------- Form-geometry capture / restore -------------------------------
;
; Snapshot the currently-displayed dgen_form's screen position + pixel
; size into the module-level pending slots. Called from
; dgenGui_deferredReopen just before hiFormCancel so the post-reopen
; form lands where the user left it. Wrapped in errset so a stale or
; partially-displayed form record can't error out the close path.

(defun dgen_captureFormGeometry ()
  (when (and (boundp 'dgen_form) dgen_form)
    (let ((locR (errset (hiGetFormLocation dgen_form) t))
          (szR  (errset (hiGetFormSize     dgen_form) t)))
      ; errset wraps success in a 1-element list; unwrap via car. nil on
      ; failure (form record not displayed yet, etc.) -> keep pending nil.
      (when locR (setq dgen_pendingFormLoc  (car locR)))
      (when szR  (setq dgen_pendingFormSize (car szR)))))
  t)

; Apply pending geometry (if any) to a freshly-instantiated form. Called
; from the two hiDisplayForm sites in dgenOpenGUI. Pending slots are
; consumed (cleared to nil) here so each capture cycles through cleanly:
; capture -> close -> reopen -> consume -> stable until next capture.
;
; hiSetFormSize must run AFTER hiInstantiateForm; per the doc it's a
; no-op on a non-instantiated form. hiDisplayForm accepts the location
; as its second positional argument.

(defun dgen_displayFormApplyPending (form formSym "gs")
  (let ((pendingLoc dgen_pendingFormLoc)
        (pendingSize dgen_pendingFormSize))
    (setq dgen_pendingFormLoc  nil)
    (setq dgen_pendingFormSize nil)
    (when pendingSize
      (errset (hiSetFormSize form pendingSize) t))
    (cond
      (pendingLoc (hiDisplayForm formSym pendingLoc))
      (t          (hiDisplayForm formSym)))))

; -------- In-place pin-label refresh ------------------------------------
;
; Rewrites each per-pin BooleanButton's visible label to reflect a fresh
; classification pass against the supplied patterns. Used by the Edit
; Patterns OK path to avoid the previous close-reopen flicker.
;
; Mechanism: SKILL stores the ?buttonText creation-time arg on the field
; record's `prompt` slot. Writing to ->prompt at runtime via evalstring
; updates the visible label immediately -- verified live against IC6.1.8
; (see memory reference_skill_form_runtime.md). The infix `=` is required
; because (setq form->field->prompt ...) rejects the slot-chain LHS.
;
; No-op when no DUT is loaded (dgen_currentPins is nil) or the field
; record is missing (defensive against rare close-reopen race).

(defun dgenGui_refreshPinLabels (pats "g")
  (when dgen_currentPins
    (let ((i 0))
      (foreach p dgen_currentPins
        (let ((cat (dgenPatternsClassify p pats))
              (display (dgen_pinDisplayName p)))
          (errset
            (evalstring (sprintf nil
              "dgen_form->%s->prompt = %L"
              (dgen_pinEnableId i)
              (dgen_pinButtonText display cat)))
            t))
        (setq i (add1 i)))))
  t)

; -------- Edit Patterns secondary form ---------------------------------
;
; Standalone modal-ish form for editing the keyword dictionary. Two
; multi-line text fields (one per category) plus a Reset-to-Defaults
; button. OK writes to ~/.skill_tools/dreg_gen.patterns and triggers a
; close-reopen of the main form so the [PWR]/[DREG] prefix labels pick
; up the new dictionary. Cancel discards without saving.
;
; Form handle stored in a module-level binding so the Reset callback
; can write back into the two MLT fields via the evalstring escape
; hatch (same pattern as dgen_form -- the form->field->value chain
; only parses with a literal symbol).
;
; Ref: skuiref.pdf p.502 (hiCreateAppForm), p.602 (hiCreateMLTextField),
;      p.767 (hiInstantiateForm), p.688 (hiDisplayForm).
;      sklangref.pdf p.165 (parseString), p.158 (buildString),
;      p.191 (pcreReplace).

(unless (boundp 'dgenPat_editorForm) (setq dgenPat_editorForm nil))

; ---- Keyword-list text serialization helpers ----

; List-of-strings -> single string with "\n" between entries. Empty list
; yields the empty string (the MLT field shows blank, which is the right
; UX -- not a literal "()").
(defun dgenPat_listToText (lst "l")
  (cond
    ((null lst) "")
    (t (buildString lst "\n"))))

; Trim leading/trailing whitespace from a string. SKILL has no built-in;
; pcreReplace on a precompiled pattern is the project-standard pcre-only
; idiom (no rexReplace per feedback_skill_pcre_over_rex.md). \s in PCRE
; matches space + tab + form-feed / etc., which is what we want for
; sloppy user input.
(defun dgenPat_trim (s "t")
  (let ((p (pcreCompile "^\\s+|\\s+$")))
    (pcreReplace p s "" 0)))

; Text-area content -> list of trimmed, non-empty keywords. parseString
; with "\n" splits the textarea content per line; we then drop blanks
; and dedupe-by-first-occurrence so a stray empty line in the editor
; doesn't end up as a match-everything entry (dgenPatternsMatchKw also
; skips blanks defensively, but cleaning at parse time keeps the saved
; file tidy).
(defun dgenPat_parseTextarea (text "t")
  (let (lines out trimmed seen)
    (setq lines (parseString text "\n"))
    (setq seen (makeTable 'dgenPat_seen nil))
    (foreach l lines
      (setq trimmed (dgenPat_trim l))
      (when (and (greaterp (strlen trimmed) 0)
                 (null seen[trimmed]))
        (setarray seen trimmed t)
        (setq out (cons trimmed out))))
    (reverse out)))

; ---- Form builder ----

(defun dgenPatternsEditorBuild (pats "g")
  (let (fields y rowH labelW mlW mlH)
    (setq fields nil)
    (setq y 0)
    (setq rowH 28)
    (setq labelW 0)            ; prompt label width baked into MLT
    (setq mlW 360)
    (setq mlH 220)
    ; Header label as a read-only string field (mirrors the customVars
    ; header pattern; hiCreateLabel works too but the read-only string
    ; field aligns better with the rest of the dreg_gen forms).
    (setq fields (cons
      (list (hiCreateStringField
              ?name 'dgenPat_header
              ?prompt "Edit Patterns"
              ?defValue ""
              ?value "One keyword per line. Matching is prefix-anchored, case-insensitive."
              ?editable nil)
            (list 0 y) (list mlW rowH) 100)
      fields))
    (setq y (plus y rowH 6))
    ; Power keywords block.
    (setq fields (cons
      (list (hiCreateMLTextField
              ?name 'dgenPat_powerList
              ?prompt "Power keywords"
              ?value (dgenPat_listToText (get pats 'power))
              ?defValue (dgenPat_listToText (dgenPatternsDefaultPower))
              ?hasVerticalScrollbar t
              ?hasHorizontalScrollbar nil
              ?enableWordWrap t)
            (list 0 y) (list mlW mlH) 100)
      fields))
    (setq y (plus y mlH 8))
    ; DREG keywords block.
    (setq fields (cons
      (list (hiCreateMLTextField
              ?name 'dgenPat_dregList
              ?prompt "DREG keywords"
              ?value (dgenPat_listToText (get pats 'dreg))
              ?defValue (dgenPat_listToText (dgenPatternsDefaultDreg))
              ?hasVerticalScrollbar t
              ?hasHorizontalScrollbar nil
              ?enableWordWrap t)
            (list 0 y) (list mlW mlH) 100)
      fields))
    (setq y (plus y mlH 6))
    ; Reset button -- rewrites the two MLT field values in-place to the
    ; built-in defaults. Does NOT save -- user still has to click OK.
    (setq fields (cons
      (list (hiCreateButton
              ?name 'dgenPat_btnReset
              ?buttonText "Reset to Defaults"
              ?callback "(dgenGui_patternsEditorResetCB dgenPat_editorForm)")
            (list 0 y) (list 140 rowH) 0)
      fields))
    (reverse fields)))

(defun dgenPatternsEditorOpen ()
  (let (pats fields form)
    (setq pats (dgenPatternsLoad))
    (setq fields (dgenPatternsEditorBuild pats))
    (setq form (hiCreateAppForm
      ?name 'dgenPat_editorForm
      ?formTitle "Dreg Generator -- Edit Pin Classification Patterns"
      ?fields fields
      ?callback (list "(dgenGui_patternsEditorOkCB dgenPat_editorForm)"
                      "(dgenGui_patternsEditorCancelCB dgenPat_editorForm)")
      ?buttonLayout 'OKCancelDef))
    (hiInstantiateForm form)
    (hiDisplayForm 'dgenPat_editorForm)
    'dgenPat_editorForm))

; Main-form callback: route the [Edit Patterns...] toolbar click into
; the editor opener. Stringly callback -- form arg unused but kept for
; signature symmetry with the other mode buttons.
(defun dgenGui_editPatternsCB (form "g")
  (dgenPatternsEditorOpen)
  t)

; ---- Editor callbacks ----

; OK: serialize the two MLT fields, write the patterns file, and refresh
; visible pin-row labels in-place. No close-reopen, no flicker, no loss of
; position / size / pin-enable state -- the form keeps everything else.
;
; The refresh walks dgen_currentPins, classifies each against the new
; dictionary, and writes the resulting [PWR]/[DREG]/<bare> prefix into
; the field's prompt slot (which is where ?buttonText lands at creation
; time; see dgenGui_refreshPinLabels header for the IC6.1.8 confirmation).
;
; Returns t so Cadence dismisses the editor automatically.
(defun dgenGui_patternsEditorOkCB (editorForm "g")
  (let (powerTxt dregTxt newPats)
    (setq powerTxt (or (dgen_fieldVal editorForm 'dgenPat_powerList) ""))
    (setq dregTxt  (or (dgen_fieldVal editorForm 'dgenPat_dregList)  ""))
    (setq newPats (list nil
      'schemaVersion 1
      'power (dgenPat_parseTextarea powerTxt)
      'dreg  (dgenPat_parseTextarea dregTxt)))
    (dgenPatternsSave newPats)
    (dgenGui_refreshPinLabels newPats)
    t))

(defun dgenGui_patternsEditorCancelCB (editorForm "g")
  t)

; Reset: blow away the two MLT field values with the built-in defaults.
; The user still has to click OK to persist; clicking Cancel after Reset
; abandons the reset, matching the "Cancel always discards" contract.
(defun dgenGui_patternsEditorResetCB (editorForm "g")
  (let ((powerTxt (dgenPat_listToText (dgenPatternsDefaultPower)))
        (dregTxt  (dgenPat_listToText (dgenPatternsDefaultDreg))))
    ; %L on a string yields a SKILL string literal (with quoting); using
    ; %s would corrupt embedded backslashes / quotes if the user ever
    ; pastes oddball content into the textarea. The defaults are
    ; alphanumeric so this is defensive rather than necessary.
    (evalstring (sprintf nil "dgenPat_editorForm->dgenPat_powerList->value = %L" powerTxt))
    (evalstring (sprintf nil "dgenPat_editorForm->dgenPat_dregList->value  = %L" dregTxt))
    t))

; -------- Picker callbacks ---------------------------------------------

; B2: [Load Pins] button callback. Reads the three top-section combo
; values, validates, saves transient state, then DEFERS the form
; close+reopen to a hiRegTimer tick so we don't trigger
;   "*WARNING* hiDeleteForm: Cannot delete a form that is mapped or
;    from within the form's callback"
; (which is exactly what happens if you call hiFormCancel/dgenOpenGUI
; while still inside dgen_btnLoad's stringly-typed callback).
;
; Validation rules:
;   * lib non-empty (else warn)
;   * cell non-empty (else warn)
;   * view defaults to "symbol" if blank
;
; The save-before-close runs SYNCHRONOUSLY here -- the form is still
; alive at this point so dgen_readForm can read the per-pin rows.
;
; The actual close+reopen lives in dgenGui_deferredReopen, scheduled
; via hiRegTimer (1 = 100ms; arg unit is tenths of seconds per
; skuiref.pdf p.84) so it runs AFTER this callback returns and the
; form's mapped/callback context has cleared.
;
; Ref: skuiref.pdf p.84 (hiRegTimer).
(defun dgenGui_loadCB (form "g")
  (let (lib cell view)
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
        ; meaningful to read from per-pin rows). MUST happen before
        ; the deferred reopen tears down the form record.
        (when dgen_currentPins
          (errset
            (let (sp src)
              (setq sp (dgen_readForm form dgen_currentPins))
              (setq src (get sp 'source))
              (dgenSaveLastState
                (dgen_specToLastState sp dgen_currentDutCell)
                src))
            t))
        ; Schedule close+reopen for the next event-loop tick.
        ; sprintf yields a one-line callback string (per skillbridge
        ; evalstring/hiRegTimer multi-line gotcha).
        (hiRegTimer
          (sprintf nil "(dgenGui_deferredReopen \"%s\" \"%s\" \"%s\")"
                   lib cell view)
          1)
        t))))

; Deferred close+reopen. Two-stage timer pattern.
;
; History:
;   Hotfix 1 used hiFormCancel + dgenOpenGUI directly here, but failed
;   with "*WARNING* hiDeleteForm: Cannot delete a form that is mapped
;   or from within the form's callback" because hiFormCancel fires our
;   wired cancel-callback chain ("(progn (dgenGui_closeCleanupCB ...)
;   (dgenGui_cancelCB ...))") and Cadence still treats that as
;   form-callback context when the very next call (hiCreateAppForm with
;   the same name) tries to delete the old record.
;
;   Hotfix 2 swapped to hiFormUnmap + hiDeleteForm to bypass the
;   callback chain. That made hiCreateAppForm succeed but freed only
;   the form RECORD -- the visible window stayed on screen because
;   neither low-level call destroys the X11/Qt widget. Result: zombie
;   windows whose Cancel/X buttons clicked into a void (form record
;   gone) and a new window per Load Pins click.
;
; Hotfix 3 (this version): hiFormCancel IS the right API to close the
; window -- it's what wires Cancel/X up correctly. The hotfix-1 timing
; bug was that dgenOpenGUI ran too soon after hiFormCancel, while
; Cadence was still inside the cancel-callback chain. Fix: split into
; two timers. Stage 1 just fires hiFormCancel. Stage 2 (armed for the
; next tick) calls dgenOpenGUI. The 200ms gap lets Cadence's
; cancel-callback context clear before hiCreateAppForm-with-same-name
; runs.
;
; dgen_form is NOT nil'd here -- hiFormCancel triggers our cleanup
; callback (which is safe in either state) and stage 2's dgenOpenGUI
; rebinds dgen_form anyway.
;
; Edge cases:
;   * User X-closes form before stage 2 fires -- dgenOpenGUI creates a
;     fresh form regardless (errset wraps any failure).
;   * Two rapid Load Pins clicks -- two stage-1 timers fire (second is
;     a no-op since dgen_form is already gone), two stage-2 timers
;     fire, end state is one new form on screen.
;
; Ref: skuiref.pdf p.84 (hiRegTimer; arg unit is tenths of seconds, so
;      2 = 200ms), hiFormCancel (the documented form-close API that
;      ALSO destroys the window widget, unlike hiFormUnmap +
;      hiDeleteForm which only free the record).
(defun dgenGui_deferredReopen (lib cell view "ttt")
  (when (and (boundp 'dgen_form) dgen_form)
    ; Snapshot pos+size BEFORE hiFormCancel destroys the window. Stage 2
    ; (dgen_actuallyOpenGUI -> dgenOpenGUI) consumes the pending slots
    ; when calling dgen_displayFormApplyPending.
    (dgen_captureFormGeometry)
    (errset (hiFormCancel dgen_form) t))
  (hiRegTimer
    (sprintf nil "(dgen_actuallyOpenGUI \"%s\" \"%s\" \"%s\")" lib cell view)
    2))

; Stage 2 of the deferred-reopen pattern. Fires from a hiRegTimer tick
; after stage 1's hiFormCancel has finished firing the form's cancel
; callback chain, so Cadence's form-callback context flag has cleared
; and hiCreateAppForm-with-same-name can clean up + recreate without
; the "Cannot delete a form ... from within the form's callback"
; warning.
;
; errset wraps the open so any failure (e.g. user already opened
; another instance during the 200ms gap) doesn't cascade.
(defun dgen_actuallyOpenGUI (lib cell view "ttt")
  (errset (dgenOpenGUI lib cell view) t))

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
; - points : list of picked points -- car is the click coordinate
;            (xCoord/yCoord are aliases for car/cadr per sklangref.pdf
;            p.71-72, so the point is a (x y) list).
;
; enterPoint captures only the COORDINATE -- it does NOT mutate the
; window's selection set (that's geSelectPoint's job, and geSelectPoint
; can't be combined with a doneProc-style callback). The previous
; revision read geGetSelSet here, which only ever returned whatever the
; user had pre-selected before clicking [Select from Schematic] --
; typically nil -- producing the spurious "No instance was picked"
; dialog seen in CDS.log on user's live test.
;
; Fix: hit-test the captured point against the schematic via
; dbGetOverlaps with a tiny bbox around the click. This returns ALL
; figures whose bbox overlaps the search box; we filter to objType
; "inst" so wires / pins / shapes are reported as "not an instance".
;
; Ref: skdfref.pdf p.1317-1319 (dbGetOverlaps),
;      skuiref.pdf p.1197 (enterPoint doneProc signature),
;      sklangref.pdf p.71-72 (xCoord/yCoord = car/cadr aliases).
(defun dgenGui_selSchemDone (w done pts "ggg")
  (cond
    ((null done) nil)        ; Esc / cancel -- silent no-op
    ((null w)    nil)        ; defensive
    ; If the user X-closed the dreg form mid-pick, dgen_form is unbound
    ; (or rebound to garbage). Bail silently rather than crash.
    ((or (null (boundp 'dgen_form)) (null dgen_form))
      (printf "[dreg-gen] pick fired but dreg form is gone -- ignoring.\n")
      nil)
    ((null pts)
      (printf "[dreg-gen] pick fired with no point -- ignoring.\n")
      nil)
    (t
      (let (cvOk cv pt eps bbox objsOk objs insts)
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
                ; Build a tiny epsilon-bbox around the click for hit-test.
                ; 0.01 user units is comfortably below typical schematic
                ; symbol dimensions (DUT bodies are O(1.0) units) and
                ; well above floating-point noise.
                (setq pt (car pts))
                (setq eps 0.01)
                (setq bbox (list
                             (list (difference (xCoord pt) eps)
                                   (difference (yCoord pt) eps))
                             (list (plus       (xCoord pt) eps)
                                   (plus       (yCoord pt) eps))))
                (setq objsOk (errset (dbGetOverlaps cv bbox) t))
                (cond
                  ((or (null objsOk) (null (car objsOk)))
                    ; dbGetOverlaps errored or no overlap returned --
                    ; clicked on empty schematic space.
                    (hiDisplayAppDBox
                      ?name 'dgenSelEmpty
                      ?dboxBanner "Select from Schematic"
                      ?dboxText "No instance at click point. Try again -- click directly on an instance body."
                      ?dialogType hicWarningDialog
                      ?buttonLayout 'Close))
                  (t
                    (setq objs (car objsOk))
                    ; dbGetOverlaps may include nested-list entries for
                    ; objects deeper in the hierarchy (skdfref.pdf
                    ; p.1317). Filter to flat top-level objects whose
                    ; objType is "inst". errset around o~>objType
                    ; defends against nested-list entries that don't
                    ; respond to ~>objType.
                    (setq insts
                      (setof o objs
                        (and (not (listp o))
                             (equal (errset o~>objType t) (list "inst")))))
                    (cond
                      ((null insts)
                        (hiDisplayAppDBox
                          ?name 'dgen_selErrDBox
                          ?dboxBanner "Dreg Generator"
                          ?dboxText "Selected object is not an instance. Click an instance body and try again."
                          ?dialogType hicErrorDialog
                          ?buttonLayout 'Close))
                      (t
                        ; Hit test naturally yields at most one instance
                        ; under a sub-grid eps-bbox in practice; if more
                        ; than one (overlapping symbols), pick the
                        ; first.
                        (dgen_applyPickedSelection 'dgen_form
                          (car insts))))))))))))))

; Helper: from a single picked instance, populate the top-section
; combos with the master lib/cell and kick off the load flow. The old
; (multi-select selSet) signature is gone because the new hit-test path
; in dgenGui_selSchemDone naturally yields at most one instance.
;
; formSym is the form's symbol (e.g. 'dgen_form) -- preserved to keep
; the evalstring infix `=` lines parseable identically to the rest of
; the codebase.
;
; Ref: feedback_skill_gotchas (setq cannot write through ~>; use infix `=`
;      via evalstring), reference_skillbridge_evalstring (one-line strings).
(defun dgen_applyPickedSelection (formSym chosen "sg")
  (let (master lib cell)
    (cond
      ((null chosen)
        (hiDisplayAppDBox
          ?name 'dgenSelEmpty
          ?dboxBanner "Select from Schematic"
          ?dboxText "No instance at click point. Try again -- click directly on an instance body."
          ?dialogType hicWarningDialog
          ?buttonLayout 'Close)
        nil)
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
            ; Populate combos via infix `=` (setq cannot write through
            ; ~> per skill-gotchas). evalstring strings MUST be
            ; one-liners (per reference_skillbridge_evalstring).
            (evalstring (sprintf nil "dgen_form->dgen_srcLib->value = \"%s\"" lib))
            (evalstring (sprintf nil "dgen_form->dgen_srcCell->value = \"%s\"" cell))
            (evalstring "dgen_form->dgen_srcView->value = \"symbol\"")
            ; Trigger load flow. dgenGui_loadCB now defers the actual
            ; close+reopen via hiRegTimer (Bug 3 fix), so calling it
            ; from this enterPoint-doneProc context is safe -- no risk
            ; of "delete a form from within its callback" warnings.
            (dgenGui_loadCB dgen_form)
            t))))))

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
; Bug fix (live test, dgenBrowseFail dialog -- CDS.log):
;   "*WARNING* ddsSyncWithForm: dgen_srcLib not a field on form nil"
; Root cause: we were passing 'dgen_form (a quoted symbol). The
; documented example (skdfref.pdf p.1905-1906, "Example 1") passes the
; form RECORD itself (unquoted, e.g. exampleOpenForm), not its name.
; Resolving the symbol's value yields the live form record, which is
; what ddsSyncWithForm expects per the g_form arg description.
;
; The action remains 'browse: per skdfref.pdf p.1904 'browse is one of
; the documented values for s_action (alongside 'design/'open/'place/
; 'other), and Example 1 in the same chapter uses
;   ddsSyncWithForm( exampleOpenForm 'browse ... )
; verbatim for the [Browse...] button. So the action was never the bug.
;
; Ref: skdfref.pdf p.1904-1907 (ddsSyncWithForm),
;      p.1909 (ddsEndSyncWithForm).
(defun dgenGui_browseCB (form "g")
  (let (rc)
    ; Signature (skdfref.pdf p.1904):
    ;   ddsSyncWithForm(g_form s_action s_libField
    ;                   [s_cellField] [s_viewField] [l_viewTypes])
    ; Pass the form RECORD as the first arg (per Example 1, p.1905-1906)
    ; -- the caller already received this as `form`. The field args
    ; remain quoted symbols (their on-form names).
    ;
    ; We deliberately OMIT the optional l_viewTypes arg so the LM tree
    ; shows ALL views (default Cadence behavior -- no filtering). An
    ; earlier rev passed (list "schematic" "symbol") here, but that
    ; filter HIDES any view not in the list (e.g. a cell with only
    ; "schematic" appears to have no other views, and a cell with
    ; only "veriloga"+"symbol" loses the veriloga entry). The user's
    ; live feedback was "Library能打开了，但是里面有的cell好像显示不全？
    ; 例如 test_cell我只能看见schematic" -- exactly the symptom of
    ; the filter. Dropping it lets the user see everything.
    (setq rc (errset
               (ddsSyncWithForm
                 form
                 'browse
                 'dgen_srcLib
                 'dgen_srcCell
                 'dgen_srcView)
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
    (setq rowH 30)
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
              'defaultPattern "d_*"
              'pins           pins
              'customVars     nil))
            (setq lastState (dgenLoadLastState))
            (setq currentSpec (dgen_resolveCurrentSpec factorySpec lastState dutCell))
            ; CustomVars: consume the one-shot dgen_preserveCvs flag.
            ; Set to t by [+ Digital]/[+ Analog]/[Delete] callbacks just
            ; before they schedule the deferred reopen -- preserves the
            ; user's in-flight edits across the close-rebuild cycle.
            ; All other paths leave the flag at nil so the form opens with
            ; a clean customVars slate (per the policy in the
            ; dgen_currentCustomVars header comment).
            (cond
              ((and (boundp 'dgen_preserveCvs) dgen_preserveCvs) nil)
              (t (setq dgen_currentCustomVars nil)))
            (setq dgen_preserveCvs nil)
            ; Splice the resolved customVars list (kept or freshly nil-ed
            ; above) into currentSpec so dgen_buildMiddleFields lays out
            ; the right rows -- it iterates (get currentSpec 'customVars).
            (setq currentSpec (dgen_specWithCustomVars currentSpec dgen_currentCustomVars))
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
            ; Target lib+cell combos: 2-arg form (no view triplet on the
            ; target side -- target view is fixed/inferred by callers).
            ; Probed live: 2-arg call returns t cleanly (skuiref.pdf p.495).
            (errset (ddHiLinkFields form->dgen_tgtLib form->dgen_tgtCell) t)
            (dgen_displayFormApplyPending form 'dgen_form)
            'dgen_form)))
      (t
        ; DUT-less path. Reset per-pin state. Pre-fill combos from v2
        ; last-state when present (don't auto-render -- wait for user
        ; to confirm via [Load Pins] / [Select from Schematic] / [Browse]).
        (setq dgen_currentPins nil)
        (setq dgen_currentCustomVars nil)
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
        (dgen_displayFormApplyPending form 'dgen_form)
        'dgen_form))))

; ---------------------------------------------------------------------------
; MyTool plugin registration
; ---------------------------------------------------------------------------
;
; Self-register on load so the framework's MyTool pulldown gains a "Dreg
; Generator" entry on every attached schematic / Maestro / ADE-XL window.
; Guarded with `getd` (NOT functionp -- functionp on an undefined symbol
; can raise rather than return nil); plugin still loads cleanly when
; mytool/ is not present.
;
; Ref: workarea/skill_tools/mytool/README.md (Plugin registration pattern).
(when (getd 'mtRegister)
  (mtRegister "Dreg Generator" 'dgenOpenGUI "Open the Dreg-Generator GUI"))
