; vhGui.il -- Verilog Helper: a THIN SKILL launcher for the Python pipeline.
;
; The whole tool is Python (stdlib-only CLIs). This .il is ONLY a launcher:
; it picks a DUT in the schematic, gathers paths, and shells out (system())
; to the vh_*.py CLIs -- no skillbridge, no logic in SKILL. Same pattern as
; note_helper/nhGui.il (system() + temp file) and dreg_gen/dgenGui.il
; (Lib/Cell/View combos + [Select from Schematic] + [Browse Library...]).
;
;   [Source Lib/Cell/View combos]   <- ddHiCreate*ComboField (from dgenGui.il)
;   [Select from Schematic] [Browse Library...]
;   config(expand.cfg) / cds.lib / captured netlist / Output folder
;   checks.json / user testbench
;   external -v lib  [Add -v lib] [Show env]      <- vh_env.py
;   [Extract A] [Convert B] [Generate C] [Package D]   <- the four CLIs
;   Status
;
; Each action button builds an argv string and runs the matching CLI through
; vh_runCLI, which redirects stdout+stderr to a temp file, system()s it, prints
; the full log to the CIW, and surfaces a one-line summary on the Status field.
;
; Refs: skuiref.pdf hiCreateAppForm p.502, hiInstantiateForm p.767,
;   hiSetFormSize p.813, hiDisplayForm p.688, hiCreateStringField p.650,
;   hiCreateCyclicField p.536, hiCreateButton p.524,
;   hiCreateFileSelectorField p.542; ddHiCreateLibraryComboField p.484,
;   ddHiCreateCellComboField p.481, ddHiCreateViewComboField p.487,
;   ddHiLinkFields p.495; enterPoint p.1197, cancelEnterFun p.1229;
;   ddsSyncWithForm skdfref.pdf p.1904, ddsEndSyncWithForm p.1909;
;   dbGetOverlaps skdfref.pdf p.1317; system sklangref.pdf p.638,
;   makeTempFileName p.446, infile p.423, gets p.420, deleteFile p.620.

; ---------------------------------------------------------------------------
; State globals (idempotent -- never clobber on reload, like nhStore.il).
; ---------------------------------------------------------------------------

