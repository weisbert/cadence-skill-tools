; rkResults_smoke.il -- smoke test for rkResults.il (result tables, schematic
; jump, highlight, DUT pick). Runs in the live Virtuoso over skillbridge:
;
;   python3 relkit/tests/run_skill_test.py relkit/tests/rkResults_smoke.il
;
; Fixtures:
;   * A scratch library rkt_reslib under <workarea>/relkit_dev/tmp/ (generic
;     names), created here and deleted at the end; cds.lib is restored
;     byte-for-byte if the delete leaves it different:
;       rkt_tb/schematic      I0, I1 (rkt_amp), V0 (analogLib vdc)
;       rkt_tb/config         viewlist "spectre schematic symbol", stop "spectre symbol",
;                             instance binding (rkt_tb).I0 -> :schematic_alt
;       rkt_amp/schematic     X1 (rkt_inv), XB<2:3> (rkt_inv), R0 (analogLib res)
;       rkt_amp/schematic_alt X2 (rkt_inv), M9 (analogLib nmos4)
;       rkt_inv/schematic     M3 (nmos4), M4 (pmos4), PM1 (pmos4)
;     so I0.X2.M3 exists only through the config, I0.X1.M3 only without it.
;   * A fake netlist dir with ihnl/cds0/map + map/current (netlist-name map).
;   * The owner's VM test cells sim_yusheng/Test and Test_PMU (config views),
;     read only: real paths I7.PIN5 (Test) and I26.PIN3 (Test_PMU).
; Only windows this test opened are closed; forms are never displayed.

(rkTestBegin "rkResults_smoke")

(setq rk_resT_lib "rkt_reslib")
(setq rk_resT_wa (rkWorkarea))
(setq rk_resT_tmp (rkPathJoin rk_resT_wa "relkit_dev/tmp"))
(setq rk_resT_libDir (rkPathJoin rk_resT_tmp rk_resT_lib))
(setq rk_resT_cdsLib (rkPathJoin (getWorkingDir) "cds.lib"))
(setq rk_resT_cdsText nil)
(setq rk_resT_winsBefore nil)
(setq rk_resT_forms nil)
(setq rk_resT_dut nil)
(setq rk_resT_stage "setup")

; ---------------------------------------------------------------------------
; fixture builders
; ---------------------------------------------------------------------------

(defun rk_resT_sym (cell terms)
  (let ((cv (dbOpenCellViewByType rk_resT_lib cell "symbol" "schematicSymbol" "w")) net)
    (dbCreateRect cv (list "device" "drawing") (list (list 0 0) (list 1 1)))
    (foreach t1 terms
      (setq net (dbCreateNet cv t1))
      (dbCreateTerm net t1 "inputOutput"))
    (dbSave cv)
    (dbClose cv)
    t))

(defun rk_resT_sch (cell view insts)
  (let ((cv (dbOpenCellViewByType rk_resT_lib cell view "schematic" "w")) m (x 0))
    (foreach e insts
      (setq m (dbOpenCellViewByType (nth 1 e) (nth 2 e) "symbol" nil "r"))
      (dbCreateInst cv m (nth 0 e) (list x 0) "R0")
      (setq x (plus x 3)))
    (dbSave cv)
    (dbClose cv)
    t))

