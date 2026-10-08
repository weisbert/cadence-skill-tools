; dgenStore.il -- Step 1 of Dreg Generator: spec serialization, cell-property and last-state I/O,
; and the shared emit-item iterator that unifies pins + customVars for the downstream generators.
;
; Last-state schema:
;   v1 (legacy): plist with targetLib, targetCellTpl, dvddDefault, defaultMode,
;                defaultPattern, pinStates. No 'schemaVersion key.
;   v2 (current): v1 + 'schemaVersion 2 + 'lastDutLib / 'lastDutCell / 'lastDutView.
;
; History note: a v3 schema briefly added 'customVarStates so customVars
; would round-trip across opens. That was rolled back -- customVars are
; session-transient by design (see dgen_currentCustomVars in dgenGui.il)
; and the last-state file only carries persistent DUT/pin configuration.
; Old last-state files that still contain 'customVarStates are read
; verbatim and the field is silently ignored (forward-compatible).
;
; Migration policy: silent forward-only.
;   - Reader returns the plist verbatim; consumers use `get` so missing fields
;     read as nil. v1 files therefore yield nil for lastDutLib/Cell/View, which
;     is the desired fallback. Future v3+ fields are also returned verbatim and
;     ignored by current consumers.
;   - Writer always stamps 'schemaVersion 2 (auto-injected if not already in
;     the input plist).
;
; SPEC SHAPE (in-memory; not the same as last-state file shape):
;   spec is a plist:
;     'source         (nil 'lib L 'cell C 'view V)         ; DUT cellview
;     'target         (nil 'lib L 'cell C 'view "veriloga"); generated Dreg cellview
;     'dvddDefault    "0.9"                                ; string, .va parameter
;     'defaultMode    "literal" | "empty" | "variable_pin" | "custom"
;     'defaultPattern "d_*" or similar                     ; only used in "custom"
;     'pins           list of pin plists from dgenScanPins
;     'customVars     list of customVar plists             ; user-added in GUI
;     'timing         list of timing rows (dgenTiming.il)   ; transient edges
;     'timingVars     list of (nil 'name "T0" 'default "5n") ; variables the
;                     timing cells may use (-> CDF tv_T0 = design var T0)
;
;   pin plist (from dgenScanPins, augmented in GUI):
;     'name, 'isBus, 'busHi, 'busLo, 'srcDirection, 'enabled, 'default,
;     'kind ("digital" default | "analog" -- scalar pins only; a bus pin
;            is always digital whatever 'kind says)
;
;   timing row (see dgenTiming.il header for semantics); every cell is an
;   expression -- literal, variable or sum ("5n", "T0", "T1+70n"):
;     (nil 'signal "EN" 'time "T1+70n" 'edge "50p" 'value "")
;
;   customVar plist (user-added in GUI):
;     'name      "XX_ctrl"      ; bus suffix stripped at parse time
;     'kind      "digital" | "analog"
;     'isBus     t/nil          ; analog is always scalar (nil/absent)
;     'busHi     int            ; only when isBus = t
;     'busLo     int            ; only when isBus = t
;     'default   "0" | "1.8"    ; digital: integer string; analog: real string
;
;   Naming convention used by the emitters (single source of truth in
;   dgen_emitParamName below):
;     digital item -> .va parameter named d_<name>, integer, V() <+ d_<name> * DVDD
;     analog  item -> .va parameter named v_<name>, real,    V() <+ v_<name>
;
;   Pins default to digital; the GUI's per-row Digital/Analog switch sets
;   'kind "analog" on a scalar pin (e.g. to ramp a VDD). CustomVars carry
;   their kind explicitly. The dgen_specEmitList helper unifies both
;   into a single emit-item list so symbol / VA / CDF emitters iterate one
;   list and branch on 'kind for kind-specific behavior.

; sprintf with %L round-trips through readstring.
; Ref: sklangref.pdf p.214 (sprintf), p.198 (readstring), p.410 (%L format).
(defun dgenSpecToString (spec "g")
  (sprintf nil "%L" spec))

