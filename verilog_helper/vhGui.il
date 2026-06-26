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
;   checks.json / user testbench / Example TB (auto-discovered dropdown)
;   external -v lib  [Add -v lib] [Show env]      <- vh_env.py
;   xrun defines (Run)  <- forwarded to run.sh ("$@" -> e.g. +define+CHECK_NDIV)
;   [Extract A] [Convert B] [Generate C] [Run xrun] [Package D]   <- the CLIs
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

; Alist (label fullpath) of the example testbenches discovered under examples/.
; Rebuilt on every vh_guiBuild so a newly-added example TB shows up on reopen.
(unless (boundp 'vh_exTbMap)    (setq vh_exTbMap nil))

; --- async run state (Extract/Convert/Generate/Run/Package run in the BACKGROUND
; so Virtuoso stays responsive; a poll timer updates the Status line with elapsed
; time and the final result). Only one bg run at a time. ---
(unless (boundp 'vh_asyncBusy)  (setq vh_asyncBusy nil))   ; t while a bg run is active
(unless (boundp 'vh_asyncLog)   (setq vh_asyncLog nil))    ; the run's stdout/stderr log
(unless (boundp 'vh_asyncStage) (setq vh_asyncStage nil))  ; label, e.g. "Stage A"
(unless (boundp 'vh_asyncKind)  (setq vh_asyncKind "cli")) ; "cli" | "run"
(unless (boundp 'vh_asyncForm)  (setq vh_asyncForm nil))   ; form to report to
(unless (boundp 'vh_asyncTick)  (setq vh_asyncTick 0))     ; poll counter (for elapsed)

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

; Auto-write a temp cds.lib from the LIVE OA session (every defined lib + its
; readPath). Lets the GUI run Stage A without the user pointing at a cds.lib --
; the session already knows where every library lives. Returns the temp path, or
; nil if OA isn't reachable. (CLI users still pass --cdslib; this is GUI-only.)
(defun vh_autoCdslib ()
  (let (path port)
    (cond
      ((null (getd 'ddGetLibList)) nil)
      (t
        (setq path (makeTempFileName "/tmp/vh_cdslib"))
        (setq port (outfile path "w"))
        (cond
          ((null port) nil)
          (t
            (foreach lib (ddGetLibList)
              (errset (fprintf port "DEFINE %s %s\n" lib~>name lib~>readPath) t))
            (close port)
            path))))))

; Auto-find a config view's expand.cfg for lib/cell on disk (<libpath>/<cell>/
; config/expand.cfg). Returns the path if it exists, else nil. Most DUTs have no
; config view -> nil -> Stage A runs standalone from lib+cell (no config needed).
(defun vh_autoConfig (lib cell "tt")
  (let (lp cand)
    (setq lp (car (errset (let ((o (ddGetObj lib))) (and o o~>readPath)) t)))
    (cond
      ((not (stringp lp)) nil)
      (t
        (setq cand (strcat lp "/" cell "/config/expand.cfg"))
        (if (isFile cand) cand nil)))))

; Default browse/output dir: explicit vh_browseDir, else $WORK_ROOT2, else ".".
(defun vh_defaultDir ()
  (let (w)
    (cond
      ((and vh_browseDir (isDir vh_browseDir)) vh_browseDir)
      ((and (setq w (getShellEnvVar "WORK_ROOT2")) (not (equal w "")) (isDir w)) w)
      (t "."))))

; Discover the example testbenches shipped with the tool: examples/<ex>/tb_*.vams.
; Returns a list of (label fullpath) pairs, label = "<exdir>/<file>", so the GUI
; can offer a grow-by-itself dropdown of ready-made TBs (the user picks one + an
; export folder -> Generate C builds the test env, no CLI path-typing). A pure
; on-disk scan -> any future examples/<x>/tb_*.vams appears automatically on reopen.
(defun vh_exampleTBs ()
  (let (exRoot out)
    (setq exRoot (strcat (vh_dir) "examples"))
    (setq out nil)
    (when (isDir exRoot)
      (foreach sub (getDirFiles exRoot)
        (let (subPath)
          (setq subPath (strcat exRoot "/" sub))
          (when (and (nequal sub ".") (nequal sub "..") (isDir subPath))
            (foreach f (getDirFiles subPath)
              (when (pcreMatchp "^tb_.*\\.vams$" f)
                (setq out (cons (list (strcat sub "/" f)
                                      (strcat subPath "/" f)) out))))))))
    (reverse out)))

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

; Build a CLI command string (no redirection): <prefix> python3 <dir>/<script> <args>.
(defun vh_cliCmd (script argStr "tt")
  (let ((scriptPath (strcat (vh_dir) script)))
    (unless (isFile scriptPath)
      (error (strcat "verilog-helper: CLI not found: " scriptPath)))
    (sprintf nil "%s %s %s %s" vh_shellPrefix vh_pythonCmd (vh_q scriptPath) argStr)))

; Run `cmd` in the BACKGROUND (so Virtuoso never freezes), then poll for the
; result. A `.done` marker file (holding the exit code) appears when the command
; finishes; vh_pollAsync watches for it and writes the verdict to the Status line.
; kind = "cli" (exit-0 OK / else FAILED) | "run" (TB PASS/FAIL + RUN-KIND).
(defun vh_runAsync (form stage cmd kind "gttt")
  (cond
    (vh_asyncBusy
      (vh_setStatus form
        (sprintf nil "busy: %s still running -- wait for it to finish" vh_asyncStage))
      nil)
    (t
      (setq vh_asyncLog   (makeTempFileName "/tmp/vh_async"))
      (setq vh_asyncStage stage)
      (setq vh_asyncKind  kind)
      (setq vh_asyncForm  form)
      (setq vh_asyncTick  0)
      (setq vh_asyncBusy  t)
      (printf "[verilog-helper] (bg) %s\n" cmd)
      ; Run cmd in its OWN nested subshell so even a cmd that calls `exit` can't
      ; stop the outer shell from writing the exit code to <log>.done. The trailing
      ; & backgrounds the whole thing so system() returns immediately.
      (system (sprintf nil "( ( %s ) > %s 2>&1 ; echo $? > %s ) &"
                cmd (vh_q vh_asyncLog) (vh_q (strcat vh_asyncLog ".done"))))
      (vh_setStatus form
        (strcat stage ": running... (Virtuoso stays responsive; result appears here)"))
      (hiRegTimer "(vh_pollAsync)" 8)
      t)))

; Poll the running bg job: if its .done marker exists, read the exit code + log,
; write the verdict, and stop; otherwise update elapsed time and re-arm.
(defun vh_pollAsync ()
  (let (donef rc body)
    (cond
      ((null vh_asyncBusy) nil)
      (t
        (setq donef (strcat vh_asyncLog ".done"))
        (cond
          ((isFile donef)
            (setq rc   (atoi (vh_readFile donef)))
            (setq body (if (isFile vh_asyncLog) (vh_readFile vh_asyncLog) ""))
            (printf "[verilog-helper] %s done (exit=%d)\n%s\n" vh_asyncStage rc body)
            (vh_setStatus vh_asyncForm (vh_asyncVerdict rc body))
            (errset (deleteFile vh_asyncLog) t)
            (errset (deleteFile donef) t)
            (setq vh_asyncBusy nil))
          (t
            (setq vh_asyncTick (plus vh_asyncTick 1))
            (vh_setStatus vh_asyncForm
              (sprintf nil "%s: running %ds... (Virtuoso responsive)"
                vh_asyncStage (fix (times vh_asyncTick 0.8))))
            (hiRegTimer "(vh_pollAsync)" 8)))))
    t))

; Compute the Status verdict from a finished bg job's exit code + log text.
(defun vh_asyncVerdict (rc txt "xt")
  (let (v k)
    (cond
      ((equal vh_asyncKind "run")
        (setq v (cond
                  ((pcreMatchp "=== TB PASS" txt) "=== TB PASS ===")
                  ((pcreMatchp "=== TB FAIL" txt) "=== TB FAIL ===  -- see CIW")
                  (t (sprintf nil "xrun exit %d (no PASS/FAIL line -- see CIW)" rc))))
        (setq k (cond
                  ((pcreMatchp "RUN-KIND: SMOKE" txt)      "  [SMOKE: externals stubbed]")
                  ((pcreMatchp "RUN-KIND: FUNCTIONAL" txt) "  [functional: all ext resolved]")
                  (t "")))
        (strcat vh_asyncStage ": " v k))
      (t
        (if (equal rc 0)
            (strcat vh_asyncStage " OK: " (vh_lastLine txt))
            (sprintf nil "%s FAILED (exit %d) -- see CIW" vh_asyncStage rc))))))

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
        ; --- derive what the live OA session already knows, so the user only has
        ; to pick the DUT + Output ---
        ; cds.lib: if not given, auto-write one from the session's lib list.
        (when (equal cdslib "")
          (let ((ac (car (errset (vh_autoCdslib) t))))
            (when (and ac (stringp ac))
              (setq cdslib ac)
              (printf "[verilog-helper] auto cds.lib from session -> %s\n" ac))))
        ; config: optional. If not given but a config view exists for the DUT, use
        ; it; otherwise Stage A runs standalone from lib+cell.
        (when (and (equal cfg "") (not (equal lib "")) (not (equal cell "")))
          (let ((acfg (car (errset (vh_autoConfig lib cell) t))))
            (when (and acfg (stringp acfg))
              (setq cfg acfg)
              (printf "[verilog-helper] found config view -> %s\n" acfg))))
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
          (vh_runAsync form "Stage A" (vh_cliCmd "vh_extract.py" args) "cli"))))
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
            (vh_runAsync form "Stage B" (vh_cliCmd "vh_convert.py" args) "cli")))))
    t))

; Stage C (vh_gen.py): TB + wreal stubs + run.sh from the gathered sources, built
; into <out>/sim. Source = <out>/export (the normal extract layout); if that does
; not exist, fall back to <out> itself so the user can point Output straight at an
; export/ folder. Testbench precedence: explicit "user testbench" file > the
; "Example TB" dropdown > generated checks (--checks).
(defun vh_genCB (form "g")
  (let (out src sim checks tb exsel extb hit srcFiles args)
    (cond
      ((null (setq out (vh_needOut form))) nil)
      (t
        (setq src (strcat out "/export"))
        (unless (isDir src) (setq src out))      ; allow pointing Output AT an export/ dir
        (setq sim (strcat out "/sim"))
        (setq srcFiles
          (and (isDir src) (setof f (getDirFiles src) (pcreMatchp "\\.(v|va|vams)$" f))))
        (cond
          ((null srcFiles)
            (vh_setStatus form
              "no netlist -- run Extract (A), or point Output at the extract folder (has export/)"))
          (t
            (setq checks (vh_str form->vh_checks->value))
            (setq tb     (vh_str form->vh_tb->value))
            ; resolve the Example TB dropdown label -> full path via vh_exTbMap
            (setq exsel (vh_str form->vh_exTb->value))
            (setq extb "")
            (when (and (nequal exsel "") (nequal exsel "(none)")
                       (boundp 'vh_exTbMap) vh_exTbMap)
              (setq hit (assoc exsel vh_exTbMap))
              (when hit (setq extb (cadr hit))))
            (setq args (strcat "--src " (vh_q src) " --out " (vh_q sim)))
            (cond
              ((not (equal tb ""))     (setq args (strcat args " --tb " (vh_q tb))))
              ((not (equal extb ""))   (setq args (strcat args " --tb " (vh_q extb))))
              ((not (equal checks "")) (setq args (strcat args " --checks " (vh_q checks)))))
            (vh_runAsync form "Stage C" (vh_cliCmd "vh_gen.py" args) "cli")))))
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
            (vh_runAsync form "Stage D" (vh_cliCmd "vh_package.py" args) "cli")))))
    t))

; [Run xrun]: execute <out>/sim/run.sh -- the pure-digital xrun the whole tool
; exists to drive -- and surface its verdict on the Status line. (run.sh cd's to
; its own dir + sources setup_env.sh, so a bare `bash <path>` is self-contained:
; ambient xrun on the red zone, dev Xcelium fallback otherwise.) Pure-digital
; wreal exits 0 even with benign spectre-license warnings, so the "=== TB PASS"
; marker in the log -- not the exit code -- is the real verdict.
(defun vh_runCB (form "g")
  (let (out runsh defs cmd)
    (cond
      ((null (setq out (vh_needOut form))) nil)
      (t
        (setq runsh (strcat out "/sim/run.sh"))
        (cond
          ((not (isFile runsh))
            (vh_setStatus form "no sim/run.sh -- run Generate (C) first"))
          (t
            ; optional defines (e.g. "+define+CHECK_NDIV +define+WAVES") -> run.sh
            ; forwards "$@" to xrun. Blank = the generic completeness smoke run.
            (setq defs (vh_str form->vh_defs->value))
            (setq cmd (strcat "bash " (vh_q runsh)
                              (if (equal defs "") "" (strcat " " defs))))
            ; async (xrun can take seconds-minutes); verdict via RUN-KIND/PASS-FAIL
            (vh_runAsync form "Run" cmd "run")))))
    t))

; [Diagnose]: one-shot vh_diag.py over <out> -- cross-checks every instance vs its
; master's real ports (the *E,CUVPOM "port invalid" cause), lists unresolved masters
; (the *E,CUVMUR cause, with an on-disk veriloga/verilogams check via cds.lib so you
; can tell "should be gathered" from "will be stubbed"), and echoes the manifest +
; xrun.log digest into <out>/vh_diag.txt. Prints to the CIW and points Status at the
; file, so you copy ONE thing back instead of running greps by hand.
(defun vh_diagCB (form "g")
  (let (out cdslib args)
    (cond
      ((null (setq out (vh_needOut form))) nil)
      (t
        (setq cdslib (vh_str form->vh_cdslib->value))
        (when (equal cdslib "")
          (let ((ac (car (errset (vh_autoCdslib) t))))
            (when (and ac (stringp ac)) (setq cdslib ac))))
        (setq args (strcat "--build " (vh_q out)))
        (unless (equal cdslib "") (setq args (strcat args " --cdslib " (vh_q cdslib))))
        (errset (vh_runCLI "vh_diag.py" args) t)
        (vh_setStatus form
          (strcat "Diagnose done -> " out "/vh_diag.txt  (full report in the CIW; copy it back)"))))
    t))

; ---------------------------------------------------------------------------
; External libraries manager -- a multi-entry list (like AMS Options -> Include
; Option Settings -> Library Files). Several -v files / -y dirs / +incdir dirs,
; one per line, persisted in the remembered env via vh_env. The list is exchanged
; with Python as ext_libs.list-format text (plain path = -v file, '-y <dir>',
; '+incdir+<dir>') -- same format the air-gap package uses -- so vh_env owns all
; the parsing/persistence and the GUI is just a text editor + file pickers.
; ---------------------------------------------------------------------------

; vh_env export <tmp> -> text (the current remembered list), "" if none.
(defun vh_elExportText ()
  (let (tmp txt)
    (setq tmp (makeTempFileName "/tmp/vh_extlibs"))
    (errset (vh_runCLI "vh_env.py" (strcat "export " (vh_q tmp))) t)
    (setq txt (if (isFile tmp) (vh_readFile tmp) ""))
    (errset (deleteFile tmp) t)
    txt))

; Count non-blank, non-comment entries in a list blob.
(defun vh_elCount (txt "t")
  (length (setof l (parseString (or txt "") "\n")
            (and (nequal (vh_str l) "") (not (pcreMatchp "^\\s*#" l))))))

; Open the manager: load the current list and show the popup.
(defun vh_extLibsCB (form "g")
  (vh_showExtLibsForm (vh_elExportText))
  t)

; Append an entry to the list MLT (kind = "v" file / "y" dir / "inc" dir).
(defun vh_elAddCB (kind "t")
  (let (entry cur d)
    (cond
      ((equal kind "v") (setq entry (vh_str vh_extLibsForm->vh_elFile->value)))
      ((equal kind "y")
        (setq d (vh_str vh_extLibsForm->vh_elDir->value))
        (unless (equal d "") (setq entry (strcat "-y " d))))
      ((equal kind "inc")
        (setq d (vh_str vh_extLibsForm->vh_elDir->value))
        (unless (equal d "") (setq entry (strcat "+incdir+" d)))))
    (cond
      ((or (null entry) (equal entry ""))
        (errset (vh_extLibsForm->vh_elStatus->value = "pick a file / type a dir first") t))
      (t
        (setq cur (vh_str vh_extLibsForm->vh_elList->value))
        (errset (vh_extLibsForm->vh_elList->value =
                  (if (equal cur "") entry (strcat cur "\n" entry))) t)
        (errset (vh_extLibsForm->vh_elStatus->value =
                  (strcat "added (not saved yet): " entry)) t)))
    t))

; Add EVERY .v/.va/.vams file in a directory as a -v entry. This is the right
; choice for a folder of library files that each define MULTIPLE modules (e.g.
; L16_LVT_ana.v) -- those need -v per file; -y can't find them (it wants
; filename == module name). Non-recursive (files directly in the dir).
(defun vh_elAddDirFilesCB ()
  (let (d files cur)
    (setq d (vh_str vh_extLibsForm->vh_elDir->value))
    (cond
      ((equal d "")
        (errset (vh_extLibsForm->vh_elStatus->value = "type/paste a dir path first") t))
      ((not (isDir d))
        (errset (vh_extLibsForm->vh_elStatus->value = "not a directory") t))
      (t
        (setq files (setof f (getDirFiles d) (pcreMatchp "\\.(v|va|vams)$" f)))
        (cond
          ((null files)
            (errset (vh_extLibsForm->vh_elStatus->value =
              "no .v/.va/.vams files directly in that dir") t))
          (t
            (setq cur (vh_str vh_extLibsForm->vh_elList->value))
            (foreach f files
              (setq cur (if (equal cur "") (strcat d "/" f)
                          (strcat cur "\n" d "/" f))))
            (errset (vh_extLibsForm->vh_elList->value = cur) t)
            (errset (vh_extLibsForm->vh_elStatus->value =
              (sprintf nil "added %d file(s) as -v (not saved yet)" (length files))) t)))))
    t))

; Save the list to the remembered env (REPLACE), via vh_env import.
(defun vh_elSaveCB ()
  (let (txt tmp)
    (setq txt (vh_str vh_extLibsForm->vh_elList->value))
    (setq tmp (makeTempFileName "/tmp/vh_extlibs"))
    (vh_writeFile tmp txt)
    (errset (vh_runCLI "vh_env.py" (strcat "import " (vh_q tmp))) t)
    (errset (deleteFile tmp) t)
    (errset (vh_extLibsForm->vh_elStatus->value =
              (sprintf nil "saved %d entries to remembered env" (vh_elCount txt))) t)
    t))

; Reload the list from the remembered env (discard unsaved edits).
(defun vh_elReloadCB ()
  (errset (vh_extLibsForm->vh_elList->value = (vh_elExportText)) t)
  (errset (vh_extLibsForm->vh_elStatus->value = "reloaded from remembered env") t)
  t)

; Empty the list (Save then applies the clear to the env).
(defun vh_elClearCB ()
  (errset (vh_extLibsForm->vh_elList->value = "") t)
  (errset (vh_extLibsForm->vh_elStatus->value = "list cleared -- click Save to apply") t)
  t)

; Build + show the manager popup.
(defun vh_showExtLibsForm (txt "t")
  (let (fList fFile fAddF fDir fAddDir fAddY fAddI fSave fReload fClear fStatus form)
    (errset (hiFormCancel vh_extLibsForm) t)
    (setq fList (hiCreateMLTextField ?name 'vh_elList ?prompt "" ?value txt
                  ?hasVerticalScrollbar t ?hasHorizontalScrollbar t ?enableWordWrap nil))
    (setq fFile (hiCreateFileSelectorField ?name 'vh_elFile ?mode 'existingFile
                  ?prompt "a -v file" ?value ""))
    (vh_cfgFileSel fFile "Choose a -v library file" "Verilog (*.v *.vams *.va);;All Files (*)")
    (setq fAddF (hiCreateButton ?name 'vh_elBtnAddF ?buttonText "Add -v file"
                  ?callback "(vh_elAddCB \"v\")"))
    (setq fDir  (hiCreateStringField ?name 'vh_elDir ?prompt "a dir" ?value ""))
    ; the recommended button for a folder of multi-module library files
    (setq fAddDir (hiCreateButton ?name 'vh_elBtnAddDir ?buttonText "Add all in dir (-v)"
                    ?callback "(vh_elAddDirFilesCB)"))
    (setq fAddY (hiCreateButton ?name 'vh_elBtnAddY ?buttonText "Add -y dir"
                  ?callback "(vh_elAddCB \"y\")"))
    (setq fAddI (hiCreateButton ?name 'vh_elBtnAddI ?buttonText "Add +incdir"
                  ?callback "(vh_elAddCB \"inc\")"))
    (setq fSave   (hiCreateButton ?name 'vh_elBtnSave ?buttonText "Save"
                    ?callback "(vh_elSaveCB)"))
    (setq fReload (hiCreateButton ?name 'vh_elBtnReload ?buttonText "Reload"
                    ?callback "(vh_elReloadCB)"))
    (setq fClear  (hiCreateButton ?name 'vh_elBtnClear ?buttonText "Clear"
                    ?callback "(vh_elClearCB)"))
    (setq fStatus (hiCreateStringField ?name 'vh_elStatus ?prompt "" ?editable nil
                    ?value (sprintf nil "%d entries remembered" (vh_elCount txt))))
    (setq form (hiCreateAppForm
      ?name 'vh_extLibsForm
      ?formTitle "External HDL libraries (xrun -v / -y / +incdir) -- remembered"
      ?fields (list
        (list fList   (list 0 0)    (list 450 170) 0)
        (list fFile   (list 0 178)  (list 380 28)  70)
        (list fAddF   (list 0 210)  (list 110 28)  0)
        (list fDir    (list 0 244)  (list 380 28)  60)
        (list fAddDir (list 0 276)  (list 150 28)  0)
        (list fAddY   (list 155 276) (list 100 28) 0)
        (list fAddI   (list 260 276) (list 110 28) 0)
        (list fSave   (list 0 314)  (list 90 28)   0)
        (list fReload (list 100 314) (list 90 28)  0)
        (list fClear  (list 200 314) (list 90 28)  0)
        (list fStatus (list 0 350)  (list 460 28)  0))
      ?buttonLayout 'Close))
    (hiInstantiateForm form)
    (errset (hiSetFormSize form (list 500 460)) t)
    (hiDisplayForm 'vh_extLibsForm)
    'vh_extLibsForm))

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

; Pop a small modeless preview window with the pin list in a (selectable) MLT
; field, so you can eyeball it and copy straight from the dialog. The list is
; ALSO already on the clipboard + in the file; this is the on-screen preview.
(defun vh_showPinsForm (title txt "tt")
  (let (fTxt form)
    (errset (hiFormCancel vh_pinsForm) t)   ; drop a prior preview if open
    (setq fTxt (hiCreateMLTextField ?name 'vh_pinsText ?prompt "" ?value txt
                 ?hasVerticalScrollbar t ?hasHorizontalScrollbar t ?enableWordWrap nil))
    (setq form (hiCreateAppForm ?name 'vh_pinsForm ?formTitle title
                 ?fields (list (list fTxt (list 0 0) (list 430 300) 0))
                 ?buttonLayout 'Close))
    (hiInstantiateForm form)
    (errset (hiSetFormSize form (list 470 360)) t)
    (hiDisplayForm 'vh_pinsForm)
    'vh_pinsForm))

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
            (errset (vh_showPinsForm                     ; on-screen preview popup
              (sprintf nil "Pins: %s/%s (%d) -- on clipboard + %s"
                lib cell (length descs) path) txt) t)
            (vh_setStatus form
              (sprintf nil "scanned %d pins -> preview + clipboard + %s"
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
        fCfg fCds fNet fOut fChecks fTb fExTb fBwrite fExtLibs fDiag fDefs
        fA fB fC fRun fD fStatus exChoices
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
    ; ----- ready-made example TBs (auto-discovered dropdown; grows with examples/) -----
    (setq vh_exTbMap (vh_exampleTBs))
    (setq exChoices (cons "(none)" (foreach mapcar p vh_exTbMap (car p))))
    (setq fExTb (hiCreateCyclicField ?name 'vh_exTb
                  ?prompt "Example TB (Stage C)" ?choices exChoices ?value "(none)"))
    (setq fBwrite (hiCreateCyclicField ?name 'vh_bwrite
                    ?prompt "Stage B: write candidate beside cell"
                    ?choices (list "yes" "no") ?value "yes"))
    ; ----- external libraries (multi-entry manager popup) -----
    (setq fExtLibs (hiCreateButton ?name 'vh_btnExtLibs
                     ?buttonText "External libraries..."
                     ?callback "(vh_extLibsCB (vh_curForm))"))
    (setq fDiag (hiCreateButton ?name 'vh_btnDiag ?buttonText "Diagnose"
                  ?callback "(vh_diagCB (vh_curForm))"))
    ; ----- stage actions -----
    (setq fA (hiCreateButton ?name 'vh_btnA ?buttonText "Extract A"
               ?callback "(vh_extractCB (vh_curForm))"))
    (setq fB (hiCreateButton ?name 'vh_btnB ?buttonText "Convert B"
               ?callback "(vh_convertCB (vh_curForm))"))
    (setq fC (hiCreateButton ?name 'vh_btnC ?buttonText "Generate C"
               ?callback "(vh_genCB (vh_curForm))"))
    (setq fRun (hiCreateButton ?name 'vh_btnRun ?buttonText "Run xrun"
                 ?callback "(vh_runCB (vh_curForm))"))
    ; optional xrun defines forwarded to run.sh (blank = generic completeness smoke)
    (setq fDefs (hiCreateStringField ?name 'vh_defs
                  ?prompt "xrun defines (Run, e.g. +define+CHECK_NDIV)" ?value ""))
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
        (list fExTb   (list 0 292)  (list 340 rowH) 255)
        (list fBwrite (list 0 320)  (list 340 rowH) 255)
        (list fExtLibs (list 0 358) (list 180 btnH) 0)
        (list fDiag   (list 190 358) (list 110 btnH) 0)
        (list fDefs   (list 0 396)  sizePt promptW)
        (list fA      (list 0 432)   (list 102 btnH) 0)
        (list fB      (list 105 432) (list 102 btnH) 0)
        (list fC      (list 210 432) (list 102 btnH) 0)
        (list fRun    (list 315 432) (list 102 btnH) 0)
        (list fD      (list 420 432) (list 102 btnH) 0)
        (list fStatus (list 0 468)  (list 525 rowH) 60))
      ?callback (list "(progn (vh_closeCleanupCB vh_form) t)"
                      "(progn (vh_closeCleanupCB vh_form) t)")
      ?buttonLayout 'Close))
    (hiInstantiateForm form)
    ; Link Lib->Cell->View dropdowns (requires instantiation -- skuiref p.495).
    (errset (ddHiLinkFields form->vh_srcLib form->vh_srcCell form->vh_srcView) t)
    ; hiSetFormSize AFTER instantiate (retracts the outer scrollbar -- Ref
    ; nhGui.il / form_mlt_wheel_propagation memory).
    (errset (hiSetFormSize form (list 560 575)) t)
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
