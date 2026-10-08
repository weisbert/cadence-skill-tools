; rkGui.il -- the relkit panel (plan section 3, 4.9; CONTRACT section 6).
;
; OWNER: SKILL panel & IPC agent.
;
; One modeless window: a fixed top bar (Test, design, RelStudio home, DUT,
; IP_Name, [Reload from Maestro]), the shared Corners table, and four tab pages
; Aging / DEOS / EMIR / Runs. Every Python call goes through rkIpc (async);
; long runs are followed by pollers that refresh the page status lines.
;
; Form lifecycle (eda-test-workarea memory feedback_skill_form_lifecycle):
; Pattern A -- every build gets a FRESH form name (rk_panel_<n>); callbacks
; reach the live form through the global rk_guiForm, never by name. A hidden
; panel is never re-displayed: rkOpenPanel raises a displayed panel, otherwise
; it builds a new one (re-reading Maestro). No ?closeCallback (invalid in
; IC6.1.8): the Close button / window-manager close land in the form's
; ?callback pair, which stops the panel's pollers (runs keep running: they are
; supervised by detached Python processes, and the next panel resumes them).
; ?dontBlock t: hiDisplayForm returns at once (else it blocks its caller).
;
; Public API:
;   rkOpenPanel([t_sess])  -> r_form   ; MyTool callback: raise if shown, else build + display
;   rkGuiBuild([t_sess] [t_test]) -> r_form ; build + instantiate + load, NOT displayed
;   rkGuiCurrentForm()     -> r_form / nil
;   rkGuiClose()           -> t        ; close the displayed panel (stops pollers)
;   rkGuiField(s_sym)      -> r_field  ; any panel field (top bar or tab page)
;   rkGuiGet(s_sym) / rkGuiSet(s_sym g_value) ; field value
;   rkGuiState()           -> o_table  ; session, test, dut, run dirs, last status per type
;   rkGuiSubmit(t_type)    -> t / nil  ; same as the page's [Submit] button
;   rkGuiRunCtx(t_type)    -> o_ctx    ; the ctx a submit of that type would send
;   rkGuiMessage()         -> t_msg    ; last panel status line
;   rkGuiSiteWorkarea      ; nil (default): the site is looked up from the real
;                          ; workarea; a directory: rkSiteLoad(dir) (tests)
;
; Field symbols (tests set them through rkGuiSet, then call the button
; callbacks rk_gui*CB directly -- see tests/rkGui_smoke.il):
;   top    rk_gTest rk_gDesign rk_gRsHome rk_gDut rk_gIp rk_gCornerShow rk_gCorners rk_gCornerInfo
;          rk_gTabs rk_gStatus
;   aging  rk_gaLife rk_gaUnit rk_gaStart rk_gaStop rk_gaEvalT rk_gaDonau rk_gaDonauInfo rk_gaStatus rk_gaRes
;   deos   rk_gdLife rk_gdUnit rk_gdStart rk_gdStop rk_gdSimT rk_gdTddb rk_gdDonau rk_gdDonauInfo rk_gdStatus rk_gdRes
;   emir   rk_geDut rk_geOwn rk_geAuto rk_geDspf rk_geGds rk_geLLib rk_geLView rk_geXCorner rk_geXTemp
;          rk_geXVariant rk_geXQrc rk_geXPower rk_geXGround rk_geXStatus rk_geDonau rk_geDonauInfo
;          rk_gePower rk_geGround rk_geRc rk_geEmT rk_geRunType rk_geSelfheat rk_geStart rk_geStop
;          rk_geStep rk_geLife rk_geLic rk_geLicH rk_geStatus rk_geRes
;   runs   rk_grType rk_grTest rk_grSince rk_grUntil rk_grAll rk_grList rk_grNote rk_grTags rk_grStatus rk_grCount
;
; Ref (IC6.1.8 PDFs, checked): skuiref.pdf hiCreateAppForm p.502 (?dontBlock,
;   ?buttonLayout 'Close -> ok callback; Cancel/WM close -> cancel callback),
;   hiCreateTabField p.654 (pages form->tab->pageN->field), hiCreateReportField
;   p.624 (?headers width 0 = hidden, ?doubleClickCB string, ?callback symbol gets
;   (fieldSym items)), hiReportGetSelectedItems p.798, hiCreateCyclicField,
;   hiCreateComboField, hiCreateStringField, hiCreateBooleanButton,
;   hiCreateFileSelectorField (?mode 'existingFile), hiCreateButton,
;   hiInstantiateForm, hiDisplayForm, hiIsFormDisplayed p.769, hiFormCancel,
;   hiRegTimer p.84, "Creating Context Menus for Fields" p.476-477 (field->hiContextMenu =
;   menu from hiCreateSimpleMenu p.206; every field type but cyclic/frame/separator),
;   hiCreateSimpleMenu. skdfref.pdf: ddGetObj, ddGetObjReadPath p.1781 (view dirs for the
;   DSPF/GDS freshness check). adexlSKILLref.pdf: none directly (rkMae does Maestro).
;
; SKILL rules (memory feedback_skill_gotchas): no let*, no prefix arithmetic,
; no defvar, identifiers [A-Za-z0-9_], no setq on slots (putprop / setarray),
; ~> only on db / form objects, no closures (SKILL lambdas are not lexical).

(unless (boundp 'rk_guiCounter)  (setq rk_guiCounter 0))
(unless (boundp 'rk_guiForm)     (setq rk_guiForm nil))
(unless (boundp 'rk_guiSess)     (setq rk_guiSess nil))
(unless (boundp 'rk_guiCtx)      (setq rk_guiCtx nil))
(unless (boundp 'rk_guiDut)      (setq rk_guiDut nil))
(unless (boundp 'rk_guiDuts)     (setq rk_guiDuts nil))
(unless (boundp 'rk_guiMsg)      (setq rk_guiMsg ""))
(unless (boundp 'rk_guiRunsRows) (setq rk_guiRunsRows nil))
(unless (boundp 'rk_guiDelArm)   (setq rk_guiDelArm nil))
; field sym -> page sym; boundp-guarded so reloading rkGui.il does not
; orphan the fields of a panel that is open (filled only by rk_gPut).
(unless (boundp 'rk_guiPageOf) (setq rk_guiPageOf (makeTable "rk_guiPageOf" nil)))
(setq rk_guiTypes (list "aging" "deos" "emir"))
(setq rk_guiPrefix (list (list "aging" "rk_ga") (list "deos" "rk_gd") (list "emir" "rk_ge")))
(setq rk_guiLicChoices (list "wait forever" "wait N hours" "fail"))
(setq rk_guiLicValues  (list "wait_forever" "wait_hours" "fail"))
(setq rk_guiFinal (list "done" "failed" "cancelled" "dry_run_done" "lvs_failed"))
; corners table filter (display only; Use toggles act on the full list)
(setq rk_guiShowChoices (list "All" "Selected only" "Unselected only"))
(setq rk_guiNoDut "(choose the DUT)")

(unless (boundp 'rk_guiRunDir)  (setq rk_guiRunDir  (makeTable "rk_guiRunDir" nil)))
(unless (boundp 'rk_guiLast)    (setq rk_guiLast    (makeTable "rk_guiLast" nil)))
(unless (boundp 'rk_guiResults) (setq rk_guiResults (makeTable "rk_guiResults" nil)))
(unless (boundp 'rk_guiPending) (setq rk_guiPending (makeTable "rk_guiPending" nil)))
(unless (boundp 'rk_guiExtract) (setq rk_guiExtract nil))
; last extract-resolve result (parameters derived from Virtuoso's environment)
(unless (boundp 'rk_guiResolve) (setq rk_guiResolve nil))
; out file of the newest extract-resolve call: older results arriving late are ignored
(unless (boundp 'rk_guiResolveOut) (setq rk_guiResolveOut nil))
; last extract-check result (are the DUT's DSPF/GDS fresh?) and its newest out file
(unless (boundp 'rk_guiFresh) (setq rk_guiFresh nil))
(unless (boundp 'rk_guiFreshOut) (setq rk_guiFreshOut nil))
; progress window (one at a time; poller "rkprog:progress", independent of the panel)
(unless (boundp 'rk_guiProgForm) (setq rk_guiProgForm nil))
(unless (boundp 'rk_guiProgCounter) (setq rk_guiProgCounter 0))
(unless (boundp 'rk_guiProgRun) (setq rk_guiProgRun nil))
(unless (boundp 'rk_guiProgRes) (setq rk_guiProgRes nil))
(unless (boundp 'rk_guiProgLogs) (setq rk_guiProgLogs nil))
(unless (boundp 'rk_guiProgFails) (setq rk_guiProgFails 0))
(setq rk_guiAuto "(auto)")
(unless (boundp 'rkGuiSiteWorkarea) (setq rkGuiSiteWorkarea nil))
; t once the current panel was closed: no new pollers (timers) are started for
; it, and runs submitted before the close are only recorded (the next panel
; resumes them).
(unless (boundp 'rk_guiClosed) (setq rk_guiClosed nil))
; consecutive failed status polls per poller name (rk_guiPollFailed)
(unless (boundp 'rk_guiPollFails) (setq rk_guiPollFails (makeTable "rk_guiPollFails" nil)))
(setq rk_guiPollMaxFails 20)

; ---------------------------------------------------------------------------
; Small helpers
; ---------------------------------------------------------------------------

(defun rkGuiCurrentForm () rk_guiForm)
(defun rkGuiMessage () rk_guiMsg)

(defun rk_guiTrim (s)
  (if (stringp s) (pcreReplace (pcreCompile "^\\s+|\\s+$") s "" 0) ""))

(defun rk_guiBlank (s) (equal (rk_guiTrim (or s "")) ""))

(defun rk_guiStr (v)
  (cond
    ((null v) "")
    ((stringp v) v)
    ((eq v t) "true")
    ((eq v rkJsonFalse) "false")
    ((integerp v) (sprintf nil "%d" v))
    ((floatp v) (sprintf nil "%g" v))
    ((symbolp v) (symbolToString v))
    (t (sprintf nil "%L" v))))

; "12" -> 12, "1.5" -> 1.5, else nil
(defun rk_guiNum (s)
  (setq s (rk_guiTrim (rk_guiStr s)))
  (cond
    ((pcreMatchp "^[-+]?[0-9]+$" s) (atoi s))
    ((pcreMatchp "^[-+]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?$" s) (atof s))
    (t nil)))

(defun rk_guiWords (s)
  (parseString (rk_guiTrim (or s "")) " ,;\t"))

; JSON arrays written by SKILL may be rkJsonEmptyArray (a symbol): treat as nil.
(defun rk_guiL (v) (if (listp v) v nil))

(defun rk_guiJoin (lst sep)
  (setq lst (rk_guiL lst))
  (if lst (buildString (mapcar 'rk_guiStr lst) sep) ""))

(defun rk_guiNth (lst i) (and (integerp i) (nth i lst)))

(defun rk_guiPrefixOf (type) (cadr (assoc type rk_guiPrefix)))

; field symbol of a run-type page: (rk_guiTF "aging" "Status") -> rk_gaStatus
(defun rk_guiTF (type name)
  (stringToSymbol (strcat (rk_guiPrefixOf type) name)))

(defun rk_guiIsFinal (state) (and (member state rk_guiFinal) t))

(defun rk_guiSay (msg)
  (setq rk_guiMsg msg)
  (printf "[relkit] %s\n" msg)
  (when rk_guiForm (rkGuiSet 'rk_gStatus msg))
  msg)

; ---------------------------------------------------------------------------
; Field access (form->tab->pageN->field for tab pages)
; ---------------------------------------------------------------------------

(defun rkGuiField (sym)
  (let ((page (arrayref rk_guiPageOf sym)) tab)
    (when rk_guiForm
      (cond
        (page
          (setq tab (get rk_guiForm 'rk_gTabs))
          (and tab (get (get tab page) sym)))
        (t (get rk_guiForm sym))))))

(defun rkGuiGet (sym)
  (let ((f (rkGuiField sym)))
    (and f (get f 'value))))

; Programmatic value writes run the field's callback synchronously (a cyclic
; field's ?callback fires on putprop 'value) -- verified on IC6.1.8: without
; this guard rk_guiShowDut -> putprop -> rk_guiDutCB -> rk_guiShowDut recursed
; until Virtuoso died. rk_guiMute is bound (dynamically) around every write;
; field callbacks return at once while it is set.
(unless (boundp 'rk_guiMute) (setq rk_guiMute nil))

(defun rkGuiSet (sym val)
  (let ((f (rkGuiField sym)) (rk_guiMute t))
    (when f (putprop f val 'value))
    val))

(defun rk_guiSetChoices (sym choices)
  (let ((f (rkGuiField sym)))
    (when f (putprop f choices 'choices))
    choices))

(defun rk_guiEnable (sym on)
  (let ((f (rkGuiField sym)))
    (when f (putprop f (and on t) 'enabled))
    on))

; Selected row indices of a report field (positions in its choices).
(defun rk_guiSelected (sym)
  (let ((f (rkGuiField sym)) r)
    (when f
      (setq r (errset (hiReportGetSelectedItems f) nil))
      (setq r (if r (car r) (get f 'value)))
      (setof x r (integerp x)))))

; Row data index (hidden first column) of the selected rows.
(defun rk_guiSelectedIdx (sym)
  (let ((f (rkGuiField sym)) rows)
    (when f
      (setq rows (get f 'choices))
      (mapcar (lambda (i) (atoi (car (nth i rows)))) (rk_guiSelected sym)))))

; ---------------------------------------------------------------------------
; Form construction helpers (2-D layout entries: (field (x y) (w h) promptW))
; ---------------------------------------------------------------------------

(unless (boundp 'rk_gEntries) (setq rk_gEntries nil))
(unless (boundp 'rk_gPage)    (setq rk_gPage nil))

(defun rk_gPut (fld sym x y w h pw)
  (setarray rk_guiPageOf sym rk_gPage)
  (setq rk_gEntries (cons (if pw (list fld (list x y) (list w h) pw)
                              (list fld (list x y) (list w h)))
                          rk_gEntries))
  fld)

(defun rk_gStr (sym prompt value x y w pw @optional ro)
  (rk_gPut (hiCreateStringField ?name sym ?prompt prompt ?value (rk_guiStr value)
                                ?editable (not ro))
           sym x y w 30 pw))

(defun rk_gBtn (sym text cb x y w)
  (rk_gPut (hiCreateButton ?name sym ?buttonText text ?callback cb) sym x y w 28 nil))

(defun rk_gCyc (sym prompt choices value cb x y w pw)
  (rk_gPut (hiCreateCyclicField ?name sym ?prompt prompt ?choices choices
                                ?value (or value (car choices)) ?callback (or cb ""))
           sym x y w 30 pw))

(defun rk_gCombo (sym prompt items value x y w pw)
  (rk_gPut (hiCreateComboField ?name sym ?prompt prompt ?items (mapcar 'rk_guiStr items)
                               ?value (rk_guiStr value))
           sym x y w 30 pw))

(defun rk_gBool (sym text value x y w)
  (rk_gPut (hiCreateBooleanButton ?name sym ?buttonText text ?value value
                                  ?buttonLocation 'left)
           sym x y w 30 nil))

(defun rk_gFile (sym prompt value x y w pw)
  (rk_gPut (hiCreateFileSelectorField ?name sym ?mode 'existingFile ?prompt prompt
                                      ?value (rk_guiStr value))
           sym x y w 30 pw))

(defun rk_gRep (sym headers x y w h mode dbl sel)
  (rk_gPut (if sel
             (hiCreateReportField ?name sym ?headers headers ?choices nil ?selectMode mode
                                  ?altRowHilight t ?doubleClickCB (or dbl "") ?callback sel)
             (hiCreateReportField ?name sym ?headers headers ?choices nil ?selectMode mode
                                  ?altRowHilight t ?doubleClickCB (or dbl "")))
           sym x y w h nil))

(defun rk_gTakeEntries ()
  (let ((e (reverse rk_gEntries)))
    (setq rk_gEntries nil)
    e))

; ---------------------------------------------------------------------------
; Defaults / saved settings
; ---------------------------------------------------------------------------

(defun rk_guiDef (type key @optional dflt)
  (let ((v (rkSiteGet (sprintf nil "defaults.%s.%s" type key))))
    (if (null v) dflt v)))

(defun rk_guiSite (key @optional dflt)
  (let ((v (rkSiteGet key)))
    (if (null v) dflt v)))

; ---------------------------------------------------------------------------
; Pages
; ---------------------------------------------------------------------------

(defun rk_guiResHeaders ()
  (list (list "_i" 0 'left 'string)
        (list "Corner" 150 'left 'string t)
        (list "Stress" 55 'left 'string t)
        (list "Pass" 50 'center 'string t)
        (list "Key metrics" 380 'left 'string)
        (list "Worst device" 200 'left 'string t)
        (list "Worst model" 110 'left 'string t)))

; Life time + unit + Start/Stop (aging and DEOS share the layout)
(defun rk_guiPageTimes (type y)
  (let ((p (rk_guiPrefixOf type)))
    (rk_gStr (stringToSymbol (strcat p "Life")) "Life time" (rk_guiStr (rk_guiDef type "life_time" "10")) 5 y 170 75)
    (rk_gCombo (stringToSymbol (strcat p "Unit")) "Unit" (list "years" "days" "hours")
               (rk_guiDef type "life_time_unit" "years") 180 y 150 40)
    (rk_gStr (stringToSymbol (strcat p "Start")) "Start" (rk_guiDef type "start_time" "0n") 340 y 160 45)
    (rk_gStr (stringToSymbol (strcat p "Stop")) "Stop" (rk_guiDef type "stop_time" "20n") 510 y 160 45)))

(defun rk_guiPageResults (type y h)
  (let ((p (rk_guiPrefixOf type)))
    (rk_gStr (stringToSymbol (strcat p "Status")) "Run" "" 5 y 965 45 t)
    (rk_gRep (stringToSymbol (strcat p "Res")) (rk_guiResHeaders) 5 (plus y 34) 965 h 'single
             (sprintf nil "(rk_guiResOpenCB %L)" type) nil)
    (rk_gBtn (stringToSymbol (strcat p "BOpen")) "Open device table" (sprintf nil "(rk_guiResOpenCB %L)" type)
             5 (plus y h 40) 160)
    (rk_gBtn (stringToSymbol (strcat p "BJump")) "Jump to worst device" (sprintf nil "(rk_guiResJumpCB %L)" type)
             170 (plus y h 40) 170)
    (rk_gBtn (stringToSymbol (strcat p "BFull")) "Summary window" (sprintf nil "(rk_guiResFullCB %L)" type)
             345 (plus y h 40) 150)))

(defun rk_guiRunButtons (type y)
  (let ((p (rk_guiPrefixOf type)))
    (rk_gBtn (stringToSymbol (strcat p "BSubmit")) (sprintf nil "Submit %s" (if (equal type "deos") "DEOS" (if (equal type "emir") "EMIR" "aging")))
             (sprintf nil "(rkGuiSubmit %L)" type) 5 y 140)
    (rk_gBtn (stringToSymbol (strcat p "BCancel")) "Cancel run" (sprintf nil "(rk_guiCancelRunCB %L)" type) 150 y 110)
    (rk_gBtn (stringToSymbol (strcat p "BOff")) "Official report" (sprintf nil "(rk_guiOfficialCB %L)" type) 265 y 130)
    (rk_gBtn (stringToSymbol (strcat p "BAux")) "Aux report" (sprintf nil "(rk_guiAuxCB %L)" type) 400 y 110)
    (rk_gBtn (stringToSymbol (strcat p "BProg")) "Progress..." (sprintf nil "(rk_guiPageProgressCB %L)" type) 515 y 95)))

; --- Donau profiles (site donau_profiles / donau_default; CONTRACT 1) -------

; profile name -> table of its cluster keys (site `cluster` merged under it)
(defun rk_guiDonauTable ()
  (let ((profs (rkSiteGet "donau_profiles")) (base (rkSiteGet "cluster")) out names)
    (setq out (makeTable "rk_guiDonau" nil))
    (when (tablep profs)
      (foreach k (rkKeys profs)
        (when (and (stringp k) (not (pcreMatchp "^_" k)) (tablep (arrayref profs k)))
          (setq names (cons k names)))))
    (foreach k (or names (list "default"))
      (let ((t2 (makeTable k nil)) (p (and (tablep profs) (arrayref profs k))))
        (when (tablep base) (foreach kk (rkKeys base) (setarray t2 kk (arrayref base kk))))
        (when (tablep p) (foreach kk (rkKeys p) (setarray t2 kk (arrayref p kk))))
        (setarray out k t2)))
    out))

(defun rk_guiDonauNames ()
  (sort (rkKeys (rk_guiDonauTable)) 'alphalessp))

(defun rk_guiDonauDefault (type)
  (let ((names (rk_guiDonauNames)) (d (rkSiteGet "donau_default")) want)
    (setq want (and (tablep d) (arrayref d type)))
    (cond
      ((member want names) want)
      ((member "default" names) "default")
      (t (car names)))))

(defun rk_guiDonauSummary (name)
  (let ((p (arrayref (rk_guiDonauTable) name)))
    (if (tablep p)
      (sprintf nil "Group %s, Queue %s, CPU %s, Memory %s, GPU %s%s"
               (rk_guiStr (arrayref p "Group")) (rk_guiStr (arrayref p "Queue"))
               (rk_guiStr (arrayref p "CPU")) (rk_guiStr (arrayref p "Memory"))
               (rk_guiStr (arrayref p "GPU"))
               (if (eq (arrayref p "Using_Cluster") rkJsonFalse) "  (cluster OFF: local run)" ""))
      (sprintf nil "(profile %s is not in the site config)" (rk_guiStr name)))))

(defun rk_guiDonauRow (type y)
  (let ((p (rk_guiPrefixOf type)) (names (rk_guiDonauNames)) dflt)
    (setq dflt (rk_guiDonauDefault type))
    (rk_gCyc (stringToSymbol (strcat p "Donau")) "Donau profile" names dflt
             (sprintf nil "(rk_guiDonauCB %L)" type) 5 y 270 100)
    (rk_gStr (stringToSymbol (strcat p "DonauInfo")) "" (rk_guiDonauSummary dflt) 280 y 690 0 t)))

(defun rk_guiDonauCB (type)
  (rkGuiSet (rk_guiTF type "DonauInfo") (rk_guiDonauSummary (rkGuiGet (rk_guiTF type "Donau"))))
  t)

(defun rk_guiBuildAging ()
  (setq rk_gPage 'page1)
  (rk_guiPageTimes "aging" 5)
  (rk_gStr 'rk_gaEvalT "Eval temperatures" (rk_guiJoin (rk_guiDef "aging" "eval_temperatures") " ")
           5 37 500 130)
  (rk_gPut (hiCreateLabel ?name 'rk_gaEvalHint ?labelText "(blank = each corner's own temperature)")
           'rk_gaEvalHint 515 42 330 24 nil)
  (rk_guiDonauRow "aging" 69)
  (rk_guiRunButtons "aging" 101)
  (rk_gBtn 'rk_gaBAged "Create aged corners (R1)" "(rk_guiAgedCB)" 615 101 180)
  (rk_gBtn 'rk_gaBDelta "Delta table (fresh/aged)" "(rk_guiDeltaCB)" 800 101 170)
  (rk_guiPageResults "aging" 135 330)
  (rk_gTakeEntries))

(defun rk_guiBuildDeos ()
  (setq rk_gPage 'page2)
  (rk_guiPageTimes "deos" 5)
  (rk_gStr 'rk_gdSimT "Simulation time" (rk_guiDef "deos" "simulation_time" "20n") 5 37 250 110)
  (rk_gStr 'rk_gdTddb "TDDB temperature" (rk_guiStr (rk_guiDef "deos" "tddb_temperature")) 265 37 250 120)
  (rk_gPut (hiCreateLabel ?name 'rk_gdTddbHint ?labelText "(blank = corner temperature)")
           'rk_gdTddbHint 525 42 250 24 nil)
  (rk_guiDonauRow "deos" 69)
  (rk_guiRunButtons "deos" 101)
  (rk_guiPageResults "deos" 135 330)
  (rk_gTakeEntries))

; RC corner names offered by the site (extract.corners, Quantus RuleSet names)
(defun rk_guiCornerNames ()
  (let ((names (mapcar (lambda (c) (if (tablep c) (rkGet c "name") (rk_guiStr c)))
                       (rk_guiL (rk_guiSite "extract.corners")))))
    (or (setof n names (stringp n)) (list "typical"))))

(defun rk_guiBuildEmir ()
  (let ((lic (rk_guiSite "emir.license_policy" "wait_forever")) licC corners corner)
    (setq licC (nth (or (rk_guiIndexOf lic rk_guiLicValues) 0) rk_guiLicChoices))
    (setq corners (rk_guiCornerNames))
    (setq corner (rk_guiStr (or (rk_guiSite "extract.technology_corner") (rk_guiSite "extract.default_corner"))))
    (unless (member corner corners) (setq corner (car corners)))
    (setq rk_gPage 'page3)
    (rk_gStr 'rk_geDut "DUT" "" 5 5 965 90 t)
    ; DSPF + GDS are made automatically (EMIR [Submit] extracts first when they
    ; are missing or stale); own files only behind the check box
    (rk_gPut (hiCreateBooleanButton ?name 'rk_geOwn ?buttonText "Use my own DSPF/GDS files"
                                    ?value nil ?buttonLocation 'left ?callback "(rk_guiOwnCB)")
             'rk_geOwn 5 37 230 30 nil)
    (rk_gStr 'rk_geAuto "" "auto: checking..." 240 37 580 0 t)
    (rk_gBtn 'rk_geBDetect "Use existing (detect)" "(rk_guiDetectCB)" 825 37 145)
    (rk_gFile 'rk_geDspf "DSPF" "" 5 69 480 45)
    (rk_gFile 'rk_geGds "GDS" "" 490 69 480 40)
    ; extraction: parameters come from Virtuoso's environment (extract-resolve);
    ; the user picks the variant / RC corner / QRC deck and the LVS supply names
    (rk_gStr 'rk_geLLib "Layout lib" "" 5 101 230 90)
    (rk_gStr 'rk_geLView "view" (rk_guiSite "extract.layout_view" "layout") 240 101 160 40)
    (rk_gCyc 'rk_geXCorner "RC corner" corners corner "(rk_guiXChoiceCB)" 405 101 250 85)
    (rk_gStr 'rk_geXTemp "Extract temp" (rk_guiStr (rk_guiSite "extract.temperature" 25)) 660 101 180 95)
    (rk_gCyc 'rk_geXVariant "LVS variant" (list rk_guiAuto) rk_guiAuto "(rk_guiXChoiceCB)" 5 133 230 90)
    (rk_gCyc 'rk_geXQrc "QRC deck" (list rk_guiAuto) rk_guiAuto "(rk_guiXChoiceCB)" 240 133 730 75)
    (rk_gStr 'rk_geXPower "LVS power" "" 5 165 480 90)
    (rk_gStr 'rk_geXGround "LVS ground" "" 490 165 480 85)
    (rk_gBtn 'rk_geBResolve "Resolve / preview" "(rk_guiResolveCB)" 5 197 140)
    (rk_gBtn 'rk_geBShowRes "Show resolved" "(rk_guiShowResolvedCB)" 150 197 120)
    (rk_gBtn 'rk_geBExtract "Extract only" "(rk_guiExtractCB)" 275 197 110)
    (rk_gBtn 'rk_geBXCancel "Cancel extract" "(rk_guiExtractCancelCB)" 390 197 115)
    (rk_gBtn 'rk_geBCalibre "Open Calibre GUI" "(rk_guiCalibreCB)" 510 197 130)
    (rk_gBtn 'rk_geBLvs "LVS report" "(rk_guiLvsReportCB)" 645 197 100)
    (rk_gStr 'rk_geXStatus "Extract" "" 5 229 965 90 t)
    ; EMIR run
    (rk_gStr 'rk_gePower "Power nets" "" 5 261 460 90)
    (rk_gStr 'rk_geGround "Ground" "" 470 261 300 55)
    (rk_gBtn 'rk_geBPorts "Fill from DUT ports" "(rk_guiSuppliesCB)" 775 261 180)
    (rk_gStr 'rk_geEmT "EM temp" (rk_guiStr (rk_guiDef "emir" "em_temperature" 110)) 5 293 160 70)
    (rk_gCombo 'rk_geRunType "Run_Type" (list "DYN SEM") (rk_guiDef "emir" "run_type" "DYN SEM") 170 293 210 70)
    (rk_gBool 'rk_geSelfheat "Self-heat" (and (rk_guiDef "emir" "selfheat") t) 390 293 110)
    (rk_gStr 'rk_geStart "Start" (rk_guiDef "emir" "start_time" "0n") 505 293 150 45)
    (rk_gStr 'rk_geStop "Stop" (rk_guiDef "emir" "stop_time" "20n") 660 293 145 45)
    (rk_gStr 'rk_geStep "Step" (rk_guiDef "emir" "dynamic_time_step" "20p") 810 293 145 45)
    (rk_gStr 'rk_geRc "Rc_Corner" (rk_guiStr (rk_guiSite "emir.rc_corner" "typical")) 5 325 230 90)
    (rk_gStr 'rk_geLife "Life" (rk_guiStr (rk_guiDef "emir" "life_time" "10")) 240 325 140 45)
    (rk_gCyc 'rk_geLic "License" rk_guiLicChoices licC "" 385 325 290 65)
    (rk_gStr 'rk_geLicH "N hours" (rk_guiStr (rk_guiSite "emir.license_wait_hours" 8)) 680 325 160 70)
    (rk_guiDonauRow "emir" 357)
    (rk_guiRunButtons "emir" 389)
    (rk_guiPageResults "emir" 423 70)
    (rk_gTakeEntries)))

(defun rk_guiBuildRuns ()
  (setq rk_gPage 'page4)
  (rk_gCyc 'rk_grType "Type" (list "all" "aging" "deos" "emir") "all" "" 5 5 160 40)
  (rk_gStr 'rk_grTest "Test" "" 170 5 190 40)
  (rk_gStr 'rk_grSince "Since" "" 365 5 160 45)
  (rk_gStr 'rk_grUntil "Until" "" 530 5 160 45)
  (rk_gBool 'rk_grAll "All cells" nil 695 5 100)
  (rk_gBtn 'rk_grBRefresh "Refresh" "(rk_guiRunsRefreshCB)" 845 5 120)
  (rk_gRep 'rk_grList
           (list (list "_i" 0 'left 'string)
                 (list "Run id" 175 'left 'string t)
                 (list "Type" 50 'left 'string t)
                 (list "Test" 80 'left 'string t)
                 (list "DUT" 90 'left 'string t)
                 (list "Corners" 55 'right 'string t)
                 (list "Life" 60 'left 'string t)
                 (list "State" 105 'left 'string t)
                 (list "Pass" 45 'center 'string t)
                 (list "Key metric" 135 'left 'string)
                 (list "Note" 120 'left 'string)
                 (list "Tags" 80 'left 'string)
                 (list "Raw data" 65 'left 'string t))
           5 37 965 300 'multiple "(rk_guiRunsResultsCB)" 'rk_guiRunsSelCB)
  (rk_gBtn 'rk_grBResults "Show results" "(rk_guiRunsResultsCB)" 5 343 120)
  (rk_gBtn 'rk_grBOff "Official report" "(rk_guiRunsOfficialCB)" 130 343 125)
  (rk_gBtn 'rk_grBAux "Aux report" "(rk_guiRunsAuxCB)" 260 343 100)
  (rk_gBtn 'rk_grBWork "Open Work_Dir" "(rk_guiRunsWorkDirCB)" 365 343 120)
  (rk_gBtn 'rk_grBRs "RelStudio GUI" "(rk_guiRelstudioCB)" 490 343 120)
  (rk_gBtn 'rk_grBStatus "Refresh status" "(rk_guiRunsStatusCB)" 615 343 120)
  (rk_gStr 'rk_grCount "" "" 740 343 230 0 t)
  (rk_gBtn 'rk_grBRerun "Rerun with these settings" "(rk_guiRunsRerunCB)" 5 375 190)
  (rk_gBtn 'rk_grBCompare "Compare two" "(rk_guiRunsCompareCB)" 200 375 120)
  (rk_gBtn 'rk_grBCancel "Cancel run" "(rk_guiRunsCancelCB)" 325 375 110)
  (rk_gBtn 'rk_grBDelete "Delete record" "(rk_guiRunsDeleteCB)" 440 375 120)
  (rk_gBtn 'rk_grBProg "Progress..." "(rk_guiCtxMenuCB \"runs\" \"progress\")" 565 375 100)
  (rk_gPut (hiCreateLabel ?name 'rk_grHint ?labelText "(click a run, then right-click: progress, log, ...)")
           'rk_grHint 670 380 290 24 nil)
  (rk_gStr 'rk_grNote "Note" "" 5 407 600 45)
  (rk_gStr 'rk_grTags "Tags" "" 610 407 240 45)
  (rk_gBtn 'rk_grBNote "Save note" "(rk_guiRunsNoteCB)" 855 407 110)
  (rk_gStr 'rk_grStatus "Runs" "" 5 441 965 45 t)
  (rk_gTakeEntries))

(defun rk_guiIndexOf (x lst)
  (let ((i 0) hit)
    (foreach e lst
      (when (and (null hit) (equal e x)) (setq hit i))
      (setq i (add1 i)))
    hit))

; ---------------------------------------------------------------------------
; Build / open / close
; ---------------------------------------------------------------------------

(defun rkGuiBuild (@optional sess test)
  (let (nm top tab form p1 p2 p3 p4)
    ; every build re-reads the site file (site edits apply on reopen);
    ; rkGuiSiteWorkarea (tests) makes it read <that dir>/.relkit_site.json
    (rkSiteLoad rkGuiSiteWorkarea t)
    (setq rk_guiCounter (add1 rk_guiCounter))
    (setq nm (stringToSymbol (sprintf nil "rk_panel_%d" rk_guiCounter)))
    (rkIpcPollStopAll "gui:")
    ; Pattern A: a rebuild closes the previous panel (different form name)
    (when (and rk_guiForm (hiIsFormDisplayed rk_guiForm)) (hiFormCancel rk_guiForm))
    (setq rk_gEntries nil)
    (setq rk_gPage nil)
    (rk_gCyc 'rk_gTest "Test" (list "-") "-" "(rk_guiTestCB)" 5 5 300 60)
    (rk_gStr 'rk_gDesign "Design" "" 310 5 480 60 t)
    (rk_gBtn 'rk_gBReload "Reload from Maestro" "(rk_guiReloadCB)" 800 5 170)
    (rk_gStr 'rk_gRsHome "RelStudio" "" 5 37 600 80 t)
    (rk_gStr 'rk_gIp "IP_Name" "" 615 37 355 70)
    ; the button first: a cyclic field grows to its longest choice (long DUT
    ; labels pushed it over a button placed to its right)
    (rk_gBtn 'rk_gBPick "Pick from schematic" "(rk_guiPickDutCB)" 5 69 160)
    (rk_gCyc 'rk_gDut "DUT" (list rk_guiNoDut) rk_guiNoDut "(rk_guiDutCB)" 175 69 795 40)
    ; corners: filter + count + selection buttons ABOVE the table
    (rk_gCyc 'rk_gCornerShow "Corners" rk_guiShowChoices (car rk_guiShowChoices) "(rk_guiCornerShowCB)"
             5 101 230 60)
    (rk_gStr 'rk_gCornerInfo "" "" 240 101 280 0 t)
    (rk_gBtn 'rk_gBToggle "Toggle Use" "(rk_guiCornerToggleCB)" 525 101 110)
    (rk_gBtn 'rk_gBAll "All" "(rk_guiCornerSetCB 'all)" 640 101 60)
    (rk_gBtn 'rk_gBNone "None" "(rk_guiCornerSetCB 'none)" 705 101 60)
    (rk_gBtn 'rk_gBMae "As in Maestro" "(rk_guiCornerSetCB 'maestro)" 770 101 120)
    (rk_gRep 'rk_gCorners
             (list (list "_i" 0 'left 'string)
                   (list "Use" 40 'center 'string)
                   (list "Corner" 170 'left 'string t)
                   (list "Sections" 260 'left 'string)
                   (list "Temp" 55 'right 'string)
                   (list "Overrides" 300 'left 'string)
                   (list "Maestro" 65 'center 'string))
             5 133 965 118 'extended "(rk_guiCornerToggleCB)" nil)
    (setq top (rk_gTakeEntries))
    (setq p1 (rk_guiBuildAging))
    (setq p2 (rk_guiBuildDeos))
    (setq p3 (rk_guiBuildEmir))
    (setq p4 (rk_guiBuildRuns))
    (setq rk_gPage nil)
    (setq tab (hiCreateTabField ?name 'rk_gTabs ?tabs (list "Aging" "DEOS" "EMIR" "Runs")
                                ?tabPlacement 'top ?fields (list p1 p2 p3 p4)))
    (setarray rk_guiPageOf 'rk_gTabs nil)
    (rk_gStr 'rk_gStatus "Status" "" 5 860 990 55 t)   ; 995 wide: the tab's right border stays inside the window
    (setq top (append top (cons (list tab (list 5 258) (list 975 597)) (rk_gTakeEntries))))
    (setq form (hiCreateAppForm
                 ?name nm
                 ?formTitle (sprintf nil "RelStudio (relkit %s)" rk_version)
                 ?fields top
                 ?callback (list (sprintf nil "(rk_guiClosedCB '%s)" (symbolToString nm))
                                 (sprintf nil "(rk_guiClosedCB '%s)" (symbolToString nm)))
                 ?buttonLayout 'Close
                 ?dialogStyle 'modeless
                 ?dontBlock t
                 ?initialSize (list 1010 935)))
    (hiInstantiateForm form)
    (setq rk_guiForm form)
    (setq rk_guiClosed nil)
    (setq rk_guiPollFails (makeTable "rk_guiPollFails" nil))
    (setq rk_guiSess nil)
    (setq rk_guiCtx nil)
    (setq rk_guiDut nil)
    (setq rk_guiDuts nil)
    (setq rk_guiRunsRows nil)
    (setq rk_guiExtract nil)
    (setq rk_guiResolve nil)
    (setq rk_guiRunDir  (makeTable "rk_guiRunDir" nil))
    (setq rk_guiLast    (makeTable "rk_guiLast" nil))
    (setq rk_guiResults (makeTable "rk_guiResults" nil))
    (setq rk_guiPending (makeTable "rk_guiPending" nil))
    (setq rk_guiFresh nil)
    (rk_guiEnable 'rk_geBCalibre nil)
    (rk_guiAttachMenus)
    (rk_guiLoad sess test t)
    (rk_guiOwnCB)
    form))

(defun rkOpenPanel (@optional sess)
  (cond
    ((and rk_guiForm (hiIsFormDisplayed rk_guiForm))
      (hiDisplayForm rk_guiForm)          ; already shown: raise it
      rk_guiForm)
    (t
      (rkGuiBuild sess)
      (hiDisplayForm rk_guiForm)
      rk_guiForm)))

; formSym: the closed panel's form name. Only the CURRENT panel's close counts:
; the close of a panel replaced by a rebuild must not stop the new one's pollers.
(defun rk_guiClosedCB (@optional formSym)
  (when (or (null formSym) (null rk_guiForm) (eq formSym rk_guiForm->hiFormSym))
    (setq rk_guiClosed t)
    (rkIpcPollStopAll "gui:"))
  t)

(defun rkGuiClose ()
  (setq rk_guiClosed t)
  (rkIpcPollStopAll "gui:")
  (when (and rk_guiForm (hiIsFormDisplayed rk_guiForm))
    (hiFormCancel rk_guiForm))
  t)

(defun rkGuiState ()
  (let ((o (rkMakeObj)))
    (rkPut o "session" rk_guiSess)
    (rkPut o "test" (and rk_guiCtx (rkGet rk_guiCtx "test")))
    (rkPut o "dut" rk_guiDut)
    (rkPut o "run_dirs" rk_guiRunDir)
    (rkPut o "last" rk_guiLast)
    (rkPut o "results" rk_guiResults)
    (rkPut o "extract" rk_guiExtract)
    (rkPut o "resolve" rk_guiResolve)
    (rkPut o "runs" rk_guiRunsRows)
    (rkPut o "pollers" (rkIpcPollActive "gui:"))
    (rkPut o "message" rk_guiMsg)
    o))

; ---------------------------------------------------------------------------
; Context: Maestro, DUT, corners, saved settings
; ---------------------------------------------------------------------------

; (Re)read Maestro. first = also apply saved settings and resume runs.
(defun rk_guiLoad (sess test first)
  (let (r ctx tests design saved d)
    (unless sess (setq sess (or rk_guiSess (rkMaeCurrentSession))))
    (setq rk_guiSess sess)
    (rkGuiSet 'rk_gRsHome (or (rkRelstudioHome) "(not set: $RELSTUDIO_HOME and site relstudio_home are empty)"))
    (cond
      ((null sess)
        (rk_guiSay "No Maestro session found: open the panel from a Maestro window (MyTool > RelStudio...)."))
      (t
        (setq r (errset (rkMaeGetContext sess test) t))
        (cond
          ((null r) (rk_guiSay (sprintf nil "Reading Maestro failed: %s" (rk_guiErrText errset.errset))))
          (t
            (setq ctx (car r))
            (setq rk_guiCtx ctx)
            (setq tests (rk_guiL (rkGet ctx "tests")))
            (rk_guiSetChoices 'rk_gTest (or tests (list "-")))
            (rkGuiSet 'rk_gTest (rkGet ctx "test"))
            (setq design (rkGet ctx "design"))
            (rkGuiSet 'rk_gDesign
                      (sprintf nil "%s/%s/%s%s" (rkGet design "lib" "?") (rkGet design "cell" "?")
                               (rkGet design "view" "?")
                               (if (eq (rkGet design "is_config") t)
                                 (sprintf nil "  (config; top %s/%s/%s)" (rkGet design "top.lib" "?")
                                          (rkGet design "top.cell" "?") (rkGet design "top.view" "?"))
                                 "")))
            (when (rk_guiBlank (rkGuiGet 'rk_gIp)) (rkGuiSet 'rk_gIp (rkGet ctx "ip_name" "")))
            (when (rk_guiBlank (rkGuiGet 'rk_geLLib)) (rkGuiSet 'rk_geLLib (rkGet ctx "maestro.lib" "")))
            (rk_guiLoadDuts)
            (rk_guiCornersFromCtx)
            (when first
              (setq saved (car (errset (rkMaeReadSettings ctx) nil)))
              (when saved (rk_guiApplySaved saved)))
            (when (and rk_guiDut (null (rk_guiDutIndex (rkGet rk_guiDut "inst"))))
              (setq rk_guiDut nil))
            (rk_guiShowDut)
            (rk_guiSay (sprintf nil "Maestro %s/%s/%s, test %s: %d corners (%d enabled)%s"
                                (rkGet ctx "maestro.lib" "?") (rkGet ctx "maestro.cell" "?")
                                (rkGet ctx "maestro.view" "?") (rkGet ctx "test")
                                (length (rk_guiL (rkGet ctx "corners")))
                                (length (setof c (rk_guiL (rkGet ctx "corners")) (eq (rkGet c "enabled") t)))
                                (if (rk_guiL (rkGet ctx "warnings"))
                                  (strcat "; warnings: " (rk_guiJoin (rk_guiL (rkGet ctx "warnings")) "; "))
                                  "")))
            (when first (rk_guiRunsRefresh t))
            (rk_guiResolveExtract)))))
    rk_guiCtx))

(defun rk_guiReloadCB ()
  (rk_guiLoad rk_guiSess (and rk_guiCtx (rkGet rk_guiCtx "test")) nil))

(defun rk_guiTestCB ()
  (let ((t2 (rkGuiGet 'rk_gTest)))
    (when (and (not rk_guiMute) rk_guiCtx (stringp t2) (nequal t2 (rkGet rk_guiCtx "test")))
      (rk_guiLoad rk_guiSess t2 nil))))

; --- DUT -------------------------------------------------------------------

(defun rk_guiDutLabel (d)
  (sprintf nil "%s  ->  %s/%s (%s)" (rkGet d "inst" "?") (rkGet d "lib" "?") (rkGet d "cell" "?")
           (rkGet d "view" "schematic")))

(defun rk_guiDutIndex (inst)
  (let ((i 0) hit)
    (foreach d rk_guiDuts
      (when (and (null hit) (equal (rkGet d "inst") inst)) (setq hit i))
      (setq i (add1 i)))
    hit))

(defun rk_guiLoadDuts ()
  (let (design r)
    (setq design (rkGet rk_guiCtx "design"))
    (setq r (errset (rkResultsListTopInstances (rkGet design "lib") (rkGet design "cell")
                                               (rkGet design "view"))
                    nil))
    (setq rk_guiDuts (and r (car r)))
    (unless r (rk_guiSay "Could not list the testbench instances (DUT drop-down is empty)."))
    rk_guiDuts))

(defun rk_guiShowDut ()
  (let ((choices (cons rk_guiNoDut (mapcar 'rk_guiDutLabel rk_guiDuts))) i)
    (rk_guiSetChoices 'rk_gDut choices)
    (setq i (and rk_guiDut (rk_guiDutIndex (rkGet rk_guiDut "inst"))))
    (rkGuiSet 'rk_gDut (if i (nth (add1 i) choices) rk_guiNoDut))
    (rkGuiSet 'rk_geDut
              (if rk_guiDut
                (sprintf nil "Sim_Cell %s, Instance_Name %s  (%s/%s)" (rkGet rk_guiDut "cell")
                         (rkGet rk_guiDut "inst") (rkGet rk_guiDut "lib") (rkGet rk_guiDut "view" "schematic"))
                "(choose the DUT in the top bar)"))
    rk_guiDut))

; dut: table {inst lib cell view terms} (rkResults / settings) or nil
(defun rk_guiSetDut (dut @optional quiet)
  (let (i)
    (cond
      ((null dut) (setq rk_guiDut nil))
      (t
        (setq i (rk_guiDutIndex (rkGet dut "inst")))
        ; the full candidate entry has the exact config-bound view and terms
        (setq rk_guiDut (if i (nth i rk_guiDuts) dut))
        (unless i (setq rk_guiDuts (append rk_guiDuts (list dut))))))
    (rk_guiShowDut)
    (unless quiet
      (when rk_guiDut
        (rk_guiSaveSettings)
        (rk_guiSay (sprintf nil "DUT: %s" (rk_guiDutLabel rk_guiDut))))
      (rk_guiResolveExtract))
    rk_guiDut))

(defun rk_guiDutCB ()
  (let ((v (rkGuiGet 'rk_gDut)) i)
    (unless rk_guiMute
      (setq i (rk_guiIndexOf v (mapcar 'rk_guiDutLabel rk_guiDuts)))
      (rk_guiSetDut (and i (nth i rk_guiDuts))))))

(defun rk_guiPickDutCB ()
  (cond
    ((null rk_guiCtx) (rk_guiSay "No Maestro context."))
    (t
      (rk_guiSay "Click the DUT instance in the testbench schematic...")
      (rkResultsPickDut rk_guiCtx 'rk_guiDutPicked))))

(defun rk_guiDutPicked (dut)
  (cond
    (dut (rk_guiSetDut dut))
    (t (rk_guiSay "DUT pick cancelled or no instance there.")))
  t)

; --- corners -----------------------------------------------------------------

(defun rk_guiCornerRow (c i)
  (list (sprintf nil "%d" i)
        (if (eq (rkGet c "selected") t) "x" "")
        (rkGet c "name" "?")
        (rk_guiJoin (mapcar (lambda (s) (rkGet s "section" "")) (rk_guiL (rkGet c "sections"))) ",")
        (rk_guiStr (rkGet c "temperature"))
        (rk_guiJoin (mapcar (lambda (k) (sprintf nil "%s=%s" k (rk_guiStr (arrayref (rkGet c "vars") k))))
                            (if (tablep (rkGet c "vars")) (rkKeys (rkGet c "vars")) nil))
                    " ")
        (if (eq (rkGet c "enabled") t) "on" "off")))

; Show filter (rk_gCornerShow): "All" / "Selected only" / "Unselected only".
(defun rk_guiCornerShown (c)
  (let ((how (or (rkGuiGet 'rk_gCornerShow) "All")))
    (cond
      ((equal how "Selected only") (eq (rkGet c "selected") t))
      ((equal how "Unselected only") (not (eq (rkGet c "selected") t)))
      (t t))))

; Rebuild the table. Each row's hidden first column is the corner's index in
; the FULL list, so Use toggles on a filtered view hit the right corners;
; keepSel re-selects the same corners (by index) that are still shown.
(defun rk_guiShowCorners (@optional keepSel)
  (let ((i 0) rows selIdx pos n shown (corners (and rk_guiCtx (rk_guiL (rkGet rk_guiCtx "corners")))))
    (setq selIdx (and keepSel (rk_guiSelectedIdx 'rk_gCorners)))
    (foreach c corners
      (when (rk_guiCornerShown c)
        (setq rows (cons (rk_guiCornerRow c i) rows)))
      (setq i (add1 i)))
    (setq rows (reverse rows))
    (rk_guiSetChoices 'rk_gCorners rows)
    (when selIdx
      (setq i 0)
      (foreach r rows
        (when (member (atoi (car r)) selIdx) (setq pos (cons i pos)))
        (setq i (add1 i)))
      (when pos (errset (hiReportSelectItems (rkGuiField 'rk_gCorners) (reverse pos) nil) nil)))
    (setq n (length (setof c corners (eq (rkGet c "selected") t))))
    (setq shown (length rows))
    (rkGuiSet 'rk_gCornerInfo (sprintf nil "%d of %d selected%s" n (length corners)
                                       (if (equal shown (length corners)) ""
                                         (sprintf nil " (showing %d)" shown))))
    n))

(defun rk_guiCornerShowCB ()
  (unless rk_guiMute
    (rk_guiShowCorners t)
    (rk_guiSaveSettings))
  t)

(defun rk_guiCornersFromCtx ()
  (foreach c (rk_guiL (rkGet rk_guiCtx "corners"))
    (rkPut c "selected" (rkJsonBool (eq (rkGet c "enabled") t))))
  (rk_guiShowCorners))

(defun rk_guiCornerToggleCB ()
  (let ((corners (and rk_guiCtx (rk_guiL (rkGet rk_guiCtx "corners")))) c)
    (foreach i (rk_guiSelectedIdx 'rk_gCorners)
      (setq c (nth i corners))
      (when c (rkPut c "selected" (rkJsonBool (not (eq (rkGet c "selected") t))))))
    (rk_guiShowCorners t)))

(defun rk_guiCornerSetCB (how)
  (foreach c (and rk_guiCtx (rk_guiL (rkGet rk_guiCtx "corners")))
    (rkPut c "selected"
           (rkJsonBool (cond ((eq how 'all) t) ((eq how 'none) nil) (t (eq (rkGet c "enabled") t))))))
  (rk_guiShowCorners))

; select exactly the named corners -> list of names not found
(defun rk_guiSelectCorners (names)
  (let (missing (all (mapcar (lambda (c) (rkGet c "name")) (rk_guiL (rkGet rk_guiCtx "corners")))))
    (foreach c (rk_guiL (rkGet rk_guiCtx "corners"))
      (rkPut c "selected" (rkJsonBool (member (rkGet c "name") names))))
    (foreach n names (unless (member n all) (setq missing (cons n missing))))
    (rk_guiShowCorners)
    (reverse missing)))

(defun rk_guiSelectedCorners ()
  (setof c (and rk_guiCtx (rk_guiL (rkGet rk_guiCtx "corners"))) (eq (rkGet c "selected") t)))

; ---------------------------------------------------------------------------
; Page settings <-> fields
; ---------------------------------------------------------------------------

(defun rk_guiSupplies (powerStr groundStr)
  (let ((sup (rkMakeObj)) (pw (rkMakeObj)) (gd (rkMakeObj)) kv)
    (foreach w (rk_guiWords powerStr)
      (setq kv (parseString w "="))
      (rkPut pw (car kv) (or (cadr kv) nil)))
    (foreach w (rk_guiWords groundStr)
      (setq kv (parseString w "="))
      (rkPut gd (car kv) (or (cadr kv) "0")))
    (rkPut sup "power" pw)
    (rkPut sup "ground" gd)
    sup))

(defun rk_guiSuppliesText (tbl)
  (if (tablep tbl)
    (rk_guiJoin (mapcar (lambda (k) (let ((v (arrayref tbl k)))
                                      (if v (sprintf nil "%s=%s" k (rk_guiStr v)) k)))
                        (rkKeys tbl))
                " ")
    ""))

(defun rk_guiLicPolicy ()
  (or (nth (or (rk_guiIndexOf (rkGuiGet 'rk_geLic) rk_guiLicChoices) 0) rk_guiLicValues) "wait_forever"))

(defun rk_guiNullIfBlank (s) (if (rk_guiBlank s) nil (rk_guiTrim s)))

; Settings of one page (CONTRACT 2.4) as a table; blank = null = default.
(defun rk_guiPageSettings (type)
  (let ((s (rkMakeObj)) evalT)
    (cond
      ((equal type "aging")
        (rkPut s "life_time" (rk_guiNullIfBlank (rkGuiGet 'rk_gaLife)))
        (rkPut s "life_time_unit" (rk_guiNullIfBlank (rkGuiGet 'rk_gaUnit)))
        (rkPut s "start_time" (rk_guiNullIfBlank (rkGuiGet 'rk_gaStart)))
        (rkPut s "stop_time" (rk_guiNullIfBlank (rkGuiGet 'rk_gaStop)))
        (setq evalT (rk_guiWords (rkGuiGet 'rk_gaEvalT)))
        (rkPut s "eval_temperatures" evalT)
        (rkPut s "donau_profile" (rkGuiGet 'rk_gaDonau)))
      ((equal type "deos")
        (rkPut s "life_time" (rk_guiNullIfBlank (rkGuiGet 'rk_gdLife)))
        (rkPut s "life_time_unit" (rk_guiNullIfBlank (rkGuiGet 'rk_gdUnit)))
        (rkPut s "start_time" (rk_guiNullIfBlank (rkGuiGet 'rk_gdStart)))
        (rkPut s "stop_time" (rk_guiNullIfBlank (rkGuiGet 'rk_gdStop)))
        (rkPut s "simulation_time" (rk_guiNullIfBlank (rkGuiGet 'rk_gdSimT)))
        (rkPut s "tddb_temperature" (rk_guiNum (rkGuiGet 'rk_gdTddb)))
        (rkPut s "donau_profile" (rkGuiGet 'rk_gdDonau)))
      ((equal type "emir")
        (rkPut s "run_type" (rk_guiNullIfBlank (rkGuiGet 'rk_geRunType)))
        (rkPut s "selfheat" (rkJsonBool (rkGuiGet 'rk_geSelfheat)))
        (rkPut s "em_temperature" (rk_guiNum (rkGuiGet 'rk_geEmT)))
        (rkPut s "rc_corner" (rk_guiNullIfBlank (rkGuiGet 'rk_geRc)))
        (rkPut s "start_time" (rk_guiNullIfBlank (rkGuiGet 'rk_geStart)))
        (rkPut s "stop_time" (rk_guiNullIfBlank (rkGuiGet 'rk_geStop)))
        (rkPut s "dynamic_time_step" (rk_guiNullIfBlank (rkGuiGet 'rk_geStep)))
        (rkPut s "life_time" (rk_guiNullIfBlank (rkGuiGet 'rk_geLife)))
        ; auto (default): relkit extracts / reuses <artifact_root>/<DUT>/<DUT>.dspf/.gds
        (rkPut s "auto_extract" (rkJsonBool (not (rkGuiGet 'rk_geOwn))))
        (rkPut s "dspf_file" (and (rkGuiGet 'rk_geOwn) (rk_guiNullIfBlank (rkGuiGet 'rk_geDspf))))
        (rkPut s "gds_file" (and (rkGuiGet 'rk_geOwn) (rk_guiNullIfBlank (rkGuiGet 'rk_geGds))))
        (rkPut s "donau_profile" (rkGuiGet 'rk_geDonau))
        (rkPut s "layout_lib" (rk_guiNullIfBlank (rkGuiGet 'rk_geLLib)))
        (rkPut s "layout_view" (rk_guiNullIfBlank (rkGuiGet 'rk_geLView)))
        (rkPut s "supplies" (rk_guiSupplies (rkGuiGet 'rk_gePower) (rkGuiGet 'rk_geGround)))
        (rkPut s "license_policy" (rk_guiLicPolicy))
        (rkPut s "license_wait_hours" (rk_guiNum (rkGuiGet 'rk_geLicH))))
      ((equal type "extract")
        (rkPut s "layout_lib" (rk_guiNullIfBlank (rkGuiGet 'rk_geLLib)))
        (rkPut s "layout_view" (rk_guiNullIfBlank (rkGuiGet 'rk_geLView)))
        (rkPut s "technology_corner" (rk_guiNullIfBlank (rkGuiGet 'rk_geXCorner)))
        (rkPut s "temperature" (rk_guiNum (rkGuiGet 'rk_geXTemp)))
        (rkPut s "lvs_variant" (rk_guiChoiceOrNil (rkGuiGet 'rk_geXVariant)))
        (rkPut s "qrc_deck" (rk_guiQrcPath (rkGuiGet 'rk_geXQrc)))
        (rkPut s "power_names" (rk_guiWords (rkGuiGet 'rk_geXPower)))
        (rkPut s "ground_names" (rk_guiWords (rkGuiGet 'rk_geXGround)))
        ; view directories for the freshness check (else Python reads cds.lib)
        (when rk_guiDut
          (rkPut s "layout_dir" (rk_guiViewDir (or (rk_guiNullIfBlank (rkGuiGet 'rk_geLLib))
                                                   (rkGet rk_guiDut "lib"))
                                               (rkGet rk_guiDut "cell")
                                               (or (rk_guiNullIfBlank (rkGuiGet 'rk_geLView)) "layout")))
          (rkPut s "schematic_dir" (rk_guiViewDir (or (rk_guiNullIfBlank (rkGuiGet 'rk_geLLib))
                                                      (rkGet rk_guiDut "lib"))
                                                  (rkGet rk_guiDut "cell")
                                                  (rk_guiSite "extract.source_view" "schematic"))))))
    s))

; Directory of a cellview on disk (ddGetObj + ddGetObjReadPath), or nil.
(defun rk_guiViewDir (lib cell view)
  (let (o r)
    (when (and (stringp lib) (stringp cell) (stringp view))
      (setq r (errset (ddGetObj lib cell view) nil))
      (setq o (and r (car r)))
      (and o (car (errset (ddGetObjReadPath o) nil))))))

(defun rk_guiSetIf (sym v)
  (when (and v (not (eq v rkJsonFalse))) (rkGuiSet sym (rk_guiStr v))))

; "(auto)" / blank -> nil (let the resolver pick)
(defun rk_guiChoiceOrNil (v)
  (if (or (rk_guiBlank v) (equal v rk_guiAuto)) nil (rk_guiTrim v)))

; Set a cyclic field to v, adding v to its choices when it is not offered
; (a saved choice that the current environment does not list).
(defun rk_guiSetCyc (sym v)
  (let ((f (rkGuiField sym)) ch)
    (when (and f (stringp v) (nequal v ""))
      (setq ch (get f 'choices))
      (unless (member v ch) (rk_guiSetChoices sym (append ch (list v))))
      (rkGuiSet sym v))
    v))

; Fill one page from a settings table (saved settings / rerun).
(defun rk_guiFillPage (type s)
  (when (tablep s)
    (cond
      ((equal type "aging")
        (rk_guiSetIf 'rk_gaLife (arrayref s "life_time"))
        (rk_guiSetIf 'rk_gaUnit (arrayref s "life_time_unit"))
        (rk_guiSetIf 'rk_gaStart (arrayref s "start_time"))
        (rk_guiSetIf 'rk_gaStop (arrayref s "stop_time"))
        (rkGuiSet 'rk_gaEvalT (rk_guiJoin (arrayref s "eval_temperatures") " "))
        (rk_guiSetDonau "aging" (arrayref s "donau_profile")))
      ((equal type "deos")
        (rk_guiSetIf 'rk_gdLife (arrayref s "life_time"))
        (rk_guiSetIf 'rk_gdUnit (arrayref s "life_time_unit"))
        (rk_guiSetIf 'rk_gdStart (arrayref s "start_time"))
        (rk_guiSetIf 'rk_gdStop (arrayref s "stop_time"))
        (rk_guiSetIf 'rk_gdSimT (arrayref s "simulation_time"))
        (rkGuiSet 'rk_gdTddb (rk_guiStr (arrayref s "tddb_temperature")))
        (rk_guiSetDonau "deos" (arrayref s "donau_profile")))
      ((equal type "emir")
        (rk_guiSetIf 'rk_geRunType (arrayref s "run_type"))
        (when (member (arrayref s "selfheat") (list t rkJsonFalse))
          (rkGuiSet 'rk_geSelfheat (eq (arrayref s "selfheat") t)))
        (rk_guiSetIf 'rk_geEmT (arrayref s "em_temperature"))
        (rk_guiSetIf 'rk_geRc (arrayref s "rc_corner"))
        (rk_guiSetIf 'rk_geStart (arrayref s "start_time"))
        (rk_guiSetIf 'rk_geStop (arrayref s "stop_time"))
        (rk_guiSetIf 'rk_geStep (arrayref s "dynamic_time_step"))
        (rk_guiSetIf 'rk_geLife (arrayref s "life_time"))
        (rk_guiSetIf 'rk_geDspf (arrayref s "dspf_file"))
        (rk_guiSetIf 'rk_geGds (arrayref s "gds_file"))
        (when (member (arrayref s "auto_extract") (list t rkJsonFalse))
          (rkGuiSet 'rk_geOwn (eq (arrayref s "auto_extract") rkJsonFalse))
          (rk_guiOwnCB))
        (rk_guiSetDonau "emir" (arrayref s "donau_profile"))
        (rk_guiSetIf 'rk_geLLib (arrayref s "layout_lib"))
        (rk_guiSetIf 'rk_geLView (arrayref s "layout_view"))
        (when (tablep (arrayref s "supplies"))
          (rkGuiSet 'rk_gePower (rk_guiSuppliesText (rkGet s "supplies.power")))
          (rkGuiSet 'rk_geGround (rk_guiSuppliesText (rkGet s "supplies.ground"))))
        (when (member (arrayref s "license_policy") rk_guiLicValues)
          (rkGuiSet 'rk_geLic (nth (rk_guiIndexOf (arrayref s "license_policy") rk_guiLicValues)
                                   rk_guiLicChoices)))
        (rk_guiSetIf 'rk_geLicH (arrayref s "license_wait_hours")))
      ((equal type "extract")
        (rk_guiSetIf 'rk_geLLib (arrayref s "layout_lib"))
        (rk_guiSetIf 'rk_geLView (arrayref s "layout_view"))
        (rk_guiSetCyc 'rk_geXCorner (arrayref s "technology_corner"))
        (rk_guiSetIf 'rk_geXTemp (arrayref s "temperature"))
        (rk_guiSetCyc 'rk_geXVariant (arrayref s "lvs_variant"))
        (when (stringp (arrayref s "qrc_deck"))
          (rk_guiSetCyc 'rk_geXQrc (rk_guiQrcLabel (arrayref s "qrc_deck"))))
        (when (rk_guiL (arrayref s "power_names"))
          (rkGuiSet 'rk_geXPower (rk_guiJoin (arrayref s "power_names") " ")))
        (when (rk_guiL (arrayref s "ground_names"))
          (rkGuiSet 'rk_geXGround (rk_guiJoin (arrayref s "ground_names") " "))))))
  t)

; Donau profile cyclic of a page (a saved/rerun name the site no longer has is
; kept visible with a warning summary; rk_yml falls back with a warning too)
(defun rk_guiSetDonau (type name)
  (when (stringp name)
    (rk_guiSetCyc (rk_guiTF type "Donau") name)
    (rk_guiDonauCB type))
  name)

(defun rk_guiApplySaved (saved)
  (let (dut)
    (when (stringp (rkGet saved "ip_name")) (rkGuiSet 'rk_gIp (rkGet saved "ip_name")))
    (when (member (rkGet saved "corner_show") rk_guiShowChoices)
      (rkGuiSet 'rk_gCornerShow (rkGet saved "corner_show"))
      (rk_guiShowCorners))
    (foreach type (list "aging" "deos" "emir" "extract")
      (rk_guiFillPage type (rkGet saved (strcat "settings." type))))
    (setq dut (rkGet saved "dut"))
    (when (and (tablep dut) (rkGet dut "inst") (rk_guiDutIndex (rkGet dut "inst")))
      (rk_guiSetDut dut t))
    t))

(defun rk_guiSaveSettings ()
  (let ((o (rkMakeObj)) (st (rkMakeObj)) r)
    (when rk_guiCtx
      (rkPut o "schema" 1)
      (rkPut o "dut" rk_guiDut)
      (rkPut o "ip_name" (rk_guiNullIfBlank (rkGuiGet 'rk_gIp)))
      (rkPut o "corner_show" (rkGuiGet 'rk_gCornerShow))
      (foreach type (list "aging" "deos" "emir" "extract")
        (rkPut st type (rk_guiPageSettings type)))
      (rkPut o "settings" st)
      (setq r (errset (rkMaeWriteSettings rk_guiCtx o) nil))
      (unless r (printf "[relkit] could not save the per-cell settings: %L\n" errset.errset))
      (and r (car r)))))

; ---------------------------------------------------------------------------
; ctx for a run
; ---------------------------------------------------------------------------

(defun rkGuiRunCtx (type)
  (let (ctx st)
    (unless rk_guiCtx (error "relkit: no Maestro context"))
    (setq ctx (rk_copyTree rk_guiCtx))
    (rkPut ctx "dut" (and rk_guiDut (rk_copyTree rk_guiDut)))
    (rkPut ctx "ip_name" (or (rk_guiNullIfBlank (rkGuiGet 'rk_gIp)) (rkGet ctx "maestro.cell")))
    (rkPut ctx "run_type" type)
    (setq st (rkMakeObj))
    (foreach ty (list "aging" "deos" "emir" "extract")
      (rkPut st ty (rk_guiPageSettings ty)))
    (rkPut ctx "settings" st)
    ctx))

; ctx with the netlist exported (needs the DUT) -> (ctx nil) / (nil message)
(defun rk_guiCtxWithNetlist (type)
  (let (ctx r)
    (cond
      ((null rk_guiCtx) (list nil "no Maestro context"))
      ((null rk_guiDut) (list nil "choose the DUT first (top bar)"))
      (t
        (setq ctx (rkGuiRunCtx type))
        (setq r (errset (rkMaeExportNetlist ctx) nil))
        (cond
          (r (list ctx nil))
          (t (list nil (sprintf nil "netlist export failed: %s"
                                (rk_guiErrText errset.errset)))))))))

(defun rk_guiErrText (e)
  (let ((m (car e)))
    (cond
      ((stringp m) m)
      ((and (listp m) (stringp (car m))) (car m))
      (t (sprintf nil "%L" e)))))

; ---------------------------------------------------------------------------
; Submit / status
; ---------------------------------------------------------------------------

(defun rk_guiPageSay (type msg)
  (rkGuiSet (rk_guiTF type "Status") msg)
  (rk_guiSay (sprintf nil "%s: %s" type msg)))

(defun rkGuiSubmit (type)
  (let (r ctx ctxFile out s h)
    (cond
      ((rkIpcBusy (arrayref rk_guiPending type))
        (rk_guiPageSay type "a submit is already in progress")
        nil)
      ((null (rk_guiSelectedCorners))
        (rk_guiPageSay type "no corner selected (Corners table)")
        nil)
      (t
        (rk_guiPageSay type "exporting the netlist...")
        (setq r (rk_guiCtxWithNetlist type))
        (setq ctx (car r))
        (cond
          ((null ctx) (rk_guiPageSay type (cadr r)) nil)
          (t
            (when (equal type "emir")
              (setq s (rkGet ctx "settings.emir"))
              (cond
                ((rkGuiGet 'rk_geOwn)
                  (unless (and (rkGet s "dspf_file") (isFile (rkGet s "dspf_file"))
                               (rkGet s "gds_file") (isFile (rkGet s "gds_file")))
                    (setq ctx nil)
                    (rk_guiPageSay type "own DSPF / GDS file missing: browse them, or untick 'Use my own DSPF/GDS files'")))
                ((rk_guiL (rkGet rk_guiResolve "missing_env"))
                  (setq ctx nil)
                  (rk_guiPageSay type (strcat "cannot make the DSPF/GDS: " (rk_guiMissingEnvText rk_guiResolve)))))
              (when (and ctx (null (rkKeys (rkGet s "supplies.power"))))
                (setq ctx nil)
                (rk_guiPageSay type "no power net given (Power nets)"))
              (when (and ctx (exists k (rkKeys (rkGet s "supplies.power"))
                                     (null (arrayref (rkGet s "supplies.power") k))))
                (setq ctx nil)
                (rk_guiPageSay type "every power net needs a voltage (NET=V in Power nets)")))
            (when ctx
              (rk_guiSaveSettings)
              (setq ctxFile (rkIpcNewCtxFile ctx (strcat "submit_" type)))
              (setq out (rkIpcNewOutFile (strcat "submit_" type)))
              (rk_guiPageSay type (sprintf nil "submitting %d corner(s)..." (length (rk_guiSelectedCorners))))
              (setq h (rkIpcRun "submit" ctxFile out (stringToSymbol (strcat "rk_guiSubmitDone_" type))
                                nil 300))
              (setarray rk_guiPending type h)
              t)))))))

(defun rk_guiSubmitDone_aging (res) (rk_guiSubmitDone "aging" res))
(defun rk_guiSubmitDone_deos (res) (rk_guiSubmitDone "deos" res))
(defun rk_guiSubmitDone_emir (res) (rk_guiSubmitDone "emir" res))

(defun rk_guiSubmitDone (type res)
  (cond
    ((not (eq (rkGet res "ok") t))
      (rk_guiPageSay type (sprintf nil "submit failed: %s" (rkGet res "error" "?"))))
    (t
      (rk_guiFollowRun type (rkGet res "run_dir"))
      (rk_guiPageSay type (sprintf nil "%s submitted (%s%s); Work_Dir %s%s"
                                   (rkGet res "run_id") (rkGet res "state" "?")
                                   (if (eq (rkGet res "dry_run") t) ", dry run" "")
                                   (rkGet res "work_dir" "?")
                                   (if (equal (rkGet res "state") "extracting")
                                     "  -- DSPF/GDS missing or stale: extracting first, EMIR follows ([Progress...] shows the steps)"
                                     "")))
      (when (equal (rkGet res "state") "extracting")
        (rkGuiSet 'rk_geXStatus (sprintf nil "auto-extract for EMIR run %s started" (rkGet res "run_id"))))
      (rk_guiRunsRefresh nil)))
  t)

(defun rk_guiPollSeconds ()
  (let ((v (rk_guiNum (rkSiteGet "gui.status_poll_seconds"))))
    (max 1 (or v 30))))

; Start following a run on its page (poller "gui:run:<type>").
(defun rk_guiFollowRun (type runDir)
  (setarray rk_guiRunDir type runDir)
  (setarray rk_guiResults type nil)
  (rk_guiShowResults type)
  (setarray rk_guiPollFails (strcat "gui:run:" type) 0)
  (unless rk_guiClosed
    (rkIpcPollStart (strcat "gui:run:" type) "status" nil (list "--run" runDir)
                    (rk_guiPollSeconds) (stringToSymbol (strcat "rk_guiStatus_" type)))))

; A failed status poll -> t (keep polling) until rk_guiPollMaxFails failures in
; a row, then nil: a run record that went away does not keep a timer armed for
; the panel's lifetime.
(defun rk_guiPollFailed (name)
  (let ((n (add1 (or (arrayref rk_guiPollFails name) 0))))
    (setarray rk_guiPollFails name n)
    (lessp n rk_guiPollMaxFails)))

(defun rk_guiStatus_aging (res) (rk_guiStatusCB "aging" res))
(defun rk_guiStatus_deos (res) (rk_guiStatusCB "deos" res))
(defun rk_guiStatus_emir (res) (rk_guiStatusCB "emir" res))

(defun rk_guiStatusText (res)
  (let ((state (rkGet res "state" "?")) (lic (rkGet res "license")) msg jobs)
    (setq jobs (rkGet res "jobs"))
    (setq msg (sprintf nil "%s: %s" (rkGet res "run_id" "?") state))
    (when (and (tablep lic) (or (equal state "waiting_license") (eq (rkGet lic "waiting") t)))
      ; retries = resubmits done so far; the one we wait for is retries + 1
      (setq msg (sprintf nil "%s -- waiting for a Totem license (retry %d%s, policy %s)" msg
                         (add1 (or (rk_guiNum (rkGet lic "retries" 0)) 0))
                         (if (rkGet lic "next_retry") (sprintf nil " at %s" (rkGet lic "next_retry")) "")
                         (rk_guiStr (rkGet lic "policy" "?")))))
    (when jobs
      (setq msg (sprintf nil "%s; jobs %d done / %d" msg
                         (length (setof j jobs (equal (rkGet j "state") "done"))) (length jobs))))
    (when (and (stringp (rkGet res "message")) (nequal (rkGet res "message") ""))
      (setq msg (sprintf nil "%s -- %s" msg (rkGet res "message"))))
    msg))

; Poll result of a followed run -> t to keep polling.
(defun rk_guiStatusCB (type res)
  (let ((state (rkGet res "state")) keep)
    (setarray rk_guiLast type res)
    (cond
      ((not (eq (rkGet res "ok") t))
        (setq keep (rk_guiPollFailed (strcat "gui:run:" type)))
        (rk_guiPageSay type (sprintf nil "status failed: %s%s" (rkGet res "error" "?")
                                     (if keep "" " (stopped following this run; [Refresh status] on the Runs page)"))))
      (t
        (setarray rk_guiPollFails (strcat "gui:run:" type) 0)
        (rkGuiSet (rk_guiTF type "Status") (rk_guiStatusText res))
        (when (equal type "emir") (rk_guiRunExtractInfo res))
        (cond
          ((rk_guiIsFinal state)
            (when (equal state "done") (rk_guiLoadResults type (arrayref rk_guiRunDir type)))
            (when (equal state "failed")
              (rk_guiSay (sprintf nil "%s run failed: %s%s" type (rkGet res "message" "")
                                  (if (rkGet res "failure_tail")
                                    (strcat " | " (car (last (rkGet res "failure_tail"))))
                                    ""))))
            (rk_guiRunsRefresh nil)
            (setq keep nil))
          (t (setq keep t)))))
    keep))

; EMIR run with auto-extract: mirror its extraction on the extract line; an
; LVS failure enables [Open Calibre GUI] / [LVS report] for that runset.
(defun rk_guiRunExtractInfo (res)
  (let ((ex (rkGet res "extract")) state)
    (when (and (tablep ex) (equal (rkGet ex "mode") "auto"))
      (setq state (rkGet ex "state"))
      (cond
        ((or (equal state "lvs_failed") (equal (rkGet res "state") "lvs_failed"))
          (setq rk_guiExtract ex)
          (rk_guiEnable 'rk_geBCalibre t)
          ; short: a read-only field shows the END of a long text
          (rkGuiSet 'rk_geXStatus (sprintf nil "LVS FAILED (EMIR run %s): [Open Calibre GUI] / [LVS report]"
                                           (rkGet res "run_id" "?"))))
        ((member state (list "running" "pending"))
          (rkGuiSet 'rk_geXStatus (sprintf nil "auto-extract for EMIR run %s: %s" (rkGet res "run_id" "?")
                                           (rk_guiJoin (mapcar (lambda (s) (sprintf nil "%s:%s" (rkGet s "name") (rkGet s "state")))
                                                               (rk_guiL (rkGet ex "steps")))
                                                       " "))))
        ((and (equal state "done") (not (equal (rkGet rk_guiFresh "state") "fresh")))
          (rkGuiSet 'rk_geXStatus (sprintf nil "auto-extract for EMIR run %s: done" (rkGet res "run_id" "?")))
          (rk_guiCheckFresh))))
    t))

(defun rk_guiCancelRunCB (type)
  (let ((d (arrayref rk_guiRunDir type)))
    (cond
      ((null d) (rk_guiPageSay type "no run on this page"))
      (t
        (rk_guiPageSay type "cancelling...")
        (rkIpcRun "cancel" nil (rkIpcNewOutFile "cancel") (stringToSymbol (strcat "rk_guiCancelled_" type))
                  (list "--run" d) 60)))))

(defun rk_guiCancelled_aging (res) (rk_guiCancelled "aging" res))
(defun rk_guiCancelled_deos (res) (rk_guiCancelled "deos" res))
(defun rk_guiCancelled_emir (res) (rk_guiCancelled "emir" res))
(defun rk_guiCancelled (type res)
  (rk_guiPageSay type (if (eq (rkGet res "ok") t)
                        (sprintf nil "%s: %s" (rkGet res "run_id" "?") (rkGet res "state" "?"))
                        (sprintf nil "cancel failed: %s" (rkGet res "error" "?"))))
  (rkIpcPollNow (strcat "gui:run:" type))
  t)

; ---------------------------------------------------------------------------
; Results on a page
; ---------------------------------------------------------------------------

(defun rk_guiMetricsText (type m)
  (let (keys out)
    (when (tablep m)
      (setq keys (rkKeys m))
      (when (and (equal type "deos") (member "Total_DPM" keys))
        (setq keys (cons "Total_DPM" (setof k keys (nequal k "Total_DPM")))))
      (foreach k keys
        (when (lessp (length out) 8)
          (setq out (cons (sprintf nil "%s=%s" k (rk_guiStr (arrayref m k))) out)))))
    (rk_guiJoin (reverse out) "  ")))

(defun rk_guiShowResults (type)
  (let ((r (arrayref rk_guiResults type)) rows (i 0) pass)
    (when r
      (foreach c (rk_guiL (rkGet r "corners"))
        (setq pass (arrayref c "pass"))
        (setq rows (cons (list (sprintf nil "%d" i)
                               (rk_guiStr (rkGet c "corner"))
                               (rk_guiStr (rkGet c "stress_id"))
                               (cond ((eq pass t) "PASS") ((eq pass rkJsonFalse) "FAIL") (t "?"))
                               (rk_guiMetricsText type (rkGet c "metrics"))
                               (rk_guiStr (rkGet c "worst_device"))
                               (rk_guiStr (rkGet c "worst_model")))
                         rows))
        (setq i (add1 i))))
    (rk_guiSetChoices (rk_guiTF type "Res") (reverse rows))
    (length rows)))

; summary.json of a run dir -> page table
(defun rk_guiLoadResults (type runDir)
  (let ((p (and runDir (rkPathJoin runDir "summary.json"))) r)
    (cond
      ((not (and p (isFile p)))
        (rkGuiSet (rk_guiTF type "Status") (sprintf nil "%s (no summary.json yet)" (rkGuiGet (rk_guiTF type "Status"))))
        nil)
      (t
        (setq r (errset (rkResultsLoadResults p) nil))
        (setarray rk_guiResults type (and r (car r)))
        (rkPut (or (arrayref rk_guiResults type) (rkMakeObj)) "_path" p)
        (rk_guiShowResults type)))))

(defun rk_guiResCorner (type)
  (let ((r (arrayref rk_guiResults type)) idx)
    (setq idx (car (rk_guiSelectedIdx (rk_guiTF type "Res"))))
    (cond
      ((null r) nil)
      ((null idx) (car (rk_guiL (rkGet r "corners"))))
      (t (nth idx (rk_guiL (rkGet r "corners")))))))

; ctx used for schematic jumps from result tables
(defun rk_guiJumpCtx ()
  (let ((ctx (and rk_guiCtx (rk_copyTree rk_guiCtx))))
    (when ctx (rkPut ctx "dut" (and rk_guiDut (rk_copyTree rk_guiDut))))
    ctx))

; double-click / [Open device table]: the corner's device table window
(defun rk_guiResOpenCB (type)
  (let ((c (rk_guiResCorner type)) tp)
    (setq tp (and c (rkGet c "table_path")))
    (cond
      ((null c) (rk_guiPageSay type "no results yet"))
      ((not (and (stringp tp) (isFile tp))) (rk_guiPageSay type "this corner has no device table"))
      (t (rkResultsShowTable (sprintf nil "%s %s %s" type (rk_guiStr (rkGet c "corner"))
                                      (if (rkGet c "stress_id") (strcat "Stress_" (rk_guiStr (rkGet c "stress_id"))) ""))
                             (rkResultsDeviceTable tp) (rk_guiJumpCtx) rk_guiNoDisplay)))))

(unless (boundp 'rk_guiNoDisplay) (setq rk_guiNoDisplay nil))   ; tests: build tables headless

(defun rk_guiResJumpCB (type)
  (let ((c (rk_guiResCorner type)) w)
    (setq w (and c (rkGet c "worst_device")))
    (cond
      ((null w) (rk_guiPageSay type "no worst device for this row"))
      (t
        (rkResultsJumpToInstance w (rk_guiJumpCtx))
        (rk_guiSay (rkResultsLastMessage))))))

(defun rk_guiResFullCB (type)
  (let ((r (arrayref rk_guiResults type)))
    (if r
      (rkResultsShowTable (sprintf nil "%s summary" type) (rkGet r "_path") (rk_guiJumpCtx) rk_guiNoDisplay)
      (rk_guiPageSay type "no results yet"))))

; ---------------------------------------------------------------------------
; Reports, Work_Dir, RelStudio GUI
; ---------------------------------------------------------------------------

(defun rk_guiReadRun (runDir)
  (let ((p (and runDir (rkPathJoin runDir "run.json"))) r)
    (setq r (and p (isFile p) (errset (rkJsonRead p) nil)))
    (and r (car r))))

; Official report of a run: the RelStudio report if still there, else the
; text copy kept in the run record (reports/).
(defun rk_guiOfficialReport (runDir)
  (let ((run (rk_guiReadRun runDir)) cands hit copies)
    (setq cands (and run (rkGet run "official_reports")))
    (foreach c cands
      (let ((p (if (tablep c) (or (rkGet c "path") (rkGet c "copy")) c)))
        (when (and (null hit) (stringp p) (isFile p) (pcreMatchp "\\.report$" p)) (setq hit p))))
    (unless hit
      (foreach c cands
        (let ((p (if (tablep c) (rkGet c "path") c)))
          (when (and (null hit) (stringp p) (isFile p)) (setq hit p)))))
    (unless hit
      (setq copies (and (isDir (rkPathJoin runDir "reports"))
                        (setof f (getDirFiles (rkPathJoin runDir "reports")) (pcreMatchp "\\.report$" f))))
      (when copies (setq hit (rkPathJoin (rkPathJoin runDir "reports") (car (sort copies 'alphalessp))))))
    hit))

(defun rk_guiOpenReport (runDir kind)
  (let (p run)
    (cond
      ((null runDir) (rk_guiSay "no run selected"))
      ((equal kind "aux")
        (setq run (rk_guiReadRun runDir))
        (setq p (or (and run (rkGet run "aux_report")) (rkPathJoin runDir "aux_report.html")))
        (if (isFile p) (progn (rkResultsOpenFile p) (rk_guiSay (sprintf nil "opened %s" p)) p)
          (rk_guiSay "no aux report yet (written when the run finishes)")))
      (t
        (setq p (rk_guiOfficialReport runDir))
        (if p (progn (rkResultsOpenFile p) (rk_guiSay (sprintf nil "opened %s" p)) p)
          (rk_guiSay "no official report yet (RelStudio writes it when the run finishes)"))))))

(defun rk_guiOfficialCB (type) (rk_guiOpenReport (arrayref rk_guiRunDir type) "official"))
(defun rk_guiAuxCB (type) (rk_guiOpenReport (arrayref rk_guiRunDir type) "aux"))

(defun rk_guiOpenDir (dir)
  (let ((cmd (rk_guiSite "gui.open_dir_cmd" "xdg-open")))
    (cond
      ((not (and (stringp dir) (isDir dir)))
        (rk_guiSay (sprintf nil "Work_Dir %s is gone (RelStudio raw data is cleaned after ~11 days); the run record keeps the summary and report copies" (rk_guiStr dir))))
      (t
        (rkIpcLaunch (strcat cmd " " (rkShellQuote dir)))
        (rk_guiSay (sprintf nil "opening %s" dir))
        dir))))

(defun rk_guiRelstudioCmd ()
  (let ((c (rkSiteGet "gui.relstudio_cmd")) (home (rkRelstudioHome)))
    (cond
      ((and (stringp c) (nequal c "")) c)
      ((and (stringp home) (isFile (rkPathJoin home "bin/relstudio")))
        (rkShellQuote (rkPathJoin home "bin/relstudio")))
      (t "relstudio"))))

(defun rk_guiRelstudioCB ()
  (let ((cmd (strcat "cd " (rkShellQuote (rkWorkarea)) " && " (rk_guiRelstudioCmd))))
    (rkIpcLaunch cmd)
    (rk_guiSay (sprintf nil "launched: %s" cmd))
    cmd))

; ---------------------------------------------------------------------------
; R1 (aging page): aged corners + delta table -- rkAged functions, guarded
; ---------------------------------------------------------------------------

(defun rk_guiAgedCB ()
  (let ((d (arrayref rk_guiRunDir "aging")) r ctx args)
    (cond
      ((null d) (rk_guiPageSay "aging" "no aging run on this page (submit one, or pick one on the Runs page)"))
      ((not (getd 'rkAgedCreateCorners)) (rk_guiPageSay "aging" "R1 (rkAgedCreateCorners) is not available"))
      (t
        (setq args (list "--run" d))
        ; compare the Stress netlist with the current one when we can export it
        (when rk_guiDut
          (setq r (rk_guiCtxWithNetlist "aging"))
          (setq ctx (car r))
          (when (and ctx (rkGet ctx "netlist.path"))
            (setq args (append args (list "--netlist" (rkGet ctx "netlist.path"))))))
        (rk_guiPageSay "aging" "preparing the aged include files...")
        (rkIpcRun "aged-include" nil (rkIpcNewOutFile "aged_include") 'rk_guiAgedDone args 120)))))

(defun rk_guiAgedDone (res)
  (let (r names kf)
    (cond
      ((not (eq (rkGet res "ok") t))
        (rk_guiPageSay "aging" (sprintf nil "aged-include failed: %s" (rkGet res "error" "?"))))
      (t
        ; rkIpc reads out.json with JSON false -> nil, which would turn
        ; netlist_match:false ("netlists differ") into "not compared":
        ; re-read it keeping false (rkJsonFalse).
        (setq kf (errset (rkJsonReadKeepFalse (rkGet res "_out")) nil))
        (when (and kf (tablep (car kf))) (setq res (car kf)))
        (setq r (errset (rkAgedCreateCorners rk_guiSess (rk_guiJumpCtx) res t) t))
        (setq names (and r (car r)))
        (rk_guiPageSay "aging"
                       (cond
                         ((null r) (sprintf nil "creating aged corners failed: %s" (rk_guiErrText errset.errset)))
                         ((null names) (sprintf nil "no aged corner created%s%s"
                                                (if (rk_guiL (rkGet res "missing"))
                                                  (sprintf nil " (%d Stress missing: rerun the Stress)" (length (rkGet res "missing")))
                                                  "")
                                                (rk_guiAgedMsgs)))
                         (t (sprintf nil "created %d corner(s) in Maestro: %s%s%s" (length names) (rk_guiJoin names ", ")
                                     (if (eq (rkGet res "netlist_match") rkJsonFalse)
                                       "  -- WARNING: the current netlist differs from the Stress netlist; instance names may not match"
                                       "")
                                     (rk_guiAgedMsgs)))))))
    t))

(defun rk_guiAgedMsgs ()
  (let ((m (and (getd 'rkAgedMessages) (car (errset (rkAgedMessages) nil)))))
    (if m (strcat "  -- " (rk_guiJoin m "; ")) "")))

(defun rk_guiDeltaCB ()
  (let (h r tsv ctx)
    (cond
      ((not (getd 'rkAgedDeltaTable)) (rk_guiPageSay "aging" "R1 (rkAgedDeltaTable) is not available"))
      ((null rk_guiSess) (rk_guiPageSay "aging" "no Maestro session"))
      (t
        (setq h (car (errset (rkMaeFindHistory rk_guiSess (rkGet rk_guiCtx "test")) nil)))
        (setq ctx (rk_guiJumpCtx))
        (rkPut ctx "run_dir" (arrayref rk_guiRunDir "aging"))   ; the aging run the aged corners came from
        (setq r (errset (rkAgedDeltaTable rk_guiSess ctx (and h (rkGet h "name"))) t))
        (setq tsv (and r (car r)))
        (cond
          ((null r) (rk_guiPageSay "aging" (sprintf nil "delta table failed: %s" (rk_guiErrText errset.errset))))
          ((not (and (stringp tsv) (isFile tsv)))
            (rk_guiPageSay "aging" (strcat "no delta table (run the aged corners in Maestro first)" (rk_guiAgedMsgs))))
          (t
            (rk_guiPageSay "aging" (sprintf nil "delta table: %s%s" tsv (rk_guiAgedMsgs)))
            (rkResultsShowTable "fresh vs aged" tsv (rk_guiJumpCtx) rk_guiNoDisplay)))))))

; ---------------------------------------------------------------------------
; EMIR page: extraction, existing files, supplies
; ---------------------------------------------------------------------------

; --- extract-resolve: parameters derived from Virtuoso's environment ---------

(defun rk_guiMissingEnvText (res)
  (sprintf nil "MISSING environment variable(s) %s -- start Virtuoso from a shell that sourced the PDK setup, or pin extract.<key> in the site config; [Show resolved] for details"
           (rk_guiJoin (mapcar (lambda (v) (strcat "$" v)) (rk_guiL (rkGet res "missing_env"))) " ")))

; Run extract-resolve (async). Called on panel load, DUT change, choice change
; and by [Resolve / preview]. The result fills the choices and the status line.
(defun rk_guiResolveExtract ()
  (let (ctx out)
    (when (and rk_guiForm rk_guiCtx (not rk_guiClosed))
      (setq ctx (rkGuiRunCtx "emir"))
      (setq out (rkIpcNewOutFile "resolve"))
      (setq rk_guiResolveOut out)
      (rkIpcRun "extract-resolve" (rkIpcNewCtxFile ctx "resolve") out 'rk_guiResolved
                (list "--text" (strcat out ".txt")) 60))))

; QRC deck choices are shown as short labels (<version>/<deck>; the full
; QCI_deck path made the cyclic grow past the page); label -> path table.
(unless (boundp 'rk_guiQrcMap) (setq rk_guiQrcMap (makeTable "rk_guiQrcMap" nil)))

(defun rk_guiQrcLabel (path)
  (let ((segs (parseString (or path "") "/")) lab n)
    (when (equal (car (last segs)) "QCI_deck") (setq segs (reverse (cdr (reverse segs)))))
    (setq n (length segs))
    (setq lab (if (geqp n 2) (strcat (nth (difference n 2) segs) "/" (nth (sub1 n) segs)) (or (car segs) "?")))
    (let ((base lab) (i 2))
      (while (and (arrayref rk_guiQrcMap lab) (nequal (arrayref rk_guiQrcMap lab) path))
        (setq lab (sprintf nil "%s#%d" base i))
        (setq i (add1 i))))
    (setarray rk_guiQrcMap lab path)
    lab))

; cyclic value -> the deck path ((auto) -> nil); unknown labels pass through
(defun rk_guiQrcPath (v)
  (let ((c (rk_guiChoiceOrNil v)))
    (and c (or (arrayref rk_guiQrcMap c) c))))

(defun rk_guiResolveCB ()
  (cond
    ((null rk_guiCtx) (rkGuiSet 'rk_geXStatus "no Maestro context"))
    (t (rkGuiSet 'rk_geXStatus "resolving the extraction parameters...")
       (rk_guiResolveExtract)
       t)))

(defun rk_guiXChoiceCB ()
  (unless rk_guiMute (rk_guiResolveExtract)))

(defun rk_guiResolved (res)
  (let (ch variants decks errs txt)
    (cond
      ((nequal (rkGet res "_out") rk_guiResolveOut) nil)   ; superseded by a newer call
      ((not (eq (rkGet res "ok") t))
        (setq rk_guiResolve nil)
        (rkGuiSet 'rk_geXStatus (sprintf nil "extract-resolve failed: %s" (rkGet res "error" "?"))))
      (t
        (setq rk_guiResolve res)
        (setq ch (rkGet res "choices"))
        (setq variants (rk_guiL (rkGet ch "variants")))
        (setq decks (rk_guiL (rkGet ch "qrc_decks")))
        (rk_guiSyncChoices 'rk_geXVariant variants)
        (rk_guiSyncChoices 'rk_geXQrc (mapcar 'rk_guiQrcLabel (setof d decks (stringp d))))
        (when (rk_guiBlank (rkGuiGet 'rk_geXPower))
          (rkGuiSet 'rk_geXPower (rk_guiJoin (rkGet res "suggested.power_names") " ")))
        (when (rk_guiBlank (rkGuiGet 'rk_geXGround))
          (rkGuiSet 'rk_geXGround (rk_guiJoin (rkGet res "suggested.ground_names") " ")))
        (setq errs (rk_guiL (rkGet res "errors")))
        (cond
          ((rk_guiL (rkGet res "missing_env"))
            (rk_guiEnable 'rk_geBExtract nil)
            (setq txt (rk_guiMissingEnvText res)))
          (errs
            (rk_guiEnable 'rk_geBExtract t)
            (setq txt (sprintf nil "not ready: %s%s" (car errs)
                               (if (cdr errs) (sprintf nil " (+%d more; [Show resolved])" (length (cdr errs))) ""))))
          (t
            (rk_guiEnable 'rk_geBExtract t)
            (setq txt (sprintf nil "ready: tech %s, LVS %s.%s, corner %s, QRC deck %s"
                               (rk_guiStr (rkGet res "resolved.tech_name.value"))
                               (rk_guiStr (rkGet res "resolved.lvs_basename.value"))
                               (rk_guiStr (rkGet res "resolved.lvs_variant.value"))
                               (rk_guiStr (rkGet res "resolved.technology_corner.value"))
                               (if (stringp (rkGet res "resolved.qrc_deck_dir.value"))
                                 (rk_guiQrcLabel (rkGet res "resolved.qrc_deck_dir.value"))
                                 "?")))))
        ; keep an LVS failure on the line (its [Open Calibre GUI] is still offered)
        (unless (or (rkIpcPollActive "gui:extract")
                    (pcreMatchp "^LVS FAILED" (or (rkGuiGet 'rk_geXStatus) "")))
          (rkGuiSet 'rk_geXStatus txt))
        (rk_guiCheckFresh))))
  t)

; cyclic choices = (auto) + what the environment offers; keep the current pick
(defun rk_guiSyncChoices (sym items)
  (let ((cur (rkGuiGet sym)))
    (rk_guiSetChoices sym (cons rk_guiAuto (setof x items (stringp x))))
    (rkGuiSet sym (if (member cur items) cur rk_guiAuto))))

(defun rk_guiShowResolvedCB ()
  (let ((p (and rk_guiResolve (rkGet rk_guiResolve "text"))))
    (cond
      ((and (stringp p) (isFile p)) (rkResultsOpenFile p))
      (t (rkGuiSet 'rk_geXStatus "nothing resolved yet: press [Resolve / preview]")))))

(defun rk_guiExtractCB ()
  (let (ctx ctxFile)
    (cond
      ((null rk_guiDut) (rkGuiSet 'rk_geXStatus "choose the DUT first"))
      ((rkIpcPollActive "gui:extract") (rkGuiSet 'rk_geXStatus "an extraction is already being followed"))
      ((rk_guiL (rkGet rk_guiResolve "missing_env"))
        (rkGuiSet 'rk_geXStatus (rk_guiMissingEnvText rk_guiResolve)))
      (t
        (setq ctx (rkGuiRunCtx "emir"))
        (setq ctxFile (rkIpcNewCtxFile ctx "extract"))
        (rkGuiSet 'rk_geXStatus "starting the extraction (strmout -> si -> LVS -> QRC)...")
        (setq rk_guiExtract nil)          ; the previous result no longer applies
        (rk_guiEnable 'rk_geBCalibre nil)
        (rkIpcRun "extract" ctxFile (rkIpcNewOutFile "extract") 'rk_guiExtractStarted nil 120)))))

(defun rk_guiExtractStarted (res)
  (cond
    ((not (eq (rkGet res "ok") t))
      (rkGuiSet 'rk_geXStatus
                (sprintf nil "extraction not started: %s" (rkGet res "error" "?"))))
    (t
      (setq rk_guiExtract res)
      (rk_guiFollowExtract (rkGet res "extract_dir"))))
  t)

(defun rk_guiFollowExtract (dir)
  (setarray rk_guiPollFails "gui:extract" 0)
  (unless rk_guiClosed
    (rkIpcPollStart "gui:extract" "extract-status" nil (list "--dir" dir)
                    (min 5 (rk_guiPollSeconds)) 'rk_guiExtractStatus)))

(defun rk_guiExtractStatus (res)
  (let ((state (rkGet res "state")) steps txt)
    (cond
      ((not (eq (rkGet res "ok") t))
        ; keep the last good result: its extract_dir is what [Cancel extract] needs
        (rkGuiSet 'rk_geXStatus (sprintf nil "extract-status failed: %s" (rkGet res "error" "?")))
        (rk_guiPollFailed "gui:extract"))
      (t
        (setq rk_guiExtract res)
        (setarray rk_guiPollFails "gui:extract" 0)
        (setq steps (rk_guiJoin (mapcar (lambda (s) (sprintf nil "%s:%s" (rkGet s "name") (rkGet s "state")))
                                        (rkGet res "steps"))
                                " "))
        (setq txt (sprintf nil "%s  [%s]%s" state steps
                           (if (rkGet res "message") (strcat "  " (rk_guiStr (rkGet res "message"))) "")))
        (cond
          ((equal state "done")
            (rkGuiSet 'rk_geDspf (rkGet res "dspf"))
            (rkGuiSet 'rk_geGds (rkGet res "gds"))
            (rkGuiSet 'rk_geXStatus (strcat "done: DSPF + GDS published  " txt))
            (rk_guiCheckFresh)
            nil)
          ((equal state "lvs_failed")
            (rk_guiEnable 'rk_geBCalibre t)
            (rkGuiSet 'rk_geXStatus (sprintf nil "LVS FAILED: [Open Calibre GUI] / [LVS report]  [%s]" steps))
            nil)
          ((member state (list "failed" "cancelled" "none"))
            (rkGuiSet 'rk_geXStatus txt)
            nil)
          (t
            (rkGuiSet 'rk_geXStatus (sprintf nil "%s  %s" txt
                                             (rk_guiStr (car (last (rkGet res "log_tail"))))))
            t))))))

(defun rk_guiExtractCancelCB ()
  (let ((dir (and rk_guiExtract (rkGet rk_guiExtract "extract_dir"))))
    (cond
      ((null dir) (rkGuiSet 'rk_geXStatus "no extraction to cancel"))
      (t (rkIpcRun "extract-cancel" nil (rkIpcNewOutFile "extract_cancel") 'rk_guiExtractCancelled
                   (list "--dir" dir) 60)))))

(defun rk_guiExtractCancelled (res)
  (rkGuiSet 'rk_geXStatus (sprintf nil "extract-cancel: %s" (if (eq (rkGet res "ok") t) (rkGet res "state" "?")
                                                              (rkGet res "error" "?"))))
  (rkIpcPollNow "gui:extract")
  t)

(defun rk_guiCalibreCB ()
  (let ((cmd (and rk_guiExtract (rkGet rk_guiExtract "calibre_gui_cmd")))
        (cwd (and rk_guiExtract (rkGet rk_guiExtract "calibre_gui_cwd"))))
    (cond
      ((not (stringp cmd)) (rkGuiSet 'rk_geXStatus "no LVS runset yet"))
      (t
        (rkIpcLaunch (strcat "cd " (rkShellQuote (or cwd (rkWorkarea))) " && " cmd))
        (rkGuiSet 'rk_geXStatus (sprintf nil "launched: %s" cmd))
        cmd))))

(defun rk_guiLvsReportCB ()
  (let ((p (and rk_guiExtract (rkGet rk_guiExtract "lvs_report"))))
    (if (and (stringp p) (isFile p)) (rkResultsOpenFile p) (rkGuiSet 'rk_geXStatus "no LVS report yet"))))

; [Use existing (detect)]: the canonical / newest DSPF + GDS of the DUT
(defun rk_guiDetectCB ()
  (let (ctxFile)
    (cond
      ((null rk_guiDut) (rkGuiSet 'rk_geXStatus "choose the DUT first"))
      (t
        (setq ctxFile (rkIpcNewCtxFile (rkGuiRunCtx "emir") "detect"))
        (rkIpcRun "extract-status" ctxFile (rkIpcNewOutFile "detect") 'rk_guiDetected nil 60)))))

(defun rk_guiPathOf (x)
  (cond ((tablep x) (rkGet x "path")) ((stringp x) x) (t nil)))

(defun rk_guiDetected (res)
  (let ((ex (rkGet res "existing")) d g)
    (cond
      ((not (eq (rkGet res "ok") t))
        (rkGuiSet 'rk_geXStatus (sprintf nil "detect failed: %s" (rkGet res "error" "?"))))
      (t
        (setq d (or (rk_guiPathOf (rkGet ex "dspf")) (rk_guiPathOf (car (rkGet ex "dspf_candidates")))))
        (setq g (or (rk_guiPathOf (rkGet ex "gds")) (rk_guiPathOf (car (rkGet ex "gds_candidates")))))
        (when d (rkGuiSet 'rk_geDspf d))
        (when g (rkGuiSet 'rk_geGds g))
        (rkGuiSet 'rk_geXStatus
                  (cond
                    ((and d g) (sprintf nil "using existing files%s" (if (rkGet ex "warning") (strcat " -- " (rkGet ex "warning")) "")))
                    (t (sprintf nil "no existing %s under %s; extract them or browse"
                                (if d "GDS" (if g "DSPF" "DSPF/GDS")) (rk_guiStr (rkGet ex "artifact_dir")))))))))
  t)

; [Fill from DUT ports]: emir-inputs (needs the exported netlist)
(defun rk_guiSuppliesCB ()
  (let (r ctx)
    (setq r (rk_guiCtxWithNetlist "emir"))
    (setq ctx (car r))
    (cond
      ((null ctx) (rk_guiPageSay "emir" (cadr r)))
      (t
        (rkIpcRun "emir-inputs" (rkIpcNewCtxFile ctx "emir_inputs") (rkIpcNewOutFile "emir_inputs")
                  'rk_guiSuppliesDone nil 120)))))

(defun rk_guiSuppliesDone (res)
  (cond
    ((not (eq (rkGet res "ok") t))
      (rk_guiPageSay "emir" (sprintf nil "emir-inputs failed: %s" (rkGet res "error" "?"))))
    (t
      (rkGuiSet 'rk_gePower (rk_guiSuppliesText (rkGet res "supplies.power")))
      (rkGuiSet 'rk_geGround (rk_guiSuppliesText (rkGet res "supplies.ground")))
      (when (and (rk_guiBlank (rkGuiGet 'rk_geDspf)) (rkGet res "dspf_candidates"))
        (rkGuiSet 'rk_geDspf (rk_guiPathOf (car (rkGet res "dspf_candidates")))))
      (when (and (rk_guiBlank (rkGuiGet 'rk_geGds)) (rkGet res "gds_candidates"))
        (rkGuiSet 'rk_geGds (rk_guiPathOf (car (rkGet res "gds_candidates")))))
      (rk_guiPageSay "emir"
                     (sprintf nil "supplies filled from %d DUT port(s)%s" (length (rkGet res "dut_ports"))
                              (if (rkGet res "unresolved")
                                (sprintf nil "; no voltage for %s -- type NET=V" (rk_guiJoin (rkGet res "unresolved") " "))
                                "")))))
  t)

; ---------------------------------------------------------------------------
; Runs page
; ---------------------------------------------------------------------------

(defun rk_guiRunsArgs ()
  (let ((args (list "list")) v)
    (setq v (rkGuiGet 'rk_grType))
    (when (member v (list "aging" "deos" "emir")) (setq args (append args (list "--type" v))))
    (setq v (rk_guiNullIfBlank (rkGuiGet 'rk_grTest)))
    (when v (setq args (append args (list "--test" v))))
    (setq v (rk_guiNullIfBlank (rkGuiGet 'rk_grSince)))
    (when v (setq args (append args (list "--since" v))))
    (setq v (rk_guiNullIfBlank (rkGuiGet 'rk_grUntil)))
    (when v (setq args (append args (list "--until" v))))
    (when (rkGuiGet 'rk_grAll) (setq args (append args (list "--all"))))
    args))

(unless (boundp 'rk_guiResume) (setq rk_guiResume nil))

; resume = also follow / show the newest run of each type (panel open)
(defun rk_guiRunsRefresh (resume)
  (cond
    ((null rk_guiCtx) nil)
    (t
      (when resume (setq rk_guiResume t))
      (rkIpcRun "runs" (rkIpcNewCtxFile rk_guiCtx "runs") (rkIpcNewOutFile "runs_list") 'rk_guiRunsListed
                (if resume (list "list") (rk_guiRunsArgs)) 120))))

(defun rk_guiRunsRefreshCB () (rk_guiRunsRefresh nil))

(defun rk_guiRunsRow (r i)
  (let ((pass (arrayref r "pass")))
    (list (sprintf nil "%d" i)
          (rk_guiStr (rkGet r "id")) (rk_guiStr (rkGet r "type")) (rk_guiStr (rkGet r "test"))
          (rk_guiStr (rkGet r "dut")) (rk_guiStr (rkGet r "n_corners")) (rk_guiStr (rkGet r "life"))
          (rk_guiStr (rkGet r "state"))
          (cond ((eq pass t) "Pass") ((eq pass rkJsonFalse) "Fail") (t ""))
          (rk_guiStr (rkGet r "key_metric")) (rk_guiStr (rkGet r "note"))
          (rk_guiJoin (rkGet r "tags") ",")
          (if (eq (rkGet r "raw_data_present") rkJsonFalse) "cleaned" "present"))))

(defun rk_guiRunsListed (res)
  (let (r rows (i 0) resume)
    (setq resume rk_guiResume)
    (setq rk_guiResume nil)
    (cond
      ((not (eq (rkGet res "ok") t))
        (rkGuiSet 'rk_grStatus (sprintf nil "runs list failed: %s" (rkGet res "error" "?"))))
      (t
        ; re-read with JSON false kept, so pass:false shows "Fail"
        (setq r (errset (rkJsonReadKeepFalse (rkGet res "_out")) nil))
        (setq rk_guiRunsRows (rkGet (if r (car r) res) "runs"))
        (foreach row rk_guiRunsRows
          (setq rows (cons (rk_guiRunsRow row i) rows))
          (setq i (add1 i)))
        (rk_guiSetChoices 'rk_grList (reverse rows))
        ; the count has its own field: rk_grStatus keeps the last action's message
        (rkGuiSet 'rk_grCount (sprintf nil "%d run(s)" (length rows)))
        (when (rk_guiL (rkGet res "warnings"))
          (rkGuiSet 'rk_grStatus (strcat "runs list: " (rk_guiJoin (rk_guiL (rkGet res "warnings")) "; "))))
        (when resume (rk_guiResumeRuns))))
    t))

; Newest run of each type: follow it if active, else show its results.
(defun rk_guiResumeRuns ()
  (foreach type rk_guiTypes
    (let ((row (car (setof r rk_guiRunsRows (equal (rkGet r "type") type)))) d)
      (when (and row (null (arrayref rk_guiRunDir type)))
        (setq d (rkGet row "run_dir"))
        (cond
          ((not (rk_guiIsFinal (rkGet row "state")))
            (rk_guiFollowRun type d))
          (t
            (setarray rk_guiRunDir type d)
            (rkGuiSet (rk_guiTF type "Status")
                      (sprintf nil "last run %s: %s" (rkGet row "id") (rkGet row "state")))
            (when (equal (rkGet row "state") "done") (rk_guiLoadResults type d))
            ; an EMIR run that stopped at LVS: offer its runset again
            (when (and (equal type "emir") (equal (rkGet row "state") "lvs_failed"))
              (let ((run (rk_guiReadRun d)) (st (rkMakeObj)))
                (when run
                  (rkPut st "run_id" (rkGet run "id"))
                  (rkPut st "state" (rkGet run "state"))
                  (rkPut st "extract" (rkGet run "extract"))
                  (rk_guiRunExtractInfo st)))))))))
  t)

(defun rk_guiRunsSel ()
  (let (out)
    (foreach i (rk_guiSelectedIdx 'rk_grList)
      (when (nth i rk_guiRunsRows) (setq out (cons (nth i rk_guiRunsRows) out))))
    (reverse out)))

(defun rk_guiRunsOne ()
  (let ((sel (rk_guiRunsSel)))
    (unless sel (rkGuiSet 'rk_grStatus "select a run first"))
    (car sel)))

; single-click: note/tags of the run into the edit fields
(defun rk_guiRunsSelCB (field items)
  (let ((r (and (not rk_guiMute) (rk_guiRunsOne))))
    (when r
      (rkGuiSet 'rk_grNote (rk_guiStr (rkGet r "note")))
      (rkGuiSet 'rk_grTags (rk_guiJoin (rkGet r "tags") ",")))
    t))

(defun rk_guiRunsResultsCB ()
  (let ((r (rk_guiRunsOne)) p)
    (when r
      (setq p (rkPathJoin (rkGet r "run_dir") "summary.json"))
      (cond
        ((isFile p)
          (rkResultsShowTable (sprintf nil "%s results" (rkGet r "id")) p (rk_guiJumpCtx) rk_guiNoDisplay))
        (t (rkGuiSet 'rk_grStatus (sprintf nil "%s has no results (state %s)" (rkGet r "id") (rkGet r "state"))))))))

(defun rk_guiRunsOfficialCB ()
  (let ((r (rk_guiRunsOne))) (when r (rk_guiOpenReport (rkGet r "run_dir") "official"))))

(defun rk_guiRunsAuxCB ()
  (let ((r (rk_guiRunsOne))) (when r (rk_guiOpenReport (rkGet r "run_dir") "aux"))))

(defun rk_guiRunsWorkDirCB ()
  (let ((r (rk_guiRunsOne)) run)
    (when r
      (setq run (rk_guiReadRun (rkGet r "run_dir")))
      (rk_guiOpenDir (and run (rkGet run "work_dir"))))))

(defun rk_guiRunsStatusCB ()
  (let ((r (rk_guiRunsOne)))
    (when r
      (rkIpcRun "status" nil (rkIpcNewOutFile "runs_status") 'rk_guiRunsStatusDone
                (list "--run" (rkGet r "run_dir")) 60))))

(defun rk_guiRunsStatusDone (res)
  (rkGuiSet 'rk_grStatus (if (eq (rkGet res "ok") t) (rk_guiStatusText res)
                           (sprintf nil "status failed: %s" (rkGet res "error" "?"))))
  (rk_guiRunsRefresh nil)
  t)

(defun rk_guiRunsCancelCB ()
  (let ((r (rk_guiRunsOne)))
    (when r
      (rkIpcRun "cancel" nil (rkIpcNewOutFile "runs_cancel") 'rk_guiRunsStatusDone
                (list "--run" (rkGet r "run_dir")) 60))))

(defun rk_guiRunsNoteCB ()
  (let ((r (rk_guiRunsOne)))
    (when r
      (rkIpcRun "runs" (rkIpcNewCtxFile rk_guiCtx "runs_note") (rkIpcNewOutFile "runs_note") 'rk_guiRunsNoted
                (list "note" "--run" (rkGet r "run_dir") "--note" (or (rkGuiGet 'rk_grNote) "")
                      "--tags" (or (rkGuiGet 'rk_grTags) ""))
                60))))

(defun rk_guiRunsNoted (res)
  (rkGuiSet 'rk_grStatus (if (eq (rkGet res "ok") t) (sprintf nil "note saved for %s" (rkGet res "run_id"))
                           (sprintf nil "note failed: %s" (rkGet res "error" "?"))))
  (rk_guiRunsRefresh nil)
  t)

; Delete needs two clicks on the same run within 15 s (no modal dialog).
(defun rk_guiRunsDeleteCB ()
  (let ((r (rk_guiRunsOne)) now)
    (when r
      (setq now (rkTimestamp))
      (cond
        ((and rk_guiDelArm (equal (car rk_guiDelArm) (rkGet r "run_dir"))
              (rk_guiWithin (cadr rk_guiDelArm) 15))
          (setq rk_guiDelArm nil)
          (rkIpcRun "runs" (rkIpcNewCtxFile rk_guiCtx "runs_delete") (rkIpcNewOutFile "runs_delete")
                    'rk_guiRunsDeleted (list "delete" "--run" (rkGet r "run_dir")) 60))
        (t
          (setq rk_guiDelArm (list (rkGet r "run_dir") (rk_guiEpoch)))
          (rkGuiSet 'rk_grStatus (sprintf nil "press [Delete record] again within 15 s to delete the record of %s (Work_Dir is not touched)"
                                          (rkGet r "id"))))))))

(defun rk_guiEpoch ()
  (let ((p (parseString (rkTimestamp) "-")) hms)
    (setq hms (cadr p))
    (plus (times 86400 (atoi (substring (car p) 7 2)))
          (times 3600 (atoi (substring hms 1 2))) (times 60 (atoi (substring hms 3 2)))
          (atoi (substring hms 5 2)))))

(defun rk_guiWithin (t0 secs)
  (let ((d (difference (rk_guiEpoch) t0)))
    (and (geqp d 0) (leqp d secs))))

(defun rk_guiRunsDeleted (res)
  (rkGuiSet 'rk_grStatus (if (eq (rkGet res "ok") t) (sprintf nil "deleted record %s" (rk_guiStr (rkGet res "deleted")))
                           (sprintf nil "delete failed: %s" (rkGet res "error" "?"))))
  (rk_guiRunsRefresh nil)
  t)

(defun rk_guiRunsCompareCB ()
  (let ((sel (rk_guiRunsSel)))
    (cond
      ((nequal (length sel) 2) (rkGuiSet 'rk_grStatus "select exactly two runs to compare"))
      (t
        (rkIpcRun "runs" (rkIpcNewCtxFile rk_guiCtx "runs_compare") (rkIpcNewOutFile "runs_compare")
                  'rk_guiRunsCompared
                  (list "compare" "--run" (rkGet (car sel) "run_dir") "--run2" (rkGet (cadr sel) "run_dir"))
                  120)))))

(defun rk_guiRunsCompared (res)
  (let (n)
    (cond
      ((not (eq (rkGet res "ok") t))
        (rkGuiSet 'rk_grStatus (sprintf nil "compare failed: %s" (rkGet res "error" "?"))))
      (t
        (setq n (length (setof c (rkGet res "conditions") (not (eq (rkGet c "same") t)))))
        (rkGuiSet 'rk_grStatus (sprintf nil "compare %s vs %s: %d condition(s) differ, %d metric row(s)"
                                        (rk_guiStr (rkGet res "a.id")) (rk_guiStr (rkGet res "b.id")) n
                                        (length (rkGet res "metrics"))))
        (when (and (stringp (rkGet res "conditions_table_path")) (isFile (rkGet res "conditions_table_path")))
          (rkResultsShowTable "compare: conditions" (rkGet res "conditions_table_path") (rk_guiJumpCtx) rk_guiNoDisplay))
        (when (and (stringp (rkGet res "table_path")) (isFile (rkGet res "table_path")))
          (rkResultsShowTable "compare: metrics" (rkGet res "table_path") (rk_guiJumpCtx) rk_guiNoDisplay))))
    t))

; [Rerun with these settings]: fill the panel from run.json (nothing submitted)
(defun rk_guiRunsRerunCB ()
  (let ((r (rk_guiRunsOne)))
    (when r
      (rkIpcRun "runs" (rkIpcNewCtxFile rk_guiCtx "runs_rerun") (rkIpcNewOutFile "runs_rerun") 'rk_guiRunsRerunFill
                (list "settings-for-rerun" "--run" (rkGet r "run_dir")) 60))))

(defun rk_guiRunsRerunFill (res)
  (let (type test missing dut r)
    (cond
      ((not (eq (rkGet res "ok") t))
        (rkGuiSet 'rk_grStatus (sprintf nil "rerun settings failed: %s" (rkGet res "error" "?"))))
      (t
        (setq r (errset (rkJsonReadKeepFalse (rkGet res "_out")) nil))
        (when r (setq res (car r)))
        (setq type (rkGet res "run_type"))
        (setq test (rkGet res "test"))
        (when (and (stringp test) rk_guiCtx (nequal test (rkGet rk_guiCtx "test"))
                   (member test (rk_guiL (rkGet rk_guiCtx "tests"))))
          (rk_guiLoad rk_guiSess test nil))
        (setq dut (rkGet res "dut"))
        (when (tablep dut) (rk_guiSetDut dut t))
        (when (stringp (rkGet res "ip_name")) (rkGuiSet 'rk_gIp (rkGet res "ip_name")))
        (setq missing (rk_guiSelectCorners (rk_guiL (rkGet res "corners"))))
        (rk_guiFillPage type (rkGet res "settings"))
        (when (equal type "emir") (rk_guiFillPage "extract" (rkGet res "settings")))
        (when (member type rk_guiTypes)
          (rkGuiSet 'rk_gTabs (add1 (rk_guiIndexOf type rk_guiTypes))))
        (rk_guiSay (sprintf nil "panel filled from %s (%s): review and press Submit%s"
                            (rkGet res "run_id") type
                            (if missing (sprintf nil "; corners no longer in Maestro: %s" (rk_guiJoin missing " ")) "")))
        (rkGuiSet 'rk_grStatus rk_guiMsg)))
    t))

; ---------------------------------------------------------------------------
; EMIR page: automatic DSPF/GDS (own files only behind the check box)
; ---------------------------------------------------------------------------

(defun rk_guiOwnCB ()
  (let ((own (and (rkGuiGet 'rk_geOwn) t)))
    (foreach sym (list 'rk_geDspf 'rk_geGds 'rk_geBDetect) (rk_guiEnable sym own))
    (cond
      (own (rkGuiSet 'rk_geAuto "own files: the DSPF / GDS below are used as they are (no extraction)"))
      ((not rk_guiMute) (rk_guiCheckFresh)))
    t))

; extract-check (async): are <artifact_root>/<DUT>/<DUT>.dspf/.gds fresh?
(defun rk_guiCheckFresh ()
  (let (out)
    (cond
      ((or (null rk_guiForm) rk_guiClosed (null rk_guiCtx)) nil)
      ((rkGuiGet 'rk_geOwn) nil)
      ((null rk_guiDut) (rkGuiSet 'rk_geAuto "auto: choose the DUT first"))
      (t
        (setq out (rkIpcNewOutFile "fresh"))
        (setq rk_guiFreshOut out)
        (rkIpcRun "extract-check" (rkIpcNewCtxFile (rkGuiRunCtx "emir") "fresh") out
                  'rk_guiFreshDone nil 60)))))

(defun rk_guiFreshDone (res)
  (let ((state (rkGet res "state")) (why (car (rk_guiL (rkGet res "reasons")))) n)
    (cond
      ((nequal (rkGet res "_out") rk_guiFreshOut) nil)     ; superseded
      ((rkGuiGet 'rk_geOwn) nil)
      ((not (eq (rkGet res "ok") t))
        (setq rk_guiFresh nil)
        (rkGuiSet 'rk_geAuto (sprintf nil "auto: check failed: %s" (rkGet res "error" "?"))))
      (t
        (setq rk_guiFresh res)
        (setq n (length (rk_guiL (rkGet res "reasons"))))
        (rkGuiSet 'rk_geDspf (rk_guiStr (rkGet res "dspf")))
        (rkGuiSet 'rk_geGds (rk_guiStr (rkGet res "gds")))
        (rkGuiSet 'rk_geAuto
                  (cond
                    ((equal state "fresh")
                      (sprintf nil "auto: FRESH (extracted %s) -- Submit EMIR reuses them" (rk_guiStr (rkGet res "extracted"))))
                    ((equal state "missing") "auto: MISSING -- Submit EMIR extracts them first")
                    ((equal state "stale")
                      (sprintf nil "auto: STALE (%s%s) -- Submit EMIR re-extracts" (rk_guiStr why)
                               (if (greaterp n 1) (sprintf nil "; +%d more" (sub1 n)) "")))
                    ((equal state "running") "auto: an extraction is running")
                    (t "auto: cannot extract here (environment) -- see the Extract line")))))
    t))

; ---------------------------------------------------------------------------
; Context menus (right-click) on the run tables -- skuiref "Creating Context
; Menus for Fields": field->hiContextMenu = a hiCreateSimpleMenu menu. The
; items act on the run of the page (results tables) or on the selected row
; (Runs page).
; ---------------------------------------------------------------------------

(setq rk_guiCtxItems (list "Show progress" "Refresh status" "Open log" "Open Work_Dir" "Cancel run"))
(setq rk_guiCtxActions (list "progress" "status" "log" "workdir" "cancel"))

(defun rk_guiCtxMenu (where)
  (let ((sym (stringToSymbol (strcat "rk_guiCtxMenu_" where))))
    (unless (and (boundp sym) (symeval sym))
      (set sym (hiCreateSimpleMenu sym "Run"
                                   rk_guiCtxItems
                                   (mapcar (lambda (a) (sprintf nil "(rk_guiCtxMenuCB %L %L)" where a))
                                           rk_guiCtxActions))))
    (symeval sym)))

(defun rk_guiSetCtxMenu (sym menu)
  (let ((f (rkGuiField sym)))
    (when (and f menu)
      (putprop f menu 'hiContextMenu)
      (eq (get f 'hiContextMenu) menu))))

(defun rk_guiAttachMenus ()
  (let ((ok t))
    (unless (rk_guiSetCtxMenu 'rk_grList (rk_guiCtxMenu "runs")) (setq ok nil))
    (foreach type rk_guiTypes
      (unless (rk_guiSetCtxMenu (rk_guiTF type "Res") (rk_guiCtxMenu type)) (setq ok nil)))
    (unless ok (printf "[relkit] could not attach the run context menus\n"))
    ok))

; run dir a context-menu action applies to
(defun rk_guiCtxRunDir (where)
  (if (equal where "runs")
    (let ((r (rk_guiRunsOne))) (and r (rkGet r "run_dir")))
    (arrayref rk_guiRunDir where)))

(defun rk_guiCtxMenuCB (where action)
  (let ((dir (rk_guiCtxRunDir where)) run)
    (cond
      ((null dir) (rk_guiSay (if (equal where "runs")
                               "click a run first (a right-click does not select the row), then right-click"
                               "no run on this page yet")))
      ((equal action "progress") (rkGuiShowProgress dir))
      ((member action (list "status" "cancel"))
        (rkIpcRun action nil (rkIpcNewOutFile (strcat "ctx_" action)) 'rk_guiCtxStatusDone
                  (list "--run" dir) 60))
      ((equal action "log") (rk_guiOpenRunLog dir))
      ((equal action "workdir")
        (setq run (rk_guiReadRun dir))
        (rk_guiOpenDir (and run (rkGet run "work_dir")))))
    t))

(defun rk_guiCtxStatusDone (res)
  (let ((msg (if (eq (rkGet res "ok") t)
               (if (rkGet res "jobs") (rk_guiStatusText res)
                 (sprintf nil "%s: %s" (rkGet res "run_id" "?") (rkGet res "state" "?")))
               (sprintf nil "status failed: %s" (rkGet res "error" "?")))))
    (rk_guiSay msg)
    (when rk_guiForm (rkGuiSet 'rk_grStatus msg))
    (foreach type rk_guiTypes
      (when (and (equal (rkGet res "run_dir") (arrayref rk_guiRunDir type))
                 (rkIpcPollActive (strcat "gui:run:" type)))
        (rkIpcPollNow (strcat "gui:run:" type))))
    (rk_guiRunsRefresh nil)
    t))

; The most useful log of a run: LVS report (LVS failed), extract.log (while
; extracting), the failed job's job.out, else run_relsim's own log.
(defun rk_guiOpenRunLog (runDir)
  (let ((run (rk_guiReadRun runDir)) ex cands sims hit state)
    (when run
      (setq ex (rkGet run "extract"))
      (setq state (rkGet run "state"))
      (when (and (tablep ex) (equal state "lvs_failed"))
        (setq cands (append cands (list (rkGet ex "lvs_report")))))
      (when (and (tablep ex) (stringp (rkGet ex "dir")) (member state (list "extracting" "lvs_failed" "failed")))
        (setq cands (append cands (list (rkPathJoin (rkGet ex "dir") "extract.log")))))
      (foreach j (rk_guiL (rkGet run "jobs"))
        (when (equal (rkGet j "state") "failed")
          (foreach c (rk_guiL (rkGet run "corner_map"))
            (when (and (equal (rkGet c "sim") (rkGet j "sim")) (stringp (rkGet c "sim_dir")))
              (setq sims (cons (rkPathJoin (rkGet c "sim_dir") "job.out") sims))))))
      (setq cands (append cands (reverse sims)))
      (setq cands (append cands (mapcar (lambda (n) (rkPathJoin (rkPathJoin runDir "logs") n))
                                        (list "relsim_start.log" "relsim_submit.log" "supervise.log")))))
    (foreach c cands (when (and (null hit) (stringp c) (isFile c)) (setq hit c)))
    (cond
      (hit (rkResultsOpenFile hit) (rk_guiSay (sprintf nil "opened %s" hit)) hit)
      (t (rk_guiSay "no log for this run yet") nil))))

; ---------------------------------------------------------------------------
; Progress window: per-job rows of a run (`relkit.py progress`), refreshed
; every gui.status_poll_seconds while it is open and the run is not final.
; ---------------------------------------------------------------------------

(defun rk_guiBaseName (p) (car (last (parseString (or p "") "/"))))

(defun rk_guiProgHeaders ()
  (list (list "_i" 0 'left 'string)
        (list "Stage" 60 'left 'string)
        (list "Name" 70 'left 'string)
        (list "Corner / mode" 170 'left 'string)
        (list "State" 95 'left 'string)
        (list "Job id" 70 'left 'string)
        (list "Started" 75 'left 'string)
        (list "Elapsed" 70 'right 'string)
        (list "Donau" 110 'left 'string)
        (list "Last line" 360 'left 'string)))

(defun rk_guiPageProgressCB (type)
  (let ((d (arrayref rk_guiRunDir type)))
    (if d (rkGuiShowProgress d) (rk_guiPageSay type "no run on this page yet"))))

(defun rkGuiShowProgress (runDir)
  (let (nm form)
    (rkGuiCloseProgress)
    (setq rk_guiProgCounter (add1 rk_guiProgCounter))
    (setq nm (stringToSymbol (sprintf nil "rk_prog_%d" rk_guiProgCounter)))
    (setq rk_guiProgRun runDir)
    (setq rk_guiProgRes nil)
    (setq rk_guiProgLogs nil)
    (setq rk_guiProgFails 0)
    (setq form (hiCreateAppForm
                 ?name nm
                 ?formTitle (sprintf nil "relkit progress: %s" (rk_guiBaseName runDir))
                 ?fields
                 (list
                   (list (hiCreateStringField ?name 'rk_pHead ?prompt "Run" ?value "loading..." ?editable nil)
                         (list 5 5) (list 1090 30) 50)
                   (list (hiCreateReportField ?name 'rk_pRows ?headers (rk_guiProgHeaders) ?choices nil
                                              ?selectMode 'single ?altRowHilight t
                                              ?doubleClickCB "(rk_guiProgLogCB)")
                         (list 5 40) (list 1090 300))
                   (list (hiCreateButton ?name 'rk_pBRefresh ?buttonText "Refresh now" ?callback "(rk_guiProgRefreshCB)")
                         (list 5 348) (list 110 28))
                   (list (hiCreateButton ?name 'rk_pBLog ?buttonText "Open log of the row" ?callback "(rk_guiProgLogCB)")
                         (list 120 348) (list 160 28))
                   (list (hiCreateButton ?name 'rk_pBRunLog ?buttonText "Open run log" ?callback "(rk_guiOpenRunLog rk_guiProgRun)")
                         (list 285 348) (list 110 28))
                   (list (hiCreateStringField ?name 'rk_pMsg ?prompt "" ?value "" ?editable nil)
                         (list 400 348) (list 695 30) 0))
                 ?callback (list (sprintf nil "(rk_guiProgressClosed '%s)" (symbolToString nm))
                                 (sprintf nil "(rk_guiProgressClosed '%s)" (symbolToString nm)))
                 ?buttonLayout 'Close
                 ?dialogStyle 'modeless
                 ?dontBlock t
                 ?initialSize (list 1110 435)))
    (hiInstantiateForm form)
    (setq rk_guiProgForm form)
    (rkIpcPollStart "rkprog:progress" "progress" nil (list "--run" runDir) (rk_guiPollSeconds)
                    'rk_guiProgressCB)
    (unless rk_guiNoDisplay (hiDisplayForm form))
    form))

(defun rk_guiProgAlive ()
  (and rk_guiProgForm (or rk_guiNoDisplay (hiIsFormDisplayed rk_guiProgForm)) t))

(defun rk_guiProgSet (sym v)
  (let ((f (and rk_guiProgForm (get rk_guiProgForm sym))))
    (when f (putprop f v (if (eq sym 'rk_pRows) 'choices 'value)))
    v))

(defun rk_guiHms (iso)
  (if (and (stringp iso) (geqp (strlen iso) 19)) (substring iso 12 8) (rk_guiStr iso)))

(defun rk_guiProgFill (res)
  (let ((i 0) rows logs)
    (foreach r (rk_guiL (rkGet res "rows"))
      (setq rows (cons (list (sprintf nil "%d" i)
                             (rk_guiStr (rkGet r "stage")) (rk_guiStr (rkGet r "name"))
                             (rk_guiJoin (setof x (list (rkGet r "corner") (rkGet r "mode"))
                                               (and (stringp x) (nequal x "")))
                                         " / ")
                             (rk_guiStr (rkGet r "state")) (rk_guiStr (rkGet r "job_id"))
                             (rk_guiHms (rkGet r "started")) (rk_guiStr (rkGet r "elapsed"))
                             (rk_guiStr (rkGet r "donau")) (rk_guiStr (rkGet r "last")))
                       rows))
      (setq logs (cons (rkGet r "log") logs))
      (setq i (add1 i)))
    (setq rk_guiProgLogs (reverse logs))
    (rk_guiProgSet 'rk_pRows (reverse rows))
    (rk_guiProgSet 'rk_pHead (sprintf nil "%s  (%s)  %s since %s%s" (rk_guiStr (rkGet res "run_id"))
                                      (rk_guiStr (rkGet res "type")) (rk_guiStr (rkGet res "state"))
                                      (rk_guiHms (rkGet res "state_since"))
                                      (if (eq (rkGet res "final") t) "  -- final" "")))
    (rk_guiProgSet 'rk_pMsg (sprintf nil "%s  [updated %s]" (rk_guiStr (rkGet res "message"))
                                     (rk_guiHms (rkGet res "now"))))
    i))

; poll result -> t to keep polling (window open and run not final)
(defun rk_guiProgressCB (res)
  (cond
    ((not (rk_guiProgAlive)) nil)
    ((not (eq (rkGet res "ok") t))
      (setq rk_guiProgFails (add1 rk_guiProgFails))
      (rk_guiProgSet 'rk_pMsg (sprintf nil "progress failed: %s" (rkGet res "error" "?")))
      (lessp rk_guiProgFails rk_guiPollMaxFails))
    (t
      (setq rk_guiProgFails 0)
      (setq rk_guiProgRes res)
      (rk_guiProgFill res)
      (not (eq (rkGet res "final") t)))))

(defun rk_guiProgRefreshCB ()
  (cond
    ((rkIpcPollActive "rkprog:progress") (rkIpcPollNow "rkprog:progress"))
    (rk_guiProgRun
      (rkIpcPollStart "rkprog:progress" "progress" nil (list "--run" rk_guiProgRun) (rk_guiPollSeconds)
                      'rk_guiProgressCB)))
  t)

(defun rk_guiProgLogCB ()
  (let ((f (and rk_guiProgForm (get rk_guiProgForm 'rk_pRows))) sel p)
    (setq sel (and f (car (errset (hiReportGetSelectedItems f) nil))))
    (setq sel (car (setof x (if (listp sel) sel (list sel)) (integerp x))))
    (setq p (and sel (nth sel rk_guiProgLogs)))
    (cond
      ((and (stringp p) (isFile p)) (rkResultsOpenFile p) p)
      (t (rk_guiProgSet 'rk_pMsg (if sel "this row has no log file yet" "select a row first")) nil))))

; close callback of a progress window: only the current window's close counts
(defun rk_guiProgressClosed (@optional formSym)
  (when (or (null formSym) (null rk_guiProgForm) (eq formSym rk_guiProgForm->hiFormSym))
    (rkIpcPollStop "rkprog:progress"))
  t)

(defun rkGuiCloseProgress ()
  (rkIpcPollStop "rkprog:progress")
  (when (and rk_guiProgForm (hiIsFormDisplayed rk_guiProgForm))
    (hiFormCancel rk_guiProgForm))
  (setq rk_guiProgForm nil)
  t)
