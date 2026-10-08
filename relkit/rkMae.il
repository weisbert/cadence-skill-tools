; rkMae.il -- Maestro context for relkit (plan section 4.1, CONTRACT sections 2 + 6).
;
; Reads everything relkit needs from a Maestro (ADE Assembler/Explorer)
; session: session of the current window, tests, the test's design (config
; views resolved to the top cell that is really simulated), design variables,
; corners (enabled state, per-test disable, model files + sections in Maestro
; order, temperature, variable overrides, sweeps expanded into one entry per
; combination), the netlist of an existing history (copied to the artifact
; dir with relative includes made absolute), the netlist's top-level
; `parameters`, the TB top-level instances (DUT drop-down) and the per-cell
; saved settings file.
;
; Corner reading/expansion: adapted from simkit skill/pvtCorners.il
; (_pvtCornersReadVars / _pvtCornersReadModels / _pvtCornersSplitWhitespace /
; _pvtCornersStripQuotes / _pvtCornersTestScope), prefix renamed pvt -> rk,
; rewritten without prog/return and without defvar.
;
; Public API (CONTRACT section 6):
;   rkMaeListSessions()            -> list of tables {session lib cell view has_window}
;   rkMaeCurrentSession([w_win])   -> t_session / nil
;   rkMaeListTests(t_sess)         -> l_testNames
;   rkMaeEnabledTests(t_sess)      -> l_testNames
;   rkMaeDefaultTest(t_sess)       -> t_test / nil   (first enabled, else first)
;   rkMaeGetDesign(t_sess t_test)  -> table {lib cell view is_config top{lib cell view}}
;   rkMaeGetGlobalVars(t_sess t_test) -> table name -> value string
;   rkMaeTestModels(t_sess t_test) -> list of (t_file t_section) of the test setup
;   rkMaeGetCorners(t_sess t_test) -> list of corner tables (CONTRACT 2.3)
;   rkMaeGetContext(t_sess [t_test]) -> ctx table (CONTRACT 2, no dut/settings/netlist)
;   rkMaeFindHistory(t_sess t_test [t_histName]) -> table {name dir netlist_dir source mtime} / nil
;   rkMaeExportNetlist(o_ctx [t_histName]) -> t_path; fills ctx "netlist" + "history"
;   rkMaeCopyNetlist(t_src t_dest [t_logPath]) -> table {rewrites kept log}
;   rkMaeParseNetlistParams(t_path) -> table name -> value string
;   rkMaeListTopInstances(t_sess t_test) -> list of tables
;       {inst lib cell view master_view terms is_primitive has_schematic}
;   rkMaeTopInstancesOf(t_lib t_cell t_view [o_bindings]) -> same, for a cellview
;   rkMaeSettingsPath(o_ctx)       -> t_path   (per-cell settings file, CONTRACT 2.5)
;   rkMaeReadSettings(o_ctx)       -> o_table / nil
;   rkMaeWriteSettings(o_ctx o_settings) -> t_path
;
; API references (all checked against the IC6.1.8 PDFs in SKILL_file/):
;   adexlSKILLref.pdf: axlGetWindowSession p.38, axlGetMainSetupDB p.31,
;     axlGetSessionLibName/CellName/ViewName p.32-34, axlGetTests p.282,
;     axlGetTest p.281, axlGetEnabledTests p.279, axlGetTestToolArgs p.283,
;     axlGetToolSession p.36, axlGetVars p.175, axlGetVar p.173,
;     axlGetVarValue p.177, axlGetEnabled p.93, axlGetEnabledGlobalVarPerTest
;     p.277, axlGetCorners p.317, axlGetCorner p.315, axlGetCornerDisabledTests
;     p.319, axlGetNominalCornerEnabled p.322, axlGetNominalCornerTestEnabled
;     p.323, axlGetModels p.215, axlGetModel p.203, axlGetModelFile p.205,
;     axlGetModelSection p.211, axlGetModelTest p.213, axlGetHistory p.420,
;     axlGetHistoryEntry p.423, axlGetResultsLocation p.111,
;     axlGetSetupDBDir p.118, axlGetPointNetlistDir p.102.
;   maeSKILLref.pdf: maeGetSessions. (IC6.1.8 has NO per-corner netlist API --
;     no maeCreateNetlistForCorner; the netlist is taken from a history.)
;   skartistref.pdf: asiGetSession p.648, asiGetDesignVarList p.637,
;     asiGetModelLibSelectionList p.454, asiGetModelLibFile, asiGetModelLibSection.
;     asiGetTemperature is NOT in the PDF; it exists in IC6.1.8 (verified on the
;     dev VM) and is used guarded (getd + errset), only for corners without a
;     temperature and the Nominal corner; fallback "27".
;   skdfref.pdf: hdbIsConfig, hdbOpen p.671, hdbGetTopLibName/CellName/ViewName
;     p.677-679, hdbClose p.670, dbOpenCellViewByType, dbClose, ddGetObj.
;   sklangref.pdf: fileTimeModified p.408, simplifyFilename, parseString,
;     lowerCase, getDirFiles, pcreCompile/pcreReplace.
;
; SKILL rules (eda-test-workarea memory feedback_skill_gotchas): no let*, no
; prefix arithmetic, no defvar, identifiers [A-Za-z0-9_], tables written with
; setarray / rkPut, ~> only on db/dd objects.

