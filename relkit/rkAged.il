; rkAged.il -- R1: aged corners in Maestro + fresh/aged delta table
; (plan section 4.6, decisions D11 / D16 / D20; CONTRACT sections 5.3 and 6).
;
; Flow:
;   1. `relkit.py aged-include --run <aging run> [--netlist <current netlist>]`
;      (rk_aged.py, or rkAgedPrepare below) copies each Stress's .hrmiage0 +
;      .hrmiage0.dat into the run record (hrmi/<stress id>/), rewrites the
;      age_data_file path, writes aged_<stress id>.scs (the HRMI block of the
;      run's own Aged netlist) and compares the netlist instance signature.
;   2. rkAgedCreateCorners(sess ctx agedOut [withFresh]) adds one Maestro corner
;      per Stress x evaluation temperature:
;        <corner>_aged<Life>_T<temp>_<run short id>      e.g. SS_aged10y_Tm40_10081007
;      = the Stress corner's model files + sections and variables, temperature =
;      the evaluation temperature, plus ONE extra model file aged_<id>.scs with
;      no section; scoped to the run's test. withFresh adds the twin
;        <corner>_fresh_T<temp>_<run short id>
;      (same corner without the aged include) for a like-for-like comparison.
;   3. The user runs the corners in Maestro. rkAgedDeltaTable(sess ctx history)
;      reads every output of that history (maeReadResDB), pairs each aged corner
;      with its fresh twin (else the source corner), writes the TSV
;      Output x corner: Fresh / Aged / Delta / Delta %, and records it in the
;      aging run (relkit.py aged-delta) so the aux report shows it.
;
; Names: minus sign -> "m", "." -> "p", any other character outside
; [A-Za-z0-9_] -> "_". Run short id = MMDDHHMM of the run id
; (20261008-100700_aging -> 10081007; a collision suffix _2 -> 10081007s2).
;
; Public API (CONTRACT section 6):
;   rkAgedCreateCorners(t_sess o_ctx g_agedOut [g_withFresh]) -> l_cornerNames
;       g_agedOut: aged-include out.json path or its parsed table.
;       sess nil -> ctx maestro.session, else rkMaeCurrentSession().
;   rkAgedDeleteCorners(t_sess l_names) -> t when every corner was removed
;   rkAgedListCorners(t_sess [t_shortId]) -> names of relkit aged/fresh corners
;   rkAgedDeltaTable(t_sess o_ctx t_history [t_outPath]) -> t_tsvPath
;       ctx keys used (all optional): run_dir (aging run record), aged_pairs
;       ((fresh aged) ...) to compare explicit corners, maestro{lib cell}.
;   rkAgedDeltaRows(t_sess t_history [l_pairs]) -> (header rows)
;   rkAgedReadResults(t_sess t_history) -> list of (point corner test output value)
;   rkAgedPrepare(t_runDir [t_netlist l_stressIds]) -> aged-include result table
;   rkAgedMessages() -> messages (warnings, "re-run Stress" ...) of the last call
;   rkAgedLastDelta() -> (header rows) of the last rkAgedDeltaTable
;   rkAgedShortId(t_runId), rkAgedTempLabel(t_temp), rkAgedSafeName(t_s),
;   rkAgedCornerName(t_corner t_life t_temp t_runId),
;   rkAgedFreshName(t_corner t_temp t_runId), rkAgedParseName(t_name)
;       -> (kind base life tempLabel shortId suffix) / nil
;
; API references (checked against the IC6.1.8 PDFs in SKILL_file/):
;   adexlSKILLref.pdf: axlGetMainSetupDB p.31, axlGetTests p.282, axlGetCorners
;     p.317, axlGetCorner p.315, axlPutCorner p.332, axlPutVar p.178,
;     axlPutModel p.216 (unique model names: "file.scs:1"), axlSetModelFile p.221,
;     axlSetModelSection p.226 (section stored quoted, as Maestro does),
;     axlSetEnabled p.156, axlSetCornerTestEnabled p.339, axlRemoveElement p.134
;     (corner removal as in simkit pvtCorners.il _pvtCornersRemoveByName),
;     axlGetSessionLibName/CellName p.32-33.
;   maeSKILLref.pdf: maeReadResDB (rdb->points(), point->outputs(): output
;     ->cornerName ->testName ->name ->value), maeOpenResults /
;     maeGetResultOutputs / maeGetOutputValue / maeCloseResults (not used:
;     maeGetOutputValue needs the corner names up front; the rdb walk gives
;     every corner of every point in one pass).
;   Python subcommands run through rkIpcRunSync (rkIpc.il: ipcBeginProcess,
;     ipcWait, ipcKillProcess on timeout).
;   Corner creation follows simkit skill/pvtCorners.il _pvtCornersPushRow
;   (axlPutCorner -> axlPutVar -> axlPutModel + axlSetModelFile +
;   axlSetModelSection -> axlSetCornerTestEnabled), prefix renamed to rk,
;   rewritten without prog/return.
;
; SKILL rules (eda-test-workarea memory feedback_skill_gotchas): no let*, no
; prefix arithmetic, no defvar, identifiers [A-Za-z0-9_], tables written with
; setarray / rkPut, ~> only on db objects.

(unless (boundp 'rk_agedMsgs) (setq rk_agedMsgs nil))
(unless (boundp 'rk_agedLast) (setq rk_agedLast nil))

(setq rk_agedDeltaHeader
  (list "_key" "_sev" "Output" "Test" "Point" "Fresh corner" "Aged corner"
        "Fresh" "Aged" "Delta" "Delta %"))

; ---------------------------------------------------------------------------
; Small helpers
; ---------------------------------------------------------------------------

(unless (getd 'rk_agedTry)
  (defmacro rk_agedTry (form)
    `(car (errset ,form nil))))

(defun rk_agedMsg (msg)
  (setq rk_agedMsgs (cons msg rk_agedMsgs))
  (printf "[relkit] aged: %s\n" msg)
  nil)

(defun rkAgedMessages () (reverse rk_agedMsgs))
(defun rkAgedLastDelta () rk_agedLast)

(defun rk_agedOk (x) (and x (not (equal x 0))))

(defun rk_agedStr (v)
  (cond
    ((null v) nil)
    ((stringp v) v)
    ((symbolp v) (symbolToString v))
    ((integerp v) (sprintf nil "%d" v))
    ((floatp v) (sprintf nil "%g" v))
    (t (sprintf nil "%L" v))))

(defun rk_agedBasename (p)
  (let ((r (rindex p "/")))
    (if r (or (substring r 2) "") p)))

(defun rk_agedListOf (v)
  (cond ((null v) nil) ((equal v rkJsonEmptyArray) nil) ((listp v) v) (t (list v))))

; ---------------------------------------------------------------------------
; Names (CONTRACT 5.3)
; ---------------------------------------------------------------------------

; "-" -> "m", "." -> "p", other characters outside [A-Za-z0-9_] -> "_".
(defun rkAgedSafeName (s)
  (setq s (pcreReplace (pcreCompile "-") (rk_agedStr s) "m" 0))
  (setq s (pcreReplace (pcreCompile "[.]") s "p" 0))
  (pcreReplace (pcreCompile "[^A-Za-z0-9_]") s "_" 0))

(defun rkAgedTempLabel (temp) (rkAgedSafeName temp))

; File-name stem, same rule as rk_aged.safe() in Python ([^A-Za-z0-9._+-] -> "_"),
; so the delta TSV SKILL writes is the file aged-delta records (no second copy).
(defun rk_agedSafeFile (s)
  (pcreReplace (pcreCompile "[^A-Za-z0-9._+-]") (rk_agedStr s) "_" 0))

; 20261008-100700_aging -> "10081007"; 20261008-100700_aging_2 -> "10081007s2";
; anything else -> the id with non-alphanumerics dropped.
(defun rkAgedShortId (runId)
  (let ((re (pcreCompile "^[0-9]{4}([0-9]{4})-([0-9]{4})[0-9]{2}_[A-Za-z]+(_([0-9]+))?$")))
    (cond
      ((and (stringp runId) (pcreExecute re runId))
        (strcat (pcreSubstitute re "\\1") (pcreSubstitute re "\\2")
                (if (nequal (pcreSubstitute re "\\4") "")
                    (strcat "s" (pcreSubstitute re "\\4")) "")))
      (t (pcreReplace (pcreCompile "[^A-Za-z0-9]") (or (rk_agedStr runId) "run") "" 0)))))

(defun rkAgedCornerName (corner life temp runId)
  (sprintf nil "%s_aged%s_T%s_%s" (rkAgedSafeName corner) (rkAgedSafeName life)
           (rkAgedTempLabel temp) (rkAgedShortId runId)))

(defun rkAgedFreshName (corner temp runId)
  (sprintf nil "%s_fresh_T%s_%s" (rkAgedSafeName corner) (rkAgedTempLabel temp)
           (rkAgedShortId runId)))

; -> ("aged" base life tempLabel shortId suffix) / ("fresh" base nil tempLabel shortId suffix)
; / nil. suffix = a trailing "_<n>" Maestro may add to a result corner name ("" if none).
(defun rkAgedParseName (name)
  (let ((ra (pcreCompile "^(.+)_aged([^_]+)_T([^_]+)_([A-Za-z0-9]+)(_[0-9]+)?$"))
        (rf (pcreCompile "^(.+)_fresh_T([^_]+)_([A-Za-z0-9]+)(_[0-9]+)?$")))
    (cond
      ((not (stringp name)) nil)
      ((pcreExecute ra name)
        (list "aged" (pcreSubstitute ra "\\1") (pcreSubstitute ra "\\2")
              (pcreSubstitute ra "\\3") (pcreSubstitute ra "\\4") (pcreSubstitute ra "\\5")))
      ((pcreExecute rf name)
        (list "fresh" (pcreSubstitute rf "\\1") nil (pcreSubstitute rf "\\2")
              (pcreSubstitute rf "\\3") (pcreSubstitute rf "\\4")))
      (t nil))))

; ---------------------------------------------------------------------------
; Session / setup helpers
; ---------------------------------------------------------------------------

(defun rk_agedSession (sess ctx)
  (or sess (rkGet ctx "maestro.session") (rkMaeCurrentSession)))

(defun rk_agedSdb (sess)
  (let ((sdb (and (stringp sess) (rk_agedTry (axlGetMainSetupDB sess)))))
    (unless (rk_agedOk sdb)
      (error "relkit: %L is not an open Maestro session" sess))
    sdb))

(defun rk_agedCornerHandle (sdb name)
  (let ((ch (rk_agedTry (axlGetCorner sdb name))))
    (and (rk_agedOk ch) ch)))

(defun rk_agedRemoveCorner (sdb name)
  (let ((ch (rk_agedCornerHandle sdb name)))
    (cond
      ((null ch) nil)
      (t (rk_agedTry (axlRemoveElement ch))
         (null (rk_agedCornerHandle sdb name))))))

; Unique axlPutModel name within one corner: "file.scs", "file.scs:1", ...
(defun rk_agedModelName (file used)
  (let ((base (rk_agedBasename file)) (nm nil) (i 0))
    (when (equal base "") (setq base "model"))
    (setq nm base)
    (while (member nm used)
      (setq i (add1 i))
      (setq nm (sprintf nil "%s:%d" base i)))
    nm))

; Section as Maestro stores it: "tt" -> "\"tt\"" (already quoted: unchanged).
(defun rk_agedQuoteSection (s)
  (cond
    ((or (null s) (equal s "")) nil)
    ((equal (substring s 1 1) "\"") s)
    (t (strcat "\"" s "\""))))

; Add one model file to corner ch -> model handle / nil.
(defun rk_agedPutModel (ch file section used)
  (let ((nm (rk_agedModelName file used)) mh)
    (setq mh (rk_agedTry (axlPutModel ch nm)))
    (cond
      ((not (rk_agedOk mh))
        (rk_agedMsg (sprintf nil "axlPutModel failed for %s" file))
        nil)
      (t
        ; axlPutModel only registers the name; without axlSetModelFile Spectre
        ; gets include "" (simkit note, adexlSKILLref p.217 example).
        (rk_agedTry (axlSetModelFile mh file))
        (when (rk_agedQuoteSection section)
          (rk_agedTry (axlSetModelSection mh (rk_agedQuoteSection section))))
        (rk_agedTry (axlSetEnabled mh t))
        (list mh nm)))))

; Create (or re-create) one corner.
;   cdef    : corner_def table {name sections[] temperature vars{}}
;   include : aged include path or nil (fresh twin)
;   test    : the test to enable it for (nil -> every test)
(defun rk_agedPutCorner (sdb name cdef temp include test)
  (let (ch used r vars tests)
    (when (rk_agedCornerHandle sdb name)
      (unless (rk_agedRemoveCorner sdb name)
        (rk_agedMsg (sprintf nil "corner %s exists and could not be removed; updating it" name))))
    (setq ch (rk_agedTry (axlPutCorner sdb name)))
    (cond
      ((not (rk_agedOk ch))
        (rk_agedMsg (sprintf nil "axlPutCorner failed for %s" name))
        nil)
      (t
        (rk_agedTry (axlPutVar ch "temperature" (rk_agedStr temp)))
        (setq vars (rkGet cdef "vars"))
        (when (tablep vars)
          (foreach k (rkKeys vars)
            (unless (equal k "temperature")
              (rk_agedTry (axlPutVar ch k (or (rk_agedStr (arrayref vars k)) ""))))))
        (foreach sec (rk_agedListOf (rkGet cdef "sections"))
          (let ((file (rk_agedStr (rkGet sec "model_file"))))
            (cond
              ((or (null file) (equal file ""))
                (rk_agedMsg (sprintf nil "corner %s: a model entry has no file; skipped" name)))
              (t
                (setq r (rk_agedPutModel ch file (rk_agedStr (rkGet sec "section")) used))
                (when r (setq used (cons (cadr r) used)))))))
        (when include
          (setq r (rk_agedPutModel ch include nil used))
          (when r (setq used (cons (cadr r) used))))
        (rk_agedTry (axlSetEnabled ch t))
        (setq tests (cadr (rk_agedTry (axlGetTests sdb))))
        (when (and test (member test tests))
          (foreach tn tests
            (rk_agedTry (axlSetCornerTestEnabled ch tn (equal tn test)))))
        name))))

(defun rk_agedFindCtxCorner (ctx name)
  (car (setof c (rk_agedListOf (rkGet ctx "corners"))
              (and (tablep c) (equal (rkGet c "name") name)))))

; ---------------------------------------------------------------------------
; Python (aged-include / aged-delta), synchronous
; ---------------------------------------------------------------------------

(unless (boundp 'rk_agedPyN) (setq rk_agedPyN 0))

; Run `relkit.py <subcmd> --out <ipc>/... <args>` and wait -> result table
; (CONTRACT 3.0 shape: ok/error + _exit/_out/_log). Goes through
; rkIpcRunSync (exec'd child killed on timeout, rkIpcEnv honoured, a failed
; ipcBeginProcess reported instead of raising), then re-reads out.json keeping
; JSON false (aged-include's netlist_match:false must not read as "not compared").
(defun rk_agedRunPy (subcmd args @optional timeoutSec)
  (let (dir stem out res kf)
    (setq dir (rkPathJoin (rkSiteGet "persist_root" (rkPathJoin (rkWorkarea) "relkit_runs")) "_ipc"))
    (rkMkdirs dir)
    (setq rk_agedPyN (add1 rk_agedPyN))
    (setq stem (rkPathJoin dir (sprintf nil "%s_%s_%d_%s" (rkUser) (rkTimestamp) rk_agedPyN subcmd)))
    (setq out (strcat stem "_out.json"))
    (setq res (rkIpcRunSync subcmd nil out args (or timeoutSec 600)))
    (setq kf (and (isFile out) (rk_agedTry (rkJsonReadKeepFalse out))))
    (when (tablep kf)
      (foreach k (list "_exit" "_out" "_log" "_timeout")
        (rkPut kf k (arrayref res k)))
      (setq res kf))
    (when (equal (rkGet res "ok") rkJsonFalse) (rkPut res "ok" nil))
    res))

; aged-include for an aging run record -> result table (CONTRACT 5.3).
; netlist: current Maestro netlist (instance-signature check), optional.
(defun rkAgedPrepare (runDir @optional netlist stressIds)
  (let ((args (list "--run" runDir)) res)
    (when netlist (setq args (append args (list "--netlist" netlist))))
    (foreach s stressIds (setq args (append args (list "--stress" (rk_agedStr s)))))
    (setq res (rk_agedRunPy "aged-include" args))
    (unless (rkGet res "ok")
      (rk_agedMsg (sprintf nil "aged-include failed: %s" (rkGet res "error" "?"))))
    res))

; ---------------------------------------------------------------------------
; Aged corners
; ---------------------------------------------------------------------------

(defun rk_agedLoadOut (agedOut)
  (cond
    ((stringp agedOut) (rkJsonReadKeepFalse agedOut))
    ((tablep agedOut) agedOut)
    (t (error "rkAgedCreateCorners: agedOut must be an aged-include out.json path or table"))))

(defun rkAgedCreateCorners (sess ctx agedOut @optional withFresh)
  (let (out sdb runId test life names cdef inc temps match name sid)
    (setq rk_agedMsgs nil)
    (setq out (rk_agedLoadOut agedOut))
    (when (or (equal (rkGet out "ok") rkJsonFalse)
              (and (null (rkGet out "ok")) (rkGet out "error")))
      (error "rkAgedCreateCorners: aged-include failed: %s" (rkGet out "error" "?")))
    (setq sess (rk_agedSession sess ctx))
    (setq sdb (rk_agedSdb sess))
    (setq runId (or (rkGet out "run_id") "run"))
    (setq test (or (rkGet out "test") (rkGet ctx "test")))
    ; netlist consistency (plan 4.6): instance names must match the Stress netlist
    (setq match (arrayref out "netlist_match"))
    (cond
      ((equal match rkJsonFalse)
        (rk_agedMsg "WARNING: the current Maestro netlist differs from the netlist the Stress ran on (subckt/instance names); the aging data may not apply to every device"))
      ((null match)
        (rk_agedMsg "netlist not compared (pass the current netlist to aged-include --netlist)")))
    (foreach m (rk_agedListOf (rkGet out "missing"))
      (rk_agedMsg (sprintf nil "Stress %s: %s -- re-run Stress"
                           (rkGet m "stress_id" "?") (rkGet m "reason" "files missing"))))
    (foreach it (rk_agedListOf (rkGet out "items"))
      (setq sid (rk_agedStr (rkGet it "stress_id")))
      (setq inc (rkGet it "include_path"))
      (setq cdef (or (rkGet it "corner_def") (rk_agedFindCtxCorner ctx (rkGet it "corner"))))
      (setq life (or (rkGet it "life") (rkGet out "life") "10y"))
      (cond
        ((not (and (stringp inc) (isFile inc)))
          (rk_agedMsg (sprintf nil "Stress %s: aged include %L missing -- re-run Stress" sid inc)))
        ((not (tablep cdef))
          (rk_agedMsg (sprintf nil "Stress %s: corner %L not found in the run or the Maestro context; skipped"
                               sid (rkGet it "corner"))))
        (t
          (setq temps (mapcar 'rk_agedStr (rk_agedListOf (rkGet it "eval_temperatures"))))
          (unless temps (setq temps (list (or (rk_agedStr (rkGet cdef "temperature")) "27"))))
          (foreach tp temps
            (setq name (rk_agedPutCorner sdb (rkAgedCornerName (rkGet cdef "name") life tp runId)
                                         cdef tp inc test))
            (when name (setq names (cons name names)))
            (when withFresh
              (setq name (rk_agedPutCorner sdb (rkAgedFreshName (rkGet cdef "name") tp runId)
                                           cdef tp nil test))
              (when name (setq names (cons name names))))))))
    (setq names (reverse names))
    (rk_agedMsg (sprintf nil "%d corner(s) created in %s: %L" (length names) sess names))
    names))

(defun rkAgedDeleteCorners (sess names)
  (let ((sdb (rk_agedSdb (rk_agedSession sess nil))) (ok t))
    (foreach n names
      (unless (rk_agedRemoveCorner sdb n) (setq ok nil)))
    ok))

(defun rkAgedListCorners (sess @optional shortId)
  (let ((sdb (rk_agedSdb (rk_agedSession sess nil))) p)
    (setof n (cadr (rk_agedTry (axlGetCorners sdb)))
           (and (setq p (rkAgedParseName n))
                (or (null shortId) (equal (nth 4 p) shortId))))))

; ---------------------------------------------------------------------------
; Delta table
; ---------------------------------------------------------------------------

; Every output value of a history -> list of (point corner test output value).
(defun rkAgedReadResults (sess history)
  (let (rdb pts outs res)
    (setq rdb (rk_agedTry (maeReadResDB ?historyName history ?session sess)))
    (unless rdb (error "rkAgedReadResults: no results for history %L in session %L" history sess))
    (setq pts (rk_agedTry rdb->points()))
    (foreach pt pts
      (setq outs (rk_agedTry pt->outputs()))
      (foreach o outs
        (setq res (cons (list pt->id o->cornerName o->testName o->name o->value) res))))
    (reverse res)))

(defun rk_agedNum (v)
  (cond
    ((integerp v) (float v))
    ((floatp v) v)
    (t nil)))

(defun rk_agedFmtVal (v)
  (cond
    ((null v) "")
    ((integerp v) (sprintf nil "%d" v))
    ((floatp v) (sprintf nil "%.9g" v))
    ((stringp v) v)
    (t (sprintf nil "%L" v))))

; Auto pairs from the corner names of a result set: aged -> its fresh twin
; (same base / temperature / run, same Maestro suffix), else the source corner.
(defun rk_agedAutoPairs (corners)
  (let (pairs p fresh)
    (foreach c corners
      (setq p (rkAgedParseName c))
      (when (and p (equal (car p) "aged"))
        (setq fresh (sprintf nil "%s_fresh_T%s_%s%s" (nth 1 p) (nth 3 p) (nth 4 p) (nth 5 p)))
        (cond
          ((member fresh corners) (setq pairs (cons (list fresh c) pairs)))
          ((member (strcat (nth 1 p) (nth 5 p)) corners)
            (setq pairs (cons (list (strcat (nth 1 p) (nth 5 p)) c) pairs)))
          ((member (nth 1 p) corners) (setq pairs (cons (list (nth 1 p) c) pairs)))
          (t (rk_agedMsg (sprintf nil "%s: no fresh twin or source corner in this history" c))))))
    (reverse pairs)))

; Rows for pairs ((fresh aged) ...) from results (point corner test output value).
(defun rk_agedDeltaRowsOf (results pairs)
  (let ((vals (makeTable 'rkAgedVals nil)) keys rows key fv av fn an d pct sev
        pt test outn)
    (foreach r results
      (setq key (sprintf nil "%L|%s|%s|%s" (nth 0 r) (nth 1 r) (nth 2 r) (nth 3 r)))
      (setarray vals key (list (nth 4 r)))
      (setq key (sprintf nil "%L|%s|%s" (nth 0 r) (nth 2 r) (nth 3 r)))
      (unless (member key keys) (setq keys (cons key keys))))
    (setq keys (reverse keys))
    (foreach pr pairs
      (foreach k keys
        (setq pt (car (parseString k "|")))
        (setq test (cadr (parseString k "|")))
        (setq outn (buildString (cddr (parseString k "|")) "|"))
        (setq fv (arrayref vals (sprintf nil "%s|%s|%s|%s" pt (car pr) test outn)))
        (setq av (arrayref vals (sprintf nil "%s|%s|%s|%s" pt (cadr pr) test outn)))
        (when (or fv av)
          (setq fn (rk_agedNum (car fv)))
          (setq an (rk_agedNum (car av)))
          (setq d nil)
          (setq pct nil)
          (setq sev "")
          (cond
            ((and fn an)
              (setq d (difference an fn))
              (unless (equal fn 0.0)
                (setq pct (times 100.0 (quotient d (abs fn))))))
            ((and fn (null an)) (setq sev "warn")))
          (setq rows (cons (list (cadr pr) sev outn test pt (car pr) (cadr pr)
                                 (rk_agedFmtVal (car fv)) (rk_agedFmtVal (car av))
                                 (if d (sprintf nil "%.9g" d) "")
                                 (if pct (sprintf nil "%.4f" pct) ""))
                           rows)))))
    (reverse rows)))

(defun rkAgedDeltaRows (sess history @optional pairs)
  (let (results corners)
    (setq results (rkAgedReadResults sess history))
    (foreach r results
      (unless (member (nth 1 r) corners) (setq corners (cons (nth 1 r) corners))))
    ; relkit corners of the setup too: an aged corner whose simulation failed may
    ; have no result entry, and its row then shows the fresh value only (warn).
    (foreach c (rk_agedTry (rkAgedListCorners sess))
      (unless (member c corners) (setq corners (cons c corners))))
    (setq corners (reverse corners))
    (unless pairs (setq pairs (rk_agedAutoPairs corners)))
    (unless pairs
      (rk_agedMsg (sprintf nil "history %s has no aged/fresh corner pair (corners: %L)" history corners)))
    (list rk_agedDeltaHeader (rk_agedDeltaRowsOf results pairs))))

(defun rk_agedCell (v)
  (pcreReplace (pcreCompile "[\t\r\n]") (or (rk_agedStr v) "") " " 0))

(defun rk_agedWriteTsv (path table)
  (let (p)
    (rkMkdirs (pcreReplace (pcreCompile "/[^/]*$") path "" 1))
    (setq p (outfile path "w"))
    (unless p (error "rkAgedDeltaTable: cannot write %s" path))
    (foreach row (cons (car table) (cadr table))
      (fprintf p "%s\n" (buildString (mapcar 'rk_agedCell row) "\t")))
    (close p)
    path))

; Aging run record whose short id is shortId (persist_root/<lib>/<cell>/<run id>).
(defun rk_agedFindRunDir (sess ctx shortId)
  (let (lib cell dir found)
    (setq lib (or (rkGet ctx "maestro.lib") (rk_agedTry (axlGetSessionLibName sess))))
    (setq cell (or (rkGet ctx "maestro.cell") (rk_agedTry (axlGetSessionCellName sess))))
    (when (and lib cell shortId)
      (setq dir (rkPathJoin (rkPathJoin (rkSiteGet "persist_root" "") lib) cell))
      (when (isDir dir)
        (foreach d (getDirFiles dir)
          (when (and (null found) (pcreMatchp "_aging(_[0-9]+)?$" d)
                     (equal (rkAgedShortId d) shortId)
                     (isFile (rkPathJoin (rkPathJoin dir d) "run.json")))
            (setq found (rkPathJoin dir d))))))
    found))

(defun rkAgedDeltaTable (sess ctx history @optional outPath)
  (let (table runDir shorts res nNum)
    (setq rk_agedMsgs nil)
    (setq sess (rk_agedSession sess ctx))
    (setq table (rkAgedDeltaRows sess history (rkGet ctx "aged_pairs")))
    (setq rk_agedLast table)
    (setq runDir (rkGet ctx "run_dir"))
    (unless runDir
      (foreach r (cadr table)
        (let ((p (rkAgedParseName (nth 6 r))))
          (when (and p (not (member (nth 4 p) shorts))) (setq shorts (cons (nth 4 p) shorts)))))
      (when (equal (length shorts) 1)
        (setq runDir (rk_agedFindRunDir sess ctx (car shorts)))))
    (unless outPath
      (setq outPath
        (if runDir
            (rkPathJoin runDir (sprintf nil "tables/aged_delta_%s.tsv" (rk_agedSafeFile history)))
            (rkPathJoin (rkPathJoin (rkSiteGet "persist_root" (rkWorkarea)) "_ipc")
                        (sprintf nil "%s_%s_aged_delta_%s.tsv" (rkUser) (rkTimestamp)
                                 (rk_agedSafeFile history))))))
    (rk_agedWriteTsv outPath table)
    (setq nNum (length (setof r (cadr table) (nequal (nth 9 r) ""))))
    (rk_agedMsg (sprintf nil "delta table: %d row(s), %d numeric -> %s" (length (cadr table)) nNum outPath))
    (cond
      (runDir
        (setq res (rk_agedRunPy "aged-delta" (list "--run" runDir "--tsv" outPath "--history" history)))
        (if (rkGet res "ok")
            (rk_agedMsg (sprintf nil "recorded in %s (report %s)" runDir (rkGet res "html_path" "")))
            (rk_agedMsg (sprintf nil "aged-delta failed: %s" (rkGet res "error" "?")))))
      (t (rk_agedMsg "aging run record not found; the delta table is not added to an aux report")))
    outPath))