(defun rk_resT_makeLib ()
  (let (cfg r)
    (when (ddGetObj rk_resT_lib) (ddDeleteObj (ddGetObj rk_resT_lib)))
    (ddCreateLib rk_resT_lib rk_resT_libDir)
    (rk_resT_sym "rkt_inv" nil)
    (rk_resT_sch "rkt_inv" "schematic"
      (list (list "M3" "analogLib" "nmos4") (list "M4" "analogLib" "pmos4")
            (list "PM1" "analogLib" "pmos4")))
    (rk_resT_sym "rkt_amp" (list "Y" "A" "VDD"))
    (rk_resT_sch "rkt_amp" "schematic"
      (list (list "X1" rk_resT_lib "rkt_inv") (list "XB<2:3>" rk_resT_lib "rkt_inv")
            (list "R0" "analogLib" "res")))
    (rk_resT_sch "rkt_amp" "schematic_alt"
      (list (list "X2" rk_resT_lib "rkt_inv") (list "M9" "analogLib" "nmos4")))
    (rk_resT_sch "rkt_tb" "schematic"
      (list (list "I0" rk_resT_lib "rkt_amp") (list "V0" "analogLib" "vdc")
            (list "I1" rk_resT_lib "rkt_amp")))
    (setq cfg (hdbOpen rk_resT_lib "rkt_tb" "config" "w"))
    (setq r (list
      (hdbSetTopCellViewName cfg rk_resT_lib "rkt_tb" "schematic")
      (hdbSetDefaultLibListString cfg rk_resT_lib)
      (hdbSetDefaultViewListString cfg "spectre schematic symbol")
      (hdbSetDefaultStopListString cfg "spectre symbol")
      (hdbSetObjBindRule cfg (list (list rk_resT_lib "rkt_tb" "schematic" "I0"))
                         (list 'hdbcBindingRule (list nil nil "schematic_alt")))
      (hdbSave cfg)
      (hdbClose cfg)))
    (forall x r x)))

; fake netlist dir: X2 is called X2_nl in the netlist, XB<2:3> is escaped
(defun rk_resT_makeNetlistDir ()
  (let ((nd (rkPathJoin rk_resT_tmp "rkres_netlist")) p)
    (rkMkdirs (rkPathJoin nd "ihnl/cds0"))
    (rkMkdirs (rkPathJoin nd "map"))
    (setq p (outfile (rkPathJoin nd "ihnl/cds0/map") "w"))
    (fprintf p "( ( model\n( \"rkt_amp\" \"rkt_amp\" )\n )\n( instance\n( \"X2\" \"X2_nl\" )\n( \"XB<2:3>\" \"XB\\\\<2:3\\\\>\" )\n )\n )\n")
    (close p)
    (setq p (outfile (rkPathJoin nd "map/current") "w"))
    (fprintf p "( ( nil\n  version \"2.1\"\n  hierDelim \".\"\n )\n( \"rkt_tb\" \"ihnl/cds0/map\" )\n )\n")
    (close p)
    nd))

(defun rk_resT_ctx (lib cell view isCfg @optional netlistDir dutInst)
  (let ((ctx (rkMakeObj)) (d (rkMakeObj)) h u)
    (rkPut d "lib" lib) (rkPut d "cell" cell) (rkPut d "view" view)
    (rkPut d "is_config" (rkJsonBool isCfg))
    (rkPut ctx "design" d)
    (when netlistDir
      (setq h (rkMakeObj))
      (rkPut h "netlist_dir" netlistDir)
      (rkPut ctx "history" h))
    (when dutInst
      (setq u (rkMakeObj))
      (rkPut u "inst" dutInst)
      (rkPut ctx "dut" u))
    ctx))

(defun rk_resT_items (res)
  (mapcar (lambda (l) (rkGet l "item")) (rkGet res "levels")))

(defun rk_resT_sel (w)
  (mapcar (lambda (x) x~>name) (geGetSelSet w)))

(defun rk_resT_editCell (w)
  (let ((cv (geGetEditCellView w))) (and cv (list cv~>cellName cv~>viewName))))

(defun rk_resT_doneCb (dut) (setq rk_resT_dut (or dut 'none)) t)

(defun rk_resT_writeText (path text)
  (let ((p (outfile path "w"))) (fprintf p "%s" text) (close p) t))

; ---------------------------------------------------------------------------
; test body
; ---------------------------------------------------------------------------

(defun rk_resT_body ()
  (let (cfgCtx schCtx mapCtx dutCtx nd res w w2 n tbl spec form child sym st hl
        realCtx pmuCtx tops dut jsonPath tsvPath sumT devT items winsNow r pt bb inst)
    (setq nd (rk_resT_makeNetlistDir))
    (setq cfgCtx (rk_resT_ctx rk_resT_lib "rkt_tb" "config" t))
    (setq schCtx (rk_resT_ctx rk_resT_lib "rkt_tb" "schematic" nil))
    (setq mapCtx (rk_resT_ctx rk_resT_lib "rkt_tb" "config" t nd))
    (setq dutCtx (rk_resT_ctx rk_resT_lib "rkt_tb" "config" t nil "I0"))

    ; --- parsing -----------------------------------------------------------
    (setq rk_resT_stage "parsing")
    (rkCheckEqual "parse dot" (rkResultsParsePath "I0.X1.I3.M3") (list "dot" (list "I0" "X1" "I3" "M3")))
    (rkCheckEqual "parse dspf" (rkResultsParsePath "XXI_a/XI_b/MPM1@1") (list "dspf" (list "XXI_a" "XI_b" "MPM1")))
    (rkCheckEqual "parse escaped bus" (rkResultsParsePath "I0.XB\\<3\\>.M4") (list "dot" (list "I0" "XB<3>" "M4")))
    (rkCheckEqual "candidates dspf" (rk_resCandidates "XXI0" "dspf") (list "XXI0" "XI0" "I0"))
    (rkCheckEqual "candidates dot" (rk_resCandidates "XXI0" "dot") (list "XXI0"))
    (rkCheckEqual "bus split" (rk_resSplitBus "XB<2:3>") (list "XB" "2:3"))
    (rkCheckEqual "bus bits" (list (rk_resBusBits "2:3") (rk_resBusBits "5:3") (rk_resBusBits "1,4:8:2"))
                  (list (list 2 3) (list 5 4 3) (list 1 4 6 8)))

    ; --- resolve (DB only) ---------------------------------------------------
    (setq rk_resT_stage "resolve (DB only)")
    (setq res (rkResultsResolveInstance "I0.X2.M3" cfgCtx))
    (rkCheck "cfg resolve ok" (rkGet res "ok"))
    (rkCheckEqual "cfg resolve items" (rk_resT_items res) (list "I0" "X2" "M3"))
    (rkCheckEqual "cfg binds I0 to schematic_alt" (rkGet (car (rkGet res "levels")) "bound")
                  (list rk_resT_lib "rkt_amp" "schematic_alt"))
    (setq res (rkResultsResolveInstance "I0.X2.M3" schCtx))
    (rkCheck "no-config: X2 not found" (not (rkGet res "ok")))
    (rkCheckEqual "no-config: matched 1" (rkGet res "matched") 1)
    (rkCheck "no-config: message names X2" (pcreMatchp "'X2' not found" (rkGet res "message")))
    (rkCheck "no-config: I0.X1.M3 ok" (rkGet (rkResultsResolveInstance "I0.X1.M3" schCtx) "ok"))
    (setq res (rkResultsResolveInstance "XXI0/XX2/MPM1@3" cfgCtx))
    (rkCheckEqual "dspf resolve" (list (rkGet res "ok") (rk_resT_items res)) (list t (list "I0" "X2" "PM1")))
    (setq res (rkResultsResolveInstance "I1.XB<3>.M4" cfgCtx))
    (rkCheckEqual "bus member resolve" (list (rkGet res "ok") (rk_resT_items res)) (list t (list "I1" "XB<3>" "M4")))
    (rkCheckEqual "bus member bit" (rkGet (cadr (rkGet res "levels")) "bit") 3)
    (rkCheck "bus member out of range fails" (not (rkGet (rkResultsResolveInstance "I1.XB<5>.M4" cfgCtx) "ok")))
    (rkCheck "escaped bus resolve" (rkGet (rkResultsResolveInstance "I1.XB\\<2\\>.M4" cfgCtx) "ok"))
    (rkCheck "map: unknown without netlist dir" (not (rkGet (rkResultsResolveInstance "I0.X2_nl.M3" cfgCtx) "ok")))
    (setq res (rkResultsResolveInstance "I0.X2_nl.M3" mapCtx))
    (rkCheckEqual "map: X2_nl -> X2" (list (rkGet res "ok") (rk_resT_items res)) (list t (list "I0" "X2" "M3")))
    (setq res (rkResultsResolveInstance "X2.M3" dutCtx))
    (rkCheckEqual "relative to DUT" (list (rkGet res "ok") (rkGet res "prefixed") (rk_resT_items res))
                  (list t t (list "I0" "X2" "M3")))
    (rkCheck "case-insensitive" (rkGet (rkResultsResolveInstance "i0.x2.m3" cfgCtx) "ok"))
    (rkCheck "leading top cell dropped" (rkGet (rkResultsResolveInstance "rkt_tb.I0.X2.M3" cfgCtx) "ok"))
    (setq res (rkResultsResolveInstance "I0.M9.M3" cfgCtx))
    (rkCheck "cannot descend into a device" (and (not (rkGet res "ok")) (pcreMatchp "cannot descend" (rkGet res "message"))))

    ; --- jump ---------------------------------------------------------------
    (setq rk_resT_stage "jump")
    (rkCheck "jump I0.X2.M3" (rkResultsJumpToInstance "I0.X2.M3" cfgCtx))
    (setq w (rkResultsWindow))
    (rkCheck "jump window valid" (and w (windowp w)))
    (rkCheckEqual "jump edit cell" (rk_resT_editCell w) (list "rkt_inv" "schematic"))
    (rkCheckEqual "jump hierarchy" (geGetInstHier w) "/I0/X2")
    (rkCheckEqual "jump selection" (rk_resT_sel w) (list "M3"))
    (rkCheck "window keeps the config" (deGetConfigId w))
    (rkCheck "one valid halo set" (and rk_resHlSets (geIsValidHilightSet (car rk_resHlSets))))
    (rkCheck "jump message" (pcreMatchp "selected M3" (rkResultsLastMessage)))
    ; resolving again (opens + closes cellviews / the config) must not hurt the window
    (rkResultsResolveInstance "I0.X2.M4" cfgCtx)
    (rkCheckEqual "window cv survives resolve" (rk_resT_editCell w) (list "rkt_inv" "schematic"))
    (rkCheck "window config survives resolve" (hdbIsOpenConfig (deGetConfigId w)))

    ; --- highlight all on the current page ------------------------------------
    (setq rk_resT_stage "highlight all on the current page")
    (setq n (rkResultsHighlightAll (list "I0.X2.M3" "I0.X2.M4" "I0.X1.M3" "XXI0/XX2/MPM1@1" "I0.X2.M3") cfgCtx))
    (rkCheckEqual "highlight all count" n 3)
    (rkCheck "clear highlight" (geqp (rkResultsClearHighlight) 2))
    (rkCheckEqual "no sets after clear" rk_resHlSets nil)

    ; --- jump into a bus member (window reused) -------------------------------
    (setq rk_resT_stage "jump into a bus member (window reused)")
    (rkCheck "jump I1.XB<3>.M4" (rkResultsJumpToInstance "I1.XB<3>.M4" cfgCtx))
    (rkCheck "window reused" (eq (rkResultsWindow) w))
    (rkCheckEqual (sprintf nil "bus jump win path %L" (mapcar (lambda (e) (cons (car e)~>name (cdr e))) (geGetInstHierPath w)))
                  (rk_resWinPath w) (list "I1" "XB<3>"))
    (rkCheckEqual "bus jump selection" (rk_resT_sel w) (list "M4"))
    (rkCheckEqual "bus page highlight" (rkResultsHighlightAll (list "I1.XB<3>.PM1" "I1.XB<2>.M3") cfgCtx) 1)
    (rkResultsClearHighlight)

    ; --- bad paths stop at the deepest level ----------------------------------
    (setq rk_resT_stage "bad paths stop at the deepest level")
    (rkCheck "bad leaf returns nil" (not (rkResultsJumpToInstance "I0.X2.NOPE" cfgCtx)))
    (rkCheckEqual "bad leaf: deepest level" (rk_resT_editCell w) (list "rkt_inv" "schematic"))
    (rkCheckEqual "bad leaf: matched" (rkGet rk_resLast "matched") 2)
    (rkCheck "bad leaf: message" (pcreMatchp "'NOPE' not found" (rkResultsLastMessage)))
    (rkCheck "bad middle returns nil" (not (rkResultsJumpToInstance "I0.NOPE.M3" cfgCtx)))
    (rkCheckEqual "bad middle: stops in I0 (config view)" (rk_resT_editCell w) (list "rkt_amp" "schematic_alt"))
    (rkCheckEqual "bad middle: hierarchy" (geGetInstHier w) "/I0")
    (rkCheck "bad first returns nil" (not (rkResultsJumpToInstance "NOPE.M3" cfgCtx)))
    (rkCheckEqual "bad first: top" (rk_resT_editCell w) (list "rkt_tb" "schematic"))
    (rkCheck "device-in-device: selects the device" (not (rkResultsJumpToInstance "I0.M9.M3" cfgCtx)))
    (rkCheckEqual "device-in-device: selection" (rk_resT_sel w) (list "M9"))

    ; --- real VM test cells (config views) ------------------------------------
    (setq rk_resT_stage "real VM test cells (config views)")
    (setq realCtx (rk_resT_ctx "sim_yusheng" "Test" "config" t))
    (rkCheck "real: jump I7.PIN5" (rkResultsJumpToInstance "I7.PIN5" realCtx))
    (rkCheckEqual "real: edit cell" (rk_resT_editCell w) (list "Test_cell" "schematic"))
    (rkCheckEqual "real: selection" (rk_resT_sel w) (list "PIN5"))
    (rkCheck "real: bad path" (not (rkResultsJumpToInstance "I7.NOPE" realCtx)))
    (rkCheckEqual "real: bad path stops in I7" (rk_resT_editCell w) (list "Test_cell" "schematic"))
    (rkCheck "real: top-level device" (rkResultsJumpToInstance "M0" realCtx))
    (rkCheckEqual "real: top-level selection" (list (rk_resT_editCell w) (rk_resT_sel w))
                  (list (list "Test" "schematic") (list "M0")))
    (setq pmuCtx (rk_resT_ctx "sim_yusheng" "Test_PMU" "config" t))
    (rkCheck "real: Test_PMU I26.PIN3" (rkResultsJumpToInstance "I26.PIN3" pmuCtx))
    (rkCheckEqual "real: Test_PMU edit cell" (rk_resT_editCell w) (list "PMU_top" "schematic"))

    ; --- TB top instances (DUT list) -----------------------------------------
    (setq rk_resT_stage "TB top instances (DUT list)")
    (setq tops (rkResultsListTopInstances "sim_yusheng" "Test" "config"))
    (rkCheckEqual "real tops" (mapcar (lambda (e) (list (rkGet e "inst") (rkGet e "cell") (rkGet e "view"))) tops)
                  (list (list "I7" "Test_cell" "schematic")))
    (setq tops (rkResultsListTopInstances rk_resT_lib "rkt_tb" "config"))
    (rkCheckEqual "fixture tops (config bindings)"
                  (mapcar (lambda (e) (list (rkGet e "inst") (rkGet e "view"))) tops)
                  (list (list "I0" "schematic_alt") (list "I1" "schematic")))
    (rkCheckEqual "fixture top terms" (rkGet (car tops) "terms") (list "A" "VDD" "Y"))
    (rkCheckEqual "fixture tops without config"
                  (mapcar (lambda (e) (rkGet e "inst")) (rkResultsListTopInstances rk_resT_lib "rkt_tb" "schematic"))
                  (list "I0" "I1"))

    ; --- DUT pick ------------------------------------------------------------
    (setq rk_resT_stage "DUT pick")
    (setq w2 (rkResultsOpenTop cfgCtx))
    (rkCheck "open top" (and w2 (windowp w2)))
    (rkCheckEqual "open top shows TB" (rk_resT_editCell w2) (list "rkt_tb" "schematic"))
    (geDeselectAll w2)
    (geSelectFig (dbFindAnyInstByName (geGetEditCellView w2) "I1"))
    (setq rk_resT_dut nil)
    (hiSetCurrentWindow w2)
    (setq dut (rkResultsPickDut cfgCtx 'rk_resT_doneCb))
    (rkCheck "pick from selection returns table" (tablep dut))
    (rkCheck "pick callback called" (tablep rk_resT_dut))
    (rkCheckEqual "picked dut" (and (tablep rk_resT_dut)
                                    (list (rkGet rk_resT_dut "inst") (rkGet rk_resT_dut "lib")
                                          (rkGet rk_resT_dut "cell") (rkGet rk_resT_dut "view")))
                  (list "I1" rk_resT_lib "rkt_amp" "schematic"))
    ; click path: call the enterPoint done proc directly with a point on I0
    (geDeselectAll w2)
    (setq inst (dbFindAnyInstByName (geGetEditCellView w2) "I0"))
    (setq bb inst~>bBox)
    (setq pt (list (quotient (plus (car (car bb)) (car (cadr bb))) 2.0)
                   (quotient (plus (cadr (car bb)) (cadr (cadr bb))) 2.0)))
    (setq rk_resT_dut nil)
    (setq rk_resPick (list w2 cfgCtx 'rk_resT_doneCb))
    (rk_resPickPointDone w2 t (list pt))
    (rkCheckEqual "picked by point" (and (tablep rk_resT_dut)
                                         (list (rkGet rk_resT_dut "inst") (rkGet rk_resT_dut "view")
                                               (rkGet rk_resT_dut "terms")))
                  (list "I0" "schematic_alt" (list "A" "VDD" "Y")))
    (setq rk_resT_dut nil)
    (setq rk_resPick (list w2 cfgCtx 'rk_resT_doneCb))
    (rk_resPickPointDone w2 nil nil)
    (rkCheckEqual "pick aborted -> nil" rk_resT_dut 'none)
    (setq rk_resT_dut nil)
    (setq rk_resPick (list w2 cfgCtx 'rk_resT_doneCb))
    (rk_resPickPointDone w2 t (list (list 1000.0 1000.0)))
    (rkCheckEqual "pick on empty space -> nil" rk_resT_dut 'none)

    ; --- result tables ---------------------------------------------------------
    (setq rk_resT_stage "result tables")
    (setq tsvPath (rkPathJoin rk_resT_tmp "rkres_deos_dev.tsv"))
    (rk_resT_writeText tsvPath
      (strcat "_inst\t_sev\tDevice_Name\tDPM_EOS\tModel\n"
              "I0.X2.M4\t\tI0.X2.M4\t0.5\tpch\n"
              "I0.X2.M3\tfail\tI0.X2.M3\t12.5\tnch\n"
              "I0.X2.PM1\twarn\tI0.X2.PM1\t3e-1\tpch\n"
              "I0.R9\t\tI0.R9\tn/a\tres\n"))
    (setq jsonPath (rkPathJoin rk_resT_tmp "rkres_deos.json"))
    (rk_resT_writeText jsonPath
      (strcat "{\"ok\": true, \"error\": null, \"cmd\": \"collect\", \"type\": \"deos\", \"run_id\": \"r1\",\n"
              " \"corners\": [\n"
              "  {\"key\": \"FF125_test0_FF125\", \"corner\": \"FF125\", \"stress_id\": null, \"pass\": false,\n"
              "   \"metrics\": {\"vgs\": 3, \"Total_DPM\": 12.5, \"vds\": 0},\n"
              "   \"worst_device\": \"I0.X2.M3\", \"worst_model\": \"nch\", \"table_path\": \"" tsvPath "\"},\n"
              "  {\"key\": \"SS_t-40_test0_SS_t-40\", \"corner\": \"SS_t-40\", \"stress_id\": null, \"pass\": true,\n"
              "   \"metrics\": {\"Total_DPM\": 0.25, \"vgs\": 0, \"vds\": 0, \"extra\": \"x\"},\n"
              "   \"worst_device\": null, \"worst_model\": null, \"table_path\": null},\n"
              "  {\"key\": \"TT_test0_TT\", \"corner\": \"TT\", \"pass\": null, \"metrics\": {},\n"
              "   \"worst_device\": \"I0.X2.M4\", \"table_path\": null}\n"
              " ]}\n"))
    (setq sumT (rkResultsSummaryTable jsonPath))
    (rkCheckEqual "summary header" (car sumT)
                  (list "_key" "_inst" "_sev" "_table" "Corner" "Pass" "Total_DPM" "extra" "vds" "vgs"
                        "Worst device" "Worst model"))
    (rkCheckEqual "summary rows" (length (cadr sumT)) 3)
    (rkCheckEqual "summary pass/sev" (mapcar (lambda (r1) (list (rkResultsCell sumT r1 "Pass") (rkResultsCell sumT r1 "_sev")))
                                             (cadr sumT))
                  (list (list "FAIL" "fail") (list "PASS" "") (list "?" "")))
    (rkCheckEqual "summary metric cell" (rkResultsCell sumT (car (cadr sumT)) "Total_DPM") "12.5")
    (rkCheckEqual "summary _table" (rkResultsCell sumT (car (cadr sumT)) "_table") tsvPath)
    (setq tbl (rkJsonParse "{\"type\": \"aging\", \"corners\": [{\"key\": \"Stress_1_test0_FF\", \"corner\": \"FF\", \"stress_id\": \"1\", \"pass\": true, \"metrics\": {\"didsat\": 1.5}, \"worst_device\": \"I0.X1.M3\"}]}"))
    (setq r (rkResultsSummaryTable tbl))
    (rkCheck "aging summary has Stress" (member "Stress" (car r)))
    (rkCheckEqual "aging stress cell" (rkResultsCell r (car (cadr r)) "Stress") "1")
    (setq r (rkResultsSummaryTable (rkJsonParse "{\"type\": \"emir\", \"corners\": [{\"key\": \"FF_test0_FF_0\", \"corner\": \"FF\", \"pass\": false, \"metrics\": {\"em_avg_ratio\": 0.8, \"ir_worst\": \"12mV\"}, \"worst_device\": \"XXI0/XX2/MPM1@1\"}]}")))
    (rkCheckEqual "emir summary row" (rkResultsCell r (car (cadr r)) "ir_worst") "12mV")

    (setq devT (rkResultsDeviceTable tsvPath))
    (rkCheckEqual "device table sorted by DPM desc"
                  (mapcar (lambda (r1) (rkResultsCell devT r1 "DPM_EOS")) (cadr devT))
                  (list "12.5" "0.5" "3e-1" "n/a"))
    (rkCheckEqual "device table flags" (mapcar (lambda (r1) (rkResultsCell devT r1 "_sev")) (cadr devT))
                  (list "fail" "" "warn" ""))
    (setq r (rkResultsSortRows devT "DPM_EOS"))
    (rkCheckEqual "sort asc" (mapcar (lambda (r1) (rkResultsCell r r1 "DPM_EOS")) (cadr r)) (list "3e-1" "0.5" "12.5" "n/a"))
    (setq spec (rkResultsReportSpec devT))
    (rkCheckEqual "report headers hidden/flag"
                  (mapcar (lambda (h) (list (nth 0 h) (nth 1 h))) (rk_resFirstN (car spec) 2))
                  (list (list "_inst" 0) (list "Flag" 45)))
    (rkCheckEqual "report numeric column uses comparator" (nth 5 (nth 3 (car spec))) "rk_resCmpNum")
    (rkCheckEqual "report text column plain" (length (nth 4 (car spec))) 5)
    (rkCheckEqual "report choice flag text" (nth 1 (car (cadr spec))) "FAIL")
    (rkCheckEqual "comparator" (list (rk_resCmpNum (list "2") (list "10") 0) (rk_resCmpNum (list "x") (list "1") 0)) (list -1 1))
    (setq items (rkResultsListBoxItems devT))
    (rkCheckEqual "list box first item" (car items) "! I0.X2.M3 | 12.5 | nch")
    (rkCheckEqual "list box plain item" (cadr items) "  I0.X2.M4 | 0.5 | pch")

    ; --- table window (headless) ---------------------------------------------
    (setq rk_resT_stage "table window (headless)")
    (setq form (rkResultsShowTable "DEOS" sumT cfgCtx t))
    (setq rk_resT_forms (cons form rk_resT_forms))
    (rkCheck "table form built" form)
    (setq sym (stringToSymbol (sprintf nil "rk_resTable_%d" rk_resFormCount)))
    (rkCheck "table form registered" (tablep (arrayref rk_resForms sym)))
    (rkCheckEqual "report choices" (length (get form 'rk_resRep)->choices) 3)
    (putpropq (get form 'rk_resRep) (list 0) value)
    (setq child (rk_resTableActivate sym))
    (when child (setq rk_resT_forms (cons child rk_resT_forms)))
    (rkCheck "summary row opens device table" (and child (not (eq child form))))
    (setq sym (stringToSymbol (sprintf nil "rk_resTable_%d" rk_resFormCount)))
    (rkCheckEqual "device table first row" (car (car (get child 'rk_resRep)->choices)) "I0.X2.M3")
    (putpropq (get child 'rk_resRep) (list 0) value)
    (rkCheck "device row double-click jumps" (rk_resTableActivate sym))
    (rkCheckEqual "table jump landed" (rk_resT_sel w) (list "M3"))
    (rkCheck "table status set" (pcreMatchp "selected M3" (get child 'rk_resStatus)->value))
    (rkCheckEqual "table highlight all" (rk_resTableHiliteAll sym) 3)
    (rkCheck "table clear" (geqp (rk_resTableClear sym) 1))
    (putpropq (get child 'rk_resRep) (list 3) value)
    (rk_resTableJump sym)
    (rkCheck "row without match reports" (pcreMatchp "stopped" (get child 'rk_resStatus)->value))

    (setq form (rkResultsShowTable "DEOS json" jsonPath cfgCtx t))
    (setq rk_resT_forms (cons form rk_resT_forms))
    (rkCheckEqual "table from summary.json" (length (get form 'rk_resRep)->choices) 3)

    ; --- open file ---------------------------------------------------------------
    (setq rk_resT_stage "open file")
    (rkCheck "open missing file -> nil" (not (rkResultsOpenFile "/nonexistent/x.report")))
    (setq winsNow (hiGetWindowList))
    (rkCheck "open text file" (rkResultsOpenFile tsvPath))
    (foreach x (hiGetWindowList) (unless (memq x winsNow) (hiCloseWindow x)))
    t))

; ---------------------------------------------------------------------------
; run: setup -> body (errors caught) -> cleanup (always)
; ---------------------------------------------------------------------------

(setq rk_resT_winsBefore (hiGetWindowList))
(setq rk_resT_cdsText (and (isFile rk_resT_cdsLib) (rkReadFileText rk_resT_cdsLib)))
; cds.lib as lines (newlines kept) for the restore at the end
(setq rk_resT_cdsLines
  (and rk_resT_cdsText
       (let ((p (infile rk_resT_cdsLib)) line out)
         (while (gets line p) (setq out (cons line out)))
         (close p)
         (reverse out))))
(rkCheck "fixture library built" (car (errset (rk_resT_makeLib) t)))
(setq rk_resT_ok (errset (rk_resT_body) t))
(rkCheck (if rk_resT_ok "test body ran without error"
             (sprintf nil "test body error in stage '%s' (see CIW)" rk_resT_stage))
         rk_resT_ok)

; cleanup
(foreach f rk_resT_forms (errset (hiFormCancel f) nil))
(errset (rkResultsCloseWindow) nil)
(foreach x (hiGetWindowList) (unless (memq x rk_resT_winsBefore) (errset (hiCloseWindow x) nil)))
(rkCheck "no leftover windows" (equal (length (hiGetWindowList)) (length rk_resT_winsBefore)))
(when (ddGetObj rk_resT_lib) (errset (ddDeleteObj (ddGetObj rk_resT_lib)) t))
(rkCheck "fixture library deleted" (null (ddGetObj rk_resT_lib)))
; cds.lib must end up as before the test, minus any line naming the fixture
; library (a leftover from an aborted earlier run is removed, too).
(setq rk_resT_cdsWant (and rk_resT_cdsLines
                           (rk_joinPieces (setof x rk_resT_cdsLines (not (index x rk_resT_lib))))))
(when (and rk_resT_cdsWant (nequal (rkReadFileText rk_resT_cdsLib) rk_resT_cdsWant))
  (rk_resT_writeText rk_resT_cdsLib rk_resT_cdsWant))
(rkCheck "cds.lib restored" (or (null rk_resT_cdsWant) (equal (rkReadFileText rk_resT_cdsLib) rk_resT_cdsWant)))
