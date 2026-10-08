; rkMae_smoke.il -- smoke test for rkMae.il (Maestro context).
;
; Run on the dev VM (after bash relkit/tools/sync_vm.sh):
;   python3 relkit/tests/run_skill_test.py relkit/tests/rkMae_smoke.il
;
; Part A (no Maestro): netlist include rewrite + log, parameters parser,
;   assignment splitter, sweep expansion / corner naming, settings file I/O.
;   Synthetic files under <workarea>/relkit_dev/tmp/mae/.
; Part B (live Maestro, needs the dev library): opens rkMae_lib/rkMae_cell/
;   rkMae_view READ-ONLY with maeOpenSetup ?mode "r" (nothing can be saved),
;   reads tests / design / variables / corners, adds two temporary corners
;   (swept temperature; disabled) and one corner disabled for the test,
;   checks expansion and filtering against Maestro's own axlGetCornersForATest,
;   deletes the temporary corners, exports the netlist of the newest history,
;   lists the TB top instances, and closes the session.
; Set rkMae_lib / rkMae_cell / rkMae_view (and the expectations below) before
; loading to point the test at another Maestro view.

(rkTestBegin "rkMae_smoke")

(unless (boundp 'rkMae_lib)  (setq rkMae_lib "sim_yusheng"))
(unless (boundp 'rkMae_cell) (setq rkMae_cell "Test"))
(unless (boundp 'rkMae_view) (setq rkMae_view "maestro"))

(defun rkMaeT_write (path lines)
  (let ((p (outfile path "w")))
    (foreach l lines (fprintf p "%s\n" l))
    (close p)
    path))

(defun rkMaeT_readLines (path)
  (let ((p (infile path)) line out)
    (while (gets line p) (setq out (cons (rk_chomp line) out)))
    (close p)
    (reverse out)))

(defun rkMaeT_names (corners) (mapcar (lambda (c) (rkGet c "name")) corners))

(defun rkMaeT_find (corners name)
  (car (setof c corners (equal (rkGet c "name") name))))

; ===========================================================================
; Part A -- no Maestro
; ===========================================================================

(let (tmp nl dest res lines params tbl rw kept cs settings ctx path back)
  (setq tmp (rkPathJoin (rkWorkarea) "relkit_dev/tmp/mae"))
  (rkCheck "A mkdirs" (rkMkdirs (rkPathJoin tmp "netlist")))

  ; --- assignment splitter --------------------------------------------------
  (rkCheckEqual "split simple" (rk_maeSplitAssign "a=1 b=2") (list "a=1" "b=2"))
  (rkCheckEqual "split blanks around =" (rk_maeSplitAssign "VSS = 0 x =1 y= 2") (list "VSS=0" "x=1" "y=2"))
  (rkCheckEqual "split groups" (rk_maeSplitAssign "e=(VDD + 1) q='a b' z=[1 2]")
                (list "e=(VDD+1)" "q='a b'" "z=[12]"))

  ; --- include parser -------------------------------------------------------
  (rkCheckEqual "inc quoted" (rk_maeIncludeParts "include \"./m/a.scs\" section=tt")
                (list "include \"" "./m/a.scs" "\" section=tt" "include"))
  (rkCheckEqual "inc bare" (rk_maeIncludeParts "  .INC sp/inc.sp")
                (list "  .INC " "sp/inc.sp" "" ".inc"))
  (rkCheckEqual ".lib file sec" (rk_maeIncludeParts ".lib 'sp/lib.l' tt")
                (list ".lib '" "sp/lib.l" "' tt" ".lib"))
  (rkCheck ".lib section header ignored" (null (rk_maeIncludeParts ".lib tt")))
  (rkCheck "non-include ignored" (null (rk_maeIncludeParts "parameters a=1")))

  ; --- netlist copy + rewrite + log -----------------------------------------
  (setq nl (rkMaeT_write (rkPathJoin tmp "netlist/input.scs")
    (list "// synthetic netlist"
          "simulator lang=spectre"
          "global 0"
          "parameters VDD=1.8 VSS = 0 expr=(VDD + 1) \\"
          "    tail=2"
          "include \"./models/a.scs\" section=tt"
          "include \"../lib/toplevel.scs\" section=TOP_TT"
          "ahdl_include \"va/x.va\""
          "include \"/abs/model.scs\""
          "include \"$MODEL_ROOT/m.scs\""
          "subckt amp_core a b"
          "parameters inner=5"
          "ends amp_core"
          "simulator lang=spice"
          ".lib 'sp/lib.l' tt"
          ".lib tt"
          ".include sp/inc.sp"
          ".param SP=3"
          "+ SP2=4"
          ".subckt foo a"
          ".param INNER2=1"
          ".ends"
          "simulator lang=spectre"
          "I0 (a b) amp_core")))
  (setq dest (rkPathJoin tmp "tb_top_test0.scs"))
  (setq res (rkMaeCopyNetlist nl dest))
  (setq rw (rkGet res "rewrites"))
  (setq kept (rkGet res "kept"))
  (rkCheckEqual "rewrite count" (length rw) 4)
  (rkCheckEqual "rewrite lines" (mapcar (lambda (r) (rkGet r "line")) rw) (list 6 8 15 17))
  (rkCheckEqual "rewrite include" (rkGet (nth 0 rw) "new")
                (strcat "include \"" tmp "/netlist/models/a.scs\" section=tt"))
  (rkCheckEqual "rewrite ahdl" (rkGet (nth 1 rw) "new")
                (strcat "ahdl_include \"" tmp "/netlist/va/x.va\""))
  (rkCheckEqual "rewrite .lib" (rkGet (nth 2 rw) "new")
                (strcat ".lib '" tmp "/netlist/sp/lib.l' tt"))
  (rkCheckEqual "rewrite .include" (rkGet (nth 3 rw) "new")
                (strcat ".include " tmp "/netlist/sp/inc.sp"))
  (rkCheckEqual "toplevel kept" (mapcar (lambda (r) (rkGet r "line")) kept) (list 7))
  (setq lines (rkMaeT_readLines dest))
  (rkCheckEqual "dest line count" (length lines) 24)
  (rkCheckEqual "dest toplevel verbatim" (nth 6 lines) "include \"../lib/toplevel.scs\" section=TOP_TT")
  (rkCheckEqual "dest abs untouched" (nth 8 lines) "include \"/abs/model.scs\"")
  (rkCheckEqual "dest $VAR untouched" (nth 9 lines) "include \"$MODEL_ROOT/m.scs\"")
  (rkCheckEqual "dest rewritten line" (nth 5 lines) (rkGet (nth 0 rw) "new"))
  (rkCheck "log written" (isFile (rkGet res "log")))
  (rkCheckEqual "log path" (rkGet res "log") (rkPathJoin tmp "tb_top_test0.rewrite.log"))
  (setq lines (rkMaeT_readLines (rkGet res "log")))
  (rkCheck "log has - orig" (member "- include \"./models/a.scs\" section=tt" lines))
  (rkCheck "log has + new" (member (strcat "+ " (rkGet (nth 0 rw) "new")) lines))
  (rkCheck "log has kept" (member "= include \"../lib/toplevel.scs\" section=TOP_TT" lines))

  ; --- parameters parser ----------------------------------------------------
  (setq params (rkMaeParseNetlistParams nl))
  (rkCheckEqual "param VDD" (rkGet params "VDD") "1.8")
  (rkCheckEqual "param VSS (blanks)" (rkGet params "VSS") "0")
  (rkCheckEqual "param expr" (rkGet params "expr") "(VDD+1)")
  (rkCheckEqual "param continuation" (rkGet params "tail") "2")
  (rkCheck "param in subckt ignored" (null (rkGet params "inner")))
  (rkCheckEqual "spice .param" (rkGet params "SP") "3")
  (rkCheckEqual "spice + continuation" (rkGet params "SP2") "4")
  (rkCheck "spice .subckt param ignored" (null (rkGet params "INNER2")))
  (rkCheckEqual "param keys" (rkKeys params) (list "SP" "SP2" "VDD" "VSS" "expr" "tail"))

  ; --- sweep expansion / naming (CONTRACT 2.3) ------------------------------
  (rkCheckEqual "product" (rk_maeProduct (list (list "a" (list "1" "2")) (list "b" (list "x"))))
                (list (list (list "a" "1") (list "b" "x")) (list (list "a" "2") (list "b" "x"))))
  (setq cs (rk_maeExpandCorner "FF" t
             (list (list "temperature" (list "-40" "125")) (list "VSET" (list "12" "13")) (list "A" (list "1")))
             (list (list "/proj/model/toplevel.scs" (list "TOP_FF" "TOP_SS")) (list "/proj/model/x.scs" (list "pre")))
             nil "27"))
  (rkCheckEqual "expand count" (length cs) 8)
  (rkCheckEqual "expand names" (rkMaeT_names cs)
    (list "FF_t-40_TOP_FF_VSET12" "FF_t-40_TOP_FF_VSET13" "FF_t-40_TOP_SS_VSET12" "FF_t-40_TOP_SS_VSET13"
          "FF_t125_TOP_FF_VSET12" "FF_t125_TOP_FF_VSET13" "FF_t125_TOP_SS_VSET12" "FF_t125_TOP_SS_VSET13"))
  (rkCheckEqual "expand temp" (rkGet (nth 4 cs) "temperature") "125")
  (rkCheckEqual "expand vars" (list (rkGet (nth 1 cs) "vars.VSET") (rkGet (nth 1 cs) "vars.A")) (list "13" "1"))
  (rkCheckEqual "expand sweep keys" (rkKeys (rkGet (nth 0 cs) "sweep")) (list "VSET" "section" "temperature"))
  (rkCheckEqual "expand sections" (mapcar (lambda (s) (list (rkGet s "model_file") (rkGet s "section")))
                                          (rkGet (nth 2 cs) "sections"))
                (list (list "/proj/model/toplevel.scs" "TOP_SS") (list "/proj/model/x.scs" "pre")))
  (rkCheckEqual "expand base" (rkGet (nth 7 cs) "base_name") "FF")
  (setq cs (rk_maeExpandCorner "SS" nil nil nil (list (list "/proj/model/t.scs" "tt")) "25"))
  (rkCheckEqual "unswept name" (rkMaeT_names cs) (list "SS"))
  (rkCheckEqual "unswept enabled false" (rkGet (car cs) "enabled") rkJsonFalse)
  (rkCheckEqual "unswept temp from test" (rkGet (car cs) "temperature") "25")
  (rkCheckEqual "no models -> test models" (rkGet (car cs) "sections.0.section") "tt")
  (rkCheck "unswept sweep {}" (null (rkKeys (rkGet (car cs) "sweep"))))
  (rkCheckEqual "sanitize" (rk_maeSanitize "a b/c:1.5e-3+x") "a_b_c_1.5e-3+x")

  ; --- settings file I/O on a synthetic ctx ---------------------------------
  (setq ctx (rkMakeObj))
  (setq tbl (rkMakeObj))
  (rkPut tbl "lib" "mylib") (rkPut tbl "cell" "tb_top") (rkPut tbl "view" "maestro")
  (rkPut tbl "view_dir" (rkPathJoin tmp "lib/tb_top/maestro"))
  (rkPut ctx "maestro" tbl)
  (setq path (rkMaeSettingsPath ctx))
  (rkCheckEqual "settings path" path (rkPathJoin tmp "lib/tb_top/relkit/relkit_settings.json"))
  (when (isFile path) (deleteFile path))
  (rkCheck "settings absent -> nil" (null (rkMaeReadSettings ctx)))
  (setq settings (rkMakeObj))
  (rkPut settings "ip_name" "tb_top")
  (rkCheckEqual "settings write" (rkMaeWriteSettings ctx settings) path)
  (setq back (rkMaeReadSettings ctx))
  (rkCheckEqual "settings read ip" (rkGet back "ip_name") "tb_top")
  (rkCheckEqual "settings schema" (rkGet back "schema") 1)
  (rkPut tbl "view" "maestro_alt")
  (rkCheckEqual "settings path other view" (rkMaeSettingsPath ctx)
                (rkPathJoin tmp "lib/tb_top/relkit/relkit_settings_maestro_alt.json")))

; --- job policy helpers (synthetic .jp, no Maestro) ---------------------
(let (tmp tbl jp)
  (setq tmp (rkPathJoin (rkWorkarea) "relkit_dev/tmp/mae_jp"))
  (rkMkdirs tmp)
  (setq tbl (rk_maeDplTable (list nil 'name "demo_jp" 'distributionmethod "Command" 'maxjobs "4")))
  (rkCheckEqual "jp DPL -> table name" (rkGet tbl "name") "demo_jp")
  (rkCheckEqual "jp DPL -> table method" (rkGet tbl "distributionmethod") "Command")
  (setq jp (rkPathJoin tmp "file_stem.jp"))
  (rkMaeT_write jp (list "distributionmethod=Command" "name = demo_named" "maxjobs=2"))
  (rkCheckEqual "jp name= line" (rk_maeJpName jp) "demo_named")
  (rkMaeT_write jp (list "distributionmethod=Local"))
  (rkCheckEqual "jp stem without name=" (rk_maeJpName jp) "file_stem")
  (deleteFile jp))

; ===========================================================================
; Part B -- live Maestro (read-only session)
; ===========================================================================

(setq rkMaeT_sess nil)
(setq rkMaeT_tmpCorners (list "rkTmpSweep" "rkTmpOff" "rkTmpNoTest"))

(let (r)
  (setq r (errset (maeOpenSetup rkMae_lib rkMae_cell rkMae_view ?mode "r") t))
  (setq rkMaeT_sess (car r))
  (rkCheck "B maeOpenSetup read-only" (stringp rkMaeT_sess)))

(when (stringp rkMaeT_sess)
  (let (r)
    (setq r (errset
      (let (sess sdb before corners en mae ctx d gv ch names hist dest artifacts tops i7 ctxPath back nlTbl)
        (setq sess rkMaeT_sess)
        (setq sdb (axlGetMainSetupDB sess))
        (setq before (cadr (axlGetCorners sdb)))

        ; --- sessions / tests / design ------------------------------------
        (rkCheck "B session listed"
          (exists o (rkMaeListSessions) (equal (rkGet o "session") sess)))
        (rkCheck "B explicit window nil -> no session" (null (rkMaeCurrentSession (hiGetCIWindow))))
        (rkCheckEqual "B tests" (rkMaeListTests sess) (list "Test" "Test_trans"))
        (rkCheckEqual "B enabled tests" (rkMaeEnabledTests sess) (list "Test"))
        (rkCheckEqual "B default test" (rkMaeDefaultTest sess) "Test")
        (setq d (rkMaeGetDesign sess "Test"))
        (rkCheckEqual "B design" (list (rkGet d "lib") (rkGet d "cell") (rkGet d "view"))
                      (list "sim_yusheng" "Test" "config"))
        (rkCheckEqual "B is_config" (rkGet d "is_config") t)
        (rkCheckEqual "B config top" (list (rkGet d "top.lib") (rkGet d "top.cell") (rkGet d "top.view"))
                      (list "sim_yusheng" "Test" "schematic"))
        (setq gv (rkMaeGetGlobalVars sess "Test"))
        (rkCheckEqual "B var VDD" (rkGet gv "VDD") "3")
        (rkCheckEqual "B var flo" (rkGet gv "flo") "5G")
        (rkCheck "B test models" (rkMaeTestModels sess "Test"))
        (let ((jp (rkMaeJobPolicy sess "Test")))
          (printf "[rkMae_smoke] job policy of test Test: current %L (%L), %d available, dirs %L
"
                  (rkGet jp "current_name") (rkGet jp "current.distributionmethod")
                  (length (rkGet jp "available")) (rkGet jp "search_dirs"))
          (rkCheck "B job_policy table" (tablep jp))
          (rkCheck "B job_policy available is a list"
                   (or (listp (rkGet jp "available")) (eq (rkGet jp "available") rkJsonEmptyArray))))

        ; --- corners as stored --------------------------------------------
        (setq corners (rkMaeGetCorners sess "Test"))
        (setq en (setof c corners (eq (rkGet c "enabled") t)))
        (setq mae (axlGetCornersForATest sess "Test"))
        (rkCheckEqual "B corner count (TT 1 + TT_pvt 6 + TT_2p5G 1 + PVT_NT 15)" (length corners) 23)
        (rkCheckEqual "B enabled count == Maestro's expansion" (length en)
                      (length (setof m mae (and (car m) (nequal (car m) "")))))
        (rkCheck "B PVT_NT_ss_VDD2.8" (rkMaeT_find corners "PVT_NT_ss_VDD2.8"))
        (rkCheckEqual "B PVT_NT_ss_VDD2.8 section"
                      (rkGet (rkMaeT_find corners "PVT_NT_ss_VDD2.8") "sections.0.section") "ss")
        (rkCheck "B section model file resolved to the test's file"
          (pcreMatchp "^/.*\\.scs$" (rkGet (rkMaeT_find corners "PVT_NT_ss_VDD2.8") "sections.0.model_file")))
        (rkCheckEqual "B temperature" (rkGet (rkMaeT_find corners "PVT_NT_ss_VDD2.8") "temperature") "55")
        (rkCheckEqual "B TT disabled" (rkGet (rkMaeT_find corners "TT") "enabled") rkJsonFalse)
        (rkCheckEqual "B TT_pvt_ff_VDD3 enabled" (rkGet (rkMaeT_find corners "TT_pvt_ff_VDD3") "enabled") t)
        (rkCheckEqual "B TT_pvt vars" (rkGet (rkMaeT_find corners "TT_pvt_ff_VDD3") "vars.EN") "1")
        (rkCheck "B no Nominal (disabled in Maestro)" (null (rkMaeT_find corners "Nominal")))

        ; --- temporary corners: sweep, disabled, disabled-for-test ---------
        (setq ch (axlPutCorner sdb "rkTmpSweep"))
        (axlPutVar ch "temperature" "-40 125")
        (axlPutVar ch "VDD" "1.8")
        (setq ch (axlPutCorner sdb "rkTmpOff"))
        (axlPutVar ch "temperature" "85")
        (axlSetEnabled ch nil)
        (setq ch (axlPutCorner sdb "rkTmpNoTest"))
        (axlPutVar ch "temperature" "0")
        (axlSetCornerTestEnabled ch "Test" nil)
        (setq corners (rkMaeGetCorners sess "Test"))
        (setq names (rkMaeT_names corners))
        (rkCheck "B tmp sweep expanded" (and (member "rkTmpSweep_t-40" names) (member "rkTmpSweep_t125" names)))
        (rkCheckEqual "B tmp sweep temp" (rkGet (rkMaeT_find corners "rkTmpSweep_t-40") "temperature") "-40")
        (rkCheckEqual "B tmp sweep var" (rkGet (rkMaeT_find corners "rkTmpSweep_t125") "vars.VDD") "1.8")
        (rkCheckEqual "B tmp sweep map" (rkGet (rkMaeT_find corners "rkTmpSweep_t125") "sweep.temperature") "125")
        (rkCheckEqual "B tmp sweep enabled" (rkGet (rkMaeT_find corners "rkTmpSweep_t125") "enabled") t)
        (rkCheck "B tmp sweep w/o models -> test models"
          (greaterp (length (rkGet (rkMaeT_find corners "rkTmpSweep_t125") "sections")) 0))
        (rkCheckEqual "B tmp disabled corner" (rkGet (rkMaeT_find corners "rkTmpOff") "enabled") rkJsonFalse)
        (rkCheckEqual "B tmp disabled-for-test corner" (rkGet (rkMaeT_find corners "rkTmpNoTest") "enabled") rkJsonFalse)
        (setq en (setof c corners (eq (rkGet c "enabled") t)))
        (setq mae (axlGetCornersForATest sess "Test"))
        (rkCheckEqual "B enabled count with tmp corners == Maestro's" (length en)
                      (length (setof m mae (and (car m) (nequal (car m) "")))))

        ; --- context -> JSON -----------------------------------------------
        (setq ctx (rkMaeGetContext sess "Test"))
        (rkCheckEqual "B ctx schema" (rkGet ctx "schema") 1)
        (rkCheckEqual "B ctx maestro" (list (rkGet ctx "maestro.lib") (rkGet ctx "maestro.cell") (rkGet ctx "maestro.view"))
                      (list "sim_yusheng" "Test" "maestro"))
        (rkCheck "B ctx view_dir" (isDir (rkGet ctx "maestro.view_dir")))
        (rkCheckEqual "B ctx ip_name" (rkGet ctx "ip_name") "Test")
        (rkCheckEqual "B ctx test" (rkGet ctx "test") "Test")
        (rkCheck "B ctx created ISO" (pcreMatchp "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$" (rkGet ctx "created")))
        (setq ctxPath (rkPathJoin (rkWorkarea) "relkit_dev/tmp/mae/ctx_smoke.json"))
        (rkJsonWrite ctx ctxPath)
        (setq back (rkJsonRead ctxPath))
        (rkCheckEqual "B ctx json corners" (length (rkGet back "corners")) (length corners))
        (rkCheckEqual "B ctx json design.top.cell" (rkGet back "design.top.cell") "Test")
        (rkCheck "B ctx json has false" (pcreMatchp "\"enabled\": false" (rkReadFileText ctxPath)))
        (rkCheck "B ctx json history null" (pcreMatchp "\"history\": null" (rkReadFileText ctxPath)))

        ; --- Nominal: included only while enabled (restored afterwards) ------
        (axlSetNominalCornerEnabled sdb t)
        (setq corners (rkMaeGetCorners sess "Test"))
        (axlSetNominalCornerEnabled sdb nil)
        (rkCheck "B Nominal included when enabled" (rkMaeT_find corners "Nominal"))
        (rkCheckEqual "B Nominal sections = test models"
                      (length (rkGet (rkMaeT_find corners "Nominal") "sections"))
                      (length (rkMaeTestModels sess "Test")))
        (rkCheck "B Nominal temperature" (stringp (rkGet (rkMaeT_find corners "Nominal") "temperature")))
        (rkCheck "B Nominal disabled again" (null (axlGetNominalCornerEnabled sdb)))

        ; --- delete temporary corners (setup is never saved: read-only) ----
        (foreach nm rkMaeT_tmpCorners (axlRemoveElement (axlGetCorner sdb nm)))
        (rkCheckEqual "B tmp corners deleted" (cadr (axlGetCorners sdb)) before)

        ; --- top instances (DUT drop-down) ----------------------------------
        (setq tops (rkMaeListTopInstances sess "Test"))
        (setq i7 (car (setof o tops (equal (rkGet o "inst") "I7"))))
        (rkCheckEqual "B top inst I7 cell" (rkGet i7 "cell") "Test_cell")
        (rkCheckEqual "B top inst I7 view" (rkGet i7 "view") "schematic")
        (rkCheck "B top inst I7 terms" (member "VDD" (rkGet i7 "terms")))
        (rkCheckEqual "B DUT candidates first" (rkGet (car tops) "inst") "I7")
        (rkCheckEqual "B V0 primitive" (rkGet (car (setof o tops (equal (rkGet o "inst") "V0"))) "is_primitive") t)

        ; --- netlist export from the newest history -------------------------
        (setq hist (rkMaeFindHistory sess "Test"))
        (rkCheck "B history found" (and hist (isFile (rkGet hist "source"))))
        (rkCheck "B no history for an unknown test" (null (rkMaeFindHistory sess "NoSuchTest")))
        (rkCheck "B export without DUT errors" (null (errset (rkMaeExportNetlist ctx) nil)))
        (setq nlTbl (rkMakeObj))
        (rkPut nlTbl "inst" "I7") (rkPut nlTbl "lib" "sim_yusheng") (rkPut nlTbl "cell" "Test_cell")
        (rkPut nlTbl "view" "schematic")
        (rkPut ctx "dut" nlTbl)
        (setq artifacts (list (rkSiteGet "artifact_root") (rkPathJoin (rkSiteGet "artifact_root") "Test_cell")))
        (setq artifacts (setof a artifacts (not (isDir a))))   ; dirs this test creates
        (setq dest (rkMaeExportNetlist ctx))
        (rkCheckEqual "B export path" dest
                      (rkPathJoin (rkSiteGet "artifact_root") "Test_cell/Test_Test.scs"))
        (rkCheck "B export file" (isFile dest))
        (rkCheckEqual "B ctx history name" (rkGet ctx "history.name") (rkGet hist "name"))
        (rkCheckEqual "B ctx netlist source" (rkGet ctx "netlist.source") (rkGet hist "source"))
        (rkCheck "B ctx netlist map_dir" (isDir (rkGet ctx "netlist.map_dir")))
        (rkCheckEqual "B netlist param DVDD" (rkGet ctx "netlist.parameters.DVDD") "0.9")
        (rkCheck "B netlist param VDD" (rkGet ctx "netlist.parameters.VDD"))
        (rkCheck "B netlist rewrites list" (or (null (rkGet ctx "netlist.rewrites"))
                                               (eq (rkGet ctx "netlist.rewrites") rkJsonEmptyArray)
                                               (listp (rkGet ctx "netlist.rewrites"))))
        (rkCheck "B rewrite log" (isFile (rkGet ctx "netlist.log")))
        (rkJsonWrite ctx ctxPath)
        (rkCheckEqual "B ctx json netlist.path" (rkGet (rkJsonRead ctxPath) "netlist.path") dest)
        (rkCheckEqual "B real settings path" (rkMaeSettingsPath ctx)
                      (rkPathJoin (rk_maeDirname (rkGet ctx "maestro.view_dir")) "relkit/relkit_settings.json"))
        ; remove the exported artifacts again (dev VM hygiene)
        (deleteFile dest)
        (deleteFile (rkGet ctx "netlist.log"))
        (foreach a (reverse artifacts) (deleteDir a))
        (rkCheck "B artifact dirs cleaned" (not (exists a artifacts (isDir a))))
        t)
      t))
    (rkCheck "B body ran without error" (car r))))

; Cleanup no matter what: temporary corners out, session closed (read-only:
; nothing was or can be saved).
(when (stringp rkMaeT_sess)
  (let ((sdb (car (errset (axlGetMainSetupDB rkMaeT_sess) nil))) ch)
    (foreach nm rkMaeT_tmpCorners
      (setq ch (and sdb (car (errset (axlGetCorner sdb nm) nil))))
      (when (and ch (nequal ch 0)) (errset (axlRemoveElement ch) nil)))
    (rkCheck "B tmp corners gone"
      (not (exists nm rkMaeT_tmpCorners (member nm (cadr (car (errset (axlGetCorners sdb) nil)))))))
    (rkCheck "B session closed" (car (errset (maeCloseSession ?session rkMaeT_sess ?forceClose t) nil)))))
