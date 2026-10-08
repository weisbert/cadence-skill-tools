; dgenTimingGui.il -- the [Timing Table...] editor of the Dreg Generator.
;
; One modeless form for every timed signal of the dreg being edited:
;
;   +-------------------------------------------------------------+
;   | Signal       Time    Edge    After      Type                |  report
;   | EN           0       -       0 (init)   1-bit               |  (read-
;   | EN           5n      50p     1          1-bit               |   only,
;   | EN           50n     100p    0          1-bit               |   click
;   | N_ctrl<3:0>  30n     50p     10         bus<3:0>            |   a row
;   | VDD [A]      0       10u     1.8        analog              |   to
;   +-------------------------------------------------------------+   edit)
;   View   [By signal|By time]
;   Signal [EN v]   Time [5n]   Edge [50p]   Value [--]
;   [Add] [Update] [Delete]
;   File [...........] [Browse] [Import] [Export]
;   Status: ...
;
; WHY a report + edit row. hiCreateReportField (skuiref p.624) is the
; multi-column table IC6.1.8 offers, but its cells are not editable, so
; the classic Virtuoso pattern applies: select a row -> it fills the edit
; row -> Add / Update / Delete. Refreshing the table only rewrites
; ->choices, so no close-reopen (none of the main form's rebuild flicker).
;
; VARIABLES. Any identifier typed in a Time / Edge / Value cell is a
; variable -- alone or in sums ("T_1", "T_1+70n", "VDDH-0.1") -- and
; becomes an ADE / Maestro design variable (CDF tv_<NAME> = <NAME>, picked
; up by Copy From Cellview). Nothing is declared up front. Ordering needs
; numbers, so variables may get optional TABLE VALUES: switching to By
; time asks for the Time-cell ones that have none ([Variable values...]
; reopens the dialog); unset ones sort as 0, i.e. first. Cells show
; "T_1+70n = 120n" once all their variables have values.

; 1-BIT SIGNALS TOGGLE. For a 1-bit digital signal the user enters only
; time + edge; the Value box is greyed out and the "After" column shows the
; resulting level (computed from the initial level = the main form's value
; column, or the design-variable name in variable modes: EN / !EN). Buses
; and analog signals need an explicit new value.
;
; DATA FLOW. On open, the editor snapshots the main form (dgen_readForm)
; to learn the enabled signals, their kinds and initial values, and copies
; dgen_currentTiming into a working list. OK validates and commits the
; working list back to dgen_currentTiming + refreshes the main form's
; per-row summaries in place. Cancel discards. The timing reaches disk
; only when the main form generates (OK / Apply / Save As), where it is
; baked into the .va and stored in the dreg's embedded config.

(unless (boundp 'dgenTim_form)        (setq dgenTim_form        nil))
(unless (boundp 'dgenTim_rows)        (setq dgenTim_rows        nil)) ; working rows
(unless (boundp 'dgenTim_items)       (setq dgenTim_items       nil)) ; emit items snapshot
(unless (boundp 'dgenTim_labels)      (setq dgenTim_labels      nil)) ; cyclic labels || items
(unless (boundp 'dgenTim_spec)        (setq dgenTim_spec        nil)) ; spec snapshot
(unless (boundp 'dgenTim_rowMap)      (setq dgenTim_rowMap      nil)) ; report idx -> row idx | nil
(unless (boundp 'dgenTim_order)       (setq dgenTim_order       "By signal"))
(unless (boundp 'dgenTim_tmpVal)      (setq dgenTim_tmpVal      nil))
(unless (boundp 'dgenTim_varVals)     (setq dgenTim_varVals     nil)) ; variable table values
(unless (boundp 'dgenTim_askedVars)   (setq dgenTim_askedVars   nil)) ; shown in the values dialog

; ---------------------------------------------------------------------------
; Small helpers
; ---------------------------------------------------------------------------

; Write ->slot of a field on the editor form. The arrow chain only parses
; with literal symbols, so stage the value in a global and evalstring the
; infix assignment (same trick as dgen_setFieldValue for the main form).
(defun dgenTim_setSlot (fieldSym slot val "ssg")
  (when (and dgenTim_form (get dgenTim_form fieldSym))
    (setq dgenTim_tmpVal val)
    (errset
      (evalstring (sprintf nil "dgenTim_form->%s->%s = dgenTim_tmpVal"
                    (symbolToString fieldSym) (symbolToString slot)))
      t)
    t))

(defun dgenTim_set (fieldSym val "sg")
  (dgenTim_setSlot fieldSym 'value val))

(defun dgenTim_status (msg "t")
  (dgenTim_set 'dgenTim_statusF msg))

; Table values of variables ((nil 'name "T_1" 'default "5n") ...) being
; edited -- ordering only; committed to dgen_currentTimingVars on OK.
(defun dgenTim_vars ()
  dgenTim_varVals)

; Raw (as typed) table value of `name`, or "".
(defun dgenTim_varText (name "t")
  (let ((v (car (setof x dgenTim_varVals (equal (get x 'name) name)))))
    (or (and v (get v 'default)) "")))

; Time-cell variables that have no table value yet.
(defun dgenTim_unsetTimeVars ()
  (setof nm (dgen_tmTimeVarNames dgenTim_rows)
    (null (dgen_tmVarDefault dgenTim_varVals nm))))

; After Add / Update in the By-time view: Time-cell variables of `row`
; that have no value and haven't been asked about yet open the values
; dialog (deferred -- not from inside the button callback). A variable
; left blank there is not asked again. Returns a status suffix or "".
(defun dgenTim_askNewTimeVars (row "g")
  (let (fresh)
    (when (and (equal dgenTim_order "By time") (not (dgen_tmInitP row)))
      (setq fresh (setof nm (dgen_tmExprVars (dgen_tmExprNorm (get row 'time) "time"))
                    (and (null (dgen_tmVarDefault dgenTim_varVals nm))
                         (not (member nm dgenTim_askedVars))))))
    (cond
      (fresh
        (hiRegTimer "(dgenTimVar_open)" 1)
        (sprintf nil " %s has no value yet -- sorted as 0 (first) unless you give one."
          (buildString fresh ", ")))
      (t ""))))

; Table values limited to variables the rows still use.
(defun dgenTim_prunedVals ()
  (let ((used (dgen_tmTimingVarNames dgenTim_rows)))
    (setof v dgenTim_varVals (member (get v 'name) used))))

; Label shown for an item in the Signal column / cyclic.
(defun dgenTim_itemLabel (item "g")
  (let ((k (dgen_tmKindOf item)))
    (cond
      ((equal k "bus")
        (sprintf nil "%s<%d:%d>" (get item 'name) (get item 'busHi) (get item 'busLo)))
      ((equal k "analog") (sprintf nil "%s [A]" (get item 'name)))
      (t (get item 'name)))))

; Item currently picked in the Signal cyclic (nil if none).
(defun dgenTim_curItem ()
  (let ((lbl (dgen_fieldVal dgenTim_form 'dgenTim_signal)) (i 0) found)
    (foreach l dgenTim_labels
      (when (and (null found) (equal l lbl)) (setq found (nth i dgenTim_items)))
      (setq i (add1 i)))
    found))

; The Value box is used by every kind (1-bit: blank = toggle, 0 / 1, a
; variable or DC). Kept as a hook for the callers.
(defun dgenTim_syncValueEnable (item "g")
  (let ((rec (get dgenTim_form 'dgenTim_value)))
    (when rec (hiSetFieldEnabled rec t))
    t))

; Default transient start value written when a signal gets its first edge.
(defun dgenTim_defaultInit () "0")

; After-column text of an init row.
(defun dgenTim_initAfter (ir startText dcStr "ggt")
  (cond
    ((or (null ir) (dgen_tmDcP (get ir 'value))) (sprintf nil "DC = %s" dcStr))
    (t startText)))

; Index of `row` (by identity) in dgenTim_rows, or nil.
(defun dgenTim_rowIndex (row "g")
  (let ((i 0) found)
    (foreach r dgenTim_rows
      (when (and (null found) (eq r row)) (setq found i))
      (setq i (add1 i)))
    found))

; ---------------------------------------------------------------------------
; Table model
; ---------------------------------------------------------------------------

; Vector parallel to dgenTim_rows holding each row's "After" string.
(defun dgenTim_afterVector ()
  (let ((vec (makeVector (max 1 (length dgenTim_rows)) "-")) rows afters vars ir dc st)
    (setq vars (dgenTim_vars))
    (foreach it dgenTim_items
      (setq rows (dgen_tmRowsFor dgenTim_rows (get it 'name) vars))
      (setq ir (dgen_tmInitRow dgenTim_rows (get it 'name)))
      (setq dc (dgen_tmInitDisplay dgenTim_spec it))
      (setq st (dgen_tmStartText it (and ir (get ir 'value)) dc vars))
      (when ir
        (setarray vec (dgenTim_rowIndex ir) (dgenTim_initAfter ir st dc)))
      (setq afters (dgen_tmAfterList it rows st dc vars))
      (foreach r rows
        (setarray vec (dgenTim_rowIndex r) (car afters))
        (setq afters (cdr afters))))
    vec))

; One report line for a working row.
; Time / Edge cells: canonical expression, "= value" when variables are
; involved; the raw text if it doesn't parse yet.
(defun dgenTim_cellText (txt vars "gg")
  (let ((c (dgen_tmExprNorm (or txt "") "time")))
    (cond (c (dgen_tmExprDisplay c vars "time")) (t (or txt "")))))

(defun dgenTim_rowLine (r afterVec @optional vars)
  (let ((item (dgen_tmFindItem dgenTim_items (get r 'signal))))
    (list
      (cond (item (dgenTim_itemLabel item)) (t (get r 'signal)))
      (cond ((dgen_tmInitP r) "init") (t (dgenTim_cellText (get r 'time) vars)))
      (cond ((dgen_tmInitP r) "-") (t (dgenTim_cellText (get r 'edge) vars)))
      (cond (item afterVec[(dgenTim_rowIndex r)])
            ((equal (or (get r 'value) "") "") "-")
            (t (get r 'value)))
      (cond (item (dgen_tmKindLabel item)) (t "(not enabled)")))))

; Rebuild report choices + dgenTim_rowMap from the working rows.
;   By signal: per timed signal (main-form order) its "init" line (the
;              transient start value) then its edges by time; rows for
;              signals that are not enabled last.
;   By time:   every row by start time (shows the cross-signal sequence).
(defun dgenTim_refresh ()
  (let (choices rowMap afterVec rows orphans vars ir)
    (setq vars (dgenTim_vars))
    (setq afterVec (dgenTim_afterVector))
    (cond
      ((equal dgenTim_order "By time")
        (foreach r (dgen_tmSortByTime dgenTim_rows vars)
          (setq choices (cons (dgenTim_rowLine r afterVec vars) choices))
          (setq rowMap  (cons (dgenTim_rowIndex r) rowMap))))
      (t
        (foreach it dgenTim_items
          (setq rows (dgen_tmRowsFor dgenTim_rows (get it 'name) vars))
          (when rows
            (setq ir (dgen_tmInitRow dgenTim_rows (get it 'name)))
            (cond
              (ir
                (setq choices (cons (dgenTim_rowLine ir afterVec vars) choices))
                (setq rowMap (cons (dgenTim_rowIndex ir) rowMap)))
              (t
                ; no init line yet (table made before init lines): starts at DC
                (setq choices (cons
                  (list (dgenTim_itemLabel it) "init" "-"
                        (sprintf nil "DC = %s" (dgen_tmInitDisplay dgenTim_spec it))
                        (dgen_tmKindLabel it))
                  choices))
                (setq rowMap (cons nil rowMap))))
            (foreach r rows
              (setq choices (cons (dgenTim_rowLine r afterVec vars) choices))
              (setq rowMap  (cons (dgenTim_rowIndex r) rowMap)))))
        (setq orphans (setof r dgenTim_rows
                        (or (null (dgen_tmFindItem dgenTim_items (get r 'signal)))
                            (and (dgen_tmInitP r)
                                 (null (dgen_tmRowsFor dgenTim_rows (get r 'signal)))))))
        (foreach r orphans
          (setq choices (cons (dgenTim_rowLine r afterVec vars) choices))
          (setq rowMap  (cons (dgenTim_rowIndex r) rowMap)))))
    (setq dgenTim_rowMap (reverse rowMap))
    (dgenTim_setSlot 'dgenTim_report 'choices (reverse choices))
    (dgenTim_setSlot 'dgenTim_summaryF 'value (dgen_tmTableSummary dgenTim_rows vars))
    t))

; Select (without firing the callback) the report line showing row index i.
(defun dgenTim_selectRow (i "g")
  (let ((k 0) found rec)
    (foreach m dgenTim_rowMap
      (when (and (null found) (equal m i)) (setq found k))
      (setq k (add1 k)))
    (setq rec (get dgenTim_form 'dgenTim_report))
    (when (and found rec) (errset (hiReportSelectItem rec found nil) t))
    t))

; Working-row index of the selected report line: an integer, 'init for an
; init line, or nil when nothing is selected.
(defun dgenTim_selectedRow ()
  (let ((sel (dgen_fieldVal dgenTim_form 'dgenTim_report)) idx)
    (cond
      ((null sel) nil)
      (t
        (setq idx (nth (car sel) dgenTim_rowMap))
        (cond ((null idx) 'init) (t idx))))))

; Is the selected report line an init line (synthesized or a real row)?
(defun dgenTim_initSelected (sel "g")
  (or (eq sel 'init)
      (and (integerp sel) (dgen_tmInitP (nth sel dgenTim_rows)))))

; Build a row from the edit boxes. Returns (row errorString). Time "init"
; (any case) makes an init row (the Edge box is ignored).
(defun dgenTim_rowFromFields ()
  (let ((item (dgenTim_curItem)) row err tm)
    (setq tm (dgen_tmTrim (or (dgen_fieldVal dgenTim_form 'dgenTim_time) "")))
    (cond
      ((null item) (list nil "Pick a signal first."))
      (t
        (setq row (dgen_tmRow (get item 'name)
                    (cond ((equal (lowerCase tm) "init") "init") (t tm))
                    (cond ((equal (lowerCase tm) "init") "")
                          (t (or (dgen_fieldVal dgenTim_form 'dgenTim_edge) "")))
                    (or (dgen_fieldVal dgenTim_form 'dgenTim_value) "")))
        (setq err (dgen_tmRowError row item (dgenTim_vars)))
        (cond
          (err (list nil (sprintf nil "%s: %s" (get item 'name) err)))
          (t (list (dgen_tmNormRow row item) nil)))))))

; Another row of the same signal at the same time (skipping index `skip`)?
; Same expression, or two plain literals with the same value. Edges that
; only coincide at the default variable values are allowed (a sweep moves
; them apart; OK warns about it).
(defun dgenTim_clashP (row skip "gg")
  (let ((ce (dgen_tmExprNorm (get row 'time) "time")) (i 0) hit cr)
    (foreach r dgenTim_rows
      (setq cr (dgen_tmExprNorm (get r 'time) "time"))
      (when (and (null hit) (nequal i skip) ce cr
                 (not (dgen_tmInitP row)) (not (dgen_tmInitP r))
                 (equal (get r 'signal) (get row 'signal))
                 (or (equal ce cr)
                     (and (null (dgen_tmHasVars ce)) (null (dgen_tmHasVars cr))
                          (lessp (abs (difference (dgen_tmExprVal ce nil) (dgen_tmExprVal cr nil))) 1e-18))))
        (setq hit t))
      (setq i (add1 i)))
    hit))

; Copy of dgenTim_rows with element idx replaced by `row` (or removed
; when row is nil).
(defun dgenTim_replaceAt (idx row "gg")
  (let ((i 0) out)
    (foreach r dgenTim_rows
      (cond
        ((nequal i idx) (setq out (cons r out)))
        (row (setq out (cons row out))))
      (setq i (add1 i)))
    (reverse out)))

; ---------------------------------------------------------------------------
; Callbacks
; ---------------------------------------------------------------------------

; Report selection -> fill the edit row.
(defun dgenTimGui_selectCB (fieldSym sel "sg")
  (let (idx row item lbl)
    (setq idx (and sel (nth (car sel) dgenTim_rowMap)))
    (cond
      ((null sel) nil)
      ((or (null idx) (dgen_tmInitP (nth idx dgenTim_rows)))
        ; init line: the transient start value
        (setq lbl (car (nth (car sel) (get dgenTim_form 'dgenTim_report)->choices)))
        (when (member lbl dgenTim_labels) (dgenTim_set 'dgenTim_signal lbl))
        (dgenTim_syncValueEnable (dgenTim_curItem))
        (dgenTim_set 'dgenTim_time "init")
        (dgenTim_set 'dgenTim_edge "")
        (dgenTim_set 'dgenTim_value
          (cond (idx (or (get (nth idx dgenTim_rows) 'value) "")) (t "DC")))
        (dgenTim_status "Init line: where the transient starts (0 / 1 / a value, a variable, or DC = the main form's value). DC analyses always use the main form's value. Edit Value, then Update."))
      (t
        (setq row  (nth idx dgenTim_rows))
        (setq item (dgen_tmFindItem dgenTim_items (get row 'signal)))
        (cond
          (item
            (dgenTim_set 'dgenTim_signal (dgenTim_itemLabel item))
            (dgenTim_syncValueEnable item))
          (t (dgenTim_status (sprintf nil
               "%s is not an enabled signal -- enable it in the main form, or Delete this row."
               (get row 'signal)))))
        (dgenTim_set 'dgenTim_time (or (get row 'time) ""))
        (dgenTim_set 'dgenTim_edge (or (get row 'edge) ""))
        (dgenTim_set 'dgenTim_value (or (get row 'value) ""))))
    t))

; Signal cyclic -> grey/ungrey Value + hint.
(defun dgenTimGui_signalCB (field scope item "ggg")
  (let ((it (dgenTim_curItem)) k)
    (dgenTim_syncValueEnable it)
    (when it
      (setq k (dgen_tmKindOf it))
      (dgenTim_status
        (cond
          ((equal k "scalar") (sprintf nil "%s is 1-bit: Value empty = toggle, or 0 / 1 / a variable / DC (= main-form value)." (get it 'name)))
          ((equal k "bus") (sprintf nil "%s is a bus: Value = new integer (0..%d) or DC." (get it 'name) (dgen_tmBusMax it)))
          (t (sprintf nil "%s is analog: Value = new voltage (e.g. 1.8, 900m) or DC; Edge = ramp time." (get it 'name))))))
    t))

; View switch. Going to By time with Time-cell variables that have no
; value yet opens the values dialog (deferred so it doesn't open from
; inside the cyclic callback); blank values just sort first (as 0).
(defun dgenTimGui_orderCB (field scope item "ggg")
  (let (unset)
    (setq dgenTim_order item)
    (dgenTim_refresh)
    (when (equal item "By time")
      (setq unset (dgenTim_unsetTimeVars))
      (cond
        (unset
          (dgenTim_status (sprintf nil
            "%s: no value yet -- sorted as 0 (first). Give values in the dialog, or leave them blank."
            (buildString unset ", ")))
          (hiRegTimer "(dgenTimVar_open)" 1))
        (t (dgenTim_status "Sorted by start time (variables at their table values)."))))
    t))

; [Variable values...]
(defun dgenTimGui_varValsCB (form "g")
  (dgenTimVar_open)
  t)

; Set (replace or add) the init row of row's signal.
(defun dgenTim_setInit (row "g")
  (let ((old (dgen_tmInitRow dgenTim_rows (get row 'signal))))
    (cond
      (old (setq dgenTim_rows (dgenTim_replaceAt (dgenTim_rowIndex old) row)))
      (t (setq dgenTim_rows (append dgenTim_rows (list row)))))
    (dgenTim_refresh)
    (dgenTim_selectRow (dgenTim_rowIndex (dgen_tmInitRow dgenTim_rows (get row 'signal))))
    (dgenTim_status (sprintf nil "%s: transient starts at %s." (get row 'signal)
      (cond ((equal (get row 'value) "DC") "the DC value (main form)") (t (get row 'value)))))))

(defun dgenTimGui_addCB (form "g")
  (let ((res (dgenTim_rowFromFields)) row extra)
    (setq row (car res))
    (cond
      ((cadr res) (dgenTim_status (cadr res)))
      ((dgen_tmInitP row) (dgenTim_setInit row))
      ((dgenTim_clashP row -1)
        (dgenTim_status (sprintf nil "%s already has an edge at %s -- select it and Update instead."
          (get row 'signal) (get row 'time))))
      (t
        (setq extra "")
        ; A signal's first edge brings its init line (transient start).
        (unless (dgen_tmInitRow dgenTim_rows (get row 'signal))
          (setq dgenTim_rows (append dgenTim_rows
            (list (dgen_tmRow (get row 'signal) "init" "" (dgenTim_defaultInit)))))
          (setq extra (sprintf nil " Transient starts at %s -- change it on the init line (DC = main-form value)."
                        (dgenTim_defaultInit))))
        (setq dgenTim_rows (append dgenTim_rows (list row)))
        (dgenTim_refresh)
        (dgenTim_selectRow (sub1 (length dgenTim_rows)))
        (dgenTim_status (sprintf nil "Added %s @ %s.%s%s" (get row 'signal) (get row 'time)
                          extra (dgenTim_askNewTimeVars row)))))
    t))

(defun dgenTimGui_updateCB (form "g")
  (let ((sel (dgenTim_selectedRow)) res row)
    (setq res (dgenTim_rowFromFields))
    (setq row (car res))
    (cond
      ((null sel)
        (dgenTim_status "Select a row in the table first."))
      ((cadr res) (dgenTim_status (cadr res)))
      ((dgen_tmInitP row) (dgenTim_setInit row))
      ((dgenTim_initSelected sel)
        (dgenTim_status "This is the init line: keep Time = init and change the Value (or select an edge row)."))
      ((dgenTim_clashP row sel)
        (dgenTim_status (sprintf nil "%s already has another edge at %s."
          (get row 'signal) (get row 'time))))
      (t
        (setq dgenTim_rows (dgenTim_replaceAt sel row))
        (dgenTim_refresh)
        (dgenTim_selectRow sel)
        (dgenTim_status (sprintf nil "Updated %s @ %s.%s" (get row 'signal) (get row 'time)
                          (dgenTim_askNewTimeVars row)))))
    t))

(defun dgenTimGui_deleteCB (form "g")
  (let ((sel (dgenTim_selectedRow)) row ir extra)
    (cond
      ((null sel)
        (dgenTim_status "Select an edge row in the table first."))
      ((dgenTim_initSelected sel)
        (dgenTim_status "The init line stays while the signal has edges -- set it to DC to start from the main form's value."))
      (t
        (setq row (nth sel dgenTim_rows))
        (setq dgenTim_rows (dgenTim_replaceAt sel nil))
        (setq extra "")
        ; Last edge gone: the signal is DC again, drop its init line.
        (when (and (null (dgen_tmRowsFor dgenTim_rows (get row 'signal)))
                   (setq ir (dgen_tmInitRow dgenTim_rows (get row 'signal))))
          (setq dgenTim_rows (dgenTim_replaceAt (dgenTim_rowIndex ir) nil))
          (setq extra (sprintf nil " %s has no edges left -- it is DC again." (get row 'signal))))
        (dgenTim_refresh)
        (dgenTim_status (sprintf nil "Deleted %s @ %s.%s" (get row 'signal) (get row 'time) extra))))
    t))

; File path from the selector box ("" -> nil). Relative paths resolve
; against Virtuoso's cwd, like every other Cadence file field.
(defun dgenTim_filePath ()
  (let ((p (dgen_tmTrim (or (dgen_fieldVal dgenTim_form 'dgenTim_file) ""))))
    (cond ((equal p "") nil) (t (simplifyFilename p)))))

; Import REPLACES the working table with the file's rows (it's a load,
; not a merge) -- Cancel still reverts to the table as it was on open.
(defun dgenTimGui_importCB (form "g")
  (let ((path (dgenTim_filePath)) res rows errs)
    (cond
      ((null path) (dgenTim_status "Type or browse a file path first."))
      (t
        (setq res (dgen_tmReadFile path))
        (setq rows (car res))
        (setq errs (cadr res))
        (cond
          ((and (null rows) errs) (dgenTim_status (car errs)))
          (t
            (setq dgenTim_rows rows)
            ; "NAME = value" lines in the file replace the table values.
            (when (caddr res)
              (setq dgenTim_varVals (caddr res)))
            (dgenTim_refresh)
            (foreach e errs (printf "[dreg-gen] import %s: %s\n" path e))
            (dgenTim_status
              (cond
                (errs (sprintf nil "Imported %d rows; %d line(s) skipped (see CIW)." (length rows) (length errs)))
                (t (sprintf nil "Imported %d rows from %s." (length rows) path))))))))
    t))

(defun dgenTimGui_exportCB (form "g")
  (let ((path (dgenTim_filePath)))
    (cond
      ((null path) (dgenTim_status "Type or browse a file path first."))
      ((dgen_tmWriteFile path dgenTim_rows (dgenTim_vars))
        (dgenTim_status (sprintf nil "Exported %d rows to %s." (length dgenTim_rows) path)))
      (t (dgenTim_status (sprintf nil "Cannot write %s." path))))
    t))

; OK: validate against the snapshot, commit, refresh main-form summaries.
; A hard error keeps the editor open (needs ?unmapAfterCB t).
(defun dgenTimGui_okCB (form "g")
  (let (spec res err warns)
    (hiSetCallbackStatus form t)
    (setq spec (dgen_plistPut (dgen_plistPut dgenTim_spec 'timing dgenTim_rows)
                 'timingVars (dgenTim_prunedVals)))
    (setq res (dgen_validateTiming spec))
    (setq err (car res))
    (setq warns (cadr res))
    (cond
      (err
        (dgenTim_status err)
        (hiDisplayAppDBox
          ?name 'dgenTim_errDBox
          ?dboxBanner "Dreg Generator -- Timing Table"
          ?dboxText err
          ?dialogType hicWarningDialog
          ?buttonLayout 'Close)
        (hiSetCallbackStatus form nil)
        nil)
      (t
        (foreach w warns (printf "[dreg-gen] timing: %s\n" w))
        (setq dgen_currentTiming dgenTim_rows)
        (setq dgen_currentTimingVars (dgenTim_prunedVals))
        (dgen_refreshTimingSummaries)
        t))))

(defun dgenTimGui_cancelCB (form "g")
  t)

; ---------------------------------------------------------------------------
; Variable-values dialog
; ---------------------------------------------------------------------------
;
; One row per variable used in a Time cell (built fresh each time, so the
; field count can follow the table). Values only order the By-time view
; and the per-signal rows; a blank value counts as 0 (listed first). The
; simulation always takes the ADE / Maestro design variable.

(unless (boundp 'dgenTimVar_form)  (setq dgenTimVar_form  nil))
(unless (boundp 'dgenTimVar_names) (setq dgenTimVar_names nil))

(defun dgenTimVar_open ()
  (let (names fields y i)
    (setq names (dgen_tmTimeVarNames dgenTim_rows))
    (cond
      ((null names)
        (dgenTim_status "No Time cell uses a variable -- nothing to set.")
        nil)
      (t
        (when (and dgenTimVar_form (car (errset (hiIsFormDisplayed dgenTimVar_form) nil)))
          (errset (hiFormCancel dgenTimVar_form) t))
        (setq dgenTimVar_names names)
        (foreach nm names
          (unless (member nm dgenTim_askedVars)
            (setq dgenTim_askedVars (cons nm dgenTim_askedVars))))
        (setq fields (list
          (list (hiCreateStringField ?name 'dgenTimVar_help ?prompt ""
                  ?value "Only used to order the table (blank = 0, listed first)."
                  ?editable nil)
                (list 0 0) (list 440 30) 0)
          (list (hiCreateStringField ?name 'dgenTimVar_help2 ?prompt ""
                  ?value "Simulation uses the ADE / Maestro design variables."
                  ?editable nil)
                (list 0 30) (list 440 30) 0)))
        (setq y 66)
        (setq i 0)
        (foreach nm names
          (setq fields (append fields (list
            (list (hiCreateStringField ?name (concat 'dgenTimVar_v i) ?prompt nm
                    ?value (dgenTim_varText nm))
                  (list 0 y) (list 320 30) 150))))
          (setq y (plus y 30))
          (setq i (add1 i)))
        (setq dgenTimVar_form (hiCreateAppForm
          ?name 'dgenTimVar_form
          ?formTitle "Timing Table -- variable values"
          ?fields fields
          ?callback (list "(dgenTimVarGui_okCB dgenTimVar_form)" "(dgenTimVarGui_cancelCB dgenTimVar_form)")
          ?unmapAfterCB t
          ?buttonLayout 'OKCancel))
        (hiDisplayForm dgenTimVar_form)
        t))))

; OK: blank -> no value (sorts as 0); otherwise must be a number. Values
; of variables not listed (Edge / Value cells) are kept as they are.
(defun dgenTimVarGui_okCB (form "g")
  (let ((i 0) txt vals bad)
    (hiSetCallbackStatus form t)
    (setq vals (setof v dgenTim_varVals (not (member (get v 'name) dgenTimVar_names))))
    (foreach nm dgenTimVar_names
      (setq txt (dgen_tmTrim (or (dgen_fieldVal form (concat 'dgenTimVar_v i)) "")))
      (cond
        ((equal txt "") nil)
        ((dgen_tmVarDefaultNorm txt)
          (setq vals (append vals (list (dgen_tmVar nm txt)))))
        ((null bad)
          (setq bad (sprintf nil "%s: '%s' is not a number (e.g. 5n, 50ps, 1.2u)." nm txt))))
      (setq i (add1 i)))
    (cond
      (bad
        (dgen_warnBox bad "Timing Table -- variable values")
        (hiSetCallbackStatus form nil)
        nil)
      (t
        (setq dgenTim_varVals vals)
        (dgenTim_refresh)
        (dgenTim_status (sprintf nil "Variable values: %d of %d set (unset ones sort as 0)."
          (length (setof nm dgenTimVar_names (dgen_tmVarDefault vals nm)))
          (length dgenTimVar_names)))
        t))))

(defun dgenTimVarGui_cancelCB (form "g") t)

; ---------------------------------------------------------------------------
; Form construction
; ---------------------------------------------------------------------------

; Ref: skuiref.pdf p.624 (hiCreateReportField), p.536 (hiCreateCyclicField),
;      p.650 (hiCreateStringField), p.540 (hiCreateFileSelectorField),
;      p.524 (hiCreateButton), p.502 (hiCreateAppForm ?unmapAfterCB),
;      p.801 (hiSetCallbackStatus), p.788 (hiReportSelectItem),
;      p.769 (hiIsFormDisplayed).
(defun dgenTim_buildFields (defFile "t")
  (let (fields y rowH W pw)
    (setq rowH 30)
    (setq W 760)
    (setq pw 55)
    (setq y 0)
    (setq fields (list
      (list (hiCreateStringField ?name 'dgenTim_help ?prompt "How"
              ?value "Time: edge start (init = tran start). Value: DC = main-form value, 1-bit blank = toggle."
              ?editable nil)
            (list 0 y) (list W rowH) pw)))
    (setq y (plus y rowH 4))
    (setq fields (cons
      (list (hiCreateReportField ?name 'dgenTim_report
              ?headers (list (list "Signal" 130 'left 'string)
                             (list "Time"   175 'left 'string)
                             (list "Edge"   135 'left 'string)
                             (list "After"  175 'left 'string)
                             (list "Type"   110 'left 'string))
              ?choices nil
              ?selectMode 'single
              ?callback 'dgenTimGui_selectCB)
            (list 0 y) (list W 280))
      fields))
    (setq y (plus y 286))
    (setq fields (cons
      (list (hiCreateCyclicField ?name 'dgenTim_orderF ?prompt "View"
              ?choices (list "By signal" "By time")
              ?value dgenTim_order
              ?callback 'dgenTimGui_orderCB)
            (list 0 y) (list 220 rowH) pw)
      fields))
    ; Table values of the Time-cell variables (ordering only); also asked
    ; for automatically when switching to By time.
    (setq fields (cons
      (list (hiCreateButton ?name 'dgenTim_btnVarVals ?buttonText "Variable values..."
              ?callback "(dgenTimGui_varValsCB dgenTim_form)")
            (list 230 y) (list 150 rowH) 0)
      fields))
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgenTim_summaryF ?prompt ""
              ?value "" ?editable nil)
            (list 390 y) (list (difference W 390) rowH) 0)
      fields))
    (setq y (plus y rowH 6))
    (setq fields (cons
      (list (hiCreateCyclicField ?name 'dgenTim_signal ?prompt "Signal"
              ?choices dgenTim_labels
              ?value (car dgenTim_labels)
              ?callback 'dgenTimGui_signalCB)
            (list 0 y) (list 300 rowH) pw)
      fields))
    (setq y (plus y rowH))
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgenTim_time ?prompt "Time" ?value "")
            (list 0 y) (list 260 rowH) pw)
      fields))
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgenTim_edge ?prompt "Edge" ?value "")
            (list 270 y) (list 220 rowH) 45)
      fields))
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgenTim_value ?prompt "Value" ?value "")
            (list 500 y) (list (difference W 500) rowH) 45)
      fields))
    (setq y (plus y rowH))
    (setq fields (cons
      (list (hiCreateButton ?name 'dgenTim_btnAdd ?buttonText "Add"
              ?callback "(dgenTimGui_addCB dgenTim_form)")
            (list 0 y) (list 90 rowH) 0)
      fields))
    (setq fields (cons
      (list (hiCreateButton ?name 'dgenTim_btnUpd ?buttonText "Update"
              ?callback "(dgenTimGui_updateCB dgenTim_form)")
            (list 100 y) (list 90 rowH) 0)
      fields))
    (setq fields (cons
      (list (hiCreateButton ?name 'dgenTim_btnDel ?buttonText "Delete"
              ?callback "(dgenTimGui_deleteCB dgenTim_form)")
            (list 200 y) (list 90 rowH) 0)
      fields))
    (setq y (plus y rowH 6))
    (setq fields (cons
      (list (hiCreateFileSelectorField ?name 'dgenTim_file ?prompt "File"
              ?mode 'anyFile ?value defFile)
            (list 0 y) (list (difference W 160) rowH) pw)
      fields))
    (setq fields (cons
      (list (hiCreateButton ?name 'dgenTim_btnImport ?buttonText "Import"
              ?callback "(dgenTimGui_importCB dgenTim_form)")
            (list (difference W 150) y) (list 70 rowH) 0)
      fields))
    (setq fields (cons
      (list (hiCreateButton ?name 'dgenTim_btnExport ?buttonText "Export"
              ?callback "(dgenTimGui_exportCB dgenTim_form)")
            (list (difference W 70) y) (list 70 rowH) 0)
      fields))
    (setq y (plus y rowH 6))
    (setq fields (cons
      (list (hiCreateStringField ?name 'dgenTim_statusF ?prompt "Status"
              ?value "" ?editable nil)
            (list 0 y) (list W rowH) pw)
      fields))
    (reverse fields)))

; Snapshot the main form + build the editor. Returns the form (not
; displayed) so a test can drive it headless; dgenTimingEditorOpen
; displays it.
(defun dgenTim_buildForm ()
  (let (spec form tgt defFile)
    (setq spec (dgen_readForm dgen_form dgen_currentPins))
    (setq dgenTim_spec  spec)
    (setq dgenTim_items (dgen_specEmitList spec))
    (setq dgenTim_labels (mapcar 'dgenTim_itemLabel dgenTim_items))
    (setq dgenTim_rows  (copy dgen_currentTiming))
    (setq dgenTim_varVals (copy dgen_currentTimingVars))
    (setq dgenTim_askedVars nil)
    (setq tgt (get spec 'target))
    (setq defFile (sprintf nil "./%s_timing.txt" (or (get tgt 'cell) "dreg")))
    (setq form (hiCreateAppForm
      ?name 'dgenTim_form
      ?formTitle (sprintf nil "Dreg Generator -- Timing Table (%s/%s%s)"
                   (or (get tgt 'lib) "?") (or (get tgt 'cell) "?")
                   (cond ((and (get tgt 'view) (nequal (get tgt 'view) dgen_mainView))
                           (strcat " view " (get tgt 'view)))
                         (t "")))
      ?fields (dgenTim_buildFields defFile)
      ?callback (list "(dgenTimGui_okCB dgenTim_form)" "(dgenTimGui_cancelCB dgenTim_form)")
      ?unmapAfterCB t
      ?buttonLayout 'OKCancel))
    (hiInstantiateForm form)
    (dgenTim_refresh)
    (dgenTim_syncValueEnable (car dgenTim_items))
    (dgenTim_status
      (sprintf nil "%d signal(s) available. Click a row to edit it, or pick a Signal and Add."
        (length dgenTim_items)))
    form))

; [Timing Table...] on the main form.
(defun dgenTimingEditorOpen ()
  (cond
    ((null dgen_currentPins)
      (hiDisplayAppDBox ?name 'dgenTim_warnDBox ?dboxBanner "Dreg Generator"
        ?dboxText "Load a DUT first." ?dialogType hicWarningDialog ?buttonLayout 'Close)
      nil)
    ((and dgenTim_form (car (errset (hiIsFormDisplayed dgenTim_form) nil)))
      ; Already open: bring it up instead of rebuilding (would drop edits).
      (errset (hiDisplayForm dgenTim_form) t)
      t)
    ((null (dgen_specEmitList (dgen_readForm dgen_form dgen_currentPins)))
      (hiDisplayAppDBox ?name 'dgenTim_warnDBox ?dboxBanner "Dreg Generator"
        ?dboxText "No signal is enabled. Tick at least one pin (or add a custom variable) first."
        ?dialogType hicWarningDialog ?buttonLayout 'Close)
      nil)
    (t
      (let ((form (dgenTim_buildForm)))
        (errset (hiSetFormSize form (list 800 640)) t)
        (hiDisplayForm form)
        t))))

(defun dgenGui_timingCB (form "g")
  (dgenTimingEditorOpen)
  t)