(defun dgenStringToSpec (str "t")
  (and str (readstring str)))

; Stored as a string property named "dgenConfig" on the cell view.
; Ref: skdfref.pdf p.900 (dbOpenCellViewByType), p.559 (dbReplaceProp),
;      p.557 (dbFindProp), p.921 (dbSave), p.873 (dbClose).
; (Page numbers are physical PDF pages, matching function_index.tsv.)
;
; Mode restore. If the cellview is ALREADY open (dgenRun's compile step --
; amsUpdateTextviews -- leaves the dreg's symbol open "r"), our "a" open
; upgrades that shared handle and dbClose only drops our reference, so the
; view would stay in edit mode for the rest of the session: write lock
; held, and a panic file if Virtuoso dies (seen 2026-10-06). Remember the
; prior mode and dbReopen back to it after saving.
; Ref: skdfref.pdf p.881 (dbFindOpenCellView), p.917 (dbReopen).
(defun dgenSavePropOnCell (libName cellName viewName spec @optional (propName "dgenConfig") "tttgt")
  (let (libObj prior priorMode cv p)
    (setq libObj (ddGetObj libName))
    (setq prior (and libObj (dbFindOpenCellView libObj cellName viewName)))
    (setq priorMode (and prior prior~>mode))
    (setq cv (dbOpenCellViewByType libName cellName viewName nil "a"))
    (unless cv (error "dgenSavePropOnCell: cannot open %s/%s/%s for append" libName cellName viewName))
    ; nil removes the property (e.g. the last timing view was deleted).
    (cond
      (spec (dbReplaceProp cv propName "string" (dgenSpecToString spec)))
      (t (setq p (dbFindProp cv propName))
         (when p (dbDeleteObject p))))
    (dbSave cv)
    (when (and priorMode (nequal priorMode cv~>mode))
      (dbReopen cv priorMode))
    (dbClose cv)
    t))

(defun dgenLoadPropFromCell (libName cellName viewName @optional (propName "dgenConfig") "tttt")
  (let ((cv (dbOpenCellViewByType libName cellName viewName nil "r")) p out)
    (when cv
      (setq p (dbFindProp cv propName))
      (when p (setq out (dgenStringToSpec p~>value)))
      (dbClose cv))
    out))

; ---------------------------------------------------------------------------
; Embedded dreg config ("the dreg cell remembers how it was made")
; ---------------------------------------------------------------------------
;
; After a successful generation dgenRun stores the FULL spec -- DUT source,
; pin enable/value/kind, customVars, timing table -- as the dgenConfig
; string property on the dreg's symbol view. Anyone who later opens the
; GUI on that dreg (selected instance, [Select from Schematic], or typing
; the dreg cell as Source + [Load Pins]) gets the exact definition back,
; edits it, and regenerates (Save) or saves a copy under a new name
; (Save As). The property travels with the cell: Library Manager copies,
; tarballs into the red zone, other users' library paths.
;
; Why the symbol view: it's the one OA view every dreg has (veriloga is a
; text view) and it is what testbench instances reference. dgenRun writes
; the prop LAST because schPinListToSymbolGen recreates the symbol view
; and would drop it.
;
; configVersion 1 = this layout. Readers use `get`, so unknown future
; keys are ignored and missing ones read as nil.