; Shell command that runs Python 3 (override for a site python3).
(unless (boundp 'vh_pythonCmd)  (setq vh_pythonCmd "python3"))

; Shell prefix prepended to every CLI launch. Default empty (inherit Virtuoso's
; env -- the vh_*.py are stdlib-only, no Tk, so they don't hit the Tcl/Tk env
; poison note_helper had). If a poisoned LD_LIBRARY_PATH ever breaks the system
; python3 launched from Virtuoso, set this to e.g.
;   (setq vh_shellPrefix "env -u LD_LIBRARY_PATH")
; (Ref memory: reference_cadence_tcltk_env_poison / feedback_virtuoso_external_env_debug.)
(unless (boundp 'vh_shellPrefix) (setq vh_shellPrefix ""))

; Absolute dir holding the vh_*.py CLIs. nil => resolve at call time from
; verilog_helperDir / skillTools_root / a compile-time fallback (vh_dir).
(unless (boundp 'vh_scriptDir)  (setq vh_scriptDir nil))

; Default folder for the Browse buttons + Output field (nil => resolve at open).
(unless (boundp 'vh_browseDir)  (setq vh_browseDir nil))

; ---------------------------------------------------------------------------
; Small helpers
; ---------------------------------------------------------------------------

; Resolve the form a callback fired from. Prefer hiGetCurrentForm so multiple
; open windows (e.g. after a dev reload) each read their OWN fields; fall back
; to the vh_form global. (Ref nhGui.il nh_curForm.)
(defun vh_curForm ()
  (or (hiGetCurrentForm) (and (boundp 'vh_form) vh_form)))

; Set the (top-level) Status line on the live form. All vh_ fields are
; top-level (no tab pages), so form->name is a valid all-literal path and
; assigns directly (no evalstring dance). (Ref nhGui.il nh_setStatus.)
(defun vh_setStatus (form msg)
  (errset (form->vh_status->value = msg) t))

; Coerce a field value to a trimmed string ("" for nil / non-string / blank).
(defun vh_str (v "g")
  (cond
    ((not (stringp v)) "")
    (t (pcreReplace (pcreCompile "^\\s+|\\s+$") v "" 0))))

; Quote a path for the shell (double-quotes tolerate spaces). "" stays "".
(defun vh_q (s "t")
  (if (equal s "") "" (strcat "\"" s "\"")))

; Resolve the directory that DIRECTLY contains the vh_*.py CLIs, with a
; trailing "/". Priority: explicit vh_scriptDir > verilog_helperDir (the
; loader's global) > skillTools_root + "verilog_helper/" > compile-time path.
(defun vh_dir ()
  (let (d)
    (setq d
      (cond
        ((and (boundp 'vh_scriptDir) vh_scriptDir (stringp vh_scriptDir)) vh_scriptDir)
        ((and (boundp 'verilog_helperDir) verilog_helperDir) verilog_helperDir)
        ((and (boundp 'skillTools_root) skillTools_root)
          (strcat skillTools_root "verilog_helper/"))
        (t "/home/yusheng/cadence_work/Test/workarea/skill_tools/verilog_helper/")))
    (unless (pcreMatchp "/$" d) (setq d (strcat d "/")))
    d))

; Default browse/output dir: explicit vh_browseDir, else $WORK_ROOT2, else ".".
(defun vh_defaultDir ()
  (let (w)
    (cond
      ((and vh_browseDir (isDir vh_browseDir)) vh_browseDir)
      ((and (setq w (getShellEnvVar "WORK_ROOT2")) (not (equal w "")) (isDir w)) w)
      (t "."))))

; Read a whole text file into a string, preserving newlines (Ref nhCore.il
; nh_readFile: gets keeps the newline so concatenation rebuilds the file).
(defun vh_readFile (path "t")
  (let (port line out)
    (setq port (infile path))
    (cond
      ((null port) "")
      (t
        (setq out "")
        (while (gets line port) (setq out (strcat out line)))
        (close port)
        out))))

; Write a string to a file (overwriting). Returns t / nil.
(defun vh_writeFile (path str "tg")
  (let ((port (outfile path "w")))
    (cond
      ((null port) nil)
      (t (fprintf port "%s" (or str "")) (close port) t))))

; Last non-empty line of a log, trimmed + capped -- used for the Status line.
(defun vh_lastLine (txt "t")
  (let (lines last)
    (setq last "")
    (foreach line (parseString (or txt "") "\n")
      (when (and (stringp line) (not (equal (vh_str line) "")))
        (setq last (vh_str line))))
    (if (greaterp (length last) 90) (substring last 1 90) last)))

; Run an arbitrary shell command, capturing stdout+stderr to a temp log.
; Returns (list rc logText). (NOT cons -- SKILL's cons REQUIRES its 2nd arg to
; be a list, so (cons rc txt) on a string txt errors "argument #2 should be a
; list"; a flat (list ...) is the right pair container. Caught live via
; skillbridge.) Prints the launch line + full log to the CIW so the user sees
; progress even while Virtuoso is blocked on the synchronous system().
(defun vh_runShell (cmd "t")
  (let (logFile full rc txt)
    (setq logFile (makeTempFileName "/tmp/vh_run"))
    (setq full (sprintf nil "%s > %s 2>&1" cmd (vh_q logFile)))
    (printf "[verilog-helper] %s\n" cmd)
    (setq rc (system full))
    (setq txt (if (isFile logFile) (vh_readFile logFile) ""))
    (errset (deleteFile logFile) t)
    (printf "[verilog-helper] exit=%d\n%s\n" rc txt)
    (list rc txt)))

; Run one CLI: <prefix> python3 <dir>/<script> <argStr>  (via vh_runShell).
(defun vh_runCLI (script argStr "tt")
  (let (scriptPath)
    (setq scriptPath (strcat (vh_dir) script))
    (unless (isFile scriptPath)
      (error (strcat "verilog-helper: CLI not found: " scriptPath)))
    (vh_runShell (sprintf nil "%s %s %s %s"
                   vh_shellPrefix vh_pythonCmd (vh_q scriptPath) argStr))))

; Run a CLI and report on the Status line: exit 0 -> last log line; else "FAILED".
(defun vh_runReport (form stageLabel script argStr "gttt")
  (let (res rc txt)
    (vh_setStatus form (strcat stageLabel ": running... (see CIW)"))
    (setq res (errset (vh_runCLI script argStr) t))
    (cond
      ((null res)
        (vh_setStatus form (strcat stageLabel ": launch error -- see CIW"))
        nil)
      (t
        (setq rc  (car  (car res)))
        (setq txt (cadr (car res)))
        (cond
          ((equal rc 0)
            (vh_setStatus form (strcat stageLabel " OK: " (vh_lastLine txt)))
            t)
          (t
            (vh_setStatus form (sprintf nil "%s FAILED (exit %d) -- see CIW" stageLabel rc))
            nil))))))

; Common precheck: the Output folder field, required by A/B/C/D. Returns the
; trimmed path, or nil after setting the Status line if it is blank.
(defun vh_needOut (form "g")
  (let ((out (vh_str form->vh_out->value)))
    (cond
      ((equal out "")
        (vh_setStatus form "set an Output folder first")
        nil)
      (t out))))

; ---------------------------------------------------------------------------
; Action callbacks -- one per pipeline stage. Each maps form fields -> argv.
; ---------------------------------------------------------------------------

; Stage A (vh_extract.py): config(+cdslib) OR standalone lib/cell/view ->
; structural top + gathered .va + manifest_A.json in <out>. A captured netlist
; skips oa2verilog. --cell retargets the DUT when a config points at a TB.
(defun vh_extractCB (form "g")
  (let (out cfg cdslib netlist lib cell view args ready)
    (cond
      ((null (setq out (vh_needOut form))) nil)
      (t
        (setq cfg     (vh_str form->vh_cfg->value))
        (setq cdslib  (vh_str form->vh_cdslib->value))
        (setq netlist (vh_str form->vh_netlist->value))
        (setq lib     (vh_str form->vh_srcLib->value))
        (setq cell    (vh_str form->vh_srcCell->value))
        (setq view    (vh_str form->vh_srcView->value))
        (setq args (strcat "--out " (vh_q out)))
        (setq ready t)
        (cond
          ((not (equal cfg ""))
            ; config-driven: --config (+ --cell to retarget the DUT, + --cdslib)
            (setq args (strcat args " --config " (vh_q cfg)))
            (unless (equal cell "") (setq args (strcat args " --cell " cell)))
            (unless (equal cdslib "") (setq args (strcat args " --cdslib " (vh_q cdslib)))))
          ((and (not (equal lib "")) (not (equal cell "")))
            ; standalone: --lib --cell --view (no config)
            (setq args (strcat args " --lib " lib " --cell " cell
                          " --view " (if (equal view "") "schematic" view)))
            (unless (equal cdslib "") (setq args (strcat args " --cdslib " (vh_q cdslib)))))
          (t
            ; no usable source -- hint on Status and skip the run (return cleanly,
            ; do NOT (error ...): a raised error from a button callback dumps a
            ; stack to the CIW; the Status hint is the right UX).
            (vh_setStatus form "Stage A needs a config (expand.cfg) OR a Source Lib+Cell")
            (setq ready nil)))
        (when ready
          (unless (equal netlist "") (setq args (strcat args " --netlist " (vh_q netlist))))
          (vh_runReport form "Stage A" "vh_extract.py" args))))
    t))

; Stage B (vh_convert.py): convert the manifest's analog leaves to wreal,
; emit the detection list, and (unless [Write candidate]=no) drop a
; veriloga_wreal.va candidate beside each cell for the user to review.
(defun vh_convertCB (form "g")
  (let (out manifest args write)
    (cond
      ((null (setq out (vh_needOut form))) nil)
      (t
        (setq manifest (strcat out "/manifest_A.json"))
        (cond
          ((not (isFile manifest))
            (vh_setStatus form "no manifest_A.json -- run Extract (A) first"))
          (t
            (setq write (vh_str form->vh_bwrite->value))
            (setq args (strcat "--manifest " (vh_q manifest)))
            ; default writes the candidate beside the cell (the user's intent);
            ; "no" keeps everything out of the OA lib (--no-cell-write).
            (when (equal write "no") (setq args (strcat args " --no-cell-write")))
            (vh_runReport form "Stage B" "vh_convert.py" args)))))
    t))

; Stage C (vh_gen.py): TB + wreal stubs + run.sh from <out>/export (the gathered
; sources). A user testbench (--tb) wins over generated checks (--checks).
(defun vh_genCB (form "g")
  (let (out src sim checks tb args)
    (cond
      ((null (setq out (vh_needOut form))) nil)
      (t
        (setq src (strcat out "/export"))
        (setq sim (strcat out "/sim"))
        (cond
          ((not (isDir src))
            (vh_setStatus form "no export/ -- run Extract (A) first"))
          (t
            (setq checks (vh_str form->vh_checks->value))
            (setq tb     (vh_str form->vh_tb->value))
            (setq args (strcat "--src " (vh_q src) " --out " (vh_q sim)))
            (cond
              ((not (equal tb "")) (setq args (strcat args " --tb " (vh_q tb))))
              ((not (equal checks "")) (setq args (strcat args " --checks " (vh_q checks)))))
            (vh_runReport form "Stage C" "vh_gen.py" args)))))
    t))

; Stage D (vh_package.py): pack <out>/sim into a relocatable air-gap bundle.
(defun vh_packageCB (form "g")
  (let (out sim args)
    (cond
      ((null (setq out (vh_needOut form))) nil)
      (t
        (setq sim (strcat out "/sim"))
        (cond
          ((not (isDir sim))
            (vh_setStatus form "no sim/ -- run Generate (C) first"))
          (t
            (setq args (strcat "--build " (vh_q sim)))
            (vh_runReport form "Stage D" "vh_package.py" args)))))
    t))

; [Run xrun]: execute <out>/sim/run.sh -- the pure-digital xrun the whole tool
; exists to drive -- and surface its verdict on the Status line. (run.sh cd's to
; its own dir + sources setup_env.sh, so a bare `bash <path>` is self-contained:
; ambient xrun on the red zone, dev Xcelium fallback otherwise.) Pure-digital
; wreal exits 0 even with benign spectre-license warnings, so the "=== TB PASS"
; marker in the log -- not the exit code -- is the real verdict.
(defun vh_runCB (form "g")
  (let (out runsh res rc txt verdict kind)
    (cond
      ((null (setq out (vh_needOut form))) nil)
      (t
        (setq runsh (strcat out "/sim/run.sh"))
        (cond
          ((not (isFile runsh))
            (vh_setStatus form "no sim/run.sh -- run Generate (C) first"))
          (t
            (vh_setStatus form "Run: xrun running... (see CIW)")
            (setq res (errset (vh_runShell (strcat "bash " (vh_q runsh))) t))
            (cond
              ((null res) (vh_setStatus form "Run: launch error -- see CIW"))
              (t
                (setq rc  (car  (car res)))
                (setq txt (cadr (car res)))
                (setq verdict
                  (cond
                    ((pcreMatchp "=== TB PASS" txt) "=== TB PASS ===")
                    ((pcreMatchp "=== TB FAIL" txt) "=== TB FAIL ===  -- see CIW")
                    (t (sprintf nil "xrun exit %d (no PASS/FAIL line -- see CIW)" rc))))
                ; run.sh echoes RUN-KIND: SMOKE (externals stubbed) vs FUNCTIONAL
                ; (all resolved). Tag it so a dev/stubbed smoke pass is NEVER
                ; mistaken for a real verification.
                (setq kind
                  (cond
                    ((pcreMatchp "RUN-KIND: SMOKE" txt)      "  [SMOKE: externals stubbed]")
                    ((pcreMatchp "RUN-KIND: FUNCTIONAL" txt) "  [functional: all ext resolved]")
                    (t "")))
                (vh_setStatus form (strcat "Run: " verdict kind))))))))
    t))

; External env: remember a -v library file (vh_env.py add-lib <path>). The
; tool then resolves externals found there automatically in A/C.
(defun vh_envAddCB (form "g")
  (let ((lib (vh_str form->vh_extLib->value)))
    (cond
      ((equal lib "")
        (vh_setStatus form "pick an external -v library file to remember"))
      ((not (isFile lib))
        (vh_setStatus form "external -v file not found -- check the path"))
      (t
        (vh_runReport form "env add-lib" "vh_env.py" (strcat "add-lib " (vh_q lib)))))
    t))

; External env: print the remembered env (and which modules it provides) to CIW.
(defun vh_envShowCB (form "g")
  (vh_runReport form "env show" "vh_env.py" "show")
  t)

; ---------------------------------------------------------------------------
; [Scan Pins] -- scan the DUT cellview's terminals (name + input/output/inout
; + bus range) and hand the list back three ways: onto the clipboard (paste it
; straight to me as the basis for the testbench), to a <cell>_pins.txt file, and
; to the CIW. Reuses dreg_gen's dgenScanPins when present (bus<hi:lo> merge);
; falls back to a self-contained scalar scan otherwise.
; ---------------------------------------------------------------------------

; Normalize an OA terminal direction to input/output/inout.
(defun vh_normDir (d "g")
  (cond
    ((equal d "input")  "input")
    ((equal d "output") "output")
    ((member d (list "inputOutput" "inout" "io")) "inout")
    (t (or d "inout"))))

; Self-contained fallback scan (scalar only, no bus merge) -- used if dreg_gen's
; dgenScanPins isn't loaded. Returns dgenScanPins-shaped descriptors.
(defun vh_scanPinsLocal (lib cell view "ttt")
  (let (cv out)
    (setq cv (dbOpenCellViewByType lib cell view nil "r"))
    (unless cv (error (strcat "vh_scanPins: cannot open " lib "/" cell "/" view)))
    (foreach term cv~>terminals
      (setq out (cons (list nil 'name term~>name 'isBus nil
                            'srcDirection (or term~>direction "inout")) out)))
    (dbClose cv)
    (reverse out)))

; Pin descriptors for lib/cell/view (dgenScanPins if available, else local).
(defun vh_scanPins (lib cell view "ttt")
  (if (getd 'dgenScanPins) (dgenScanPins lib cell view)
    (vh_scanPinsLocal lib cell view)))

; Format the descriptors into a paste-friendly, parseable table.
(defun vh_fmtPins (descs lib cell view "lttt")
  (let (plines)
    (foreach d descs
      (let (nm bus)
        (setq nm (get d 'name))
        (setq bus (if (get d 'isBus)
                      (sprintf nil "<%d:%d>" (get d 'busHi) (get d 'busLo)) ""))
        (setq plines (cons (sprintf nil "%-24s %s"
                             (strcat nm bus) (vh_normDir (get d 'srcDirection))) plines))))
    (buildString
      (append
        (list (sprintf nil "# pins  %s/%s:%s  (%d)" lib cell view (length descs))
              (sprintf nil "# %-22s %s" "name" "dir"))
        (reverse plines))
      "\n")))

(defun vh_scanPinsCB (form "g")
  (let (lib cell view descs txt out path)
    (setq lib  (vh_str form->vh_srcLib->value))
    (setq cell (vh_str form->vh_srcCell->value))
    (setq view (vh_str form->vh_srcView->value))
    (when (equal view "") (setq view "symbol"))
    (cond
      ((or (equal lib "") (equal cell ""))
        (vh_setStatus form "set Source Lib + Cell first (or Select from Schematic)"))
      ((null (ddGetObj lib cell))
        (vh_setStatus form (sprintf nil "%s/%s not found" lib cell)))
      (t
        (setq descs (car (errset (vh_scanPins lib cell view) t)))
        ; pins live on the symbol -- if the chosen view has none, retry symbol
        (when (and (null descs) (nequal view "symbol"))
          (setq descs (car (errset (vh_scanPins lib cell "symbol") t)))
          (when descs (setq view "symbol")))
        (cond
          ((null descs)
            (vh_setStatus form
              (sprintf nil "no pins on %s/%s (try a symbol/schematic view)" lib cell)))
          (t
            (setq txt (vh_fmtPins descs lib cell view))
            (printf "%s\n" txt)                          ; CIW
            (errset (hiSetClipboard txt) t)              ; clipboard
            (setq out (vh_str form->vh_out->value))
            (setq path (strcat (if (equal out "") "/tmp" out) "/" cell "_pins.txt"))
            (errset (vh_writeFile path txt) t)           ; file export
            (vh_setStatus form
              (sprintf nil "scanned %d pins -> clipboard + %s (+ CIW)"
                (length descs) path))))))
    t))

; ---------------------------------------------------------------------------
; [Select from Schematic] -- interactive instance pick (copied from
; dgenGui.il's enterPoint + dbGetOverlaps hit-test, which is the proven path:
; enterPoint only captures a COORDINATE, so we hit-test it to find the
; instance, then read its master lib/cell into the Source combos).
; ---------------------------------------------------------------------------

(defun vh_selSchemCB (form "g")
  (cond
    ((greaterp (enterFunNestLevel) 0)
      (warn "[verilog-helper] Already in pick mode. Click an instance, or Esc to cancel.\n")
      nil)
    (t
      (enterPoint
        ?prompts (list "Click an instance in a schematic. Esc to cancel.")
        ?cmdName "vhSelInst"
        ?doneProc "vh_selSchemDone")
      t)))

; doneProc (window done points): hit-test the captured click point against the
; schematic and populate the Source combos from the picked instance's master.
(defun vh_selSchemDone (w done pts "ggg")
  (cond
    ((null done) nil)        ; Esc / cancel
    ((null w)    nil)
    ((or (null (boundp 'vh_form)) (null vh_form))
      (printf "[verilog-helper] pick fired but the form is gone -- ignoring.\n") nil)
    ((null pts)
      (printf "[verilog-helper] pick fired with no point -- ignoring.\n") nil)
    (t
      (let (cvOk cv pt eps bbox objsOk objs insts)
        (setq cvOk (errset (geGetWindowCellView w) t))
        (cond
          ((or (null cvOk) (null (car cvOk)))
            (vh_pickWarn "Pick window has no cellview. Click in a schematic."))
          (t
            (setq cv (car cvOk))
            (cond
              ((not (equal cv~>cellViewType "schematic"))
                (vh_pickWarn "Pick window is not a schematic. Try again."))
              (t
                (setq pt (car pts))
                (setq eps 0.01)
                (setq bbox (list
                             (list (difference (xCoord pt) eps) (difference (yCoord pt) eps))
                             (list (plus       (xCoord pt) eps) (plus       (yCoord pt) eps))))
                (setq objsOk (errset (dbGetOverlaps cv bbox) t))
                (cond
                  ((or (null objsOk) (null (car objsOk)))
                    (vh_pickWarn "No instance at the click point. Click on an instance body."))
                  (t
                    (setq objs (car objsOk))
                    (setq insts
                      (setof o objs
                        (and (not (listp o))
                             (equal (errset o~>objType t) (list "inst")))))
                    (cond
                      ((null insts)
                        (vh_pickWarn "Selected object is not an instance. Click an instance body."))
                      (t
                        (vh_applyPicked (car insts))))))))))))))

; Warning dialog for the pick path (small wrapper -- skuiref hiDisplayAppDBox).
(defun vh_pickWarn (msg "t")
  (hiDisplayAppDBox
    ?name 'vhSelWarn ?dboxBanner "Select from Schematic"
    ?dboxText msg ?dialogType hicWarningDialog ?buttonLayout 'Close))

; From the picked instance, write master lib/cell into the Source combos. The
; combos are populated via evalstring + infix `=` (the proven dgenGui.il idiom
; for writing ddHiCreate*ComboField values; one-line strings per the
; skillbridge-evalstring memory). View defaults to schematic for extraction.
(defun vh_applyPicked (chosen "g")
  (let (master lib cell)
    (cond
      ((or (null chosen) (not (equal chosen~>objType "inst")))
        (vh_pickWarn "Selected object is not an instance.") nil)
      (t
        (setq master chosen~>master)
        (setq lib    (and master master~>libName))
        (setq cell   (and master master~>cellName))
        (cond
          ((or (null lib) (null cell))
            (vh_pickWarn "Selected instance has no master lib/cell.") nil)
          (t
            (evalstring (sprintf nil "vh_form->vh_srcLib->value = \"%s\"" lib))
            (evalstring (sprintf nil "vh_form->vh_srcCell->value = \"%s\"" cell))
            (evalstring "vh_form->vh_srcView->value = \"schematic\"")
            (vh_setStatus vh_form
              (sprintf nil "picked %s/%s -- set config + Output, then Extract (A)" lib cell))
            t))))))

; [Browse Library...] -- link the Library Manager to the Source combos (copied
; from dgenGui.il: pass the form RECORD, omit l_viewTypes so all views show).
(defun vh_browseCB (form "g")
  (let ((rc (errset
              (ddsSyncWithForm form 'browse 'vh_srcLib 'vh_srcCell 'vh_srcView) t)))
    (cond
      ((or (null rc) (null (car rc)))
        (vh_setStatus form "Library Browser link failed -- see CIW") nil)
      (t
        (printf "[verilog-helper] Library Browser linked. Pick a cell/view in the tree.\n")
        (vh_setStatus form "Library Browser linked -- pick a cell in the tree")
        t))))

; Form-close cleanup: cancel a pending pick + tear down any browse link, on
; every close path (OK / Cancel / X). Both wrapped in errset (may be no-ops).
(defun vh_closeCleanupCB (form "g")
  (when (greaterp (enterFunNestLevel) 0) (errset (cancelEnterFun) t))
  (errset (ddsEndSyncWithForm) t)
  t)

; ---------------------------------------------------------------------------
; Form
; ---------------------------------------------------------------------------

; Configure a hiCreateFileSelectorField's Browse dialog (open dir + caption +
; filter, return an absolute path). Ref nhGui.il nh_cfgFileSel.
(defun vh_cfgFileSel (fld caption filter "gtt")
  (let ((dir (vh_defaultDir)))
    (when fld
      fld->hiFileDialogWorkingDir = dir
      fld->hiFileDialogCaption    = caption
      fld->hiFileDialogFilter     = filter
      fld->hiSimplifyFilename     = t))
  t)

(defun vh_guiBuild ()
  (let (fLib fCell fView fSel fBrowse fScan
        fCfg fCds fNet fOut fChecks fTb fBwrite fExt fAddLib fShow
        fA fB fC fRun fD fStatus
        form fieldW promptW rowH sizePt btnH preDir)
    (setq rowH 28) (setq fieldW 380) (setq promptW 155)
    (setq sizePt (list fieldW rowH)) (setq btnH rowH)
    (setq preDir (vh_defaultDir))
    ; ----- Source Lib/Cell/View combos (linked after instantiate) -----
    (setq fLib  (ddHiCreateLibraryComboField ?name 'vh_srcLib  ?prompt "Source Lib"
                  ?defValue "" ?value ""))
    (setq fCell (ddHiCreateCellComboField    ?name 'vh_srcCell ?prompt "Source Cell (DUT)"
                  ?defValue "" ?value ""))
    (setq fView (ddHiCreateViewComboField    ?name 'vh_srcView ?prompt "Source View"
                  ?defValue "schematic" ?value "schematic"))
    (setq fSel    (hiCreateButton ?name 'vh_btnSel ?buttonText "Select from Schematic"
                    ?callback "(vh_selSchemCB (vh_curForm))"))
    (setq fBrowse (hiCreateButton ?name 'vh_btnBrowse ?buttonText "Browse Library..."
                    ?callback "(vh_browseCB (vh_curForm))"))
    (setq fScan   (hiCreateButton ?name 'vh_btnScan ?buttonText "Scan Pins"
                    ?callback "(vh_scanPinsCB (vh_curForm))"))
    ; ----- inputs -----
    (setq fCfg (hiCreateFileSelectorField ?name 'vh_cfg ?mode 'existingFile
                 ?prompt "config (expand.cfg)" ?value ""))
    (vh_cfgFileSel fCfg "Choose expand.cfg" "Config (*.cfg);;All Files (*)")
    (setq fCds (hiCreateFileSelectorField ?name 'vh_cdslib ?mode 'existingFile
                 ?prompt "cds.lib (optional)" ?value ""))
    (vh_cfgFileSel fCds "Choose cds.lib" "cds.lib (cds.lib);;All Files (*)")
    (setq fNet (hiCreateFileSelectorField ?name 'vh_netlist ?mode 'existingFile
                 ?prompt "captured netlist (optional)" ?value ""))
    (vh_cfgFileSel fNet "Choose a captured oa2verilog .v" "Verilog (*.v);;All Files (*)")
    (setq fOut (hiCreateStringField ?name 'vh_out ?prompt "Output folder" ?value preDir))
    (setq fChecks (hiCreateFileSelectorField ?name 'vh_checks ?mode 'existingFile
                    ?prompt "checks.json (Stage C)" ?value ""))
    (vh_cfgFileSel fChecks "Choose checks.json" "JSON (*.json);;All Files (*)")
    (setq fTb (hiCreateFileSelectorField ?name 'vh_tb ?mode 'existingFile
                ?prompt "user testbench (optional)" ?value ""))
    (vh_cfgFileSel fTb "Choose a testbench" "Verilog (*.v *.vams *.va);;All Files (*)")
    (setq fBwrite (hiCreateCyclicField ?name 'vh_bwrite
                    ?prompt "Stage B: write candidate beside cell"
                    ?choices (list "yes" "no") ?value "yes"))
    ; ----- external env -----
    (setq fExt (hiCreateFileSelectorField ?name 'vh_extLib ?mode 'existingFile
                 ?prompt "external -v library" ?value ""))
    (vh_cfgFileSel fExt "Choose an external -v library file" "Verilog (*.v *.vams *.va);;All Files (*)")
    (setq fAddLib (hiCreateButton ?name 'vh_btnAddLib ?buttonText "Add -v lib"
                    ?callback "(vh_envAddCB (vh_curForm))"))
    (setq fShow   (hiCreateButton ?name 'vh_btnShow ?buttonText "Show env"
                    ?callback "(vh_envShowCB (vh_curForm))"))
    ; ----- stage actions -----
    (setq fA (hiCreateButton ?name 'vh_btnA ?buttonText "Extract A"
               ?callback "(vh_extractCB (vh_curForm))"))
    (setq fB (hiCreateButton ?name 'vh_btnB ?buttonText "Convert B"
               ?callback "(vh_convertCB (vh_curForm))"))
    (setq fC (hiCreateButton ?name 'vh_btnC ?buttonText "Generate C"
               ?callback "(vh_genCB (vh_curForm))"))
    (setq fRun (hiCreateButton ?name 'vh_btnRun ?buttonText "Run xrun"
                 ?callback "(vh_runCB (vh_curForm))"))
    (setq fD (hiCreateButton ?name 'vh_btnD ?buttonText "Package D"
               ?callback "(vh_packageCB (vh_curForm))"))
    (setq fStatus (hiCreateStringField ?name 'vh_status ?prompt "Status"
                    ?value "pick a DUT (or set config) + Output, then Extract (A)"
                    ?editable nil))
    ; ----- 2D layout: (field (x y) (w h) promptWidth) -----
    (setq form (hiCreateAppForm
      ?name 'vh_form
      ?formTitle "Verilog Helper"
      ?fields (list
        (list fLib    (list 0 0)    sizePt promptW)
        (list fCell   (list 0 28)   sizePt promptW)
        (list fView   (list 0 56)   sizePt promptW)
        (list fSel    (list 0 88)   (list 160 btnH) 0)
        (list fBrowse (list 165 88) (list 130 btnH) 0)
        (list fScan   (list 300 88) (list 110 btnH) 0)
        (list fCfg    (list 0 124)  sizePt promptW)
        (list fCds    (list 0 152)  sizePt promptW)
        (list fNet    (list 0 180)  sizePt promptW)
        (list fOut    (list 0 208)  sizePt promptW)
        (list fChecks (list 0 236)  sizePt promptW)
        (list fTb     (list 0 264)  sizePt promptW)
        (list fBwrite (list 0 292)  (list 340 rowH) 255)
        (list fExt    (list 0 324)  sizePt promptW)
        (list fAddLib (list 0 356)  (list 110 btnH) 0)
        (list fShow   (list 120 356) (list 110 btnH) 0)
        (list fA      (list 0 392)   (list 102 btnH) 0)
        (list fB      (list 105 392) (list 102 btnH) 0)
        (list fC      (list 210 392) (list 102 btnH) 0)
        (list fRun    (list 315 392) (list 102 btnH) 0)
        (list fD      (list 420 392) (list 102 btnH) 0)
        (list fStatus (list 0 428)  (list 525 rowH) 60))
      ?callback (list "(progn (vh_closeCleanupCB vh_form) t)"
                      "(progn (vh_closeCleanupCB vh_form) t)")
      ?buttonLayout 'Close))
    (hiInstantiateForm form)
    ; Link Lib->Cell->View dropdowns (requires instantiation -- skuiref p.495).
    (errset (ddHiLinkFields form->vh_srcLib form->vh_srcCell form->vh_srcView) t)
    ; hiSetFormSize AFTER instantiate (retracts the outer scrollbar -- Ref
    ; nhGui.il / form_mlt_wheel_propagation memory).
    (errset (hiSetFormSize form (list 560 530)) t)
    form))

; Open (build + display) the Verilog Helper form.
(defun vhOpenGUI ()
  (vh_guiBuild)
  (hiDisplayForm 'vh_form)
  'vh_form)

; ---------------------------------------------------------------------------
; MyTool plugin self-registration (getd guard -- loads cleanly without mytool).
; ---------------------------------------------------------------------------
(when (getd 'mtRegister)
  (mtRegister "Verilog Helper" 'vhOpenGUI "Open the Verilog Helper GUI"))
