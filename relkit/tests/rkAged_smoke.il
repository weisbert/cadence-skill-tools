; rkAged_smoke.il -- smoke test for rkAged.il (R1: aged corners + delta table).
;
; Part A (no Maestro, runs at load): names (short id, temperature label, aged /
;   fresh names and their parser), model-name uniquifier, section quoting,
;   auto pairing, delta rows from synthetic results, TSV writer.
;     python3 relkit/tests/run_skill_test.py relkit/tests/rkAged_smoke.il
;
; Part B (live Maestro) is a set of stage functions driven by
; tests/rkAged_vm_test.py, which backs up the Maestro view first and restores
; it afterwards (the stages run a real simulation, so the view and its results
; directory change on disk):
;   rkAgedT_open(lib cell view test)  -> session; writes ctx + history netlist info
;   rkAgedT_corners(runDir)           -> creates aged + fresh corners, checks them
;   rkAgedT_runSim()                  -> only the new corners, one test; history name
;   rkAgedT_delta(history)            -> auto (aged vs fresh) + explicit pairs
;   rkAgedT_close()                   -> deletes the corners, closes without saving
; Scratch: <workarea>/relkit_dev/tmp/rkaged/.

(rkTestBegin "rkAged_smoke")

(setq rkAgedT_tmp (rkPathJoin (rkWorkarea) "relkit_dev/tmp/rkaged"))
(rkMkdirs rkAgedT_tmp)

(defun rkAgedT_readLines (path)
  (let ((p (infile path)) line out)
    (when p
      (while (gets line p) (setq out (cons (rk_chomp line) out)))
      (close p))
    (reverse out)))

(defun rkAgedT_msgMatch (re)
  (exists m (rkAgedMessages) (pcreMatchp re m)))

; ===========================================================================
; Part A -- no Maestro
; ===========================================================================

