; dgenStore.il -- Step 1 of Dreg Generator: spec serialization, cell-property and last-state I/O,
; and the shared emit-item iterator that unifies pins + customVars for the downstream generators.
;
; Last-state schema:
;   v1 (legacy): plist with targetLib, targetCellTpl, dvddDefault, defaultMode,
;                defaultPattern, pinStates. No 'schemaVersion key.
;   v2          : v1 + 'schemaVersion 2 + 'lastDutLib / 'lastDutCell / 'lastDutView.
;   v3 (current): v2 + 'customVarStates (list of customVar plists; absent in v1/v2 = empty list).
;
; Migration policy: silent forward-only.
;   - Reader returns the plist verbatim; consumers use `get` so missing fields
;     read as nil. v1 files therefore yield nil for lastDutLib/Cell/View, which
;     is the desired fallback. v1/v2 files yield nil for customVarStates which
;     the GUI treats as empty list. Future v4+ fields are also returned
;     verbatim and ignored by current consumers.
;   - Writer always stamps 'schemaVersion 2 (auto-injected if not already in
;     the input plist) -- v3 fields are additive plist entries on top of v2 so
;     the version stamp stays at 2 and old GUIs reading new files just skip
;     'customVarStates harmlessly. (No v3-specific reader/writer functions
;     are needed -- presence of the 'customVarStates key IS the version probe.)
;
; SPEC SHAPE (in-memory; not the same as last-state file shape):
;   spec is a plist:
;     'source         (nil 'lib L 'cell C 'view V)         ; DUT cellview
;     'target         (nil 'lib L 'cell C 'view "veriloga"); generated Dreg cellview
;     'dvddDefault    "0.9"                                ; string, .va parameter
;     'defaultMode    "literal" | "empty" | "variable_pin" | "custom"
;     'defaultPattern "d_*" or similar                     ; only used in "custom"
;     'pins           list of pin plists from dgenScanPins
;     'customVars     list of customVar plists             ; user-added in GUI; NEW
;
;   pin plist (from dgenScanPins, augmented in GUI):
;     'name, 'isBus, 'busHi, 'busLo, 'srcDirection, 'enabled, 'default
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
;   Pins are always digital (auto-discovered from cv~>terminals). CustomVars
;   carry their kind explicitly. The dgen_specEmitList helper unifies both
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
(defun dgenSavePropOnCell (libName cellName viewName spec "tttg")
  (let ((cv (dbOpenCellViewByType libName cellName viewName nil "a")))
    (unless cv (error "dgenSavePropOnCell: cannot open %s/%s/%s for append" libName cellName viewName))
    (dbReplaceProp cv "dgenConfig" "string" (dgenSpecToString spec))
    (dbSave cv)
    (dbClose cv)
    t))

(defun dgenLoadPropFromCell (libName cellName viewName "ttt")
  (let ((cv (dbOpenCellViewByType libName cellName viewName nil "r")) p out)
    (when cv
      (setq p (dbFindProp cv "dgenConfig"))
      (when p (setq out (dgenStringToSpec p~>value)))
      (dbClose cv))
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
; 'default but no 'kind -- this helper splices kind="digital" onto enabled pins
; because every pin emitted by Dreg is a digital drive (V<+d*DVDD per bit).
; CustomVars already carry their own 'kind from the GUI.
;
; Disabled pins are dropped here. CustomVars have no enabled flag -- to disable
; one, the user deletes the row in the GUI; entries present in the list are
; always emitted.

(defun dgen_specEmitList (spec "g")
  (let (out)
    (foreach p (get spec 'pins)
      (when (get p 'enabled)
        (setq out (cons (append p (list 'kind "digital")) out))))
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