(defun dgen_saveConfigProp (spec "g")
  (let ((tgt (get spec 'target)) r)
    (setq r (errset
              (dgenSavePropOnCell (get tgt 'lib) (get tgt 'cell) "symbol"
                (dgen_plistPut spec 'configVersion 1))
              t))
    (cond
      ((and r (car r)) t)
      (t
        (warn "dgen_saveConfigProp: could not store dgenConfig on %s/%s/symbol -- the dreg works, but reopening it in the GUI will not restore its settings\n"
          (get tgt 'lib) (get tgt 'cell))
        nil))))

; Return the embedded spec of dreg lib/cell, or nil when the cell is not
; a dreg made by this tool (no symbol view, no prop, or not a spec).
; Silent: called on every [Load Pins] to decide "DUT or dreg?".
(defun dgen_dregConfigOf (libName cellName "gg")
  (let (r cfg)
    (when (and (stringp libName) (stringp cellName)
               (nequal libName "") (nequal cellName "")
               (ddGetObj libName cellName "symbol"))
      (setq r (errset (dgenLoadPropFromCell libName cellName "symbol") nil))
      (setq cfg (and r (car r))))
    (cond
      ((and cfg (listp cfg) (get cfg 'source) (get cfg 'pins)) cfg)
      (t nil))))

; ---------------------------------------------------------------------------
; Timing views ("this symbol, but use veriloga_RX")
; ---------------------------------------------------------------------------
;
; A dreg cell can carry more Verilog-A views than `veriloga`, each with its
; own timing: veriloga_RX, veriloga_TX ... They share the symbol and the
; cell CDF, so pins, Digital/Analog and DC values are those of the main
; view; only 'timing / 'timingVars differ. Which view a simulation uses is
; picked by the user's switch view list or config (View to Use) -- one
; view per netlist: all views define the same module (the cell name), and
; Spectre silently lets the last ahdl_include win (SFE-2654, verified).
;
; Storage: the main view's full spec stays in dgenConfig; the other views
; are the string property dgenViews on the symbol,
;   ((nil view "veriloga_RX" timing (...) timingVars (...)) ...)
; Readers drop entries whose view no longer exists (deleted by hand).

(unless (boundp 'dgen_mainView) (setq dgen_mainView "veriloga"))

; Stored timing views of lib/cell that still exist on disk (main excluded).
(defun dgen_dregViewsOf (libName cellName "gg")
  (let (r vs)
    (when (and (stringp libName) (stringp cellName)
               (ddGetObj libName cellName "symbol"))
      (setq r (errset (dgenLoadPropFromCell libName cellName "symbol" "dgenViews") nil))
      (setq vs (and r (car r))))
    (setof v (and (listp vs) vs)
      (and (listp v) (stringp (get v 'view))
           (nequal (get v 'view) dgen_mainView)
           (ddGetObj libName cellName (get v 'view))))))

; All timing view names of lib/cell, main first.
(defun dgen_viewNames (libName cellName "gg")
  (cons dgen_mainView
    (mapcar (lambda (v) (get v 'view)) (dgen_dregViewsOf libName cellName))))

; Full spec of one view: the main spec with that view's timing and the
; target pointing at the view.
(defun dgen_viewSpec (main variant "gg")
  (let ((tgt (get main 'target)))
    (dgen_plistPut
      (dgen_plistPut
        (dgen_plistPut main 'timing (get variant 'timing))
        'timingVars (get variant 'timingVars))
      'target (list nil 'lib (get tgt 'lib) 'cell (get tgt 'cell)
                    'view (get variant 'view)))))

; Spec of view `view` of dreg lib/cell, or nil.
(defun dgen_dregViewSpec (libName cellName view "ggg")
  (let ((main (dgen_dregConfigOf libName cellName)) v)
    (cond
      ((null main) nil)
      ((or (null view) (equal view dgen_mainView)) main)
      (t
        (setq v (car (setof x (dgen_dregViewsOf libName cellName)
                       (equal (get x 'view) view))))
        (and v (dgen_viewSpec main v))))))

; What the symbol fixes (ports) and what the cell CDF fixes (DC values).
(defun dgen_viewPinsKey (spec "g")
  (mapcar
    (lambda (it) (list (get it 'name) (dgen_tmKindOf it) (get it 'busHi) (get it 'busLo)))
    (dgen_specEmitList spec)))

(defun dgen_viewDcKey (spec "g")
  (list (get spec 'dvddDefault) (get spec 'defaultMode) (get spec 'defaultPattern)
    (mapcar (lambda (it) (get it 'default)) (dgen_specEmitList spec))))

; Why `spec` can't be saved as a timing view of `main`, or nil. A view only
; changes the timing; anything the symbol / cell CDF fixes must match.
(defun dgen_viewCompatErr (spec main "gg")
  (cond
    ((nequal (dgen_viewPinsKey spec) (dgen_viewPinsKey main))
      "Pins (enabled set, Digital/Analog, custom variables) are shared by all timing views of a cell -- a timing view can only change the timing. Change them in the main view (veriloga), or Save As a new cell.")
    ((nequal (dgen_viewDcKey spec) (dgen_viewDcKey main))
      "DVDD and the DC values are shared by all timing views of a cell -- change them in the main view (veriloga), or Save As a new cell.")
    (t nil)))

; Generic plist "put": copy of `pl` (leading-nil plist) with `key` set to
; `val` -- replaced in place if present, appended otherwise. SKILL has no
; non-destructive plist setter; specs are small so the O(n^2) append walk
; is irrelevant.
(defun dgen_plistPut (pl key val "lsg")
  (let ((out (list nil)) (rest (cdr pl)) found)
    (while rest
      (cond
        ((eq (car rest) key)
          (setq out (append out (list key val)))
          (setq found t))
        (t (setq out (append out (list (car rest) (cadr rest))))))
      (setq rest (cddr rest)))
    (unless found (setq out (append out (list key val))))
    out))

; Ref: sklangref.pdf p.627 (getShellEnvVar)
(defun dgen_lastFilePath ()
  (let ((home (getShellEnvVar "HOME")))
    (unless home (error "dgen_lastFilePath: $HOME unset"))
    (strcat home "/.skill_tools/dreg_gen.last")))

; Ref: sklangref.pdf p.631 (isDir), p.616 (createDir).
; SKILL has no let* (sequential bindings), so nest two lets to let dir see home.
(defun dgen_ensureLastDir ()
  (let ((home (getShellEnvVar "HOME")))
    (let ((dir (strcat home "/.skill_tools")))
      (unless (isDir dir) (createDir dir))
      dir)))

; Build a v2 plist by splicing 'schemaVersion 2 and (when sourcePlist given)
; 'lastDutLib / 'lastDutCell / 'lastDutView into the input plist. The input
; plist is treated as a property list with leading nil sentinel (per the
; project's plist convention -- see dgenGui.il dgen_specToLastState). If the
; input already carries a 'schemaVersion or any of the lastDut* fields, those
; user-supplied values win; we only inject when absent.
;
; sourcePlist shape: (nil 'lib X 'cell Y 'view Z) -- matches the spec's
; 'source sub-plist shape used in dgenGui.il and dgenPinScan.il.
(defun dgen_lastStateInjectV2 (plist sourcePlist "gg")
  (let (out lib cell view)
    (setq out plist)
    (unless (get out 'schemaVersion)
      (setq out (append out (list 'schemaVersion 2))))
    (when sourcePlist
      (setq lib  (get sourcePlist 'lib))
      (setq cell (get sourcePlist 'cell))
      (setq view (get sourcePlist 'view))
      (unless (get out 'lastDutLib)
        (setq out (append out (list 'lastDutLib (or lib "")))))
      (unless (get out 'lastDutCell)
        (setq out (append out (list 'lastDutCell (or cell "")))))
      (unless (get out 'lastDutView)
        (setq out (append out (list 'lastDutView (or view ""))))))
    out))

; Ref: sklangref.pdf p.450 (outfile), p.409 (fprintf)
;
; sourcePlist (optional): the spec's 'source sub-plist (nil 'lib X 'cell Y
; 'view Z). When supplied, lastDutLib/Cell/View are written into the file so
; a future dgenOpenGUI() call can pre-fill the Source-Lib/Cell/View combos.
; When omitted, the file is still v2 (carries 'schemaVersion 2) but lacks
; the lastDut* fields -- legitimate for callers that don't track DUT identity.
(defun dgenSaveLastState (plist @optional sourcePlist)
  (dgen_ensureLastDir)
  (let ((p (outfile (dgen_lastFilePath) "w"))
        (final (dgen_lastStateInjectV2 plist sourcePlist)))
    (unless p (error "dgenSaveLastState: cannot write %s" (dgen_lastFilePath)))
    (fprintf p "%L\n" final)
    (close p)
    t))

; lineread on a port returns a list of forms parsed from the next line, or nil at EOF.
; Ref: sklangref.pdf p.428 (isFile), p.423 (infile), p.437 (lineread).
;
; Returns the plist verbatim. Consumers use `get` to read fields, which
; naturally handles v1 (no schemaVersion -> nil), v2 (lastDut* present), and
; future versions (extra fields silently ignored). See dgen_lastStateIsV2P /
; dgen_lastStateDutLib/Cell/View below for typed accessors.
(defun dgenLoadLastState ()
  (let ((path (dgen_lastFilePath)) p result)
    (when (isFile path)
      (setq p (infile path))
      (when p
        (setq result (lineread p))
        (close p)))
    (cond ((null result) nil)
          ((equal result t) nil)
          (t (car result)))))

; Schema-version helpers. Treat absent 'schemaVersion as v1 (return 1) per the
; migration policy. Use these in callers instead of poking 'schemaVersion
; directly so future schema bumps stay localized.
(defun dgen_lastStateSchemaVersion (state "g")
  (or (get state 'schemaVersion) 1))

(defun dgen_lastStateIsV2P (state "g")
  (geqp (dgen_lastStateSchemaVersion state) 2))

; v1-tolerant accessors for the lastDut* fields. v1 files lack these, so the
; helpers return nil; the GUI is responsible for defaulting to "" / empty
; combos in that case. (Returning nil rather than "" lets callers distinguish
; "no last-state DUT recorded" from "saved an empty string".)
(defun dgen_lastStateDutLib (state "g")
  (and (dgen_lastStateIsV2P state) (get state 'lastDutLib)))

(defun dgen_lastStateDutCell (state "g")
  (and (dgen_lastStateIsV2P state) (get state 'lastDutCell)))

(defun dgen_lastStateDutView (state "g")
  (and (dgen_lastStateIsV2P state) (get state 'lastDutView)))

; ---------------------------------------------------------------------------
; Emit-item helpers: shared by dgenSymbol.il / dgenVerilogA.il / dgenCDF.il.
; ---------------------------------------------------------------------------
;
; The Dreg cell's symbol/Verilog-A/CDF are all generated from the SAME flat
; list of "things to emit": each enabled DUT pin becomes one emit-item, plus
; each user-added customVar becomes one emit-item. Centralizing the merge
; here means the three downstream generators just iterate the result and
; branch on 'kind for kind-specific output.
;
; An emit-item is a plist with at minimum:
;   'name    -- bare identifier (no bus suffix)
;   'kind    -- "digital" or "analog"
;   'isBus, 'busHi, 'busLo -- only meaningful when isBus = t (digital only)
;   'default -- string; digital is an integer literal, analog is a real literal
;
; Pins from dgenScanPins carry 'name/'isBus/'busHi/'busLo/'srcDirection/'enabled/
; 'default and, once the GUI has touched them, 'kind. This helper normalizes
; 'kind on enabled pins: "analog" only for a scalar pin explicitly switched to
; Analog, "digital" otherwise (absent kind = legacy spec = digital; a bus pin
; is always digital).
; CustomVars already carry their own 'kind from the GUI.
;
; Disabled pins are dropped here. CustomVars have no enabled flag -- to disable
; one, the user deletes the row in the GUI; entries present in the list are
; always emitted.

(defun dgen_specEmitList (spec "g")
  (let (out kind)
    (foreach p (get spec 'pins)
      (when (get p 'enabled)
        (setq kind (cond
                     ((and (equal (get p 'kind) "analog") (null (get p 'isBus))) "analog")
                     (t "digital")))
        (setq out (cons (dgen_plistPut p 'kind kind) out))))
    (foreach c (get spec 'customVars)
      (setq out (cons c out)))
    (reverse out)))

; Terminal name as written into the .va port list, symbol pin list, and CDF
; simInfo termOrder. Bus items keep Cadence's <hi:lo> suffix; scalars are bare.
; Used to live in three near-duplicate functions (dgen_pinTerminalName in
; dgenSymbol.il, dgen_emitPortListItem in dgenVerilogA.il, an inline lambda
; in dgenCDF.il's dgen_buildSimInfo); consolidated here so customVar bus
; entries get the same treatment without three independent code changes.

(defun dgen_emitTermName (item "g")
  (let ((nm (get item 'name)))
    (cond
      ((get item 'isBus)
        (sprintf nil "%s<%d:%d>" nm (get item 'busHi) (get item 'busLo)))
      (t nm))))

; CDF/Verilog-A parameter name. Digital items get the legacy d_<name>
; convention so existing DUT testbenches that reference d_EN keep working;
; analog items get v_<name> to keep them visually distinct in the ADE
; Properties dialog (and to avoid collision with the analog pin's own name
; in the .va, where a `parameter real X` and `electrical X` would clash).

(defun dgen_emitParamName (item "g")
  (let ((nm (get item 'name)))
    (cond
      ((equal (get item 'kind) "analog") (sprintf nil "v_%s" nm))
      (t                                  (sprintf nil "d_%s" nm)))))

; CDF prompt: the LEFT-side label shown next to the parameter in the
; instance Properties dialog. Digital scalar -> "d_<name>"; digital bus ->
; "d_<name><hi:lo>" so the user knows the input is multi-bit; analog ->
; "v_<name>". Bus suffix only ever attaches to digital (analog never buses).

(defun dgen_emitPrompt (item "g")
  (cond
    ((and (get item 'isBus) (nequal (get item 'kind) "analog"))
      (sprintf nil "%s<%d:%d>"
        (dgen_emitParamName item) (get item 'busHi) (get item 'busLo)))
    (t (dgen_emitParamName item))))

; CDF defValue string. Three accepted shapes:
;   1. integer literal "0" / "-3" / "42"     -- digital + analog
;   2. real    literal "1.8" / "-3.3"        -- analog only (digital
;      gets fallback "0" because the .va integer parameter would mismatch)
;   3. Verilog identifier "EN" / "VDDA"      -- treated as a CEL variable
;      reference at netlist time, because dgenWriteCDF passes
;      ?parseAsCEL=yes / ?parseAsNumber=yes. The .va parameter still
;      carries its literal-0 fallback (Verilog-A requires literal
;      parameter defaults), but CDF's defValue overrides at the instance
;      level so Cadence resolves the identifier through ADE design vars.
;      A printf surfaces this so a typo (e.g. "lO" instead of "10") is
;      not silently interpreted as an undefined variable reference.
; Anything else (empty string, decimals on digital, expressions, garbage)
; falls back to "0" so a malformed value can't break the CDF load.
;
; Implementation note: uses pcreMatchp (sklangref.pdf p.186), NOT
; rexMatchp (p.208). Cadence's rex flavor doesn't list `?` as a quantifier
; (only `*` and `+` are documented as quantifiers) and treats `(...)` as
; literal parens (only `\(...\)` is a group) -- the previous rex-based
; check `^-?[0-9]+\(\.[0-9]+\)?$` rejected legitimate values like "1.8"
; because the group-level `?` is unsupported. pcre is Perl-compatible and
; supports both `?` and `(...)` reliably.

(defun dgen_emitDefaultStr (item "g")
  (let ((d (get item 'default)) (analog (equal (get item 'kind) "analog")))
    (cond
      ((null d) "0")
      ((stringp d)
        (cond
          ; integer literal -- digital + analog, preserved verbatim
          ((pcreMatchp "^-?[0-9]+$" d) d)
          ; real literal -- analog only; digital falls through to "0"
          ((and analog (pcreMatchp "^-?[0-9]+\\.[0-9]+$" d)) d)
          ; Verilog identifier -- CEL variable reference
          ((pcreMatchp "^[A-Za-z_][A-Za-z0-9_]*$" d)
            (printf
              "[dreg-gen] '%s' default '%s' interpreted as CEL variable reference (resolved via ADE design vars at netlist time)\n"
              (get item 'name) d)
            d)
          ; defensive fallback
          (t "0")))
      ((integerp d) (sprintf nil "%d" d))
      ((numberp d)  (sprintf nil "%g" d))
      (t "0"))))
