; rkGui_smoke.il -- relkit panel + IPC smoke test (headless), driven by
; tests/rkGui_smoke.py over skillbridge.
;
; The panel is BUILT but never displayed (a displayed form must not block the
; bridge): fields are set with rkGuiSet and the button callbacks are called
; directly (memory reference_cadence_form_headless_test). Asynchronous parts
; (Python subprocesses, pollers) need Virtuoso's event loop, which only runs
; between bridge calls -- so the Python driver calls the phase functions below
; one at a time and waits in between with one-line probes.
;
; Uses: sim_yusheng/Test/maestro opened READ-ONLY (maeOpenSetup ?mode "r"), a
; scratch site (<scratch>/wa/.relkit_site.json, written by the driver) whose
; work/persist/artifact roots live under <scratch>, the fake RelStudio
; (EMIR: license fails twice, then succeeds; DEOS: the first instance violates)
; and the fake extraction tools.

(setq rkGuiT_sess nil)
(setq rkGuiT_dir nil)
(setq rkGuiT_forms nil)
(setq rkGuiT_corners (list "TT_pvt_tt_VDD3" "PVT_NT_ss_VDD3"))

(defun rkGuiT_names (rows) (mapcar (lambda (r) (nth 2 r)) rows))

; ---------------------------------------------------------------------------
; Phase 1: open, lifecycle, top bar, corners, DUT, settings
; ---------------------------------------------------------------------------