(let (rows tbl path lines pairs res)
  ; --- names ------------------------------------------------------------------
  (rkCheckEqual "short id" (rkAgedShortId "20261008-100700_aging") "10081007")
  (rkCheckEqual "short id collision" (rkAgedShortId "20261008-100700_aging_2") "10081007s2")
  (rkCheckEqual "short id other" (rkAgedShortId "my-run.1") "myrun1")
  (rkCheckEqual "temp minus" (rkAgedTempLabel "-40") "m40")
  (rkCheckEqual "temp frac" (rkAgedTempLabel "27.5") "27p5")
  (rkCheckEqual "temp plain" (rkAgedTempLabel "125") "125")
  (rkCheckEqual "safe name" (rkAgedSafeName "SS_t-40 x/y") "SS_tm40_x_y")
  (rkCheckEqual "safe file (= rk_aged.safe)" (rk_agedSafeFile "Interactive.5 a/b") "Interactive.5_a_b")
  (rkCheckEqual "aged name" (rkAgedCornerName "SS" "10y" "-40" "20261008-100700_aging")
                "SS_aged10y_Tm40_10081007")
  (rkCheckEqual "aged name swept corner" (rkAgedCornerName "PVT_t-40_ss_VDD2.8" "10y" "125" "20261008-100700_aging")
                "PVT_tm40_ss_VDD2p8_aged10y_T125_10081007")
  (rkCheckEqual "fresh name" (rkAgedFreshName "SS" "-40" "20261008-100700_aging")
                "SS_fresh_Tm40_10081007")
  (rkCheckEqual "parse aged" (rkAgedParseName "PVT_ss_aged10y_Tm40_10081007")
                (list "aged" "PVT_ss" "10y" "m40" "10081007" ""))
  (rkCheckEqual "parse aged + Maestro suffix" (rkAgedParseName "SS_aged10y_T125_10081007s2_3")
                (list "aged" "SS" "10y" "125" "10081007s2" "_3"))
  (rkCheckEqual "parse fresh" (rkAgedParseName "SS_fresh_Tm40_10081007")
                (list "fresh" "SS" nil "m40" "10081007" ""))
  (rkCheckEqual "parse other" (rkAgedParseName "TT_pvt_0") nil)

  ; --- model names / sections ------------------------------------------------
  (rkCheckEqual "model name" (rk_agedModelName "/m/toplevel.scs" nil) "toplevel.scs")
  (rkCheckEqual "model name dup" (rk_agedModelName "/m/toplevel.scs" (list "toplevel.scs")) "toplevel.scs:1")
  (rkCheckEqual "model name dup2" (rk_agedModelName "/x/toplevel.scs" (list "toplevel.scs" "toplevel.scs:1"))
                "toplevel.scs:2")
  (rkCheckEqual "section quoted" (rk_agedQuoteSection "tt") "\"tt\"")
  (rkCheckEqual "section kept" (rk_agedQuoteSection "\"ff\"") "\"ff\"")
  (rkCheckEqual "section empty" (rk_agedQuoteSection "") nil)

  ; --- auto pairs ---------------------------------------------------------------
  (setq rk_agedMsgs nil)
  (setq pairs (rk_agedAutoPairs (list "SS" "SS_aged10y_Tm40_1" "SS_fresh_Tm40_1" "FF_aged10y_T125_1"
                                      "FF" "TT_aged10y_T27_1_0" "TT_fresh_T27_1_0" "XX_aged5y_T27_1")))
  (rkCheckEqual "auto pairs" pairs
                (list (list "SS_fresh_Tm40_1" "SS_aged10y_Tm40_1") (list "FF" "FF_aged10y_T125_1")
                      (list "TT_fresh_T27_1_0" "TT_aged10y_T27_1_0")))
  (rkCheck "auto pairs: unpaired reported" (rkAgedT_msgMatch "^XX_aged5y_T27_1: no fresh"))

  ; --- delta rows from synthetic results (point corner test output value) ------
  (setq res (list (list 1 "F" "t0" "gain" 20.0) (list 1 "A" "t0" "gain" 19.0)
                  (list 1 "F" "t0" "zero" 0.0) (list 1 "A" "t0" "zero" 0.5)
                  (list 1 "F" "t0" "wave" "wave") (list 1 "A" "t0" "wave" "wave")
                  (list 1 "F" "t0" "ibias" 5) (list 1 "A" "t0" "ibias" nil)
                  (list 2 "F" "t0" "gain" 10.0) (list 2 "A" "t0" "gain" 11.0)
                  (list 1 "O" "t0" "gain" 1.0)))
  (setq rows (rk_agedDeltaRowsOf res (list (list "F" "A"))))
  (rkCheckEqual "delta rows" (length rows) 5)
  (rkCheckEqual "delta row gain p1" (nth 0 rows)
                (list "A" "" "gain" "t0" "1" "F" "A" "20" "19" "-1" "-5.0000"))
  (rkCheckEqual "delta row zero fresh" (nth 1 rows)
                (list "A" "" "zero" "t0" "1" "F" "A" "0" "0.5" "0.5" ""))
  (rkCheckEqual "delta row wave" (nth 2 rows)
                (list "A" "" "wave" "t0" "1" "F" "A" "wave" "wave" "" ""))
  (rkCheckEqual "delta row aged missing" (nth 3 rows)
                (list "A" "warn" "ibias" "t0" "1" "F" "A" "5" "" "" ""))
  (rkCheckEqual "delta row gain p2" (nth 4 rows)
                (list "A" "" "gain" "t0" "2" "F" "A" "10" "11" "1" "10.0000"))

  ; --- TSV writer (read back with rkTsvRead) -------------------------------------
  (setq path (rkPathJoin rkAgedT_tmp "delta_a.tsv"))
  (rk_agedWriteTsv path (list rk_agedDeltaHeader
                              (cons (list "A" "" "a\tb" "t0" "1" "F" "A" "1" "2" "1" "100.0000") rows)))
  (setq tbl (rkTsvRead path))
  (rkCheckEqual "tsv header" (car tbl) rk_agedDeltaHeader)
  (rkCheckEqual "tsv rows" (length (cadr tbl)) 6)
  (rkCheckEqual "tsv tab cleaned" (nth 2 (car (cadr tbl))) "a b")
  (rkCheckEqual "tsv empty cells kept" (nth 3 (cadr tbl))
                (list "A" "" "wave" "t0" "1" "F" "A" "wave" "wave" "" ""))

  ; --- agedOut loading / errors ---------------------------------------------------
  (setq path (rkPathJoin rkAgedT_tmp "bad_out.json"))
  (rkJsonWrite (let ((o (rkMakeObj))) (rkPut o "ok" rkJsonFalse) (rkPut o "error" "boom") o) path)
  (rkCheck "failed aged-include refused"
           (null (errset (rkAgedCreateCorners "noSession" nil path) nil))))

