; dgenStore.il -- Step 1 of Dreg Generator: spec serialization, cell-property and last-state I/O.

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

; Ref: sklangref.pdf p.450 (outfile), p.409 (fprintf)
(defun dgenSaveLastState (plist "g")
  (dgen_ensureLastDir)
  (let ((p (outfile (dgen_lastFilePath) "w")))
    (unless p (error "dgenSaveLastState: cannot write %s" (dgen_lastFilePath)))
    (fprintf p "%L\n" plist)
    (close p)
    t))

; lineread on a port returns a list of forms parsed from the next line, or nil at EOF.
; Ref: sklangref.pdf p.428 (isFile), p.423 (infile), p.437 (lineread).
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
