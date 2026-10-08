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
; Transient timing (dgenTiming.il / dgenTimingGui.il):
;   * Each pin row has a Digital/Analog switch (analog = drive a voltage,
;     e.g. ramp a VDD; bus pins stay digital) and a read-only timing
;     summary ("DC" / "3 edges 5n..120n").
;   * [Timing Table...] opens the timing editor; its rows live in
;     dgen_currentTiming until the form generates.
;   * Generation embeds the full spec in the dreg (dgen_saveConfigProp),
;     so a dreg can be reopened for editing: pick it like a DUT (type it
;     as Source + [Load Pins], [Select from Schematic] on an instance,
;     or open the GUI with exactly one dreg instance selected). The form
;     then shows the dreg's real DUT, pins, custom variables and timing,
;     with Target = that dreg.
;   * OK/Apply overwrite the Target cell ("Save"). If that changes the
;     timing of an existing dreg, a Yes/No confirm warns that every
;     testbench using it changes too. [Save As...] writes a new cell and
;     can switch the instance the edit started from to it.
;
; Buttons (?buttonLayout 'OKCancelDefApply):
;   OK / Apply -> dgenGui_okCB -> dgen_generate: read fields -> validate
;                 (custom variables, analog pins, timing) -> overwrite
;                 confirm -> dgenRun -> save last-state -> result dialog.
;                 Validation errors / "No" keep the form open
;                 (?unmapAfterCB t + hiSetCallbackStatus).
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
; PERSISTENCE POLICY. customVars are NOT kept in the per-user last-state
; file (they are user-typed for a specific dreg, not DUT-shape config).
; They do persist as part of a generated dreg's embedded config, because
; they are ports of that cell: reopening an existing dreg (or a DUT whose
; target dreg already exists) restores them, so regenerating never
; silently drops a port a testbench is wired to. A fresh DUT with no
; dreg yet starts with an empty list.
;
; Internal close-reopens ([+ Digital] / [+ Analog] / [Delete] /
; [Load Pins] on the same DUT) carry the whole in-flight spec across the
; rebuild in dgen_pendingSpec -- a one-shot slot consumed (cleared) by the
; next dgenOpenGUI, used only when its 'source matches the DUT being
; opened.
(unless (boundp 'dgen_currentCustomVars) (setq dgen_currentCustomVars nil))
(unless (boundp 'dgen_pendingSpec)       (setq dgen_pendingSpec       nil))

; Timing rows of the open form (see dgenTiming.il for the row shape).
; Seeded at dgenOpenGUI from the dreg's embedded config / pending spec,
; edited by the [Timing Table...] editor, read by dgen_readForm.
(unless (boundp 'dgen_currentTiming)     (setq dgen_currentTiming     nil))
; Timing variables of the open form ((nil 'name "T0" 'default "5n") ...),
; edited in the Timing Table's Variables box; same lifecycle as
; dgen_currentTiming.
(unless (boundp 'dgen_currentTimingVars) (setq dgen_currentTimingVars nil))

; Schematic instance the current edit session started from (a dreg
; instance picked via [Select from Schematic] or selected when the GUI
; opened), or nil. [Save As...] offers to switch it to the new cell.
(unless (boundp 'dgen_editInst)          (setq dgen_editInst          nil))

; Per-pin literal cache. Parallel to dgen_currentPins. Holds the user's
; numeric literal default for each pin so that mode-toggling (literal
; <-> variable_pin / custom / empty) doesn't clobber it: in non-literal
; modes the per-pin "value" field is repurposed to show the resolved
; variable name (e.g. EN, d_EN) as a read-only hint, so its raw ->value
; can no longer be trusted as the user's literal. dgen_readForm reads
; the cache when defaultMode != "literal".
;
; dgen_pinFieldsAreLit mirrors the last-known enabled state of the per-
; pin "value" fields. Initialised in dgen_buildMiddleFields and updated
; in dgenGui_modeCB; the modeCB uses the *previous* value to decide
; whether the current field contents are a literal worth caching (true)
; or a stale variable-name hint that should be discarded (false).
(unless (boundp 'dgen_pinLiteralCache)   (setq dgen_pinLiteralCache   nil))
(unless (boundp 'dgen_pinFieldsAreLit)   (setq dgen_pinFieldsAreLit   t))

; Scratch global for evalstring slot-writes -- evalstring runs at top-
; level scope so a let-bound local would not be visible; the global is
; read+cleared per write.
(unless (boundp 'dgen_tmpFieldVal)       (setq dgen_tmpFieldVal       ""))

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

; Per-row Digital/Analog switch (pins only) and read-only timing summary
; (pins + customVars).
(defun dgen_pinKindId (idx "n") (concat 'dgen_pin_kind_ idx))
(defun dgen_pinTmId   (idx "n") (concat 'dgen_pin_tm_   idx))
(defun dgen_cvTmId    (idx "n") (concat 'dgen_cv_tm_    idx))

; Kind <-> cyclic label. Absent / unknown kind reads as Digital.
(defun dgen_kindToLabel (kind "g")
  (cond ((equal kind "analog") "Analog") (t "Digital")))
(defun dgen_labelToKind (label "g")
  (cond ((equal label "Analog") "analog") (t "digital")))

; Timing summary text for one signal name.
(defun dgen_rowTimingSummary (name "g")
  (dgen_tmSummary (dgen_tmRowsFor dgen_currentTiming name dgen_currentTimingVars)))

; Compute the per-pin "value" field's display string for a given mode.
; In literal mode the field is editable and shows the user's number; in
; every other mode the field is greyed and shows the *resolved* variable
; name that dgen_resolveDefValue would emit, so the user sees a faithful
; preview of what ends up in the generated cell.
;
;   mode == "literal"      -> literal (user-typed number)
;   mode == "empty"        -> ""           (parameter default is empty)
;   mode == "variable_pin" -> pin name     (parameter default is the pin name)
;   mode == "custom"       -> pattern with '*' substituted by pin name;
;                             empty/nil pattern collapses to "d_*" to
;                             mirror dgen_readForm's auto-fill at OK time
;   else                   -> literal     (back-compat, treat unknown like literal)
(defun dgen_pinResolvedDisplay (mode pattern pinName literal "ggtg")
  (cond
    ((equal mode "literal")      (or literal "0"))
    ((equal mode "empty")        "")
    ((equal mode "variable_pin") pinName)
    ((equal mode "custom")
      (dgen_substStar
        (cond ((or (null pattern) (equal pattern "")) "d_*") (t pattern))
        pinName))
    (t (or literal "0"))))

; Set a form field's ->value at runtime. setq cannot write through an
; arrow expression (skuiref.pdf p.806 commentary) so we stage the value
; in a top-level scratch symbol and let evalstring do the slot write.
; Returns t on success, nil if the field record is missing (form X-
; closed mid-callback).
(defun dgen_setFieldValue (fieldSym val "gg")
  (cond
    ((and (boundp 'dgen_form) dgen_form (get dgen_form fieldSym))
      (setq dgen_tmpFieldVal val)
      (errset
        (evalstring (sprintf nil "dgen_form->%s->value = dgen_tmpFieldVal"
                                  (symbolToString fieldSym)))
        t)
      t)
    (t nil)))

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

; Return a copy of `spec` with its 'customVars slot replaced by `cvs`
; (every other key, incl. 'timing, preserved).
(defun dgen_specWithCustomVars (spec cvs "gl")
  (dgen_plistPut spec 'customVars cvs))

; Analog pins drive their value as a voltage, so it must be a number or a
; design-variable name (same rule as analog customVars). Returns nil or
; an error string. Digital pins keep the legacy permissive handling.
(defun dgen_validatePins (spec "g")
  (let (msg d)
    (foreach p (get spec 'pins)
      (when (and (null msg) (get p 'enabled)
                 (equal (get p 'kind) "analog") (null (get p 'isBus)))
        (setq d (or (get p 'default) ""))
        (unless (or (pcreMatchp "^-?[0-9]+(\\.[0-9]+)?$" d)
                    (pcreMatchp "^[A-Za-z_][A-Za-z0-9_]*$" d))
          (setq msg (sprintf nil
            "Analog pin '%s' value '%s' is neither a number nor a variable name. Use e.g. 1.8 or VDDA."
            (get p 'name) d)))))
    msg))

; Main form title: "Dreg Generator -- <DUT lib/cell>  ->  <target lib/cell>".
; Ref: skuiref.pdf p.500 (hiChangeFormTitle) for the post-generate update.
(defun dgen_formTitle (spec "g")
  (let ((s (get spec 'source)) (tg (get spec 'target)))
    (sprintf nil "Dreg Generator -- %s/%s  ->  %s/%s%s"
      (or (get s 'lib) "?") (or (get s 'cell) "?")
      (or (get tg 'lib) "?") (or (get tg 'cell) "?")
      (dgen_viewSuffix (get tg 'view)))))

; " [veriloga_RX]" for a timing view, "" for the main view.
(defun dgen_viewSuffix (view "g")
  (cond
    ((and (stringp view) (nequal view dgen_mainView)) (sprintf nil "  [%s]" view))
    (t "")))

; Timing view being edited, as (lib cell view); nil = the main view.
; Set when a timing view is opened for editing or created by Save As;
; reset when a dreg is (re)loaded as Source.
(unless (boundp 'dgen_editViewOf) (setq dgen_editViewOf nil))

; View the form writes for target lib/cell: the edited timing view while
; the target is still that cell, else the main view.
(defun dgen_targetViewFor (lib cell "gg")
  (cond
    ((and dgen_editViewOf (equal (car dgen_editViewOf) lib)
          (equal (cadr dgen_editViewOf) cell))
      (caddr dgen_editViewOf))
    (t dgen_mainView)))

; Does spec's 'source point at lib/cell?
(defun dgen_sourceIs (spec lib cell "ggg")
  (let ((s (get spec 'source)))
    (and s (equal (get s 'lib) lib) (equal (get s 'cell) cell))))

; Is `inst` a live instance whose master is lib/cell?
(defun dgen_instIsOf (inst lib cell "ggg")
  (and inst (dbValidP inst) (equal inst~>objType "inst")
       (equal inst~>libName lib) (equal inst~>cellName cell)))

(defun dgen_instUsable (inst "g")
  (and inst (dbValidP inst) (equal inst~>objType "inst")))

; Build the form's current spec from a stored spec `src` (a dreg's
; embedded config, or the pending in-flight spec of an internal reopen),
; overlaid on the freshly scanned DUT pins: pins keep their stored
; enable/value/kind by name; pins new to the DUT get factory defaults;
; stored pins the DUT no longer has are dropped.
(defun dgen_specFromSource (factorySpec src "gg")
  (let (migrated pins srcPins)
    (setq srcPins (get src 'pins))
    (setq migrated (dgen_migrateModePattern
                     (or (get src 'defaultMode) "literal") (get src 'defaultPattern)))
    (setq pins
      (mapcar
        (lambda (p)
          (let ((m (car (setof q srcPins (equal (get q 'name) (get p 'name))))))
            (cond
              ; enabled coerced to t/nil: hiCreateBooleanButton rejects
              ; anything else, and a config written by a script may
              ; carry e.g. a member() tail.
              (m (append p (list 'enabled (and (get m 'enabled) t)
                                 'default (or (get m 'default) "0")
                                 'kind    (or (get m 'kind) "digital"))))
              (t (append p (list 'enabled (dgen_factoryEnabledP p)
                                 'default "0" 'kind "digital"))))))
        (get factorySpec 'pins)))
    (list nil
      'source         (get factorySpec 'source)
      'target         (or (get src 'target) (get factorySpec 'target))
      'dvddDefault    (or (get src 'dvddDefault) (get factorySpec 'dvddDefault))
      'defaultMode    (car migrated)
      'defaultPattern (or (cadr migrated) "d_*")
      'pins           pins
      'customVars     (get src 'customVars)
      'timing         (get src 'timing)
      'timingVars     (get src 'timingVars))))

; Pick the spec the form opens with, consuming dgen_pendingSpec:
;   1. pending in-flight spec of an internal reopen / dreg pick (same DUT)
;   2. the embedded config of the resolved target cell, when that dreg
;      already exists and was made from this DUT -- so reopening the tool
;      on a DUT brings back the timing of its dreg instead of silently
;      regenerating it as pure DC
;   3. last-state overlay (legacy behaviour: no customVars, no timing)
(defun dgen_seedSpec (factorySpec lastState dutLib dutCell "ggtt")
  (let (pending base tgt cfg)
    (setq pending dgen_pendingSpec)
    (setq dgen_pendingSpec nil)
    (setq base (dgen_resolveCurrentSpec factorySpec lastState dutCell))
    (cond
      ((and pending (dgen_sourceIs pending dutLib dutCell))
        (dgen_specFromSource factorySpec pending))
      (t
        (setq tgt (get base 'target))
        (setq cfg (dgen_dregConfigOf (get tgt 'lib) (get tgt 'cell)))
        (cond
          ((and cfg (dgen_sourceIs cfg dutLib dutCell))
            (printf "[dreg-gen] %s/%s already exists -- loaded its settings (%d timing row(s), %d custom variable(s))\n"
              (get tgt 'lib) (get tgt 'cell)
              (length (get cfg 'timing)) (length (get cfg 'customVars)))
            (dgen_specFromSource factorySpec (dgen_plistPut cfg 'target tgt)))
          (t base))))))

; Pins of the DUT, or -- when the DUT can't be opened but we're reopening
; a dreg whose config carries the pin list -- the stored pin shapes.
(defun dgen_scanPinsOr (lib cell view "ttt")
  (let ((r (errset (dgenScanPins lib cell view) nil)))
    (cond
      ((and r (car r)) (car r))
      ((and dgen_pendingSpec (dgen_sourceIs dgen_pendingSpec lib cell))
        (warn "[dreg-gen] cannot open DUT %s/%s/%s -- using the pin list stored in the dreg\n"
          lib cell view)
        (mapcar
          (lambda (p)
            (list nil 'name (get p 'name) 'isBus (get p 'isBus)
                  'busHi (get p 'busHi) 'busLo (get p 'busLo)
                  'srcDirection (get p 'srcDirection)))
          (get dgen_pendingSpec 'pins)))
      (t nil))))

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
; mapping), so dgen_buildMiddleFields / dgen_readForm / dgenGui_modeCB
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
              ; pinStates tuple: (name enabled default [kind]) -- kind is
              ; absent in files written before the Digital/Analog switch.
              (cond
                (match
                  (append p (list 'enabled  (cadr  match)
                                  'default  (caddr match)
                                  'kind     (or (nth 3 match) "digital"))))
                (t
                  (append p (list 'enabled (dgen_factoryEnabledP p)
                                  'default "0"
                                  'kind    "digital")))))
            factoryPins))
        ; Migrate legacy "variable" mode silently (see dgen_migrateModePattern
        ; header). lastState wins over factorySpec only when lastState
        ; actually has a value for the field.
        (setq rawMode (or (get lastState 'defaultMode)    (get factorySpec 'defaultMode)))
        (setq rawPat  (or (get lastState 'defaultPattern) (get factorySpec 'defaultPattern)))
        (setq migrated (dgen_migrateModePattern rawMode rawPat))
        ; CustomVars / timing are NOT pulled from lastState (see the
        ; dgen_currentCustomVars header for the policy): resolveCurrentSpec
        ; returns customVars=nil and no timing; dgen_seedSpec swaps in a
        ; pending spec or the target dreg's embedded config when one
        ; applies.
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
  (let (fTgt cTgt pins cPins fields i y fieldW promptW sizePt pats)
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
    ; [Save As...] -- generate into a NEW cell (keeps the current target
    ; untouched) and optionally re-point the edited instance at it.
    (setq fields (cons
      (list (hiCreateButton ?name 'dgen_btnSaveAs
              ?buttonText "Save As..."
              ?callback "(dgenGui_saveAsCB dgen_form)")
            (list (plus fieldW 10) y) (list 100 rowH) 0)
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
    ; Transient timing: one editor for every signal + a one-line summary.
    ; The per-row summaries further down show each signal's share.
    (when pins
      (setq fields (cons
        (list (hiCreateButton ?name 'dgen_btnTiming
                ?buttonText "Timing Table..."
                ?callback "(dgenGui_timingCB dgen_form)")
              (list 0 y) (list 130 rowH) 0)
        fields))
      (setq fields (cons
        (list (hiCreateStringField ?name 'dgen_tmTableF ?prompt ""
                ?defValue (dgen_tmTableSummary (get currentSpec 'timing) (get currentSpec 'timingVars))
                ?value    (dgen_tmTableSummary (get currentSpec 'timing) (get currentSpec 'timingVars))
                ?editable nil)
              (list 140 y) (list 370 rowH) 0)
        fields))
      (setq y (plus y rowH)))
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
    ;
    ; Field-value strategy: when defaultMode is "literal" the value field
    ; is editable and shows the user-typed number (curDef). In every
    ; other mode the field is greyed and instead shows the resolved
    ; variable name (pin name / d_PIN / pattern-substituted / "") so
    ; the user can see what will actually be emitted into the generated
    ; cell -- replaces the legacy display which kept showing a stale,
    ; ignored literal. We snapshot curDef into dgen_pinLiteralCache so
    ; later mode-toggles can restore it.
    ; SKILL has no let* -- nest two lets so curPattern can be derived
    ; independently and litMode can derive from curMode in the inner
    ; binding list. (See dgenStore.il:90 / PLAN.md:187 for the rule.)
    (let ((curMode    (or (get currentSpec 'defaultMode)    "literal"))
          (curPattern (or (get currentSpec 'defaultPattern) "d_*")))
     (let ((litMode (equal curMode "literal")))
      (setq dgen_pinLiteralCache nil)
      (setq dgen_pinFieldsAreLit litMode)
      (setq i 0)
      (foreach p pins
        (let ((enId (dgen_pinEnableId i))
              (defId (dgen_pinDefaultId i))
              (display (dgen_pinDisplayName p))
              (cat (dgenPatternsClassify p pats))
              (factoryEn (dgen_factoryEnabledP p))
              (curEn  (dgen_pinFieldOr cPins (get p 'name) 'enabled (dgen_factoryEnabledP p)))
              (curDef (dgen_pinFieldOr cPins (get p 'name) 'default "0"))
              (curKind (dgen_pinFieldOr cPins (get p 'name) 'kind "digital"))
              displayVal)
          (setq dgen_pinLiteralCache (cons curDef dgen_pinLiteralCache))
          (setq displayVal
            (dgen_pinResolvedDisplay curMode curPattern (get p 'name) curDef))
          (setq fields (cons
            (list (hiCreateBooleanButton
                    ?name enId
                    ?buttonText (dgen_pinButtonText display cat)
                    ?defValue (and factoryEn t)
                    ?value    (and curEn t))
                  (list 0 y) (list 200 rowH) 0)
            fields))
          (setq fields (cons
            (list (hiCreateStringField
                    ?name defId
                    ?prompt "value"
                    ?defValue "0"
                    ?value    displayVal
                    ?enabled  litMode)
                  (list 210 y) (list 160 rowH) 50)
            fields))
          ; Digital / Analog. Analog drives the value as a voltage (no
          ; DVDD scaling) -- e.g. to ramp a supply. Bus pins are always
          ; digital (bit-decomposed), so their switch is locked.
          (setq fields (cons
            (list (hiCreateCyclicField
                    ?name (dgen_pinKindId i)
                    ?prompt ""
                    ?choices (list "Digital" "Analog")
                    ?defValue "Digital"
                    ?value (cond ((get p 'isBus) "Digital")
                                 (t (dgen_kindToLabel curKind)))
                    ?enabled (null (get p 'isBus)))
                  (list 380 y) (list 95 rowH) 0)
            fields))
          ; Read-only timing summary for this pin ("DC" / "3 edges ...").
          (setq fields (cons
            (list (hiCreateStringField
                    ?name (dgen_pinTmId i)
                    ?prompt ""
                    ?defValue (dgen_tmSummary (dgen_tmRowsFor (get currentSpec 'timing) (get p 'name) (get currentSpec 'timingVars)))
                    ?value    (dgen_tmSummary (dgen_tmRowsFor (get currentSpec 'timing) (get p 'name) (get currentSpec 'timingVars)))
                    ?editable nil)
                  (list 485 y) (list 175 rowH) 0)
            fields))
          (setq y (plus y rowH)))
        (setq i (add1 i)))
      ; Cache was consed back-to-front; reverse so index i lines up with
      ; pin index i (same indexing used by dgen_pinDefaultId / readForm).
      (setq dgen_pinLiteralCache (reverse dgen_pinLiteralCache))))

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
          ; Timing summary, aligned with the pin rows' summary column.
          (setq fields (cons
            (list (hiCreateStringField
                    ?name (dgen_cvTmId i)
                    ?prompt ""
                    ?defValue (dgen_tmSummary (dgen_tmRowsFor (get currentSpec 'timing) (or (get cv 'name) "") (get currentSpec 'timingVars)))
                    ?value    (dgen_tmSummary (dgen_tmRowsFor (get currentSpec 'timing) (or (get cv 'name) "") (get currentSpec 'timingVars)))
                    ?editable nil)
                  (list 485 y) (list 175 rowH) 0)
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
    ; Per-pin default: in non-literal modes the "value" field has been
    ; repurposed as a read-only hint that displays the resolved variable
    ; name, NOT the user's literal. Read the literal from
    ; dgen_pinLiteralCache instead so a save->reopen round-trip preserves
    ; the user's typed number (cache is populated at form build and
    ; refreshed by dgenGui_modeCB on literal->variable transitions).
    (setq outPins nil)
    (setq i 0)
    (foreach pin pins
      (setq enabled (dgen_fieldVal form (dgen_pinEnableId i)))
      (setq deflt
        (cond
          ((equal mode "literal") (dgen_fieldVal form (dgen_pinDefaultId i)))
          (t (or (nth i dgen_pinLiteralCache)
                 (dgen_fieldVal form (dgen_pinDefaultId i))
                 "0"))))
      ; Kind from the Digital/Analog switch; bus pins are always digital.
      ; A missing field (form built by an older caller) reads as digital.
      (setq outPins (cons
        (append pin (list 'enabled enabled 'default deflt
                          'kind (cond
                                  ((get pin 'isBus) "digital")
                                  (t (dgen_labelToKind
                                       (dgen_fieldVal form (dgen_pinKindId i)))))))
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
      'target       (list nil 'lib tgtLib 'cell tgtCell 'view (dgen_targetViewFor tgtLib tgtCell))
      'dvddDefault  dvdd
      'defaultMode  mode
      'defaultPattern pattern
      'pins         (reverse outPins)
      'customVars   (reverse outCvs)
      ; Timing rows + variables are edited in the Timing Table form, not
      ; in fields of this one; they ride along from the module globals.
      'timing       dgen_currentTiming
      'timingVars   dgen_currentTimingVars)))

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
        (list (get p 'name) (get p 'enabled) (or (get p 'default) "0")
              (or (get p 'kind) "digital"))
        pinStates)))
    ; CustomVars and timing are NOT written to lastState (see the
    ; dgen_currentCustomVars header): the per-user file only carries
    ; DUT/pin configuration. Both persist with the generated dreg itself
    ; (embedded config), where every user of that cell can get them back.
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

; Warning dialog helper (modal, Close button).
; Ref: skuiref.pdf p.309 (hiDisplayAppDBox).
(defun dgen_warnBox (text @optional (banner "Dreg Generator"))
  (hiDisplayAppDBox
    ?name 'dgen_warnDBox
    ?dboxBanner banner
    ?dboxText text
    ?dialogType hicWarningDialog
    ?buttonLayout 'Close)
  nil)

; Result dialog for a dgen_generate result (status msg).
(defun dgen_showResult (res "l")
  (when (cadr res)
    (hiDisplayAppDBox
      ?name 'dgen_resultDBox
      ?dboxBanner "Dreg Generator"
      ?dboxText (cadr res)
      ?dialogType (cond ((eq (car res) 'ok) hicInformationDialog)
                        (t hicWarningDialog))
      ?buttonLayout 'Close))
  t)

; Before overwriting an EXISTING target whose timing would change, ask:
; the timing is baked into the cell, so every testbench instantiating it
; simulates the new waveform. Unchanged timing (the usual "DUT pins
; changed, regenerate" case) and brand-new cells pass silently. A legacy
; dreg (no embedded config) counts as "no timing".
; Returns t to proceed, nil when the user answered No.
; Ref: skuiref.pdf p.309-316 (hiDisplayAppDBox: modal 'YesNo returns t for
;      Yes, nil for No).
(defun dgen_confirmOverwrite (spec "g")
  (let ((tgt (get spec 'target)) lib cell view old)
    (setq lib  (get tgt 'lib))
    (setq cell (get tgt 'cell))
    (setq view (or (get tgt 'view) dgen_mainView))
    (cond
      ((not (and (stringp lib) (stringp cell) (ddGetObj lib cell))) t)
      ; A timing view that doesn't exist yet: nothing to overwrite.
      ((null (setq old (dgen_dregViewSpec lib cell view))) t)
      ((and (dgen_tmTimingEqual (get old 'timing) (get spec 'timing))
            (dgen_tmVarsEqual (get old 'timingVars) (get spec 'timingVars)))
        t)
      (t
        (hiDisplayAppDBox
          ?name 'dgen_overwriteDBox
          ?dboxBanner "Dreg Generator -- overwrite timing?"
          ?dboxText (sprintf nil
            "%s/%s%s already exists and its timing will change.\n\nEvery testbench that simulates this %s will use the NEW timing.\n\nYes = overwrite\nNo  = go back (use [Save As...] to write a separate cell or timing view and keep this one)"
            lib cell (cond ((equal view dgen_mainView) "") (t (strcat " view " view)))
            (cond ((equal view dgen_mainView) "cell") (t "view")))
          ?dialogType hicQuestionDialog
          ?buttonLayout 'YesNo
          ?defaultButton 2)))))

; Saving a timing view: the cell must already be a dreg of this tool and
; only the timing may differ from its main view. nil when fine / not a
; timing view.
(defun dgen_viewSaveErr (spec "g")
  (let ((tgt (get spec 'target)) main)
    (cond
      ((equal (or (get tgt 'view) dgen_mainView) dgen_mainView) nil)
      ((null (setq main (dgen_dregConfigOf (get tgt 'lib) (get tgt 'cell))))
        (sprintf nil "%s/%s has no main view made by the Dreg Generator -- generate it first, then add timing views."
          (get tgt 'lib) (get tgt 'cell)))
      (t (dgen_viewCompatErr spec main)))))

; Read the form, validate, confirm, generate. Shows validation / confirm
; dialogs itself but NOT the final result dialog -- returns (status msg):
;   'ok    -- generated; msg = success text
;   'warn  -- cell generated but netlist.oa missing; msg explains
;   'fail  -- generation failed; msg points at the CIW
;   'abort -- nothing written (bad input or user said No); msg nil
; Shared by OK/Apply (dgenGui_okCB) and [Save As...].
(defun dgen_generate (form "g")
  (cond
    ((null dgen_currentPins)
      (dgen_warnBox "No DUT loaded. Pick a Lib/Cell and click [Load Pins] first.")
      (list 'abort nil))
    (t
      (let (spec err tres warns srcPlist tgtLib tgtCell tgtView cellOk oaPath oaOk
            libObj msg extra)
        (setq spec (dgen_readForm form dgen_currentPins))
        ; Validation happens BEFORE dgenRun so a bad name / value / timing
        ; row halts at the GUI boundary rather than producing a broken
        ; cellview. First problem wins; dialog is clearer than a dump.
        (setq err (or (dgen_validateCustomVars spec) (dgen_validatePins spec)
                      (dgen_viewSaveErr spec)))
        (unless err
          (setq tres (dgen_validateTiming spec))
          (setq err (car tres))
          (setq warns (cadr tres)))
        (cond
          (err
            (dgen_warnBox err "Dreg Generator -- please fix")
            (list 'abort nil))
          ((null (dgen_confirmOverwrite spec))
            (list 'abort nil))
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
            (setq tgtView (or (get (get spec 'target) 'view) dgen_mainView))
            (setq cellOk
              (and (ddGetObj tgtLib tgtCell "symbol")
                   (ddGetObj tgtLib tgtCell tgtView)))
            ; Independent post-condition for the netlist.oa step. Without
            ; this file Maestro/ADE-XL fail with OSSHNL-381 even though the
            ; symbol+veriloga views are present. Surface this distinctly
            ; rather than reporting plain success -- otherwise users hit
            ; the netlist err and resort to manual Check&Save, which
            ; clobbers our CDF defaults via auto-CDF.
            (setq libObj (ddGetObj tgtLib))
            (setq oaPath
              (when libObj
                (strcat libObj~>readPath "/" tgtCell "/" tgtView "/netlist.oa")))
            (setq oaOk (and oaPath (isFile oaPath)))
            ; Timing line + non-fatal timing notes for the result dialog.
            (setq extra "")
            ; Count only rows that were actually emitted (valid rows of
            ; enabled signals). SKILL's append takes exactly 2 lists, so
            ; flatten the (item rows) pairs with a loop.
            (when (get spec 'timing)
              (let (emitted)
                (foreach pr (dgen_tmTimedPairs spec)
                  (setq emitted (append emitted (cadr pr))))
                (setq extra (sprintf nil "\n\nTiming: %s." (dgen_tmTableSummary emitted (dgen_tmUsedVars spec))))
                ; Timing variables become design variables of the testbench.
                (when (dgen_tmUsedVars spec)
                  (setq extra (strcat extra (sprintf nil
                    "\nDesign variables to set in ADE / Maestro (Copy From Cellview picks them up): %s"
                    (buildString
                      (mapcar (lambda (v) (get v 'name)) (dgen_tmUsedVars spec))
                      ", ")))))))
            (when warns
              (foreach w warns (printf "[dreg-gen] timing: %s\n" w))
              (setq extra (strcat extra "\n\nNotes:\n- " (buildString warns "\n- "))))
            (when cellOk
              (setq srcPlist (get spec 'source))
              (errset (dgenSaveLastState
                        (dgen_specToLastState spec dgen_currentDutCell)
                        srcPlist) t))
            ; The form now edits the cell it just wrote (matters after
            ; [Save As...] or a hand-edited Target Cell).
            (when cellOk
              (errset (hiChangeFormTitle form (dgen_formTitle spec)) t))
            (cond
              ((and cellOk oaOk (nequal tgtView dgen_mainView))
                (setq msg (sprintf nil
                  "Saved timing view %s of %s/%s.%s\n\nSame symbol as %s. To simulate this view, either\n- put %s before %s in the switch view list\n  (ADE L: Setup > Environment; Maestro: the test's Environment Options), or\n- in a config, set View to Use = %s for cell %s."
                  tgtView tgtLib tgtCell extra dgen_mainView tgtView dgen_mainView tgtView tgtCell))
                (list 'ok msg))
              ((and cellOk oaOk)
                (setq msg (sprintf nil "Generated %s/%s successfully.%s"
                  tgtLib tgtCell extra))
                (list 'ok msg))
              (cellOk
                ; Cellviews landed but netlist.oa is missing. Maestro will
                ; fail with OSSHNL-381. Most common cause is the AMS license
                ; not being available -- see CIW for the dgen_compileVerilogA
                ; warn line for details.
                (setq msg (sprintf nil
                  "Generated %s/%s, but netlist.oa was NOT produced.\n\nMaestro/ADE-XL will fail with OSSHNL-381 until this is fixed.\n\nLikely cause: AMS Designer license not available (amsIsPresent=nil) or amsUpdateTextviews/vmsUpdateCellViews failed. See CIW for the warn from dgen_compileVerilogA.%s"
                  tgtLib tgtCell extra))
                (list 'warn msg))
              (t
                (list 'fail (sprintf nil "Failed to generate %s/%s. See CIW for details."
                              tgtLib tgtCell))))))))))

; OK / Apply callback. Generation + result dialog; on 'abort / 'fail the
; form stays open so the user can fix the input without losing it
; (hiSetCallbackStatus, which needs ?unmapAfterCB t on the form). The
; status is a toggle that must be reset to t on every entry.
; Ref: skuiref.pdf p.801 (hiSetCallbackStatus), p.505 (?unmapAfterCB).
(defun dgenGui_okCB (form "g")
  (let (res r)
    (errset (hiSetCallbackStatus form t) t)
    ; Any unexpected SKILL error inside generation must not make the form
    ; vanish silently (an error escaping a form callback unmaps it with no
    ; dialog): report it and keep the form open.
    (setq r (errset (dgen_generate form) t))
    (setq res (cond
                (r (car r))
                (t (list 'fail "Internal error while generating -- see the CIW for the SKILL error. Your settings are still in this form."))))
    (dgen_showResult res)
    ; Repaint instances dgenRun deselected, after this callback returns.
    (hiRegTimer "(dgen_redrawPending)" 2)
    (cond
      ((memq (car res) '(ok warn)) t)
      (t
        (errset (hiSetCallbackStatus form nil) t)
        nil))))

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
        ; Carry the whole in-flight spec (pins, custom variables, timing)
        ; across the form rebuild; dgenOpenGUI consumes it once.
        (setq updated (dgen_specWithCustomVars sp newCvs))
        (setq dgen_pendingSpec updated)
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
        ; Same one-shot pending spec as dgenGui_addCvCB.
        (setq updated (dgen_specWithCustomVars sp newCvs))
        (setq dgen_pendingSpec updated)
        (setq src    (get updated 'source))
        (errset (dgenSaveLastState
                  (dgen_specToLastState updated dgen_currentDutCell) src) t)
        (hiRegTimer
          (sprintf nil "(dgenGui_deferredReopen \"%s\" \"%s\" \"%s\")"
            dgen_currentDutLib dgen_currentDutCell dgen_currentDutView)
          1)
        t))))

; defaultMode-change callback. Cyclic-field callback signature
; (field scope item) per skuiref.pdf p.538.
;
; `item` is the cyclic field's LABEL string (since ?choices stores
; labels directly per skuiref.pdf p.537), so we translate via
; dgen_labelToMode to compare against canonical mode tokens.
;
; The per-pin "value" field is the user's literal number only in
; "literal" mode -- in the other three modes it doubles as a read-only
; preview of the resolved variable name. So we both flip ?enabled AND
; rewrite ->value here. Cache invariant: dgen_pinLiteralCache[i] always
; holds the user's most recent literal entry, so a literal->variable
; toggle saves the current field value (it was a literal) and a
; variable->literal toggle restores it.
;
; Ref: skuiref.pdf p.806 (hiSetFieldEnabled). We use the dedicated
; setter for ?enabled and the evalstring/scratch-symbol trick for ?value
; because Lisp-form (setq rec->slot v) is rejected (setq's first arg
; must be a symbol).
(defun dgenGui_modeCB (field scope item "ggg")
  (let (newMode isLit isCustom curPattern wasLit i rec patRec
        cached pinName curFieldVal displayVal)
    (setq newMode  (dgen_labelToMode item))
    (setq isLit    (equal newMode "literal"))
    (setq isCustom (equal newMode "custom"))
    (setq wasLit   dgen_pinFieldsAreLit)
    (setq curPattern (or (dgen_fieldVal dgen_form 'dgen_pattern) "d_*"))
    (setq i 0)
    (foreach p dgen_currentPins
      (setq rec (get dgen_form (dgen_pinDefaultId i)))
      (setq pinName (get p 'name))
      (when rec
        (cond
          ; literal -> non-literal: snapshot current field text into cache
          ; (it's still the user's literal, the field hasn't been rewritten
          ; yet) so we can restore it on a later switch back to literal.
          ((and wasLit (null isLit))
            (setq curFieldVal (or (dgen_fieldVal dgen_form (dgen_pinDefaultId i)) "0"))
            (dgen_listSetNth 'dgen_pinLiteralCache i curFieldVal)))
        (setq cached (nth i dgen_pinLiteralCache))
        (when (null cached) (setq cached "0"))
        (setq displayVal
          (dgen_pinResolvedDisplay newMode curPattern pinName cached))
        (dgen_setFieldValue (dgen_pinDefaultId i) displayVal)
        (hiSetFieldEnabled rec isLit))
      (setq i (add1 i)))
    (setq dgen_pinFieldsAreLit isLit)
    ; Pattern field is only meaningful when mode = "custom"; gray it
    ; out otherwise so the user isn't tempted to type a pattern that
    ; will be ignored.
    (when (and (boundp 'dgen_form) dgen_form)
      (setq patRec (get dgen_form 'dgen_pattern))
      (when patRec (hiSetFieldEnabled patRec isCustom)))
    t))

; Destructive list-element setter -- writes val into the idx-th cell of
; the list bound to listSym (a quoted symbol). Used by dgenGui_modeCB to
; mutate dgen_pinLiteralCache in place without rebuilding the whole list
; on every mode toggle. Out-of-range idx is a no-op. Ref: sklangref.pdf
; p.394 (rplaca), p.466 (nthcdr).
(defun dgen_listSetNth (listSym idx val "sng")
  (let ((cell (nthcdr idx (symeval listSym))))
    (when cell (rplaca cell val))
    t))

; defaultPattern-edit callback. String-field callback signature is
; (field scope newValue) per skuiref.pdf p.650. In "custom" mode we
; rewrite each greyed per-pin "value" field with the new pattern
; substitution so the read-only variable-name hint stays in sync; in
; other modes the hint doesn't depend on pattern, so the per-pin walk
; is skipped.
(defun dgenGui_patternCB (field scope newValue "ggg")
  (let (curMode i pinName)
    (setq curMode (dgen_labelToMode (dgen_fieldVal dgen_form 'dgen_mode)))
    (when (equal curMode "custom")
      (setq i 0)
      (foreach p dgen_currentPins
        (setq pinName (get p 'name))
        (dgen_setFieldValue
          (dgen_pinDefaultId i)
          (dgen_pinResolvedDisplay
            "custom"
            (cond ((or (null newValue) (equal newValue "")) "d_*") (t newValue))
            pinName
            (or (nth i dgen_pinLiteralCache) "0")))
        (setq i (add1 i)))))
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
            (dgen_pinEnableId i) (if on "t" "nil")))
          ; Kind suggestion: a scalar supply rail is driven as a voltage
          ; (Analog) if the user enables it; everything else Digital.
          ; Bus switches are locked to Digital, so skip them.
          (unless (get p 'isBus)
            (dgen_setFieldValue (dgen_pinKindId i)
              (cond ((equal cat 'power) "Analog") (t "Digital")))))
        (setq i (add1 i)))))
  t)

; -------- In-place timing-summary refresh -------------------------------
;
; Rewrites the per-row timing summaries + the [Timing Table...] summary
; from dgen_currentTiming. Called by the Timing Table editor's OK; no
; close-reopen. customVar rows are matched by the name currently typed
; in their name field (they may have been renamed since the form opened).
(defun dgen_refreshTimingSummaries ()
  (when (and (boundp 'dgen_form) dgen_form dgen_currentPins)
    (let ((i 0) nm)
      (foreach p dgen_currentPins
        (dgen_setFieldValue (dgen_pinTmId i) (dgen_rowTimingSummary (get p 'name)))
        (setq i (add1 i)))
      (setq i 0)
      (foreach _cv dgen_currentCustomVars
        (setq nm (or (dgen_tmBaseName (or (dgen_fieldVal dgen_form (dgen_cvNameId i)) "")) ""))
        (dgen_setFieldValue (dgen_cvTmId i) (dgen_rowTimingSummary nm))
        (setq i (add1 i)))
      (dgen_setFieldValue 'dgen_tmTableF
        (dgen_tmTableSummary dgen_currentTiming dgen_currentTimingVars))))
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

(defun dgen_displayFormApplyPending (form formSym @optional fields "gsg")
  (let ((pendingLoc dgen_pendingFormLoc)
        (pendingSize dgen_pendingFormSize))
    (setq dgen_pendingFormLoc  nil)
    (setq dgen_pendingFormSize nil)
    (cond
      (pendingSize
        (errset (hiSetFormSize form pendingSize) t))
      (fields
        (dgen_fitFormToFields form fields)))
    (cond
      (pendingLoc (hiDisplayForm formSym pendingLoc))
      (t          (hiDisplayForm formSym)))))

; First open of the full form: Cadence caps a new form at about 400 px
; high, so even a 5-pin DUT needed scrolling. Grow it to fit the field
; layout (each entry is (field (x y) (w h) [promptW])), up to the screen
; height; never shrink.
; Ref: skuiref.pdf p.720 (hiGetFormSize), p.813 (hiSetFormSize),
;      hiGetMaxScreenCoords.
(defun dgen_fitFormToFields (form fields "gl")
  (let ((maxX 0) (maxY 0) cur scr w h xy wh)
    (foreach f fields
      (setq xy (cadr f))
      (setq wh (caddr f))
      (when (and (listp xy) (listp wh) (numberp (car xy)) (numberp (car wh)))
        (setq maxX (max maxX (plus (car xy) (car wh))))
        (setq maxY (max maxY (plus (cadr xy) (cadr wh))))))
    (setq cur (car (errset (hiGetFormSize form) nil)))
    (setq scr (car (errset (hiGetMaxScreenCoords) nil)))
    (when (and cur (greaterp maxY 0))
      ; + room for the OK/Cancel bar and the frame
      (setq w (max (car cur) (plus maxX 30)))
      (setq h (max (cadr cur) (plus maxY 70)))
      (when scr (setq h (min h (difference (cadr scr) 150))))
      (when (or (greaterp w (car cur)) (greaterp h (cadr cur)))
        (errset (hiSetFormSize form (list w h)) t))))
  t)

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
    ; Size the form just large enough that no OUTER scrollbar appears.
    ; Without this, the form viewport defaults to a smaller size than the
    ; stacked MLT panels, Cadence adds its own scrollbar, and a wheel
    ; event over an MLT scrolls BOTH the inner text AND the outer form
    ; simultaneously (Motif wheel-event propagation). Field stack:
    ;   header   y=  0 h= 28
    ;   power    y= 34 h=220
    ;   dreg     y=262 h=220
    ;   reset    y=488 h= 28   -> content bottom = 516
    ; Form chrome (button row + title bar + frame) adds ~80px; 420x620
    ; clears the content + a small safety margin so the outer scrollbar
    ; stays retracted. Wrapped in errset because hiSetFormSize is a no-op
    ; (with a warn) on the rare timing window when the form record isn't
    ; yet fully realized.
    (errset (hiSetFormSize form (list 420 620)) t)
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
        (let ((cfg (dgen_dregConfigOf lib cell)) src)
          (cond
            ; The picked cell is a dreg made by this tool: open its
            ; definition for editing -- its real DUT as Source, the dreg
            ; itself as Target, its pins / custom variables / timing.
            (cfg
              (unless (dgen_instIsOf dgen_editInst lib cell)
                (setq dgen_editInst nil))
              (setq src (get cfg 'source))
              (setq dgen_editViewOf nil)
              (setq dgen_pendingSpec
                (dgen_plistPut cfg 'target
                  (list nil 'lib lib 'cell cell 'view dgen_mainView)))
              (printf "[dreg-gen] %s/%s is a dreg -- opening its settings (DUT %s/%s)\n"
                lib cell (get src 'lib) (get src 'cell))
              (setq lib  (get src 'lib))
              (setq cell (get src 'cell))
              (setq view (or (get src 'view) "symbol")))
            (t
              (setq dgen_editInst nil)
              ; Re-scanning the SAME DUT keeps the in-flight edits
              ; (incl. timing) instead of reverting to the saved state.
              (when (and dgen_currentPins
                         (equal lib dgen_currentDutLib)
                         (equal cell dgen_currentDutCell))
                (setq dgen_pendingSpec (dgen_readForm form dgen_currentPins))))))
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
    ; On DUT change (e.g. [Select from Schematic] -> new pin count) the
    ; captured size is meaningless and would clip the new content. Drop
    ; the size hint so the rebuilt form sizes naturally to fit its pin
    ; rows; the captured POSITION is still useful so the window doesn't
    ; jump around. +Digital / +Analog / +Delete all reopen with the same
    ; DUT so the cell-equality check leaves their size restore intact.
    (when (or (null dgen_currentDutCell)
              (null (equal cell dgen_currentDutCell)))
      (setq dgen_pendingFormSize nil))
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
            ; Remember the instance when it's a dreg made by this tool,
            ; so [Save As...] can switch it to the new cell. loadCB keeps
            ; it only while the edited dreg is this instance's master.
            (setq dgen_editInst (and (dgen_dregConfigOf lib cell) chosen))
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

; -------- Edit an existing dreg / Save As -------------------------------

; The single selected instance of the current window, when it is a dreg
; made by this tool (has an embedded config); else nil. Silent on windows
; without a selection set (CIW, Library Manager ...).
; Ref: skuiref.pdf p.956 (hiGetCurrentWindow), skdfref.pdf p.185 (geGetSelSet).
(defun dgen_selectedDregInst ()
  (let (win r insts)
    (setq win (car (errset (hiGetCurrentWindow) nil)))
    (when win
      (setq r (errset (geGetSelSet win) nil))
      (setq insts (setof o (and r (car r))
                    (equal (car (errset o~>objType nil)) "inst")))
      (when (and insts (null (cdr insts))
                 (dgen_dregConfigOf (car insts)~>libName (car insts)~>cellName))
        (car insts)))))

; Open the form on the dreg `inst` instantiates, for editing: its
; embedded config seeds everything, Target = the dreg itself, and Save As
; may switch `inst`. With openTiming, the Timing Table opens on top. When
; the cell has timing views besides veriloga (dgenStore.il), a small
; chooser asks which one to edit first.
(defun dgen_openDregInst (inst @optional openTiming "gg")
  (let (views)
    (cond
      ((null (dgen_dregConfigOf inst~>libName inst~>cellName))
        (dgen_warnBox (sprintf nil
          "%s/%s has no stored Dreg Generator setup (made by an older version?). Open MyTool > Dreg Generator, load its DUT and regenerate it once."
          inst~>libName inst~>cellName))
        nil)
      ((cdr (setq views (dgen_viewNames inst~>libName inst~>cellName)))
        (dgen_viewChooserOpen inst views openTiming))
      (t (dgen_openDregInstView inst dgen_mainView openTiming)))))

; dgenOpenGUI does not return while the form is up (hiDisplayForm of a
; blocking app form -- verified live), so the Timing Table is scheduled
; BEFORE it: the timer fires from the form's event loop, once it shows.
(defun dgen_openDregInstView (inst view @optional openTiming "gtg")
  (let (spec src)
    (setq spec (dgen_dregViewSpec inst~>libName inst~>cellName view))
    (cond
      ((null spec)
        (dgen_warnBox (sprintf nil "%s/%s has no timing view %s." inst~>libName inst~>cellName view))
        nil)
      (t
        (setq dgen_editInst inst)
        (setq dgen_editViewOf
          (and (nequal view dgen_mainView) (list inst~>libName inst~>cellName view)))
        (setq src (get spec 'source))
        (setq dgen_pendingSpec
          (dgen_plistPut spec 'target
            (list nil 'lib inst~>libName 'cell inst~>cellName 'view view)))
        (printf "[dreg-gen] editing dreg %s (%s/%s, view %s)\n"
          inst~>name inst~>libName inst~>cellName view)
        (when openTiming
          (hiRegTimer "(dgen_openTimingOnForm)" 3))
        (dgenOpenGUI (get src 'lib) (get src 'cell) (or (get src 'view) "symbol"))))))

(unless (boundp 'dgenVC_form)    (setq dgenVC_form    nil))
(unless (boundp 'dgenVC_pending) (setq dgenVC_pending nil))

; Label of one view in the chooser: "veriloga_RX   (3 edges on 2 signals)".
(defun dgen_viewChooserLabel (lib cell view "ttt")
  (sprintf nil "%s   (%s)" view
    (dgen_cdfTimingSummary (or (dgen_dregViewSpec lib cell view) (list nil)))))

(defun dgen_viewChooserOpen (inst views openTiming "glg")
  (let (labels)
    (setq labels (mapcar (lambda (v) (dgen_viewChooserLabel inst~>libName inst~>cellName v)) views))
    (setq dgenVC_pending (list inst views labels openTiming))
    (setq dgenVC_form (hiCreateAppForm
      ?name 'dgenVC_form
      ?formTitle (sprintf nil "Dreg Generator -- %s/%s: which timing view?" inst~>libName inst~>cellName)
      ?fields (list
        (list (hiCreateCyclicField ?name 'dgenVC_view ?prompt "Edit view"
                ?choices labels ?value (car labels))
              (list 0 0) (list 460 30) 80))
      ?callback (list "(dgen_viewChooserOkCB dgenVC_form)" "(dgen_viewChooserCancelCB dgenVC_form)")
      ?buttonLayout 'OKCancel))
    ; Wide enough for the title and the longest label.
    (hiInstantiateForm dgenVC_form)
    (errset (hiSetFormSize dgenVC_form (list 560 110)) t)
    (hiDisplayForm dgenVC_form)
    t))

; OK: remember the choice, open from a timer (outside this callback).
(defun dgen_viewChooserOkCB (form "g")
  (let ((lbl (dgen_fieldVal form 'dgenVC_view)) (i 0) idx)
    (foreach l (caddr dgenVC_pending)
      (when (equal l lbl) (setq idx i))
      (setq i (add1 i)))
    (setq dgenVC_pending
      (append dgenVC_pending (list (nth (or idx 0) (cadr dgenVC_pending)))))
    (hiRegTimer "(dgen_viewChooserGo)" 1)
    t))

(defun dgen_viewChooserCancelCB (form "g")
  (setq dgenVC_pending nil)
  t)

(defun dgen_viewChooserGo ()
  (let ((p dgenVC_pending))
    (setq dgenVC_pending nil)
    (when (and p (dgen_instUsable (car p)))
      (dgen_openDregInstView (car p) (nth 4 p) (cadddr p)))))

; Timer target of dgen_openDregInst: the Timing Table, once the main form
; is up with a DUT loaded (silently nothing if it never came up).
(defun dgen_openTimingOnForm ()
  (when (and (boundp 'dgen_form) dgen_form dgen_currentPins
             (car (errset (hiIsFormDisplayed dgen_form) nil)))
    (dgenTimingEditorOpen)))

; -------- [Edit timing...] in the instance Properties form (q) ----------
;
; The dreg CDF (dgenCDF.il) carries a button parameter whose ?display and
; ?callback call the two functions below -- guarded with isCallable, so
; where dreg_gen isn't loaded the button just doesn't show. Keep these
; names stable: they are stored in every generated dreg's CDF.
;
; In a CDF callback cdfgData->id is the CELL (verified live on IC6.1.8);
; the instance comes from the Properties form itself (cdfgForm->objId).

(unless (boundp 'dgen_cdfEditInst) (setq dgen_cdfEditInst nil))
(unless (boundp 'dgen_cdfEditForm) (setq dgen_cdfEditForm nil))

; Button shown only in the instance Properties form (q). Not in Add
; Instance (cdfgForm = schCreateInstForm): no instance exists yet, and a
; regeneration would rewrite the CDF that form is showing.
(defun dgenCdfEditTimingShow ()
  (and (boundp 'cdfgForm) cdfgForm
       (eq cdfgForm->hiFormSym 'schObjPropForm)
       (equal cdfgForm->objType "instance")
       t))

(defun dgenCdfEditTimingCB ()
  (let ((form (and (boundp 'cdfgForm) cdfgForm)) inst)
    (setq inst (and form (car (errset form->objId nil))))
    (cond
      ((not (dgen_instUsable inst))
        (warn "[dreg-gen] Edit timing: no instance behind this form\n"))
      (t
        (setq dgen_cdfEditInst inst)
        (setq dgen_cdfEditForm form)
        ; Not from inside the form's own callback.
        (hiRegTimer "(dgen_cdfEditTimingDeferred)" 1)))
    t))

; Close the Properties form with OK -- edits typed there are kept, and no
; open form is left showing the CDF a regeneration rewrites -- then, from
; a SECOND timer tick, open the dreg with its Timing Table on top:
; dgenOpenGUI doesn't return while the generator is up, so the form's OK
; handling gets to finish before that long blocking call starts. (The
; instance stays selected; dgenRun deselects it before regenerating --
; see dgen_deselectInstsOf.)
(defun dgen_cdfEditTimingDeferred ()
  (let ((form dgen_cdfEditForm))
    (setq dgen_cdfEditForm nil)
    (when (and form (car (errset (hiIsFormDisplayed form) nil)))
      (errset (hiFormDone form) t)
      (when (car (errset (hiIsFormDisplayed form) nil))
        (errset (hiFormCancel form) t)))
    (hiRegTimer "(dgen_cdfEditTimingOpen)" 2)
    t))

; Second tick: close an open generator / Timing Table (maybe on another
; dreg), then open this one.
(defun dgen_cdfEditTimingOpen ()
  (let ((inst dgen_cdfEditInst))
    (setq dgen_cdfEditInst nil)
    (foreach f (list (and (boundp 'dgenTim_form) dgenTim_form)
                     (and (boundp 'dgen_form) dgen_form))
      (when (and f (car (errset (hiIsFormDisplayed f) nil)))
        (errset (hiFormCancel f) t)))
    (when (dgen_instUsable inst)
      (dgen_openDregInst inst t))))

; Re-point `inst` at lib/cell/symbol. Returns a sentence for the result
; dialog. The schematic is left modified (unsaved) -- like any edit, the
; user decides when to save it.
; Ref: skcompref.pdf p.365 (schReplaceProperty "master" "lib cell view").
(defun dgen_swapInstMaster (inst lib cell "gtt")
  (let (cv r nm)
    (cond
      ((not (dgen_instUsable inst))
        "\n\nThe instance the edit started from no longer exists -- place the new cell by hand.")
      (t
        (setq cv inst~>cellView)
        (setq nm inst~>name)
        (cond
          ((not (member cv~>mode (list "a" "w")))
            (sprintf nil
              "\n\nInstance %s was NOT switched: its schematic %s/%s is open read-only. Make it editable, then switch it to %s/%s by hand."
              nm cv~>libName cv~>cellName lib cell))
          (t
            (setq r (errset (schReplaceProperty (list inst) "master"
                              (sprintf nil "%s %s symbol" lib cell)) t))
            (cond
              ((and r (car r))
                (sprintf nil
                  "\n\nInstance %s in %s/%s now uses %s/%s (schematic modified -- save it to keep the change)."
                  nm cv~>libName cv~>cellName lib cell))
              (t (sprintf nil "\n\nCould not switch instance %s -- see CIW." nm)))))))))

(unless (boundp 'dgenSA_form)       (setq dgenSA_form       nil))
(unless (boundp 'dgenSA_prevTarget) (setq dgenSA_prevTarget nil))

; [Save As...]: small form asking for the new name (same Target Lib). Two
; kinds when the Target is already a dreg of this tool: a new CELL (offers
; to switch the instance the edit started from, while that instance still
; points at the dreg being edited), or a new TIMING VIEW of the same cell
; ("this symbol, but use veriloga_RX" -- see dgenStore.il).
(unless (boundp 'dgenSA_tmpVal) (setq dgenSA_tmpVal nil))

(defun dgen_saKindCell () "New cell")
(defun dgen_saKindView () "New timing view of this cell")

; First free "veriloga_<n>" of lib/cell (n from 2).
(defun dgen_nextViewName (lib cell "tt")
  (let ((n 2) nm)
    (setq nm (sprintf nil "%s_%d" dgen_mainView n))
    (while (ddGetObj lib cell nm)
      (setq n (add1 n))
      (setq nm (sprintf nil "%s_%d" dgen_mainView n)))
    nm))

(defun dgen_saSet (fieldSym slot val "ssg")
  (setq dgenSA_tmpVal val)
  (errset (evalstring (sprintf nil "dgenSA_form->%s->%s = dgenSA_tmpVal"
                        (symbolToString fieldSym) (symbolToString slot))) t))

(defun dgenGui_saveAsCB (form "g")
  (cond
    ((null dgen_currentPins)
      (dgen_warnBox "No DUT loaded. Pick a Lib/Cell and click [Load Pins] first."))
    (t
      (let (tgtLib tgtCell fields swapInst y isDreg)
        (setq tgtLib  (or (dgen_fieldVal form 'dgen_tgtLib)  ""))
        (setq tgtCell (or (dgen_fieldVal form 'dgen_tgtCell) ""))
        (setq swapInst (and (dgen_instIsOf dgen_editInst tgtLib tgtCell) dgen_editInst))
        (setq isDreg (and (dgen_dregConfigOf tgtLib tgtCell) t))
        (setq y 0)
        (when isDreg
          (setq fields (list
            (list (hiCreateCyclicField ?name 'dgenSA_kind ?prompt "Save as"
                    ?choices (list (dgen_saKindCell) (dgen_saKindView))
                    ?value (dgen_saKindCell)
                    ?callback "(dgenGui_saveAsKindCB)")
                  (list 0 y) (list 420 30) 110)))
          (setq y (plus y 30)))
        (setq fields (append fields (list
          (list (hiCreateStringField ?name 'dgenSA_cell ?prompt "New name"
                  ?value (strcat tgtCell "_copy"))
                (list 0 y) (list 420 30) 110)
          (list (hiCreateStringField ?name 'dgenSA_lib ?prompt "Library"
                  ?value tgtLib ?editable nil)
                (list 0 (plus y 30)) (list 420 30) 110))))
        (setq y (plus y 60))
        (when swapInst
          (setq fields (append fields (list
            (list (hiCreateBooleanButton ?name 'dgenSA_swap
                    ?buttonText (sprintf nil "Switch instance %s to the new cell" swapInst~>name)
                    ?value t)
                  (list 0 y) (list 420 30) 0))))
          (setq y (plus y 30)))
        (when isDreg
          (setq fields (append fields (list
            (list (hiCreateStringField ?name 'dgenSA_hint ?prompt ""
                    ?value "Timing view: same symbol, user picks e.g. veriloga_RX"
                    ?editable nil)
                  (list 0 y) (list 420 30) 0)))))
        (setq dgenSA_form (hiCreateAppForm
          ?name 'dgenSA_form
          ?formTitle (sprintf nil "Dreg Generator -- Save %s/%s%s As" tgtLib tgtCell
                       (dgen_viewSuffix (dgen_targetViewFor tgtLib tgtCell)))
          ?fields fields
          ?callback (list "(dgenGui_saveAsOkCB dgenSA_form)" "(dgenGui_saveAsCancelCB dgenSA_form)")
          ?unmapAfterCB t
          ?buttonLayout 'OKCancel))
        (hiDisplayForm dgenSA_form)
        t))))

; Kind switch: suggest a name of that kind; the instance switch only
; applies to a new cell.
(defun dgenGui_saveAsKindCB ()
  (let ((lib (dgen_fieldVal dgenSA_form 'dgenSA_lib))
        (cell (dgen_fieldVal dgen_form 'dgen_tgtCell))
        (view (equal (dgen_fieldVal dgenSA_form 'dgenSA_kind) (dgen_saKindView))))
    (dgen_saSet 'dgenSA_cell 'value
      (cond (view (dgen_nextViewName lib cell)) (t (strcat cell "_copy"))))
    (when (get dgenSA_form 'dgenSA_swap)
      (errset (hiSetFieldEnabled (get dgenSA_form 'dgenSA_swap) (not view)) t))
    t))

(defun dgenGui_saveAsCancelCB (saForm "g") t)

; Save As OK: retarget the main form at the new cell (or the new timing
; view of the current cell), run the same generate path as OK (validation,
; overwrite confirm if the new name already exists), then optionally
; switch the instance. On abort/failure the old target is restored and the
; Save As form stays open.
(defun dgenGui_saveAsOkCB (saForm "g")
  (let (name swap res lib cell swapMsg asView prevView)
    (errset (hiSetCallbackStatus saForm t) t)
    (setq name (dgen_tmTrim (or (dgen_fieldVal saForm 'dgenSA_cell) "")))
    (setq asView (and (get saForm 'dgenSA_kind)
                      (equal (dgen_fieldVal saForm 'dgenSA_kind) (dgen_saKindView))))
    (setq swap (and (not asView) (get saForm 'dgenSA_swap) (dgen_fieldVal saForm 'dgenSA_swap)))
    (setq lib  (and (boundp 'dgen_form) dgen_form (dgen_fieldVal dgen_form 'dgen_tgtLib)))
    (setq cell (and (boundp 'dgen_form) dgen_form (dgen_fieldVal dgen_form 'dgen_tgtCell)))
    (cond
      ((null (pcreMatchp "^[A-Za-z_][A-Za-z0-9_]*$" name))
        (dgen_warnBox (sprintf nil
          "'%s' is not a usable %s name (letters, digits, underscore; no leading digit)."
          name (cond (asView "view") (t "cell"))))
        (errset (hiSetCallbackStatus saForm nil) t)
        nil)
      ((not (and (boundp 'dgen_form) dgen_form dgen_currentPins))
        (dgen_warnBox "The Dreg Generator form is closed -- reopen it first.")
        t)
      ((and asView (or (equal name dgen_mainView) (ddGetObj lib cell name)))
        (dgen_warnBox (sprintf nil
          "%s/%s already has a view named %s. Pick another name (to change an existing timing view, open it via q > [Edit timing...])."
          lib cell name))
        (errset (hiSetCallbackStatus saForm nil) t)
        nil)
      (asView
        (setq prevView dgen_editViewOf)
        (setq dgen_editViewOf (list lib cell name))
        (setq res (car (errset (dgen_generate dgen_form) t)))
        (unless res
          (setq res (list 'fail "Internal error while generating -- see the CIW for the SKILL error.")))
        (cond
          ((memq (car res) '(ok warn))
            (dgen_showResult res)
            (hiRegTimer "(dgen_redrawPending)" 2)
            t)
          (t
            (setq dgen_editViewOf prevView)
            (dgen_showResult res)
            (errset (hiSetCallbackStatus saForm nil) t)
            nil)))
      (t
        (setq dgenSA_prevTarget (dgen_fieldVal dgen_form 'dgen_tgtCell))
        (dgen_setFieldValue 'dgen_tgtCell name)
        (setq res (car (errset (dgen_generate dgen_form) t)))
        (unless res
          (setq res (list 'fail "Internal error while generating -- see the CIW for the SKILL error.")))
        (cond
          ((memq (car res) '(ok warn))
            (when swap
              (setq swapMsg (dgen_swapInstMaster dgen_editInst lib name)))
            (dgen_showResult (list (car res) (strcat (cadr res) (or swapMsg ""))))
            (hiRegTimer "(dgen_redrawPending)" 2)
            t)
          (t
            (dgen_setFieldValue 'dgen_tgtCell dgenSA_prevTarget)
            (dgen_showResult res)
            (errset (hiSetCallbackStatus saForm nil) t)
            nil))))))

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
        ; Old-behaviour path: scan pins, build full form. When reopening
        ; a dreg whose DUT can't be opened here, fall back to the pin
        ; list stored in the dreg (dgen_scanPinsOr).
        (unless dutView (setq dutView "symbol"))
        (setq pins (dgen_scanPinsOr dutLib dutCell dutView))
        (cond
          ((null pins)
            (setq dgen_pendingSpec nil)
            (warn "dgenOpenGUI: no pins scanned for %s/%s\n" dutLib dutCell)
            (dgen_warnBox (sprintf nil "Cannot read the pins of %s/%s/%s. Check the Source Lib/Cell/View."
                            dutLib dutCell dutView))
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
            ; Pending in-flight spec > target dreg's embedded config >
            ; last-state (see dgen_seedSpec). customVars + timing come
            ; with the chosen source; the module globals mirror them so
            ; the row builders, readForm and the Timing Table agree.
            (setq currentSpec (dgen_seedSpec factorySpec lastState dutLib dutCell))
            (setq dgen_currentCustomVars (get currentSpec 'customVars))
            (setq dgen_currentTiming     (get currentSpec 'timing))
            (setq dgen_currentTimingVars (get currentSpec 'timingVars))
            (setq fields (dgen_buildFields factorySpec currentSpec))
            (setq title (dgen_formTitle currentSpec))
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
              ; unmapAfterCB t: lets dgenGui_okCB keep the form open on
              ; bad input / "No" via hiSetCallbackStatus (skuiref p.801).
              ?unmapAfterCB t
              ?buttonLayout 'OKCancelDefApply))
            (hiInstantiateForm form)
            (errset (ddHiLinkFields form->dgen_srcLib form->dgen_srcCell form->dgen_srcView) t)
            ; Target lib+cell combos: 2-arg form (no view triplet on the
            ; target side -- target view is fixed/inferred by callers).
            ; Probed live: 2-arg call returns t cleanly (skuiref.pdf p.495).
            (errset (ddHiLinkFields form->dgen_tgtLib form->dgen_tgtCell) t)
            (dgen_displayFormApplyPending form 'dgen_form fields)
            'dgen_form)))
      ; Opened with exactly one dreg instance selected in the current
      ; schematic (e.g. MyTool > Dreg Generator after clicking the
      ; dreg): open that dreg for editing straight away.
      ((dgen_selectedDregInst)
        (dgen_openDregInst (dgen_selectedDregInst)))
      (t
        ; DUT-less path. Reset per-pin state. Pre-fill combos from v2
        ; last-state when present (don't auto-render -- wait for user
        ; to confirm via [Load Pins] / [Select from Schematic] / [Browse]).
        (setq dgen_currentPins nil)
        (setq dgen_currentTiming nil)
        (setq dgen_currentTimingVars nil)
        (setq dgen_pendingSpec nil)
        (setq dgen_editInst nil)
        (setq dgen_editViewOf nil)
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
          ?unmapAfterCB t
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
