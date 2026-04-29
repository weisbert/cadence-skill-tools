; test_step5_auto.il -- Automated end-to-end smoke test for dgenGui.il.
; Bypasses hiDisplayForm and hiDisplayAppDBox so nothing pops up and the
; skillbridge evaluator isn't trapped in a modal display loop. Replicates
; the OK-callback's data path inline (read form -> dgenRun -> save state).
;
; Prints diagnostics via printf (visible in CIW) and returns a final
; status string.
;
; Run via: ws['load']('.../test_step5_auto.il')

(let (pins factorySpec currentSpec fields form spec ok
      tgtBefore tgtAfterLastState modeRecLit modeRecVar
      defField0 enabledLit enabledVar lastSaved status)

  ; --- Setup ---------------------------------------------------------------

  (setq pins (dgenScanPins "sim_yusheng" "Test_cell" "symbol"))
  (printf "[T] scanned %d pins from sim_yusheng/Test_cell\n" (length pins))

  (setq dgen_currentPins pins)
  (setq dgen_currentDutCell "Test_cell")

  (setq factorySpec (list nil
    'source         (list nil 'lib "sim_yusheng" 'cell "Test_cell" 'view "symbol")
    'target         (list nil 'lib "sim_yusheng" 'cell "dreg_Test_cell" 'view "veriloga")
    'dvddDefault    "0.9"
    'defaultMode    "literal"
    'defaultPattern "*_ls"
    'pins           pins))

  ; Resolve current spec from any existing last-state. This exercises the
  ; targetCellTpl substitution path on every run after the first.
  (setq currentSpec (dgen_resolveCurrentSpec factorySpec (dgenLoadLastState) "Test_cell"))
  (setq tgtBefore        (get (get factorySpec 'target) 'cell))
  (setq tgtAfterLastState (get (get currentSpec 'target) 'cell))
  (printf "[T] factory target cell : %s\n" tgtBefore)
  (printf "[T] resolved target cell: %s  (last-state %s)\n"
    tgtAfterLastState
    (cond ((equal tgtBefore tgtAfterLastState) "absent or matches factory") (t "applied")))

  ; --- Build form (no display) ---------------------------------------------

  (setq fields (dgen_buildFields factorySpec currentSpec))
  (setq form
    (hiCreateAppForm
      ?name 'dgen_form
      ?formTitle "Dreg Generator -- AUTOTEST (not displayed)"
      ?fields fields
      ?callback (list "(dgenGui_okCB dgen_form)" "(dgenGui_cancelCB dgen_form)")
      ?buttonLayout 'OKCancelDefApply))
  (printf "[T] form constructed (not displayed). field count=%d\n" (length fields))

  ; --- Test 1: mode-change callback toggles per-pin field enabled --------

  ; Initial state under "literal" -- per-pin value field 0 should be enabled.
  (setq defField0 (get dgen_form (dgen_pinDefaultId 0)))
  (setq enabledLit defField0->enabled)

  ; Switch mode to "variable" via the same callback the UI fires.
  ; Callback signature: (field scope item) per skuiref.pdf p.538.
  (dgenGui_modeCB dgen_form->dgen_mode 'autotest "variable")
  (setq enabledVar defField0->enabled)

  ; Switch back to "literal" -- should re-enable.
  (dgenGui_modeCB dgen_form->dgen_mode 'autotest "literal")
  (setq modeRecLit defField0->enabled)

  (printf "[T] pin-value field enabled: literal=%L variable=%L back-to-literal=%L\n"
    enabledLit enabledVar modeRecLit)

  ; --- Test 2: programmatic field write + OK-callback data path -----------

  ; Slot writes via SKILL infix `=` -- routed through evalstring because
  ; raw infix lines don't parse cleanly inside a Lisp-form let body.
  (evalstring "dgen_form->dgen_tgtCell->value = \"dreg_Test_cell_step5_auto\"")
  (evalstring "dgen_form->dgen_dvdd->value    = \"0.9\"")
  (evalstring "dgen_form->dgen_mode->value    = \"literal\"")

  (printf "[T] set tgtCell=dreg_Test_cell_step5_auto, dvdd=0.9, mode=literal\n")

  ; Read the form back into a spec, then run the same path the OK callback
  ; runs minus the popup. errset wraps dgenRun so an error doesn't abort
  ; the test.
  (setq spec (dgen_readForm dgen_form dgen_currentPins))
  (setq ok (errset (dgenRun spec) t))
  (cond
    ((and ok (car ok))
      (printf "[T] dgenRun succeeded\n")
      (errset (dgenSaveLastState (dgen_specToLastState spec dgen_currentDutCell)) t)
      (setq lastSaved t))
    (t
      (printf "[T] dgenRun FAILED (errset returned nil) -- check CIW log\n")
      (setq lastSaved nil)))

  ; --- Cleanup: dismiss form (frees the global symbol for next test) ------

  ; hiFormCancel takes the form RECORD (returned by hiCreateAppForm), not
  ; the form's name symbol. The local var `form` holds the record.
  (hiFormCancel form)

  ; --- Final status --------------------------------------------------------

  (setq status
    (cond
      ((null (and (equal enabledLit t) (null enabledVar) (equal modeRecLit t)))
        "FAIL: mode-callback enable toggle not working as expected")
      ((null lastSaved)
        "FAIL: dgenRun or last-state save")
      (t "PASS")))
  (printf "[T] === %s ===\n" status)
  status)