(unless (boundp 'rk_maeWarns) (setq rk_maeWarns nil))

; Primitive libraries: their instances are flagged is_primitive in the DUT list.
(setq rk_maePrimLibs (list "analogLib" "basic" "ahdlLib" "functional" "rfLib"))

; Netlist keywords whose first argument is a file path.
(setq rk_maeIncludeKws (list "include" "ahdl_include" ".include" ".inc" ".lib" ".hdl"))

; ---------------------------------------------------------------------------
; Small helpers
; ---------------------------------------------------------------------------

(defun rk_maeWarn (msg)
  (setq rk_maeWarns (cons msg rk_maeWarns))
  (printf "[relkit] mae: %s\n" msg)
  nil)

; Warnings collected since the last rkMaeGetContext / rkMaeExportNetlist.
(defun rkMaeWarnings () (reverse rk_maeWarns))

(defun rk_maeOk (x)
  (and x (not (equal x 0))))

; errset wrapper: value of form or nil on error (no message). Guarded so a
; reload does not print "macro redefined".
(unless (getd 'rk_maeTry)
  (defmacro rk_maeTry (form)
    `(car (errset ,form nil))))

(defun rk_maeStr (v)
  (cond
    ((null v) nil)
    ((stringp v) v)
    ((symbolp v) (symbolToString v))
    ((integerp v) (sprintf nil "%d" v))
    ((floatp v) (sprintf nil "%g" v))
    (t (sprintf nil "%L" v))))

(defun rk_maeTrim (s)
  (pcreReplace (pcreCompile "^[ \t\r\n]+|[ \t\r\n]+$") s "" 0))

(defun rk_maeBasename (p)
  (let ((r (rindex p "/")))
    (cond
      ((null r) p)
      (t (or (substring r 2) "")))))

(defun rk_maeDirname (p)
  (let ((d (pcreReplace (pcreCompile "/[^/]*$") p "" 1)))
    (if (equal d "") "/" d)))

; Characters outside [A-Za-z0-9.+-] -> "_" (corner name suffixes, CONTRACT 2.3).
(defun rk_maeSanitize (s)
  (pcreReplace (pcreCompile "[^A-Za-z0-9.+-]") s "_" 0))

; Same, but "_" is also kept (file names).
(defun rk_maeSafeFile (s)
  (pcreReplace (pcreCompile "[^A-Za-z0-9._+-]") s "_" 0))

(defun rk_maeSortStrings (lst)
  (sort (copy lst) 'alphalessp))

(defun rk_maeUnique (lst)
  (let (out)
    (foreach x lst (unless (member x out) (setq out (cons x out))))
    (reverse out)))

(defun rk_maeListOrEmpty (lst)
  (or lst rkJsonEmptyArray))

; "YYYY-MM-DDTHH:MM:SS" local time (CONTRACT 0).
(defun rk_maeIsoNow ()
  (let ((ts (rkTimestamp)))
    (sprintf nil "%s-%s-%sT%s:%s:%s"
             (substring ts 1 4) (substring ts 5 2) (substring ts 7 2)
             (substring ts 10 2) (substring ts 12 2) (substring ts 14 2))))

(defun rk_maeHost ()
  (let ((h (getShellEnvVar "HOSTNAME")))
    (unless (and h (nequal h "")) (setq h (getShellEnvVar "HOST")))
    (and h (nequal h "") h)))

; Split on runs of space/tab (simkit _pvtCornersSplitWhitespace).
(defun rk_maeSplitWs (s)
  (and (stringp s) (parseString s " \t")))

; Strip one pair of surrounding double quotes (simkit _pvtCornersStripQuotes).
(defun rk_maeStripQuotes (s)
  (let ((n (and (stringp s) (strlen s))))
    (cond
      ((or (null n) (lessp n 2)) s)
      ((and (equal (substring s 1 1) "\"") (equal (substring s n 1) "\""))
        (or (substring s 2 (difference n 2)) ""))
      (t s))))

; ---------------------------------------------------------------------------
; Sessions
; ---------------------------------------------------------------------------

(defun rk_maeWinSession (w)
  (let ((s (and w (rk_maeTry (axlGetWindowSession w)))))
    (and (stringp s) (nequal s "") s)))

(defun rk_maeSdb (sess)
  (let ((sdb (and (stringp sess) (rk_maeTry (axlGetMainSetupDB sess)))))
    (unless (rk_maeOk sdb)
      (error "relkit: %L is not an open Maestro session (axlGetMainSetupDB failed)" sess))
    sdb))

(defun rk_maeWindowSessions ()
  (let (out s)
    (foreach w (hiGetWindowList)
      (setq s (rk_maeWinSession w))
      (when (and s (not (member s out))) (setq out (cons s out))))
    (reverse out)))

; All open Maestro sessions (window ones and maeOpenSetup ones).
(defun rkMaeListSessions ()
  (let ((winSess (rk_maeWindowSessions)) all out o)
    (setq all (rk_maeUnique (append winSess (rk_maeTry (maeGetSessions)))))
    (foreach s all
      (setq o (rkMakeObj))
      (rkPut o "session" s)
      (rkPut o "lib" (rk_maeTry (axlGetSessionLibName s)))
      (rkPut o "cell" (rk_maeTry (axlGetSessionCellName s)))
      (rkPut o "view" (rk_maeTry (axlGetSessionViewName s)))
      (rkPut o "has_window" (rkJsonBool (member s winSess)))
      (setq out (cons o out)))
    (reverse out)))

; Session of the given window; without a window: the current window's
; session, else the only Maestro window session, else the only open session.
; nil when nothing (or nothing unambiguous) is found.
(defun rkMaeCurrentSession (@optional win)
  (let (s cands)
    (cond
      (win (setq s (rk_maeWinSession win)))
      (t
        (setq s (rk_maeWinSession (rk_maeTry (hiGetCurrentWindow))))
        (unless s
          (setq cands (rk_maeWindowSessions))
          (when (equal (length cands) 1) (setq s (car cands))))
        (unless s
          (setq cands (rk_maeTry (maeGetSessions)))
          (when (equal (length cands) 1) (setq s (car cands))))))
    s))

; ---------------------------------------------------------------------------
; Tests and design
; ---------------------------------------------------------------------------

(defun rkMaeListTests (sess)
  (cadr (rk_maeTry (axlGetTests (rk_maeSdb sess)))))

(defun rkMaeEnabledTests (sess)
  (let ((r (rk_maeTry (axlGetEnabledTests (rk_maeSdb sess)))))
    ; documented shape: ((1005 "AC") (1013 "TEST"))
    (setof x (mapcar (lambda (e) (and (listp e) (cadr e))) r) (stringp x))))

(defun rkMaeDefaultTest (sess)
  (or (car (rkMaeEnabledTests sess)) (car (rkMaeListTests sess))))

(defun rk_maeTestHandle (sdb test)
  (let ((h (rk_maeTry (axlGetTest sdb test))))
    (unless (rk_maeOk h) (error "relkit: Maestro has no test named %L" test))
    h))

; Simulation (asi) session object of a test, or nil.
(defun rk_maeAsi (sess test)
  (let ((ts (rk_maeTry (axlGetToolSession sess test))))
    (and ts (rk_maeTry (asiGetSession ts)))))

; Parse a config's expand.cfg: (top bindings) where top = (lib cell view) of
; the "design L.C:V;" line and bindings = table "lib.cell" -> view from
; "cell L.C binding :V;" lines.
(defun rk_maeParseExpandCfg (path)
  (let ((p (infile path)) line s top (bind (rkMakeObj)) body colon dot lc v)
    (when p
      (while (gets line p)
        (setq s (rk_maeTrim line))
        (cond
          ((pcreMatchp "^design[ \t]+" s)
            (setq body (rk_maeTrim (pcreReplace (pcreCompile "^design[ \t]+|;.*$") s "" 0)))
            (setq colon (rindex body ":"))
            (setq v (and colon (substring colon 2)))
            (setq lc (if colon (substring body 1 (difference (strlen body) (strlen colon))) body))
            (setq dot (index lc "."))
            (when dot
              (setq top (list (substring lc 1 (difference (strlen lc) (strlen dot)))
                              (substring dot 2) v))))
          ((pcreMatchp "^cell[ \t]+[^ \t]+[ \t]+binding[ \t]*:" s)
            (setq body (parseString (pcreReplace (pcreCompile ";.*$") s "" 1) " \t:"))
            ; ("cell" "L.C" "binding" "V")
            (when (and (equal (length body) 4) (equal (nth 2 body) "binding"))
              (rkPut bind (nth 1 body) (nth 3 body))))))
      (close p))
    (list top bind)))

; Resolved top cellview of a (possibly config) view -> (top bindings isConfig).
(defun rk_maeResolveTop (lib cell view)
  (let (isCfg cfg top dd dir parsed bind)
    (setq isCfg (and (getd 'hdbIsConfig) (rk_maeTry (hdbIsConfig lib cell view))))
    (setq dd (rk_maeTry (ddGetObj lib cell view)))
    (setq dir (and dd dd~>readPath))
    (when (and (not isCfg) dir (isFile (rkPathJoin dir "expand.cfg")))
      (setq isCfg t))
    (when isCfg
      (setq cfg (rk_maeTry (hdbOpen lib cell view "r")))
      (when cfg
        (setq top (list (rk_maeTry (hdbGetTopLibName cfg))
                        (rk_maeTry (hdbGetTopCellName cfg))
                        (rk_maeTry (hdbGetTopViewName cfg))))
        (rk_maeTry (hdbClose cfg)))
      (when (and dir (isFile (rkPathJoin dir "expand.cfg")))
        (setq parsed (rk_maeParseExpandCfg (rkPathJoin dir "expand.cfg")))
        (setq bind (cadr parsed))
        (unless (and top (car top) (cadr top) (caddr top))
          (setq top (car parsed)))))
    (unless (and top (car top) (cadr top) (caddr top))
      (when isCfg (rk_maeWarn (sprintf nil "cannot resolve the top cell of config %s/%s/%s" lib cell view)))
      (setq top (list lib cell (if isCfg "schematic" view))))
    (list top (or bind (rkMakeObj)) isCfg)))

(defun rkMaeGetDesign (sess test)
  (let (sdb args lib cell view res d top)
    (setq sdb (rk_maeSdb sess))
    (setq args (rk_maeTry (axlGetTestToolArgs (rk_maeTestHandle sdb test))))
    (setq lib (cadr (assoc "lib" args)))
    (setq cell (cadr (assoc "cell" args)))
    (setq view (cadr (assoc "view" args)))
    (unless (and lib cell view)
      (error "relkit: cannot read the design of test %L (axlGetTestToolArgs -> %L)" test args))
    (setq res (rk_maeResolveTop lib cell view))
    (setq d (rkMakeObj))
    (rkPut d "lib" lib)
    (rkPut d "cell" cell)
    (rkPut d "view" view)
    (rkPut d "is_config" (rkJsonBool (caddr res)))
    (setq top (rkMakeObj))
    (rkPut top "lib" (nth 0 (car res)))
    (rkPut top "cell" (nth 1 (car res)))
    (rkPut top "view" (nth 2 (car res)))
    (rkPut d "top" top)
    d))

; ---------------------------------------------------------------------------
; Variables and test models
; ---------------------------------------------------------------------------

; Test design variables, overridden by Maestro global variables that are
; enabled and not overridden for this test (axlGetEnabledGlobalVarPerTest).
(defun rkMaeGetGlobalVars (sess test)
  (let ((tbl (rkMakeObj)) sdb asi vh val)
    (setq sdb (rk_maeSdb sess))
    (setq asi (rk_maeAsi sess test))
    (foreach pr (and asi (rk_maeTry (asiGetDesignVarList asi)))
      (when (and (listp pr) (car pr))
        (rkPut tbl (rk_maeStr (car pr)) (rk_maeStr (cadr pr)))))
    (foreach name (cadr (rk_maeTry (axlGetVars sdb)))
      (setq vh (rk_maeTry (axlGetVar sdb name)))
      (when (and (rk_maeOk vh)
                 (rk_maeTry (axlGetEnabled vh))
                 (rk_maeTry (axlGetEnabledGlobalVarPerTest sdb name test)))
        (setq val (rk_maeTry (axlGetVarValue vh)))
        (when val (rkPut tbl name (rk_maeStr val)))))
    (foreach name (rkKeys tbl)
      (when (greaterp (length (rk_maeSplitWs (arrayref tbl name))) 1)
        (rk_maeWarn (sprintf nil "design variable %s is swept (%s); passed on verbatim -- use a corner to sweep it for RelStudio"
                             name (arrayref tbl name)))))
    tbl))

; Model files + sections of the test setup -> list of (file section).
(defun rkMaeTestModels (sess test)
  (let ((asi (rk_maeAsi sess test)) out)
    (foreach m (and asi (rk_maeTry (asiGetModelLibSelectionList asi)))
      (setq out (cons (list (or (rk_maeTry (asiGetModelLibFile m)) (car m))
                            (or (rk_maeTry (asiGetModelLibSection m)) (cadr m) ""))
                      out)))
    (reverse out)))

(defun rk_maeTestTemperature (sess test)
  (let ((asi (rk_maeAsi sess test)) v)
    (when (and asi (getd 'asiGetTemperature))
      (setq v (rk_maeTry (asiGetTemperature asi))))
    (cond
      ((and v (nequal (rk_maeStr v) "")) (rk_maeStr v))
      (t (rk_maeWarn (sprintf nil "test %s: temperature unknown, using 27" test))
         "27"))))

; ---------------------------------------------------------------------------
; Job policies (Donau settings of RelStudio jobs; CONTRACT 2.1 job_policy)
; ---------------------------------------------------------------------------
; Current policy: maeGetJobPolicy (maeSKILLref p.53), else
; axlGetAttachedJobPolicy (adexlSKILLref p.484). Names: axlGetJobPolicyTypes
; (p.487); properties: maeGetJobPolicyByName (maeSKILLref p.54) /
; axlGetJobPolicy (p.486). No API returns the .jp file path, so the
; .cadence/jobpolicy dirs of the setup.loc search order (adexlSKILLref
; p.458-459: ., $CDS_WORKAREA, $HOME, $CDS_PROJECT, $CDS_SITE) are scanned.

; DPL (nil key "v" ...) -> table {key: string}
(defun rk_maeDplTable (dpl)
  (let ((tbl (rkMakeObj)) (l (and (listp dpl) (cdr dpl))))
    (while (and l (cdr l))
      (when (car l)
        (rkPut tbl (rk_maeStr (car l)) (rk_maeStr (cadr l))))
      (setq l (cddr l)))
    tbl))

(defun rkMaeJobPolicyDirs ()
  (let (out d)
    (foreach base (list (getWorkingDir) (getShellEnvVar "CDS_WORKAREA") (rkWorkarea)
                        (getShellEnvVar "HOME") (getShellEnvVar "CDS_PROJECT")
                        (getShellEnvVar "CDS_SITE"))
      (when (and (stringp base) (nequal base ""))
        (setq d (strcat (rk_stripTrailingSlash base) "/.cadence/jobpolicy"))
        (when (and (isDir d) (not (member d out)))
          (setq out (cons d out)))))
    ; site job_policy_dirs: extra dirs holding .jp files (a customised setup.loc)
    (foreach d (rkSiteGet "job_policy_dirs")
      (when (and (stringp d) (nequal d ""))
        (setq d (rk_stripTrailingSlash (rkExpandVars d)))
        (when (and (isDir d) (not (member d out)))
          (setq out (cons d out)))))
    (reverse out)))

; name= line of a .jp file, else the file stem
(defun rk_maeJpName (path)
  (let ((p (infile path)) line nm)
    (when p
      (while (and (null nm) (gets line p))
        (when (pcreMatchp "^[ \t]*name[ \t]*=" line)
          (setq nm (rk_maeTrim (pcreReplace (pcreCompile "^[ \t]*name[ \t]*=") line "" 0)))
          (when (equal nm "") (setq nm nil))))
      (close p))
    (or nm (pcreReplace (pcreCompile "\\.jp$") (rk_maeBasename path) "" 0))))

; {name: path} of the .jp files found (first dir in search order wins)
(defun rkMaeJobPolicyFiles ()
  (let ((tbl (rkMakeObj)) path nm)
    (foreach d (rkMaeJobPolicyDirs)
      (foreach f (rk_maeSortStrings (getDirFiles d))
        (when (pcreMatchp "\\.jp$" f)
          (setq path (strcat d "/" f))
          (when (isFile path)
            (setq nm (or (rk_maeTry (rk_maeJpName path)) f))
            (unless (arrayref tbl nm) (rkPut tbl nm path))))))
    tbl))

(defun rk_maePolicyProps (sess name)
  (let (dpl)
    (setq dpl (or (and (getd 'maeGetJobPolicyByName)
                       (rk_maeTry (maeGetJobPolicyByName name ?session sess)))
                  (and (getd 'axlGetJobPolicy) (rk_maeTry (axlGetJobPolicy name)))))
    (and dpl (rk_maeDplTable dpl))))

; -> {current_name, current, available: [{name, path, props}], search_dirs}
(defun rkMaeJobPolicy (sess test)
  (let ((jp (rkMakeObj)) dpl cur curName files names avail e)
    (setq dpl (or (and (getd 'maeGetJobPolicy)
                       (rk_maeTry (maeGetJobPolicy ?session sess ?testName test)))
                  (and (getd 'axlGetAttachedJobPolicy)
                       (or (rk_maeTry (axlGetAttachedJobPolicy sess "ICRP" test))
                           (rk_maeTry (axlGetAttachedJobPolicy sess))))))
    (when dpl
      (setq cur (rk_maeDplTable dpl))
      (setq curName (arrayref cur "name")))
    (setq files (rkMaeJobPolicyFiles))
    (setq names (rk_maeUnique (append (rkKeys files)
                                      (setof n (rk_maeTry (axlGetJobPolicyTypes)) (stringp n)))))
    (when (and (stringp curName) (not (member curName names)))
      (setq names (cons curName names)))
    (foreach n (rk_maeSortStrings names)
      (setq e (rkMakeObj))
      (rkPut e "name" n)
      (rkPut e "path" (arrayref files n))
      (rkPut e "props" (rk_maePolicyProps sess n))
      (setq avail (cons e avail)))
    (rkPut jp "current_name" curName)
    (rkPut jp "current" cur)
    (rkPut jp "available" (rk_maeListOrEmpty (reverse avail)))
    (rkPut jp "search_dirs" (rk_maeListOrEmpty (rkMaeJobPolicyDirs)))
    jp))

; ---------------------------------------------------------------------------
; Corners (CONTRACT 2.3)
; ---------------------------------------------------------------------------

; Corner variables -> list of (name tokens), Maestro order, enabled vars only.
; (simkit _pvtCornersReadVars)
(defun rk_maeCornerVars (ch)
  (let (out vh val toks)
    (foreach name (cadr (rk_maeTry (axlGetVars ch)))
      (setq vh (rk_maeTry (axlGetVar ch name)))
      (when (and (rk_maeOk vh) (rk_maeTry (axlGetEnabled vh)))
        (setq val (rk_maeTry (axlGetVarValue vh)))
        (setq toks (rk_maeSplitWs (rk_maeStr val)))
        (when toks (setq out (cons (list name toks) out)))))
    (reverse out)))

; Resolve a corner model file. "" (= the test's own model file) -> the test's
; model file when the test uses exactly one; a relative name -> the test model
; with that basename, else the file as given.
(defun rk_maeResolveModelFile (file name testModels)
  (let ((files (rk_maeUnique (mapcar 'car testModels))) hit)
    (cond
      ((and (stringp file) (nequal file "") (equal (substring file 1 1) "/")) file)
      ((or (null file) (equal file ""))
        (setq file name))
      (t nil))
    (cond
      ((and (stringp file) (nequal file "") (equal (substring file 1 1) "/")) file)
      ((and (stringp file) (nequal file ""))
        (setq hit (car (setof f files (equal (rk_maeBasename f) (rk_maeBasename file)))))
        (or hit file))
      ((equal (length files) 1) (car files))
      (t
        (rk_maeWarn (sprintf nil "corner model file is the test's model file but the test uses %d files; left empty"
                             (length files)))
        ""))))

; Corner models -> list of (file sectionTokens), Maestro order; models scoped
; to another test or disabled are skipped. (simkit _pvtCornersReadModels)
(defun rk_maeCornerModels (ch test testModels)
  (let (out mh file mtest secs)
    (foreach name (cadr (rk_maeTry (axlGetModels ch)))
      (setq mh (rk_maeTry (axlGetModel ch name)))
      (when (and (rk_maeOk mh) (not (equal (rk_maeTry (axlGetEnabled mh)) nil)))
        (setq mtest (rk_maeTry (axlGetModelTest mh)))
        (when (or (null mtest) (member mtest (list "" "All" test))
                  (member test (parseString mtest ", ")))
          (setq file (rk_maeResolveModelFile (rk_maeTry (axlGetModelFile mh)) name testModels))
          (setq secs (mapcar 'rk_maeStripQuotes
                             (rk_maeSplitWs (rk_maeStr (rk_maeTry (axlGetModelSection mh))))))
          (setq out (cons (list file (or secs (list ""))) out)))))
    (reverse out)))

; Cartesian product of dims ((key values) ...) -> list of combos ((key v) ...).
; The first dim varies slowest.
(defun rk_maeProduct (dims)
  (let ((combos (list nil)) next)
    (foreach d dims
      (setq next nil)
      (foreach c combos
        (foreach v (cadr d)
          (setq next (cons (append c (list (list (car d) v))) next))))
      (setq combos (reverse next)))
    combos))

(defun rk_maeSectionsTable (pairs)
  (rk_maeListOrEmpty
    (mapcar (lambda (fs)
              (let ((o (rkMakeObj)))
                (rkPut o "model_file" (car fs))
                (rkPut o "section" (cadr fs))
                o))
            pairs)))

; Expand one Maestro corner into corner tables.
;   vars   : ((name tokens) ...) incl. "temperature"
;   models : ((file tokens) ...)
(defun rk_maeExpandCorner (cname enabled vars models testModels testTemp)
  (let (dims tempToks other varNames sweptModels label key combos out
        o name suffix sweep vtbl secs v nModelsSwept i)
    (setq tempToks (cadr (assoc "temperature" vars)))
    (unless tempToks (setq tempToks (list testTemp)))
    (setq dims (list (list "temperature" tempToks)))
    ; models: one dim per model entry ("m1" "m2" ...)
    (setq i 0)
    (setq nModelsSwept (length (setof m models (greaterp (length (cadr m)) 1))))
    (foreach m models
      (setq i (add1 i))
      (setq dims (append dims (list (list (sprintf nil "m%d" i) (cadr m))))))
    ; variables sorted by name, temperature excluded
    (setq other (setof pr vars (nequal (car pr) "temperature")))
    (setq varNames (rk_maeSortStrings (mapcar 'car other)))
    (foreach nm varNames
      (setq dims (append dims (list (list (strcat "v:" nm) (cadr (assoc nm other)))))))
    (setq combos (rk_maeProduct dims))
    (foreach c combos
      (setq suffix nil)
      (setq sweep (rkMakeObj))
      (setq vtbl (rkMakeObj))
      (setq secs nil)
      ; temperature
      (setq v (cadr (assoc "temperature" c)))
      (when (greaterp (length tempToks) 1)
        (setq suffix (cons (strcat "_t" (rk_maeSanitize v)) suffix))
        (rkPut sweep "temperature" v))
      ; models
      (setq i 0)
      (setq sweptModels 0)
      (foreach m models
        (setq i (add1 i))
        (setq v (cadr (assoc (sprintf nil "m%d" i) c)))
        (setq secs (cons (list (car m) v) secs))
        (when (greaterp (length (cadr m)) 1)
          (setq sweptModels (add1 sweptModels))
          (setq key (if (equal nModelsSwept 1) "section" (sprintf nil "section%d" sweptModels)))
          (setq suffix (cons (strcat "_" (rk_maeSanitize v)) suffix))
          (rkPut sweep key v)))
      (setq secs (reverse secs))
      (unless models (setq secs testModels))
      ; variables
      (foreach nm varNames
        (setq v (cadr (assoc (strcat "v:" nm) c)))
        (rkPut vtbl nm v)
        (when (greaterp (length (cadr (assoc nm other))) 1)
          (setq label (rk_maeSanitize nm))
          (setq suffix (cons (strcat "_" label (rk_maeSanitize v)) suffix))
          (rkPut sweep nm v)))
      (setq name (strcat cname (rk_maeJoin (reverse suffix))))
      (setq o (rkMakeObj))
      (rkPut o "name" name)
      (rkPut o "base_name" cname)
      (rkPut o "enabled" (rkJsonBool enabled))
      (rkPut o "selected" (rkJsonBool enabled))
      (rkPut o "sections" (rk_maeSectionsTable secs))
      (rkPut o "temperature" (cadr (assoc "temperature" c)))
      (rkPut o "vars" vtbl)
      (rkPut o "sweep" sweep)
      (setq out (cons o out)))
    (reverse out)))

(defun rk_maeJoin (pieces)
  (if pieces (buildString pieces "") ""))

(defun rkMaeGetCorners (sess test)
  (let (sdb th testModels testTemp out ch enabled disabled vars models)
    (setq sdb (rk_maeSdb sess))
    (setq th (rk_maeTestHandle sdb test))
    (setq testModels (rkMaeTestModels sess test))
    (setq testTemp (rk_maeTestTemperature sess test))
    ; Nominal: only when enabled for the test (CONTRACT 2.3)
    (when (and (rk_maeTry (axlGetNominalCornerEnabled sdb))
               (rk_maeTry (axlGetNominalCornerTestEnabled th)))
      (setq out (append out (rk_maeExpandCorner "Nominal" t nil nil testModels testTemp))))
    (foreach cname (cadr (rk_maeTry (axlGetCorners sdb)))
      (setq ch (rk_maeTry (axlGetCorner sdb cname)))
      (when (rk_maeOk ch)
        ; enabled in Maestro AND not disabled for this test (simkit _pvtCornersTestScope)
        (setq disabled (cadr (rk_maeTry (axlGetCornerDisabledTests ch))))
        (setq enabled (and (rk_maeTry (axlGetEnabled ch)) (not (member test disabled))))
        (setq vars (rk_maeCornerVars ch))
        (setq models (rk_maeCornerModels ch test testModels))
        (setq out (append out (rk_maeExpandCorner cname enabled vars models testModels testTemp)))))
    out))

; ---------------------------------------------------------------------------
; Context
; ---------------------------------------------------------------------------

(defun rkMaeGetContext (sess @optional test)
  (let (ctx sdb tests m)
    (setq rk_maeWarns nil)
    (unless sess (setq sess (rkMaeCurrentSession)))
    (unless sess
      (error "relkit: no Maestro session found -- open the panel from a Maestro window"))
    (setq sdb (rk_maeSdb sess))
    (setq tests (rkMaeListTests sess))
    (unless test (setq test (rkMaeDefaultTest sess)))
    (unless (and test (member test tests))
      (error "relkit: Maestro session %s has no test %L (tests: %L)" sess test tests))
    (setq ctx (rkMakeObj))
    (rkPut ctx "schema" 1)
    (rkPut ctx "relkit_version" (if (boundp 'rk_version) rk_version "0.0.0"))
    (rkPut ctx "created" (rk_maeIsoNow))
    (rkPut ctx "user" (rkUser))
    (rkPut ctx "host" (rk_maeHost))
    (rkPut ctx "workarea" (rkWorkarea))
    (rkSiteLoad)
    (rkPut ctx "site_path" (rkSitePath))
    (rkPut ctx "relstudio_home" (rkRelstudioHome))
    (rkPut ctx "relkit_dir" (rk_stripTrailingSlash (rkRelkitDir)))
    (setq m (rkMakeObj))
    (rkPut m "lib" (rk_maeTry (axlGetSessionLibName sess)))
    (rkPut m "cell" (rk_maeTry (axlGetSessionCellName sess)))
    (rkPut m "view" (rk_maeTry (axlGetSessionViewName sess)))
    (rkPut m "session" sess)
    (rkPut m "view_dir" (rk_maeTry (axlGetSetupDBDir sdb)))
    (rkPut ctx "maestro" m)
    (rkPut ctx "test" test)
    (rkPut ctx "tests" (rk_maeListOrEmpty tests))
    (rkPut ctx "design" (rkMaeGetDesign sess test))
    (rkPut ctx "history" nil)
    (rkPut ctx "netlist" nil)
    (rkPut ctx "dut" nil)
    (rkPut ctx "ip_name" (rkGet m "cell"))
    (rkPut ctx "project_name" (rkSiteGet "project_name" "relsim1"))
    (rkPut ctx "global_vars" (rkMaeGetGlobalVars sess test))
    (rkPut ctx "corners" (rk_maeListOrEmpty (rkMaeGetCorners sess test)))
    (rkPut ctx "job_policy" (rk_maeTry (rkMaeJobPolicy sess test)))
    (rkPut ctx "run_type" nil)
    (rkPut ctx "settings" nil)
    (rkPut ctx "warnings" (rk_maeListOrEmpty (rkMaeWarnings)))
    ctx))

; ---------------------------------------------------------------------------
; History + netlist
; ---------------------------------------------------------------------------

; Netlist input.scs of test in history entry he -> (netlistDir source) / nil.
; Top-level (psf) netlist first, else the lowest numbered point directory.
(defun rk_maeHistNetlist (he test histDir)
  (let (nd src pts found)
    (setq nd (rk_maeTry (axlGetPointNetlistDir he test)))
    (when (and (stringp nd) (isFile (rkPathJoin nd "input.scs")))
      (setq found (list nd (rkPathJoin nd "input.scs"))))
    (when (and (not found) histDir (isDir histDir))
      (setq pts (setof d (getDirFiles histDir) (pcreMatchp "^[0-9]+$" d)))
      (setq pts (sort pts (lambda (a b) (lessp (atoi a) (atoi b)))))
      (foreach d pts
        (unless found
          (setq nd (rkPathJoin histDir (strcat d "/" test "/netlist")))
          (setq src (rkPathJoin nd "input.scs"))
          (when (isFile src) (setq found (list nd src))))))
    found))

; Most recent history (by netlist mtime) holding a netlist for test, or the
; named one. -> table {name dir netlist_dir source mtime} / nil
(defun rkMaeFindHistory (sess test @optional histName)
  (let (sdb resLoc names best bestT he dir nl mt o)
    (setq sdb (rk_maeSdb sess))
    (setq resLoc (rk_maeTry (axlGetResultsLocation sdb)))
    (setq names (if histName (list histName) (cadr (rk_maeTry (axlGetHistory sdb)))))
    (foreach nm names
      (setq he (rk_maeTry (axlGetHistoryEntry sdb nm)))
      (when (rk_maeOk he)
        (setq dir (and resLoc (rkPathJoin resLoc nm)))
        (setq nl (rk_maeHistNetlist he test dir))
        (when nl
          (setq mt (or (rk_maeTry (fileTimeModified (cadr nl))) 0))
          (when (or (null bestT) (greaterp mt bestT))
            (setq bestT mt)
            (setq best (list nm dir (car nl) (cadr nl) mt))))))
    (when best
      (setq o (rkMakeObj))
      (rkPut o "name" (nth 0 best))
      (rkPut o "dir" (nth 1 best))
      (rkPut o "netlist_dir" (nth 2 best))
      (rkPut o "source" (nth 3 best))
      (rkPut o "mtime" (nth 4 best))
      o)))

; Character code at 1-based index (nil past the end).
(defun rk_maeCh (s i) (rk_chr s i))

(defun rk_maeIsWs (c) (and c (or (equal c 32) (equal c 9))))

; Parse an include-like line -> (prefix path suffix kw) / nil.
; Handles: include "f" [section=x], ahdl_include "f", .include 'f', .inc f,
; .lib 'f' sec (a one-argument ".lib sec" is a section start: ignored), .hdl f.
(defun rk_maeIncludeParts (line)
  (let ((n (strlen line)) (i 1) kwStart kw pStart pEnd q c rest)
    (while (rk_maeIsWs (rk_maeCh line i)) (setq i (add1 i)))
    (setq kwStart i)
    (while (and (leqp i n) (not (rk_maeIsWs (rk_maeCh line i)))
                (not (member (rk_maeCh line i) (list 34 39))))
      (setq i (add1 i)))
    (setq kw (lowerCase (rk_sub line kwStart i)))
    (cond
      ((not (member kw rk_maeIncludeKws)) nil)
      (t
        (while (rk_maeIsWs (rk_maeCh line i)) (setq i (add1 i)))
        (setq c (rk_maeCh line i))
        (cond
          ((null c) nil)
          ((member c (list 34 39))
            (setq q c)
            (setq pStart (add1 i))
            (setq pEnd pStart)
            (while (and (leqp pEnd n) (nequal (rk_maeCh line pEnd) q))
              (setq pEnd (add1 pEnd)))
            (cond
              ((greaterp pEnd n) nil)
              (t (setq rest (rk_sub line pEnd (add1 n)))
                 (rk_maeIncludeResult line kw pStart pEnd rest))))
          (t
            (setq pStart i)
            (setq pEnd i)
            (while (and (leqp pEnd n) (not (rk_maeIsWs (rk_maeCh line pEnd))))
              (setq pEnd (add1 pEnd)))
            (setq rest (rk_sub line pEnd (add1 n)))
            (rk_maeIncludeResult line kw pStart pEnd rest)))))))

(defun rk_maeIncludeResult (line kw pStart pEnd rest)
  (let ((path (rk_sub line pStart pEnd)))
    (cond
      ((equal path "") nil)
      ; ".lib name" without a file argument is a library section header
      ((and (equal kw ".lib")
            (null (rk_maeSplitWs (pcreReplace (pcreCompile "^['\"]") rest "" 1))))
        nil)
      (t (list (rk_sub line 1 pStart) path rest kw)))))

(defun rk_maeIsRelative (path)
  (let ((c (substring path 1 1)))
    (not (member c (list "/" "$" "~")))))

; Copy src -> dest, making relative include paths absolute (relative to the
; directory of src). Includes of toplevel.scs are kept verbatim: RelStudio
; rewrites them per Corner_Group. Writes a line-level log.
; -> table {rewrites: [{line orig new}], kept: [{line orig reason}], log}
(defun rkMaeCopyNetlist (src dest @optional logPath)
  (let ((inP (infile src)) outP logP line s parts path abs newLine
        (n 0) rewrites kept baseDir o res)
    (unless inP (error "relkit: cannot read netlist %s" src))
    (setq baseDir (rk_maeDirname src))
    (unless logPath
      (setq logPath (strcat (pcreReplace (pcreCompile "\\.scs$") dest "" 1) ".rewrite.log")))
    (setq outP (outfile dest "w"))
    (unless outP (close inP) (error "relkit: cannot write %s" dest))
    (while (gets line inP)
      (setq n (add1 n))
      (setq s (rk_chomp line))
      (setq parts (rk_maeIncludeParts s))
      (setq newLine s)
      (when parts
        (setq path (cadr parts))
        (cond
          ((equal (lowerCase (rk_maeBasename path)) "toplevel.scs")
            (setq o (rkMakeObj))
            (rkPut o "line" n)
            (rkPut o "orig" s)
            (rkPut o "reason" "toplevel.scs is rewritten by RelStudio per Corner_Group")
            (setq kept (cons o kept)))
          ((rk_maeIsRelative path)
            (setq abs (simplifyFilename (strcat baseDir "/" path) t))
            (setq newLine (strcat (car parts) abs (caddr parts)))
            (setq o (rkMakeObj))
            (rkPut o "line" n)
            (rkPut o "orig" s)
            (rkPut o "new" newLine)
            (setq rewrites (cons o rewrites)))))
      (fprintf outP "%s\n" newLine))
    (close inP)
    (close outP)
    (setq rewrites (reverse rewrites))
    (setq kept (reverse kept))
    ; line-level log: original vs rewritten
    (setq logP (outfile logPath "w"))
    (when logP
      (fprintf logP "# relkit netlist copy %s\n" (rk_maeIsoNow))
      (fprintf logP "# source: %s\n# dest:   %s\n" src dest)
      (fprintf logP "# %d include path(s) made absolute, %d toplevel.scs include(s) left for RelStudio\n"
               (length rewrites) (length kept))
      (foreach r rewrites
        (fprintf logP "L%d\n- %s\n+ %s\n" (rkGet r "line") (rkGet r "orig") (rkGet r "new")))
      (foreach r kept
        (fprintf logP "L%d (kept: %s)\n= %s\n" (rkGet r "line") (rkGet r "reason") (rkGet r "orig")))
      (close logP))
    (setq res (rkMakeObj))
    (rkPut res "rewrites" (rk_maeListOrEmpty rewrites))
    (rkPut res "kept" (rk_maeListOrEmpty kept))
    (rkPut res "log" logPath)
    res))

; Split "a=1 b = (x + y) c='s t'" into ("a=1" "b=(x+y)"...) keeping groups:
; whitespace splits only outside (), [], {}, quotes, and not around "=".
(defun rk_maeSplitAssign (s)
  (let ((n (strlen s)) (i 1) (depth 0) q c cur toks j nc lastNonWs)
    (while (leqp i n)
      (setq c (rk_maeCh s i))
      (cond
        (q (setq cur (cons (rk_chrStr c) cur))
           (when (equal c q) (setq q nil)))
        ((member c (list 34 39)) (setq q c) (setq cur (cons (rk_chrStr c) cur)))
        ((member c (list 40 91 123)) (setq depth (add1 depth)) (setq cur (cons (rk_chrStr c) cur)))
        ((member c (list 41 93 125)) (setq depth (sub1 depth)) (setq cur (cons (rk_chrStr c) cur)))
        ((and (rk_maeIsWs c) (leqp depth 0))
          ; look ahead to the next non-blank char
          (setq j (add1 i))
          (while (rk_maeIsWs (rk_maeCh s j)) (setq j (add1 j)))
          (setq nc (rk_maeCh s j))
          (cond
            ((or (equal nc 61) (equal lastNonWs 61)) nil)   ; around "=": glue
            (cur (setq toks (cons (rk_maeJoin (reverse cur)) toks))
                 (setq cur nil)))
          (setq i (sub1 j)))
        ((rk_maeIsWs c) nil)                                ; blanks inside () dropped
        (t (setq cur (cons (rk_chrStr c) cur))))
      (unless (rk_maeIsWs c) (setq lastNonWs c))
      (setq i (add1 i)))
    (when cur (setq toks (cons (rk_maeJoin (reverse cur)) toks)))
    (reverse toks)))

; Logical lines of a netlist: spectre "\" continuations joined, spice "+"
; continuations joined. -> list of strings
(defun rk_maeLogicalLines (path)
  (let ((p (infile path)) line s out pending)
    (unless p (error "relkit: cannot read %s" path))
    (while (gets line p)
      (setq s (rk_chomp line))
      (cond
        ((and out (null pending) (pcreMatchp "^\\+" s))
          (setq out (cons (strcat (car out) " " (substring s 2)) (cdr out))))
        (t
          (when pending (setq s (strcat pending " " s)) (setq pending nil))
          (cond
            ((pcreMatchp "\\\\[ \t]*$" s)
              (setq pending (pcreReplace (pcreCompile "\\\\[ \t]*$") s "" 1)))
            (t (setq out (cons s out)))))))
    (when pending (setq out (cons pending out)))
    (close p)
    (reverse out)))

; "a=1 b=2" (rest of a parameters statement) -> entries of tbl.
(defun rk_maePutAssigns (tbl rest)
  (let (eq name)
    (foreach tok (rk_maeSplitAssign (or rest ""))
      (setq eq (index tok "="))
      (when eq
        (setq name (substring tok 1 (difference (strlen tok) (strlen eq))))
        (when (and name (nequal name ""))
          (rkPut tbl name (or (substring eq 2) "")))))
    tbl))

; Top-level `parameters` (spectre) / `.param` (spice) of a netlist -> table.
; Statements inside subckt ... ends / .subckt ... .ends are ignored.
(defun rkMaeParseNetlistParams (path)
  (let ((tbl (rkMakeObj)) (depth 0) (lang "spectre") s words w0)
    (foreach ln (rk_maeLogicalLines path)
      (setq s (rk_maeTrim ln))
      (setq words (rk_maeSplitWs s))
      (setq w0 (car words))
      (cond
        ((null w0) nil)
        ((equal w0 "simulator")
          (when (pcreMatchp "lang[ \t]*=[ \t]*spice" s) (setq lang "spice"))
          (when (pcreMatchp "lang[ \t]*=[ \t]*spectre" s) (setq lang "spectre")))
        ((equal lang "spectre")
          (cond
            ((pcreMatchp "^//" s) nil)
            ((or (equal w0 "subckt") (and (equal w0 "inline") (equal (cadr words) "subckt")))
              (setq depth (add1 depth)))
            ((equal w0 "ends") (setq depth (max 0 (sub1 depth))))
            ((and (equal w0 "parameters") (equal depth 0))
              (rk_maePutAssigns tbl (substring s 11)))))
        (t
          (setq w0 (lowerCase w0))
          (cond
            ((pcreMatchp "^\\*" s) nil)
            ((equal w0 ".subckt") (setq depth (add1 depth)))
            ((equal w0 ".ends") (setq depth (max 0 (sub1 depth))))
            ((and (member w0 (list ".param" ".params" ".parameters")) (equal depth 0))
              (rk_maePutAssigns tbl (substring s (add1 (strlen w0)))))))))
    tbl))

; Export the netlist for ctx (CONTRACT 2.2 netlist/history). IC6.1.8 has no
; per-corner netlist API, so the netlist of an existing history is used: the
; named one, else the most recent one holding test's netlist.
(defun rkMaeExportNetlist (ctx @optional histName)
  (let (sess test dutCell mcell hist root dir dest res nl h)
    (setq rk_maeWarns nil)
    (setq sess (rkGet ctx "maestro.session"))
    (setq test (rkGet ctx "test"))
    (setq dutCell (rkGet ctx "dut.cell"))
    (setq mcell (rkGet ctx "maestro.cell"))
    (unless dutCell
      (error "relkit: choose the DUT first (ctx dut.cell is empty); the netlist goes to <artifact_root>/<DUT cell>/"))
    (unless (and sess test mcell)
      (error "relkit: ctx lacks maestro.session / test / maestro.cell"))
    (setq hist (rkMaeFindHistory sess test histName))
    (unless hist
      (error (sprintf nil "relkit: no Maestro history of %s/%s holds a netlist for test %s%s. Run the test once in Maestro (any corner), then retry."
                      (rkGet ctx "maestro.lib" "?") mcell test
                      (if histName (sprintf nil " (history %s)" histName) ""))))
    (setq root (rkSiteGet "artifact_root"))
    (unless (stringp root) (error "relkit: site key artifact_root is not set"))
    (setq dir (rkPathJoin root dutCell))
    (unless (rkMkdirs dir) (error "relkit: cannot create %s" dir))
    (setq dest (rkPathJoin dir (strcat (rk_maeSafeFile mcell) "_" (rk_maeSafeFile test) ".scs")))
    (setq res (rkMaeCopyNetlist (rkGet hist "source") dest))
    (setq nl (rkMakeObj))
    (rkPut nl "source" (rkGet hist "source"))
    (rkPut nl "path" dest)
    (rkPut nl "map_dir" (let ((m (rkPathJoin (rkGet hist "netlist_dir") "map"))) (and (isDir m) m)))
    (rkPut nl "rewrites" (rkGet res "rewrites"))
    (rkPut nl "kept" (rkGet res "kept"))
    (rkPut nl "log" (rkGet res "log"))
    (rkPut nl "parameters" (rkMaeParseNetlistParams dest))
    (setq h (rkMakeObj))
    (rkPut h "name" (rkGet hist "name"))
    (rkPut h "dir" (rkGet hist "dir"))
    (rkPut h "netlist_dir" (rkGet hist "netlist_dir"))
    (rkPut h "netlist_mtime" (rkGet hist "mtime"))
    (rkPut ctx "netlist" nl)
    (rkPut ctx "history" h)
    dest))

; ---------------------------------------------------------------------------
; TB top-level instances (DUT drop-down)
; ---------------------------------------------------------------------------

(defun rkMaeTopInstancesOf (lib cell view @optional bindings)
  (let (cv out o key bview terms isPrim hasSch)
    (setq cv (rk_maeTry (dbOpenCellViewByType lib cell view nil "r")))
    (unless cv (error "relkit: cannot open %s/%s/%s" lib cell view))
    (foreach inst cv~>instances
      (setq key (strcat inst~>libName "." inst~>cellName))
      (setq bview (and bindings (arrayref bindings key)))
      (setq hasSch (and (rk_maeTry (ddGetObj inst~>libName inst~>cellName "schematic")) t))
      (setq isPrim (member inst~>libName rk_maePrimLibs))
      (setq terms (and inst~>master inst~>master~>terminals~>name))
      (setq o (rkMakeObj))
      (rkPut o "inst" inst~>name)
      (rkPut o "lib" inst~>libName)
      (rkPut o "cell" inst~>cellName)
      (rkPut o "master_view" inst~>viewName)
      (rkPut o "view" (cond (bview bview) (hasSch "schematic") (t inst~>viewName)))
      (rkPut o "terms" (rk_maeListOrEmpty (rk_maeSortStrings terms)))
      (rkPut o "is_primitive" (rkJsonBool isPrim))
      (rkPut o "has_schematic" (rkJsonBool hasSch))
      (setq out (cons o out)))
    (dbClose cv)
    ; DUT candidates first (non-primitive), then by instance name
    (sort out (lambda (a b)
                (let ((pa (eq (rkGet a "is_primitive") t)) (pb (eq (rkGet b "is_primitive") t)))
                  (cond
                    ((and (not pa) pb) t)
                    ((and pa (not pb)) nil)
                    (t (alphalessp (rkGet a "inst") (rkGet b "inst")))))))))

(defun rkMaeListTopInstances (sess test)
  (let (d lib cell view res top)
    (setq d (rkMaeGetDesign sess test))
    (setq lib (rkGet d "lib"))
    (setq cell (rkGet d "cell"))
    (setq view (rkGet d "view"))
    (setq res (rk_maeResolveTop lib cell view))
    (setq top (car res))
    (rkMaeTopInstancesOf (nth 0 top) (nth 1 top) (nth 2 top) (cadr res))))

; ---------------------------------------------------------------------------
; Per-cell settings (CONTRACT 2.5)
; ---------------------------------------------------------------------------
; Verified on IC6.1.8 (dev VM, 2026-10-08): a Library Manager style copy
; (ccpCopy, CCP_EXPAND_COMANAGED) of a cell does NOT carry an extra file in the
; maestro view directory (only the view's co-managed files: maestro.sdb,
; active.state, data.dm, master.tag, results/, ScriptDir/, test_states/), and
; does not carry plain cell-level files either; it DOES carry a cell-level
; directory (dd treats it as a view named "relkit"). CCP_EXPAND_ALL carries
; both. So settings live in <cell dir>/relkit/relkit_settings.json (one file
; per maestro view: relkit_settings_<view>.json for views other than
; "maestro"). Side effect: Library Manager lists a view "relkit" in the cell.
; The old <view_dir>/relkit_settings.json is still read as a fallback.

(defun rk_maeCellDir (ctx)
  (let ((vd (rkGet ctx "maestro.view_dir")) dd)
    (cond
      ((stringp vd) (rk_maeDirname vd))
      (t (setq dd (rk_maeTry (ddGetObj (rkGet ctx "maestro.lib") (rkGet ctx "maestro.cell"))))
         (and dd dd~>readPath)))))

(defun rkMaeSettingsPath (ctx)
  (let ((cdir (rk_maeCellDir ctx)) (view (rkGet ctx "maestro.view" "maestro")))
    (unless cdir (error "relkit: cannot locate the Maestro cell directory"))
    (rkPathJoin cdir
      (if (equal view "maestro")
        "relkit/relkit_settings.json"
        (strcat "relkit/relkit_settings_" (rk_maeSafeFile view) ".json")))))

(defun rkMaeReadSettings (ctx)
  (let ((path (rkMaeSettingsPath ctx)) old r)
    (unless (isFile path)
      (setq old (and (rkGet ctx "maestro.view_dir")
                     (rkPathJoin (rkGet ctx "maestro.view_dir") "relkit_settings.json")))
      (setq path (and old (isFile old) old)))
    (when path
      (setq r (errset (rkJsonRead path) nil))
      (cond
        ((and r (tablep (car r))) (car r))
        (t (rk_maeWarn (sprintf nil "ignoring unreadable settings file %s" path)) nil)))))

(defun rkMaeWriteSettings (ctx settings)
  (let ((path (rkMaeSettingsPath ctx)))
    (unless (tablep settings) (error "rkMaeWriteSettings: settings must be a table"))
    (unless (rkGet settings "schema") (rkPut settings "schema" 1))
    (unless (rkMkdirs (rk_maeDirname path)) (error "relkit: cannot create %s" (rk_maeDirname path)))
    (rkJsonWrite settings path)
    path))
