; test_wave3_smoke.il -- Headless smoke test for Wave 3 changes.
;
; Verifies the new form-construction path works WITHOUT popping any GUI
; (no hiDisplayForm). Catches:
;   - ?closeCallback rejected by hiCreateAppForm (would error during build)
;   - Wrapped progn-style ?callback strings malformed
;   - dgenGui_closeCleanupCB crashes when called with no enter-fun and
;     no active sync (it MUST be safe in this state, since OK/Cancel
;     wraps it)
;   - enterFunNestLevel baseline (must be 0 before any pick)
;
; Cannot test (require live GUI):
;   - actual button click -> enterPoint pick mode
;   - actual button click -> ddsSyncWithForm linking
;   - Esc cancel handling
;   - lifecycle teardown via real form close
;
; Run via: ws['load']('.../test_wave3_smoke.il')
; Returns: "PASS" or "FAIL: <reason>" string.

(defun dgen_wave3_smoke ()
  (let (form fields baseline cleanupRet status reasons)

  (printf "[T] === smoke test start ===\n")
  (setq reasons nil)

  ; --- 1. Baseline: no enter-function active -----------------------------

  (setq baseline (enterFunNestLevel))
  (printf "[T] enterFunNestLevel baseline = %d\n" baseline)
  (unless (zerop baseline)
    (setq reasons (cons (sprintf nil "baseline enterFunNestLevel=%d (expected 0)" baseline) reasons)))

  ; --- 2. Build no-DUT form (top section only, no display) --------------

  (when (boundp 'dgen_currentDutLib)  (setq dgen_currentDutLib  nil))
  (when (boundp 'dgen_currentDutCell) (setq dgen_currentDutCell nil))
  (when (boundp 'dgen_currentDutView) (setq dgen_currentDutView nil))
  (setq dgen_currentPins nil)

  (setq fields (car (dgen_buildTopFields "" "" "" 0 25)))
  (printf "[T] dgen_buildTopFields produced %d fields\n" (length fields))
  (unless (equal (length fields) 6)
    (setq reasons (cons (sprintf nil "expected 6 top fields (3 combos + 3 buttons), got %d" (length fields)) reasons)))

  ; Construct the form with the SAME ?callback wiring the production
  ; dgenOpenGUI uses. OK/Cancel callbacks wrap dgenGui_closeCleanupCB
  ; via progn so cleanup runs before the form goes away. (?closeCallback
  ; is NOT a valid hiCreateAppForm keyword in IC6.1.8 -- caught by an
  ; earlier smoke iteration. hiRegCloseProc would catch the X-button
  ; close path but it requires a window object that hiCreateAppForm
  ; doesn't expose -- so we accept that X-close skips cleanup, with
  ; defensive boundp guards in the doneProc handling that case.)

  (setq form (errset
               (hiCreateAppForm
                 ?name 'dgen_form
                 ?formTitle "Dreg Generator -- WAVE3 SMOKE (not displayed)"
                 ?fields fields
                 ?callback (list "(progn (dgenGui_closeCleanupCB dgen_form) (dgenGui_okCB dgen_form))"
                                 "(progn (dgenGui_closeCleanupCB dgen_form) (dgenGui_cancelCB dgen_form))")
                 ?buttonLayout 'OKCancelDefApply)
               t))

  (cond
    ((null form)
      (setq reasons (cons "hiCreateAppForm errset returned nil (build crashed)" reasons))
      (printf "[T] FAIL: hiCreateAppForm errsetted -- check CIW\n"))
    ((null (car form))
      (setq reasons (cons "hiCreateAppForm returned nil (rejected args)" reasons))
      (printf "[T] FAIL: hiCreateAppForm returned nil -- ?closeCallback rejected?\n"))
    (t
      (setq form (car form))
      (printf "[T] form built OK -- ?callback progn-wrap strings parsed\n")
      (hiInstantiateForm form)

      ; --- 3. dgenGui_closeCleanupCB on idle state ---------------------

      (setq cleanupRet (errset (dgenGui_closeCleanupCB form) t))
      (cond
        ((null cleanupRet)
          (setq reasons (cons "dgenGui_closeCleanupCB errsetted on idle state" reasons))
          (printf "[T] FAIL: cleanup CB on idle errsetted\n"))
        ((null (car cleanupRet))
          (setq reasons (cons "dgenGui_closeCleanupCB returned nil on idle state" reasons))
          (printf "[T] FAIL: cleanup CB returned nil\n"))
        (t
          (printf "[T] cleanup CB returned %L on idle (expected t)\n" (car cleanupRet))))

      ; Idempotency: call again -- must still be safe.
      (setq cleanupRet (errset (dgenGui_closeCleanupCB form) t))
      (cond
        ((null cleanupRet)
          (setq reasons (cons "dgenGui_closeCleanupCB second call errsetted" reasons))
          (printf "[T] FAIL: cleanup CB second call errsetted\n"))
        (t
          (printf "[T] cleanup CB idempotent (second call returned %L)\n" (car cleanupRet))))

      ; --- 4. Verify enterFunNestLevel still 0 after cleanup -----------

      (unless (zerop (enterFunNestLevel))
        (setq reasons (cons (sprintf nil "enterFunNestLevel=%d after cleanup (expected 0)" (enterFunNestLevel)) reasons))
        (printf "[T] FAIL: cleanup left enter-fun active\n"))

      ; --- 5. Force-cancel form (also exercises closeCallback path) -----

      (errset (hiFormCancel form) t)
      (printf "[T] form cancelled\n")))

  ; --- Final status -------------------------------------------------------

  (setq status
    (cond
      ((null reasons) "PASS")
      (t (strcat "FAIL: " (buildString (reverse reasons) " | ")))))
  (printf "[T] === %s ===\n" status)
  status))
