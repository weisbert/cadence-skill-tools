; dgenStore.il -- Step 1 of Dreg Generator: spec serialization, cell-property and last-state I/O.
;
; Last-state schema:
;   v1 (legacy): plist with targetLib, targetCellTpl, dvddDefault, defaultMode,
;                defaultPattern, pinStates. No 'schemaVersion key.
;   v2 (current): v1 + 'schemaVersion 2 + 'lastDutLib / 'lastDutCell / 'lastDutView.
;
; Migration policy: silent forward-only.
;   - Reader returns the plist verbatim; consumers use `get` so missing fields
;     read as nil. v1 files therefore yield nil for lastDutLib/Cell/View, which
;     is the desired fallback. Future v3+ fields are also returned verbatim and
;     ignored by current consumers.
;   - Writer always stamps 'schemaVersion 2 (auto-injected if not already in
;     the input plist). The optional sourcePlist argument supplies lastDutLib/
;     Cell/View; when omitted, those fields are absent (file is still v2 and
;     will roundtrip cleanly, just with no DUT pre-fill data).

; sprintf with %L round-trips through readstring.
; Ref: sklangref.pdf p.214 (sprintf), p.198 (readstring), p.410 (%L format).
(defun dgenSpecToString (spec "g")
  (sprintf nil "%L" spec))

(defun dgenStringToSpec (str "t")
  (and str (readstring str)))

; Stored as a string property named "dgenConfig" on the cell view.
; Ref: skdfref.pdf p.900 (dbOpenCellViewByType), p.559 (dbReplaceProp),
;      p.557 (dbFindProp), p.921 (dbSave), p.873 (dbClose).
; (Page numbers are physical PDF pages, matching function_index.tsv.)
(defun dgenSavePropOnCell (libName cellName viewName spec "tttg")
  (let ((cv (dbOpenCellViewByType libName cellName viewName nil "a")))
    (unless cv (error "dgenSavePropOnCell: cannot open %s/%s/%s for append" libName cellName viewName))
    (dbReplaceProp cv "dgenConfig" "string" (dgenSpecToString spec))
    (dbSave cv)
    (dbClose cv)
    t))

(defun dgenLoadPropFromCell (libName cellName viewName "ttt")
  (let ((cv (dbOpenCellViewByType libName cellName viewName nil "r")) p out)
    (when cv
      (setq p (dbFindProp cv "dgenConfig"))
      (when p (setq out (dgenStringToSpec p~>value)))
      (dbClose cv))
    out))

; Ref: sklangref.pdf p.627 (getShellEnvVar)
(defun dgen_lastFilePath ()
  (let ((home (getShellEnvVar "HOME")))
    (unless home (error "dgen_lastFilePath: $HOME unset"))
    (strcat home "/.skill_tools/dreg_gen.last")))

; Ref: sklangref.pdf p.631 (isDir), p.616 (createDir).
; SKILL has no let* (sequential bindings), so nest two lets to let dir see home.
(defun dgen_ensureLastDir ()
  (let ((home (getShellEnvVar "HOME")))
    (let ((dir (strcat home "/.skill_tools")))
      (unless (isDir dir) (createDir dir))
      dir)))

; Build a v2 plist by splicing 'schemaVersion 2 and (when sourcePlist given)
; 'lastDutLib / 'lastDutCell / 'lastDutView into the input plist. The input
; plist is treated as a property list with leading nil sentinel (per the
; project's plist convention -- see dgenGui.il dgen_specToLastState). If the
; input already carries a 'schemaVersion or any of the lastDut* fields, those
; user-supplied values win; we only inject when absent.
;
; sourcePlist shape: (nil 'lib X 'cell Y 'view Z) -- matches the spec's
; 'source sub-plist shape used in dgenGui.il and dgenPinScan.il.
(defun dgen_lastStateInjectV2 (plist sourcePlist "gg")
  (let (out lib cell view)
    (setq out plist)
    (unless (get out 'schemaVersion)
      (setq out (append out (list 'schemaVersion 2))))
    (when sourcePlist
      (setq lib  (get sourcePlist 'lib))
      (setq cell (get sourcePlist 'cell))
      (setq view (get sourcePlist 'view))
      (unless (get out 'lastDutLib)
        (setq out (append out (list 'lastDutLib (or lib "")))))
      (unless (get out 'lastDutCell)
        (setq out (append out (list 'lastDutCell (or cell "")))))
      (unless (get out 'lastDutView)
        (setq out (append out (list 'lastDutView (or view ""))))))
    out))

; Ref: sklangref.pdf p.450 (outfile), p.409 (fprintf)
;
; sourcePlist (optional): the spec's 'source sub-plist (nil 'lib X 'cell Y
; 'view Z). When supplied, lastDutLib/Cell/View are written into the file so
; a future dgenOpenGUI() call can pre-fill the Source-Lib/Cell/View combos.
; When omitted, the file is still v2 (carries 'schemaVersion 2) but lacks
; the lastDut* fields -- legitimate for callers that don't track DUT identity.
(defun dgenSaveLastState (plist @optional sourcePlist)
  (dgen_ensureLastDir)
  (let ((p (outfile (dgen_lastFilePath) "w"))
        (final (dgen_lastStateInjectV2 plist sourcePlist)))
    (unless p (error "dgenSaveLastState: cannot write %s" (dgen_lastFilePath)))
    (fprintf p "%L\n" final)
    (close p)
    t))

; lineread on a port returns a list of forms parsed from the next line, or nil at EOF.
; Ref: sklangref.pdf p.428 (isFile), p.423 (infile), p.437 (lineread).
;
; Returns the plist verbatim. Consumers use `get` to read fields, which
; naturally handles v1 (no schemaVersion -> nil), v2 (lastDut* present), and
; future versions (extra fields silently ignored). See dgen_lastStateIsV2P /
; dgen_lastStateDutLib/Cell/View below for typed accessors.
(defun dgenLoadLastState ()
  (let ((path (dgen_lastFilePath)) p result)
    (when (isFile path)
      (setq p (infile path))
      (when p
        (setq result (lineread p))
        (close p)))
    (cond ((null result) nil)
          ((equal result t) nil)
          (t (car result)))))

; Schema-version helpers. Treat absent 'schemaVersion as v1 (return 1) per the
; migration policy. Use these in callers instead of poking 'schemaVersion
; directly so future schema bumps stay localized.
(defun dgen_lastStateSchemaVersion (state "g")
  (or (get state 'schemaVersion) 1))

(defun dgen_lastStateIsV2P (state "g")
  (geqp (dgen_lastStateSchemaVersion state) 2))

; v1-tolerant accessors for the lastDut* fields. v1 files lack these, so the
; helpers return nil; the GUI is responsible for defaulting to "" / empty
; combos in that case. (Returning nil rather than "" lets callers distinguish
; "no last-state DUT recorded" from "saved an empty string".)
(defun dgen_lastStateDutLib (state "g")
  (and (dgen_lastStateIsV2P state) (get state 'lastDutLib)))

(defun dgen_lastStateDutCell (state "g")
  (and (dgen_lastStateIsV2P state) (get state 'lastDutCell)))

(defun dgen_lastStateDutView (state "g")
  (and (dgen_lastStateIsV2P state) (get state 'lastDutView)))