(defun rkGuiT_setup (scratch)
  (let (f1 f2 r rows idx nm)
    (rkTestBegin "rkGui_smoke")
    (setq rkGuiT_dir scratch)
    (setq rkGuiSiteWorkarea (rkPathJoin scratch "wa"))
    (setq rkGuiT_baseEnv (list (strcat "RELKIT_FAKE_RS_CONFIG=" (rkPathJoin scratch "fake_rs.json"))
                               (strcat "RELKIT_FAKE_TOOLS_CONFIG=" (rkPathJoin scratch "fake_tools.json"))))
    ; the synthetic PDK: inherited from Virtuoso's own environment when it was
    ; started with it (relkit_dev/fakepdk/env.csh), else passed to the children
    (setq rkGuiT_pdkEnv (rkGuiT_readLines (rkPathJoin scratch "pdk_env.txt")))
    (setq rkGuiT_pdkInherited (and (getShellEnvVar "VERIFY_ROOT")
                                   (getShellEnvVar "calibre_source_added_place") t))
    (rkGuiT_envFull)
    (setq rk_guiNoDisplay t)
    (setq r (errset (maeOpenSetup "sim_yusheng" "Test" "maestro" ?mode "r") t))
    (setq rkGuiT_sess (and r (car r)))
    (rkCheck "maeOpenSetup read-only" (stringp rkGuiT_sess))
    ; --- lifecycle: two builds -> two different form names, last one live
    (setq f1 (rkGuiBuild rkGuiT_sess))
    (setq f2 (rkGuiBuild rkGuiT_sess))
    (setq rkGuiT_forms (list f1 f2))
    (rkCheck "build returns a form" (and f1 f2 t))
    (rkCheck "Pattern A: fresh form name per build" (nequal f1->hiFormSym f2->hiFormSym))
    (rkCheck "rkGuiCurrentForm is the newest" (eq (rkGuiCurrentForm) f2))
    (rkCheck "built panel is not displayed" (not (hiIsFormDisplayed f2)))
    ; --- top bar
    (rkCheckEqual "site file used" (rkSitePath) (rkPathJoin (rkPathJoin scratch "wa") ".relkit_site.json"))
    (rkCheck "test choices hold Test" (member "Test" (get (rkGuiField 'rk_gTest) 'choices)))
    (rkCheckEqual "test value" (rkGuiGet 'rk_gTest) "Test")
    (rkCheck "design shows the config" (pcreMatchp "^sim_yusheng/Test/config .*config; top sim_yusheng/Test/schematic" (rkGuiGet 'rk_gDesign)))
    (rkCheck "RelStudio home shown" (pcreMatchp "fake_relstudio$" (rkGuiGet 'rk_gRsHome)))
    (rkCheckEqual "IP_Name default = Maestro cell" (rkGuiGet 'rk_gIp) "Test")
    (rkCheck "DUT drop-down lists I7" (exists c (get (rkGuiField 'rk_gDut) 'choices) (pcreMatchp "^I7 " c)))
    ; --- corners: default = Maestro enabled
    (setq rows (get (rkGuiField 'rk_gCorners) 'choices))
    (rkCheckEqual "corner rows" (length rows) (length (rkGet rk_guiCtx "corners")))
    (rkCheckEqual "selected = Maestro enabled"
                  (length (setof x rows (equal (nth 1 x) "x")))
                  (length (setof c (rkGet rk_guiCtx "corners") (eq (rkGet c "enabled") t))))
    (rkCheck "disabled corner shows off + unchecked"
             (exists x rows (and (equal (nth 6 x) "off") (equal (nth 1 x) ""))))
    (rk_guiCornerSetCB 'none)
    (rkCheckEqual "None -> 0 selected" (length (rk_guiSelectedCorners)) 0)
    (rk_guiCornerSetCB 'all)
    (rkCheckEqual "All -> all selected" (length (rk_guiSelectedCorners)) (length rows))
    (rk_guiCornerSetCB 'none)
    (setq idx (setof i (mapcar (lambda (x) (atoi (car x))) rows)
                     (member (nth 2 (nth i rows)) rkGuiT_corners)))
    (rkCheckEqual "test corners exist" (length idx) 2)
    (hiReportSelectItems (rkGuiField 'rk_gCorners) idx nil)
    (rk_guiCornerToggleCB)
    (rkCheckEqual "toggle selects the two corners"
                  (sort (mapcar (lambda (c) (rkGet c "name")) (rk_guiSelectedCorners)) 'alphalessp)
                  (sort (copy rkGuiT_corners) 'alphalessp))
    (rkCheck "corner info line" (pcreMatchp "^2 of [0-9]+ selected$" (rkGuiGet 'rk_gCornerInfo)))
    ; --- Show filter: display only, Use toggles on a filtered view hit the right corner
    (rkGuiSet 'rk_gCornerShow "Selected only")
    (rk_guiCornerShowCB)
    (setq rows (get (rkGuiField 'rk_gCorners) 'choices))
    (rkCheckEqual "filter: 'Selected only' shows the 2 selected" (length rows) 2)
    (rkCheck "filter: count with 'showing'" (pcreMatchp "^2 of [0-9]+ selected [(]showing 2[)]$" (rkGuiGet 'rk_gCornerInfo)))
    (setq nm (nth 2 (nth 1 rows)))
    (hiReportSelectItems (rkGuiField 'rk_gCorners) (list 1) nil)
    (rk_guiCornerToggleCB)
    (rkCheck "filter: toggled row's corner is deselected"
             (not (member nm (mapcar (lambda (c) (rkGet c "name")) (rk_guiSelectedCorners)))))
    (rkCheckEqual "filter: 1 row left in 'Selected only'" (length (get (rkGuiField 'rk_gCorners) 'choices)) 1)
    (rkGuiSet 'rk_gCornerShow "Unselected only")
    (rk_guiCornerShowCB)
    (setq rows (get (rkGuiField 'rk_gCorners) 'choices))
    (rkCheckEqual "filter: 'Unselected only' rows" (length rows)
                  (difference (length (rkGet rk_guiCtx "corners")) 1))
    (setq r 0)
    (foreach x rows (when (equal (nth 2 x) nm) (setq idx r)) (setq r (add1 r)))
    (hiReportSelectItems (rkGuiField 'rk_gCorners) (list idx) nil)
    (rk_guiCornerToggleCB)
    (rkCheckEqual "filter: toggled back from the unselected view" (length (rk_guiSelectedCorners)) 2)
    (rkCheckEqual "filter persisted in the per-cell settings"
                  (rkGet (rkMaeReadSettings rk_guiCtx) "corner_show") "Unselected only")
    (rkGuiSet 'rk_gCornerShow "All")
    (rk_guiCornerShowCB)
    (rkCheckEqual "filter: All shows every corner" (length (get (rkGuiField 'rk_gCorners) 'choices))
                  (length (rkGet rk_guiCtx "corners")))
    ; --- Donau profiles per page
    (rkCheckEqual "donau choices" (get (rkGuiField 'rk_gaDonau) 'choices) (list "emir" "std"))
    (rkCheckEqual "donau aging default" (rkGuiGet 'rk_gaDonau) "std")
    (rkCheckEqual "donau deos default" (rkGuiGet 'rk_gdDonau) "std")
    (rkCheckEqual "donau emir default" (rkGuiGet 'rk_geDonau) "emir")
    (rkCheck "donau summary" (pcreMatchp "Queue long, CPU 16, Memory 64000" (rkGuiGet 'rk_geDonauInfo)))
    (rkGuiSet 'rk_gaDonau "emir")
    (rk_guiDonauCB "aging")
    (rkCheck "donau summary follows the pick" (pcreMatchp "Queue long" (rkGuiGet 'rk_gaDonauInfo)))
    (rkCheckEqual "donau pick -> settings" (rkGet (rk_guiPageSettings "aging") "donau_profile") "emir")
    ; --- context menus attached, EMIR own files off by default
    (rkCheck "context menu on the Runs list" (get (rkGuiField 'rk_grList) 'hiContextMenu))
    (rkCheck "context menu on the EMIR results" (get (rkGuiField 'rk_geRes) 'hiContextMenu))
    (rkCheck "own DSPF/GDS off by default" (null (rkGuiGet 'rk_geOwn)))
    (rkCheck "DSPF field disabled in auto mode" (null (get (rkGuiField 'rk_geDspf) 'enabled)))
    (rkCheck "auto -> auto_extract true" (eq (rkGet (rk_guiPageSettings "emir") "auto_extract") t))
    (rkGuiSet 'rk_geOwn t)
    (rk_guiOwnCB)
    (rkCheck "own: DSPF field enabled" (get (rkGuiField 'rk_geDspf) 'enabled))
    (rkCheck "own: auto_extract false" (eq (rkGet (rk_guiPageSettings "emir") "auto_extract") rkJsonFalse))
    (rkCheck "own: state line" (pcreMatchp "^own files" (rkGuiGet 'rk_geAuto)))
    (rkGuiSet 'rk_geOwn nil)
    (rk_guiOwnCB)
    ; --- DUT from the drop-down (saves the per-cell settings)
    (rkGuiSet 'rk_gDut (car (setof c (get (rkGuiField 'rk_gDut) 'choices) (pcreMatchp "^I7 " c))))
    (rk_guiDutCB)
    (rkCheckEqual "DUT inst" (rkGet rk_guiDut "inst") "I7")
    (rkCheck "EMIR DUT line" (pcreMatchp "Instance_Name I7" (rkGuiGet 'rk_geDut)))
    (rkCheck "settings file written" (isFile (rkMaeSettingsPath rk_guiCtx)))
    ; DUT pick done-callback (the click itself is rkResults' job)
    (rk_guiDutPicked nil)
    (rkCheck "pick cancelled keeps the DUT" (equal (rkGet rk_guiDut "inst") "I7"))
    ; --- page fields
    (rkGuiSet 'rk_gaStart "0n")
    (rkGuiSet 'rk_gaStop "10n")
    (rkGuiSet 'rk_gaEvalT "")
    (rkGuiSet 'rk_gdTddb "125")
    (rkGuiSet 'rk_gdSimT "10n")
    (rkCheckEqual "aging settings" (list (rkGet (rk_guiPageSettings "aging") "stop_time")
                                         (rkGet (rk_guiPageSettings "aging") "eval_temperatures"))
                  (list "10n" nil))
    (rkCheckEqual "deos tddb as number" (rkGet (rk_guiPageSettings "deos") "tddb_temperature") 125)
    (rkCheckEqual "license policy default" (rkGet (rk_guiPageSettings "emir") "license_policy") "wait_forever")
    (rkGuiSet 'rk_geLic "fail")
    (rkCheckEqual "license policy fail" (rk_guiLicPolicy) "fail")
    (rkGuiSet 'rk_geLic "wait forever")
    ; --- run ctx
    (setq r (rkGuiRunCtx "aging"))
    (rkCheckEqual "ctx run_type" (rkGet r "run_type") "aging")
    (rkCheckEqual "ctx dut" (rkGet r "dut.inst") "I7")
    (rkCheckEqual "ctx selected corners" (length (setof c (rkGet r "corners") (eq (rkGet c "selected") t))) 2)
    (rkCheck "ctx unselected written false" (exists c (rkGet r "corners") (eq (rkGet c "selected") rkJsonFalse)))
    (rkCheck "panel did not touch the Maestro corners" (eq (rkGet (car (setof c (rkGet rk_guiCtx "corners") (equal (rkGet c "name") "TT_pvt_tt_VDD2.8"))) "enabled") t))
    t))

; ---------------------------------------------------------------------------
; Phase 1b: extract-resolve (parameters derived from the environment)
; ---------------------------------------------------------------------------

(defun rkGuiT_readLines (path)
  (let (port line out)
    (when (isFile path)
      (setq port (infile path))
      (while (gets line port)
        (setq line (rk_guiTrim line))
        (unless (equal line "") (setq out (cons line out))))
      (close port))
    (reverse out)))

; the PDK variables as the children see them: Virtuoso's own, or from the file
(defun rkGuiT_envFull ()
  (rkIpcSetEnv (if rkGuiT_pdkInherited rkGuiT_baseEnv (append rkGuiT_baseEnv rkGuiT_pdkEnv)))
  t)

(defun rkGuiT_resolveMissing ()
  ; blank the PDK variables for the children (empty = unset for the resolver)
  (rkIpcSetEnv (append rkGuiT_baseEnv
                       (list "VERIFY_ROOT=" "calibre_source_added_place=" "SETUP_ROOT="
                             "PDK_TECH_FILE=" "PDK_LAYER_MAP_FILE=" "PDK_DISPLAY_FILE=")))
  (setq rk_guiResolve nil)
  (rk_guiResolveCB)
  t)

(defun rkGuiT_checkMissing ()
  (rkCheck "resolve: missing env reported"
           (and (member "VERIFY_ROOT" (rk_guiL (rkGet rk_guiResolve "missing_env")))
                (member "calibre_source_added_place" (rk_guiL (rkGet rk_guiResolve "missing_env")))))
  (rkCheck "resolve: status names the variables" (pcreMatchp "^MISSING environment variable.*[$]VERIFY_ROOT" (rkGuiGet 'rk_geXStatus)))
  (rkCheck "extract button disabled while env missing" (null (get (rkGuiField 'rk_geBExtract) 'enabled)))
  (rk_guiExtractCB)
  (rkCheck "extract refused while env missing"
           (and (pcreMatchp "^MISSING" (rkGuiGet 'rk_geXStatus)) (null (rkIpcPollActive "gui:extract"))))
  t)

(defun rkGuiT_resolveFull ()
  (rkGuiT_envFull)
  (setq rk_guiResolve nil)
  (rk_guiResolveCB)
  t)

(defun rkGuiT_checkAutoState ()
  (rkCheck "auto DSPF/GDS state shown" (pcreMatchp "^auto: (MISSING|STALE|FRESH)" (rkGuiGet 'rk_geAuto)))
  (rkCheck "auto DSPF path shown" (pcreMatchp "Test_cell[.]dspf$" (rkGuiGet 'rk_geDspf)))
  t)

(defun rkGuiT_checkReady ()
  (printf "[rkGui_smoke] PDK env %s\n" (if rkGuiT_pdkInherited "inherited from Virtuoso" "passed via rkIpcSetEnv"))
  (rkCheck "resolve ready" (eq (rkGet rk_guiResolve "ready") t))
  (rkCheck "no missing env" (null (rk_guiL (rkGet rk_guiResolve "missing_env"))))
  (rkCheck "status: ready + tech name from the env" (pcreMatchp "^ready: tech demo_tech, LVS DEMO_LVS_R1.wodio" (rkGuiGet 'rk_geXStatus)))
  (rkCheck "extract button enabled" (get (rkGuiField 'rk_geBExtract) 'enabled))
  (rkCheck "variant choices from the deck dir"
           (and (member "wodio" (get (rkGuiField 'rk_geXVariant) 'choices))
                (member "widio" (get (rkGuiField 'rk_geXVariant) 'choices))))
  (rkCheck "QRC deck choices (short labels)" (member "Ver_B/DEMO_QRC_R1" (get (rkGuiField 'rk_geXQrc) 'choices)))
  (rkGuiSet 'rk_geXQrc "Ver_B/DEMO_QRC_R1")
  (rkCheck "QRC label -> deck path in the settings"
           (pcreMatchp "/QRC/Ver_B/DEMO_QRC_R1/QCI_deck$" (rkGet (rk_guiPageSettings "extract") "qrc_deck")))
  (rkGuiSet 'rk_geXQrc rk_guiAuto)
  (rkCheck "RC corner choices" (member "cworst" (get (rkGuiField 'rk_geXCorner) 'choices)))
  (rkCheck "LVS power prefilled" (pcreMatchp "VDD" (rkGuiGet 'rk_geXPower)))
  (rkCheck "LVS ground prefilled" (pcreMatchp "VSS" (rkGuiGet 'rk_geXGround)))
  (rkCheck "preview text written" (isFile (rkGet rk_guiResolve "text")))
  (rkGuiSet 'rk_geXVariant "widio")
  (rkCheckEqual "variant choice -> settings" (rkGet (rk_guiPageSettings "extract") "lvs_variant") "widio")
  (rkGuiSet 'rk_geXVariant rk_guiAuto)
  (rkCheckEqual "(auto) -> null" (rkGet (rk_guiPageSettings "extract") "lvs_variant") nil)
  (rkGuiSet 'rk_geXCorner "cworst")
  (rkCheckEqual "RC corner -> settings" (rkGet (rk_guiPageSettings "extract") "technology_corner") "cworst")
  (rkCheckEqual "LVS power -> settings list" (car (rkGet (rk_guiPageSettings "extract") "power_names")) "VDD")
  t)

; ---------------------------------------------------------------------------
; Phase 2: extraction (LVS fail, then pass), supplies
; ---------------------------------------------------------------------------

(defun rkGuiT_extract () (rk_guiExtractCB) t)

(defun rkGuiT_extractState ()
  (cond
    ((rkIpcPollActive "gui:extract") "polling")
    ((pcreMatchp "^extraction not started" (or (rkGuiGet 'rk_geXStatus) "")) "not_started")
    ((null rk_guiExtract) "none")
    (t (or (rkGet rk_guiExtract "state") "?"))))

(defun rkGuiT_checkLvsFail ()
  (rkCheckEqual "extract state lvs_failed" (rkGuiT_extractState) "lvs_failed")
  (rkCheck "LVS fail message" (pcreMatchp "^LVS FAILED" (rkGuiGet 'rk_geXStatus)))
  (rkCheck "Calibre GUI button enabled" (get (rkGuiField 'rk_geBCalibre) 'enabled))
  (rkCheck "calibre gui command known" (stringp (rkGet rk_guiExtract "calibre_gui_cmd")))
  (rkCheck "no DSPF published after LVS fail" (not (isFile (rkGuiGet 'rk_geDspf))))
  t)

(defun rkGuiT_checkExtractDone ()
  (rkCheckEqual "extract state done" (rkGuiT_extractState) "done")
  (rkCheck "DSPF filled" (isFile (rkGuiGet 'rk_geDspf)))
  (rkCheck "GDS filled" (isFile (rkGuiGet 'rk_geGds)))
  (rkCheck "extract message" (pcreMatchp "^done" (rkGuiGet 'rk_geXStatus)))
  ; "use existing": detect finds the same pair
  (rkGuiSet 'rk_geDspf "")
  (rkGuiSet 'rk_geGds "")
  (rk_guiDetectCB)
  t)

(defun rkGuiT_checkDetect ()
  (rkCheck "detect refills DSPF" (pcreMatchp "Test_cell\\.dspf$" (rkGuiGet 'rk_geDspf)))
  (rkCheck "detect refills GDS" (pcreMatchp "Test_cell\\.gds$" (rkGuiGet 'rk_geGds)))
  (rkGuiSet 'rk_gePower "")
  (rkGuiSet 'rk_geGround "")
  (rk_guiSuppliesCB)
  t)

(defun rkGuiT_checkSupplies ()
  (rkCheck "supplies status" (pcreMatchp "supplies filled" (rkGuiGet 'rk_geStatus)))
  ; ports without a voltage come back as bare names: type a value for them
  (when (or (rk_guiBlank (rkGuiGet 'rk_gePower))
            (exists w (rk_guiWords (rkGuiGet 'rk_gePower)) (not (pcreMatchp "=" w))))
    (rkGuiSet 'rk_gePower
              (rk_guiJoin (mapcar (lambda (w) (if (pcreMatchp "=" w) w (strcat w "=3")))
                                  (or (rk_guiWords (rkGuiGet 'rk_gePower)) (list "VDD")))
                          " ")))
  (when (rk_guiBlank (rkGuiGet 'rk_geGround)) (rkGuiSet 'rk_geGround "VSS"))
  (rkCheck "power supplies parse" (rkKeys (rkGet (rk_guiPageSettings "emir") "supplies.power")))
  t)

; ---------------------------------------------------------------------------
; Phase 3: submit the three types, follow them to the end
; ---------------------------------------------------------------------------

(defun rkGuiT_submit ()
  (rkCheck "submit aging" (rkGuiSubmit "aging"))
  (rkCheck "submit deos" (rkGuiSubmit "deos"))
  (rkCheck "submit emir" (rkGuiSubmit "emir"))
  (rkCheck "a second submit while one is pending is refused" (null (rkGuiSubmit "aging")))
  (rkCheck "refusal message" (pcreMatchp "already in progress" (rkGuiGet 'rk_gaStatus)))
  t)

(defun rkGuiT_state (type)
  (let ((l (arrayref rk_guiLast type)))
    (cond
      ((rkIpcBusy (arrayref rk_guiPending type)) "submitting")
      ((null (arrayref rk_guiRunDir type)) "refused")
      ((null l) "pending")
      (t (or (rkGet l "state") (sprintf nil "error: %s" (rkGet l "error" "?")))))))

(defun rkGuiT_states () (mapcar 'rkGuiT_state rk_guiTypes))

(defun rkGuiT_allFinal ()
  (and (forall ty rk_guiTypes (or (rk_guiIsFinal (rkGuiT_state ty)) (equal (rkGuiT_state ty) "refused")))
       (null (rkIpcPollActive "gui:run:"))))

(defun rkGuiT_checkRuns ()
  (let (run lic tl)
    (foreach ty rk_guiTypes
      (rkCheckEqual (sprintf nil "%s run done" ty) (rkGuiT_state ty) "done")
      (rkCheck (sprintf nil "%s run record" ty) (isFile (rkPathJoin (arrayref rk_guiRunDir ty) "run.json")))
      (rkCheck (sprintf nil "%s results rows" ty) (get (rkGuiField (rk_guiTF ty "Res")) 'choices))
      (rkCheck (sprintf nil "%s status line" ty) (pcreMatchp ": done" (rkGuiGet (rk_guiTF ty "Status"))))
      (rkCheck (sprintf nil "%s aux report" ty) (isFile (rkPathJoin (arrayref rk_guiRunDir ty) "aux_report.html")))
      (rkCheck (sprintf nil "%s official report found" ty) (rk_guiOfficialReport (arrayref rk_guiRunDir ty))))
    ; EMIR: license failed twice then succeeded
    (setq run (rk_guiReadRun (arrayref rk_guiRunDir "emir")))
    (setq lic (rkGet run "license"))
    (rkCheckEqual "emir license retries" (rkGet lic "retries") 2)
    (setq tl (setof e (rkGet run "timeline") (equal (rkGet e "state") "waiting_license")))
    (rkCheck "emir timeline has waiting_license" tl)
    ; DEOS: the violating first instance (I7.PIN5) is the worst device, FAIL row
    (rkCheck "deos FAIL row" (exists r (get (rkGuiField 'rk_gdRes) 'choices) (equal (nth 3 r) "FAIL")))
    (rkCheck "deos worst device I7.PIN5" (exists r (get (rkGuiField 'rk_gdRes) 'choices) (equal (nth 5 r) "I7.PIN5")))
    ; EMIR: DSPF/GDS automatic (extracted first unless the pair was fresh)
    (rkCheckEqual "emir auto-extract mode" (rkGet run "extract.mode") "auto")
    (rkCheck "emir: extracted first when not fresh"
             (or (equal (rkGet run "extract.check") "fresh")
                 (and (equal (rkGet run "extract.state") "done")
                      (exists e (rkGet run "timeline") (equal (rkGet e "state") "extracting")))))
    (rkCheck "emir: yml names the canonical DSPF" (pcreMatchp "/Test_cell/Test_cell[.]dspf$" (rkGet run "settings.dspf_file")))
    ; Donau profiles recorded per run
    (rkCheckEqual "emir donau profile" (rkGet run "settings.donau_profile") "emir")
    (setq run (rk_guiReadRun (arrayref rk_guiRunDir "aging")))
    (rkCheckEqual "aging donau profile (picked)" (rkGet run "settings.donau_profile") "emir")
    (rkCheckEqual "aging cluster from the profile" (rkGet run "cluster.Queue") "long")
    (setq run (rk_guiReadRun (arrayref rk_guiRunDir "deos")))
    (rkCheckEqual "deos donau profile (default)" (rkGet run "settings.donau_profile") "std")
    (rkCheckEqual "deos cluster" (rkGet run "cluster.Queue") "short")
    t))

; --- progress window from the Runs page context menu, then the page button
(defun rkGuiT_progress ()
  (rkGuiT_select (list (rk_guiBaseName (arrayref rk_guiRunDir "emir"))))
  (setq rk_guiProgRes nil)
  (rk_guiCtxMenuCB "runs" "progress")
  t)

(defun rkGuiT_progSummary ()
  (sprintf nil "%s: %d row(s) %L" (rkGet rk_guiProgRes "state" "?") (length (rkGet rk_guiProgRes "rows"))
           (mapcar (lambda (r) (list (nth 1 r) (nth 2 r) (nth 4 r))) (get (get rk_guiProgForm 'rk_pRows) 'choices))))

(defun rkGuiT_checkProgress ()
  (let ((rows (get (get rk_guiProgForm 'rk_pRows) 'choices)) f1)
    (rkCheck "progress: window built for the emir run" (pcreMatchp "_emir" (get (get rk_guiProgForm 'rk_pHead) 'value)))
    (rkCheck "progress: job rows" (exists r rows (equal (nth 1 r) "job")))
    (rkCheck "progress: every job done" (forall r (setof x rows (equal (nth 1 x) "job")) (equal (nth 4 r) "done")))
    (rkCheck "progress: extract rows when it extracted"
             (or (equal (rkGet (rk_guiReadRun (arrayref rk_guiRunDir "emir")) "extract.check") "fresh")
                 (equal (mapcar (lambda (r) (nth 2 r)) (setof x rows (equal (nth 1 x) "extract")))
                        (list "strmout" "si" "lvs" "qrc"))))
    (rkCheck "progress: final run -> poller stopped" (null (rkIpcPollActive "rkprog:")))
    (rkCheck "progress: log of a job row" (exists l rk_guiProgLogs (and (stringp l) (pcreMatchp "job[.]out$" l))))
    (setq f1 rk_guiProgForm)
    (rk_guiPageProgressCB "deos")
    (rkCheck "progress: page button replaces the window" (and rk_guiProgForm (nequal rk_guiProgForm f1)))
    (rkCheck "progress: page button follows the deos run" (pcreMatchp "_deos" (rk_guiBaseName rk_guiProgRun)))
    (rkGuiCloseProgress)
    (rkCheck "progress: closed -> no poller" (null (rkIpcPollActive "rkprog:")))
    (rkCheck "progress: closed -> no form" (null rk_guiProgForm))
    t))

; --- EMIR auto-extract whose LVS fails: run ends lvs_failed, Calibre button on
(defun rkGuiT_emirLvsFail ()
  (rkGuiSet 'rk_geXCorner "rcworst")     ; settings change (was cworst) -> the pair is stale
  (setarray rk_guiLast "emir" nil)
  (rk_guiEnable 'rk_geBCalibre nil)
  (rkGuiSubmit "emir"))

(defun rkGuiT_checkEmirLvsFail ()
  (let ((run (rk_guiReadRun (arrayref rk_guiRunDir "emir"))))
    (rkCheckEqual "emir auto LVS fail: run state" (rkGet run "state") "lvs_failed")
    (rkCheck "emir auto LVS fail: page status" (pcreMatchp "lvs_failed" (rkGuiGet 'rk_geStatus)))
    (rkCheck "emir auto LVS fail: extract line" (pcreMatchp "^LVS FAILED [(]EMIR run" (rkGuiGet 'rk_geXStatus)))
    (rkCheck "emir auto LVS fail: Calibre GUI button enabled" (get (rkGuiField 'rk_geBCalibre) 'enabled))
    (rkCheck "emir auto LVS fail: runset command" (pcreMatchp "-runset" (rkGet rk_guiExtract "calibre_gui_cmd")))
    (rkCheck "emir auto LVS fail: no RelStudio job" (null (rkGet run "jobs")))
    (rkGuiSet 'rk_geXCorner "cworst")
    t))

; drill-down: summary row -> device table window (headless) -> jump
(defun rkGuiT_drill ()
  (let (f st ok)
    (hiReportSelectItems (rkGuiField 'rk_gdRes) (list 0) nil)
    (setq f (rk_guiResOpenCB "deos"))
    (rkCheck "deos device table window built" (and f (arrayref rk_resForms f->hiFormSym)))
    (setq st (and f (arrayref rk_resForms f->hiFormSym)))
    (rkCheck "device table sorted by DPM, first row = I7.PIN5"
             (and st (equal (rkResultsCell (list (rkGet st "header") nil) (car (rkGet st "rows")) "_inst") "I7.PIN5")))
    (rkCheck "device table first row flagged fail"
             (and st (equal (rkResultsCell (list (rkGet st "header") nil) (car (rkGet st "rows")) "_sev") "fail")))
    (when f (hiFormCancel f))
    (setq f (rk_guiResOpenCB "aging"))
    (rkCheck "aging dfr0 table window built" (and f t))
    (when f (hiFormCancel f))
    (setq f (rk_guiResFullCB "emir"))
    (rkCheck "emir summary window built" (and f t))
    (when f (hiFormCancel f))
    ; jump to the worst DEOS device in the testbench schematic
    (rk_guiResJumpCB "deos")
    (setq ok (rkGet rk_resLast "ok"))
    (rkCheck "jump to I7.PIN5 resolved" (eq ok t))
    (rkCheck "jump window open" (rkResultsWindow))
    (rkResultsCloseWindow)
    t))

; ---------------------------------------------------------------------------
; Phase 4: Runs page
; ---------------------------------------------------------------------------

(defun rkGuiT_ids () (mapcar (lambda (ty) (rk_guiBase (arrayref rk_guiRunDir ty))) rk_guiTypes))
(defun rk_guiBase (p) (car (last (parseString p "/"))))

(defun rkGuiT_runsRefresh ()
  (setq rk_guiRunsRows nil)
  (rkGuiSet 'rk_grType "all")
  (rk_guiRunsRefreshCB)
  t)

(defun rkGuiT_runsIdx (id)
  (let ((i 0) hit)
    (foreach r rk_guiRunsRows
      (when (and (null hit) (equal (rkGet r "id") id)) (setq hit i))
      (setq i (add1 i)))
    hit))

(defun rkGuiT_checkRunsList ()
  (let ((ids (rkGuiT_ids)))
    (rkCheck "runs list holds the three runs" (forall id ids (rkGuiT_runsIdx id)))
    (rkCheckEqual "runs report rows" (length (get (rkGuiField 'rk_grList) 'choices)) (length rk_guiRunsRows))
    t))

(defun rkGuiT_select (ids)
  (hiReportDeselectAllItems (rkGuiField 'rk_grList) nil)
  (hiReportSelectItems (rkGuiField 'rk_grList) (mapcar 'rkGuiT_runsIdx ids) nil)
  (rk_guiRunsSel))

; note + compare (async)
(defun rkGuiT_runsActions ()
  (let ((ids (rkGuiT_ids)) sel)
    (setq sel (rkGuiT_select (list (nth 0 ids))))
    (rkCheckEqual "one run selected" (rkGet (car sel) "id") (nth 0 ids))
    (rkGuiSet 'rk_grNote "smoke note")
    (rkGuiSet 'rk_grTags "smoke,gui")
    (rk_guiRunsNoteCB)
    (setq sel (rkGuiT_select (list (nth 0 ids) (nth 1 ids))))
    (rkCheckEqual "two runs selected" (length sel) 2)
    (rk_guiRunsCompareCB)
    t))

(defun rkGuiT_checkNote ()
  (let ((r (nth (rkGuiT_runsIdx (car (rkGuiT_ids))) rk_guiRunsRows)))
    (rkCheckEqual "note listed" (rkGet r "note") "smoke note")
    (rkCheckEqual "tags listed" (rkGet r "tags") (list "smoke" "gui"))
    t))

; rerun: fill the panel from the DEOS run after scrambling the fields
(defun rkGuiT_rerun ()
  (rkGuiSet 'rk_gdTddb "")
  (rkGuiSet 'rk_gdStop "99n")
  (rkGuiSet 'rk_gdDonau "emir")
  (rk_guiCornerSetCB 'all)
  (putprop (get rk_guiForm 'rk_gTabs) 1 'value)
  (rkGuiT_select (list (nth 1 (rkGuiT_ids))))
  (setq rk_guiMsg "")
  (rk_guiRunsRerunCB)
  t)

(defun rkGuiT_checkRerun ()
  (rkCheck "rerun message" (pcreMatchp "^panel filled from .*_deos" rk_guiMsg))
  (rkCheckEqual "rerun: DEOS tab shown" (get (get rk_guiForm 'rk_gTabs) 'value) 2)
  (rkCheckEqual "rerun: stop time restored" (rkGuiGet 'rk_gdStop) "20n")
  (rkCheckEqual "rerun: tddb restored" (rkGuiGet 'rk_gdTddb) "125")
  (rkCheckEqual "rerun: Donau profile restored" (rkGuiGet 'rk_gdDonau) "std")
  (rkCheckEqual "rerun: corners restored"
                (sort (mapcar (lambda (c) (rkGet c "name")) (rk_guiSelectedCorners)) 'alphalessp)
                (sort (copy rkGuiT_corners) 'alphalessp))
  t)

; R1 buttons (rkAged may still be a stub: then "no aged corner created")
(defun rkGuiT_aged ()
  (rkGuiSet 'rk_gaStatus "")
  (rk_guiAgedCB)
  t)

(defun rkGuiT_checkAged ()
  (rkCheck "R1 aged-include ran and rkAged was called"
           (pcreMatchp "aged corner|created [0-9]+ corner|creating aged corners failed|not available"
                       (rkGuiGet 'rk_gaStatus)))
  t)

; SKILL review: JSON false must survive the IPC result for R1 -- rkIpc reads
; out.json with false -> nil, so rk_guiAgedDone re-reads it keeping false.
(defun rkGuiT_agedKeepFalse ()
  (let ((p (rkPathJoin rkGuiT_dir "aged_false_out.json")) (o (rkMakeObj)) res)
    (rkPut o "ok" t)
    (rkPut o "netlist_match" rkJsonFalse)
    (rkPut o "items" rkJsonEmptyArray)
    (rkPut o "run_id" "20261008-000000_aging")
    (rkJsonWrite o p)
    (setq res (rkJsonRead p))           ; what an rkIpcRun callback receives
    (rkPut res "_out" p)
    (rkCheck "IPC result reads netlist_match false as nil" (null (arrayref res "netlist_match")))
    (rk_guiAgedDone res)
    (rkCheck "R1: netlist mismatch reported, not 'not compared'"
             (exists m (rkAgedMessages) (pcreMatchp "netlist differs" m)))
    (rkCheck "R1: mismatch warning shown on the page" (pcreMatchp "netlist differs" (rkGuiGet 'rk_gaStatus)))
    (deleteFile p)
    t))

; SKILL review: a closed panel arms no new pollers; a replaced panel's late
; close callback does not stop the new panel; failed polls stop after a limit.
(defun rkGuiT_closedNoPollers ()
  (let ((n 0) (keep t))
    (rkCheck "closed flag set" rk_guiClosed)
    (rk_guiFollowRun "aging" (rkPathJoin rkGuiT_dir "no_such_run"))
    (rkCheck "closed panel: following a run starts no poller" (null (rkIpcPollActive "gui:")))
    (rkCheck "closed panel: run dir still recorded" (pcreMatchp "no_such_run$" (arrayref rk_guiRunDir "aging")))
    (while (and keep (lessp n 50))
      (setq keep (rk_guiPollFailed "gui:review"))
      (setq n (add1 n)))
    (rkCheckEqual "failed polls stop after rk_guiPollMaxFails" n rk_guiPollMaxFails)
    t))

; delete needs two clicks
(defun rkGuiT_delete ()
  (let ((id (car (rkGuiT_ids))))
    (rkGuiT_select (list id))
    (rk_guiRunsDeleteCB)
    (rkCheck "first delete click only arms" (pcreMatchp "again within" (rkGuiGet 'rk_grStatus)))
    (rk_guiRunsDeleteCB)
    t))

(defun rkGuiT_checkDeleted ()
  (rkCheck "record deleted" (not (isDir (arrayref rk_guiRunDir "aging"))))
  (rkCheck "deleted run no longer listed" (null (rkGuiT_runsIdx (car (rkGuiT_ids)))))
  t)

; ---------------------------------------------------------------------------
; Phase 5: reopen (lifecycle + resume), display check, cleanup
; ---------------------------------------------------------------------------

(defun rkGuiT_reopen ()
  (let ((old rk_guiForm) f)
    (setq f (rkGuiBuild rkGuiT_sess))
    (setq rkGuiT_forms (cons f rkGuiT_forms))
    (rkCheck "reopen: new form name" (nequal old->hiFormSym f->hiFormSym))
    (rk_guiClosedCB old->hiFormSym)     ; the replaced panel reporting its close late
    (rkCheck "reopen: stale close callback of the old panel ignored" (null rk_guiClosed))
    (rkCheck "reopen: DUT restored from the per-cell settings" (equal (rkGet rk_guiDut "inst") "I7"))
    (rkCheckEqual "reopen: DEOS settings restored" (rkGuiGet 'rk_gdTddb) "125")
    (rkCheckEqual "reopen: corners back to Maestro selection"
                  (length (rk_guiSelectedCorners))
                  (length (setof c (rkGet rk_guiCtx "corners") (eq (rkGet c "enabled") t))))
    t))

(defun rkGuiT_checkResume ()
  (rkCheck "reopen: DEOS page shows the last run" (pcreMatchp "^last run .*_deos: done" (rkGuiGet 'rk_gdStatus)))
  (rkCheck "reopen: DEOS results reloaded" (get (rkGuiField 'rk_gdRes) 'choices))
  (rkCheck "reopen: EMIR page shows the last (lvs_failed) run" (pcreMatchp "^last run .*_emir: lvs_failed" (rkGuiGet 'rk_geStatus)))
  (rkCheck "reopen: the LVS-failed EMIR run offers its Calibre runset" (get (rkGuiField 'rk_geBCalibre) 'enabled))
  (rkCheck "reopen: LVS failure on the extract line" (pcreMatchp "^LVS FAILED [(]EMIR run" (rkGuiGet 'rk_geXStatus)))
  t)

; display through a timer (the bridge must not wait on hiDisplayForm)
(defun rkGuiT_displayLater ()
  (setq rkGuiT_shown nil)
  (hiRegTimer "(progn (rkOpenPanel rkGuiT_sess) (setq rkGuiT_shown (hiIsFormDisplayed rk_guiForm)))" 2)
  t)

(defun rkGuiT_closeShown ()
  (rkCheck "panel displayed (timer)" rkGuiT_shown)
  (rkCheck "displayed panel is the live form" (hiIsFormDisplayed rk_guiForm))
  (rkGuiClose)
  (rkCheck "panel closed" (not (hiIsFormDisplayed rk_guiForm)))
  (rkCheck "no panel pollers after close" (null (rkIpcPollActive "gui:")))
  t)

(defun rkGuiT_cleanup ()
  (rkIpcPollStopAll "gui:")
  (rkGuiCloseProgress)
  (foreach f rkGuiT_forms (when (and f (hiIsFormDisplayed f)) (hiFormCancel f)))
  (rkResultsCloseWindow)
  (when rkGuiT_sess
    (rkCheck "session closed" (car (errset (maeCloseSession ?session rkGuiT_sess ?forceClose t) nil))))
  (setq rkGuiT_sess nil)
  (setq rkGuiSiteWorkarea nil)
  (rkIpcSetEnv nil)
  (setq rk_guiNoDisplay nil)
  (rkSiteLoad nil t)
  t)