; ===========================================================================
; Part B -- live Maestro stages (driven by rkAged_vm_test.py)
; ===========================================================================

(unless (boundp 'rkAgedT_sess) (setq rkAgedT_sess nil))
(unless (boundp 'rkAgedT_done) (setq rkAgedT_done nil))

; Open the Maestro view in append mode; write ctx.json and hist.json (newest
; history netlist) to the scratch dir -> session.
(defun rkAgedT_open (lib cell view test)
  (let (ctx hist info)
    (setq rkAgedT_sess (maeOpenSetup lib cell view ?mode "a"))
    (rkCheck "B session" rkAgedT_sess)
    (setq ctx (rkMaeGetContext rkAgedT_sess test))
    (setq rkAgedT_ctx ctx)
    (rkJsonWrite ctx (rkPathJoin rkAgedT_tmp "ctx.json"))
    (setq hist (rkMaeFindHistory rkAgedT_sess test))
    (rkCheck "B history netlist" hist)
    (setq info (rkMakeObj))
    (rkPut info "netlist" (rkGet hist "source"))
    (rkPut info "history" (rkGet hist "name"))
    (rkPut info "session" rkAgedT_sess)
    (rkJsonWrite info (rkPathJoin rkAgedT_tmp "hist.json"))
    rkAgedT_sess))

(defun rkAgedT_cornerModels (ch)
  (let (out mh)
    (foreach m (cadr (axlGetModels ch))
      (setq mh (axlGetModel ch m))
      (setq out (cons (list m (axlGetModelFile mh) (axlGetModelSection mh)) out)))
    (reverse out)))

(defun rkAgedT_cornerVars (ch)
  (let (out)
    (foreach v (cadr (axlGetVars ch))
      (setq out (cons (list v (axlGetVarValue (axlGetVar ch v))) out)))
    (reverse out)))

; Create the aged + fresh corners from a synthetic aging run record -> names.
(defun rkAgedT_corners (runDir)
  (let (sdb out names it inc ch models vars cdef secs file sec dis tests other bad)
    (setq sdb (axlGetMainSetupDB rkAgedT_sess))
    (setq out (rkAgedPrepare runDir (rkGet (rkJsonRead (rkPathJoin rkAgedT_tmp "hist.json")) "netlist")))
    (rkCheck "B aged-include ok" (rkGet out "ok"))
    (rkCheckEqual "B netlist match" (arrayref out "netlist_match") t)
    (setq it (car (rkGet out "items")))
    (setq inc (rkGet it "include_path"))
    (rkCheck "B include file" (and inc (isFile inc)))
    (setq rkAgedT_include inc)
    (setq rkAgedT_out out)
    (setq names (rkAgedCreateCorners rkAgedT_sess rkAgedT_ctx out t))
    (setq rkAgedT_names names)
    (rkCheckEqual "B created" (length names) 4)
    (rkCheck "B no netlist warning" (not (rkAgedT_msgMatch "WARNING")))
    (setq cdef (rkGet it "corner_def"))
    (setq secs (rkGet cdef "sections"))
    (setq tests (rkMaeListTests rkAgedT_sess))
    (foreach n names
      (setq ch (axlGetCorner sdb n))
      (rkCheck (sprintf nil "B corner %s exists" n) (rk_agedOk ch))
      (setq models (rkAgedT_cornerModels ch))
      (setq vars (rkAgedT_cornerVars ch))
      (rkCheck (sprintf nil "B %s enabled" n) (axlGetEnabled ch))
      (rkCheckEqual (sprintf nil "B %s temperature" n) (cadr (assoc "temperature" vars))
                    (if (pcreMatchp "_Tm40_" n) "-40" "55"))
      ; every source model file + section, in order
      (foreach s secs
        (setq file (rkGet s "model_file"))
        (setq sec (rkGet s "section"))
        (rkCheck (sprintf nil "B %s has %s %s" n file sec)
                 (exists m models (and (equal (cadr m) file)
                                       (equal (caddr m) (rk_agedQuoteSection sec))))))
      ; the aged include: aged corners only, no section
      (if (pcreMatchp "_aged" n)
          (rkCheck (sprintf nil "B %s aged include" n)
                   (exists m models (and (equal (cadr m) inc)
                                         (member (caddr m) (list nil "")))))
          (rkCheck (sprintf nil "B %s no aged include" n)
                   (not (exists m models (equal (cadr m) inc)))))
      ; scoped to the run's test only
      (setq dis (cadr (axlGetCornerDisabledTests ch)))
      (setq other (setof tn tests (nequal tn (rkGet out "test"))))
      (rkCheckEqual (sprintf nil "B %s test scope" n)
                    (sort (copy dis) 'alphalessp) (sort (copy other) 'alphalessp)))
    (rkCheckEqual "B list corners" (sort (rkAgedListCorners rkAgedT_sess (rkAgedShortId (rkGet out "run_id"))) 'alphalessp)
                  (sort (copy names) 'alphalessp))
    ; re-create is idempotent (no duplicate model entries)
    (rkAgedCreateCorners rkAgedT_sess rkAgedT_ctx out t)
    (rkCheckEqual "B recreate model count"
                  (length (rkAgedT_cornerModels (axlGetCorner sdb (car names))))
                  (add1 (length secs)))
    ; netlist mismatch + missing include -> messages, nothing created for the missing one
    (setq bad (rkJsonParseKeepFalse (rkJsonToString out)))
    (rkPut bad "netlist_match" rkJsonFalse)
    (rkPut (car (rkGet bad "items")) "include_path" "/nonexistent/aged_9.scs")
    (rkCheckEqual "B missing include -> no corner" (rkAgedCreateCorners rkAgedT_sess rkAgedT_ctx bad) nil)
    (rkCheck "B mismatch warned" (rkAgedT_msgMatch "^WARNING: the current Maestro netlist differs"))
    (rkCheck "B re-run Stress" (rkAgedT_msgMatch "re-run Stress"))
    names))

; Run only the relkit corners (Nominal and every other corner off, only the
; run's test) -> history name; rkAgedT_done becomes t when Maestro finishes.
(defun rkAgedT_runSim ()
  (let ((sdb (axlGetMainSetupDB rkAgedT_sess)) test hist)
    (setq test (rkGet rkAgedT_out "test"))
    (axlSetNominalCornerEnabled sdb nil)
    (foreach c (cadr (axlGetCorners sdb))
      (unless (member c rkAgedT_names) (axlSetEnabled (axlGetCorner sdb c) nil)))
    (foreach tn (rkMaeListTests rkAgedT_sess)
      (axlSetEnabled (axlGetTest sdb tn) (equal tn test)))
    ; a pre-run script left over from an earlier tool (pointing at a deleted
    ; file) would fail every point before Spectre starts; in memory only
    (axlSetPreRunScriptEnabled rkAgedT_sess test nil)
    (setq rkAgedT_done nil)
    (setq hist (maeRunSimulation ?session rkAgedT_sess ?callback "(setq rkAgedT_done t)"))
    (rkCheck "B run started" hist)
    (setq rkAgedT_hist hist)
    hist))

(defun rkAgedT_delta (history)
  (let (path tbl rows nNum ctx2 fresh55 freshM40 runDir)
    (setq runDir (rkGet rkAgedT_out "run_dir"))
    ; auto pairs (aged vs fresh twin); the run record is found from the corner names
    (setq path (rkAgedDeltaTable rkAgedT_sess rkAgedT_ctx history))
    (rkCheckEqual "B delta path in run record" path
                  (rkPathJoin runDir (sprintf nil "tables/aged_delta_%s.tsv" (rk_agedSafeFile history))))
    (setq tbl (rkTsvRead path))
    (rkCheckEqual "B delta header" (car tbl) rk_agedDeltaHeader)
    (rkCheck "B delta auto rows" (cadr tbl))
    (rkCheck "B delta recorded" (rkAgedT_msgMatch "^recorded in "))
    (setq rkAgedT_autoRows (length (cadr tbl)))
    ; explicit pairs: fresh 55 vs fresh -40 (both simulate in Spectre) -> numeric rows
    (setq fresh55 (car (setof n rkAgedT_names (pcreMatchp "_fresh_T55_" n))))
    (setq freshM40 (car (setof n rkAgedT_names (pcreMatchp "_fresh_Tm40_" n))))
    (setq ctx2 (rkMakeObj))
    (rkPut ctx2 "aged_pairs" (list (list fresh55 freshM40)))
    (rkPut ctx2 "run_dir" runDir)
    (setq path (rkAgedDeltaTable rkAgedT_sess ctx2 history
                                 (rkPathJoin runDir "tables/aged_delta_explicit.tsv")))
    (setq tbl (rkTsvRead path))
    (setq rows (cadr tbl))
    (setq nNum (length (setof r rows (nequal (nth 9 r) ""))))
    (rkCheck "B delta explicit numeric rows" (greaterp nNum 0))
    (setq rkAgedT_numRows nNum)
    (list rkAgedT_autoRows nNum)))

; An existing history with at least two corners holding numeric outputs ->
; (history cornerA cornerB) / nil. Newest first.
(defun rkAgedT_findDeltaHistory ()
  (let ((sdb (axlGetMainSetupDB rkAgedT_sess)) found res counts)
    (foreach h (reverse (cadr (axlGetHistory sdb)))
      (unless found
        (setq res (car (errset (rkAgedReadResults rkAgedT_sess h) nil)))
        (setq counts nil)
        (foreach r res
          (when (floatp (nth 4 r))
            (unless (member (nth 1 r) counts) (setq counts (append counts (list (nth 1 r)))))))
        (when (geqp (length counts) 2)
          (setq found (list h (car counts) (cadr counts))))))
    found))

; Delta table on an existing history with an explicit corner pair: numeric rows,
; TSV + run-record recording (no simulation needed).
(defun rkAgedT_deltaExisting (runDir)
  (let (hc ctx2 path tbl nNum)
    (setq hc (rkAgedT_findDeltaHistory))
    (rkCheck "B existing history with 2 numeric corners" hc)
    (when hc
      (setq ctx2 (rkMakeObj))
      (rkPut ctx2 "aged_pairs" (list (list (nth 1 hc) (nth 2 hc))))
      (rkPut ctx2 "run_dir" runDir)
      (setq path (rkAgedDeltaTable rkAgedT_sess ctx2 (car hc)))
      (rkCheckEqual "B existing delta path" path
                    (rkPathJoin runDir (sprintf nil "tables/aged_delta_%s.tsv" (rk_agedSafeFile (car hc)))))
      (setq tbl (rkTsvRead path))
      (rkCheckEqual "B existing delta header" (car tbl) rk_agedDeltaHeader)
      (setq nNum (length (setof r (cadr tbl) (nequal (nth 9 r) ""))))
      (rkCheck "B existing delta numeric rows" (greaterp nNum 0))
      (rkCheck "B existing delta recorded" (rkAgedT_msgMatch "^recorded in "))
      (rkCheckEqual "B last delta = file" (rkAgedLastDelta) tbl)
      (list (car hc) (nth 1 hc) (nth 2 hc) (length (cadr tbl)) nNum))))

(defun rkAgedT_close ()
  (let (ok)
    (when rkAgedT_names
      (setq ok (rkAgedDeleteCorners rkAgedT_sess rkAgedT_names))
      (rkCheck "B corners deleted" ok)
      (rkCheckEqual "B none left" (rkAgedListCorners rkAgedT_sess) nil))
    (when rkAgedT_sess
      (maeCloseSession ?session rkAgedT_sess ?forceClose t))
    (setq rkAgedT_sess nil)
    t))
