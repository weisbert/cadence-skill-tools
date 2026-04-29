; dgenVerilogA.il -- Step 2 of Dreg Generator: emit veriloga.va + master.tag
; for the dreg cell described by the spec plist, drop them into the target
; library's cell directory, refresh Cadence's lib list, and place the new
; cell in a "dreg" category so the user can find it in Library Manager.

; ------------------------------------------------------------------
; Pin emitters -- one helper per piece of the Verilog-A template.
; Each returns a string. dgen_buildVAText concatenates them.
; ------------------------------------------------------------------

; Port-list piece: just the bare name (port-list parens).
; Same for scalar and bus -- bus dimensions go in the dimension brackets,
; not in the port-list reference.
(defun dgen_emitPortListItem (pin "g")
  (get pin 'name))

; "output ..." + "electrical ..." declarations for one pin.
(defun dgen_emitPortDecl (pin "g")
  (let ((nm (get pin 'name)))
    (cond
      ((get pin 'isBus)
        (sprintf nil "    output [%d:%d] %s;\n    electrical [%d:%d] %s;\n"
          (get pin 'busHi) (get pin 'busLo) nm
          (get pin 'busHi) (get pin 'busLo) nm))
      (t
        (sprintf nil "    output %s;\n    electrical %s;\n" nm nm)))))

; Parse the spec's `default` string as an integer. Spec doc says v1 is a
; numeric string; "DVDD" or non-numeric falls back to 0. atoi returns 0
; for non-numeric input, which is exactly what we want here.
; Ref: sklangref.pdf p.36 (atoi)
(defun dgen_pinDefaultInt (pin "g")
  (let ((d (get pin 'default)))
    (cond
      ((null d) 0)
      ((stringp d) (atoi d))
      ((integerp d) d)
      (t 0))))

; "parameter integer d_<name> = <int>;" for one pin.
(defun dgen_emitPinParam (pin "g")
  (sprintf nil "    parameter integer d_%s = %d;\n"
    (get pin 'name) (dgen_pinDefaultInt pin)))

; Analog-block lines for one pin: one line for scalar, busHi..busLo lines
; for buses. Iterates from hi toward lo regardless of direction so that
; reverse-numbered buses (<0:7>) also work — the bit weight always matches
; the index, since `>> i` and `[i]` use the same i.
(defun dgen_emitPinAnalog (pin "g")
  (let ((nm (get pin 'name)))
    (cond
      ((get pin 'isBus)
        (let ((hi (get pin 'busHi)) (lo (get pin 'busLo))
              (out "") i step done)
          (setq i hi)
          (setq step (cond ((geqp hi lo) -1) (t 1)))
          (setq done nil)
          (while (null done)
            (setq out (strcat out
              (sprintf nil "        V(%s[%d]) <+ ((d_%s >> %d) & 1) * DVDD;\n"
                nm i nm i)))
            (cond ((equal i lo) (setq done t))
                  (t (setq i (plus i step)))))
          out))
      (t
        (sprintf nil "        V(%s) <+ d_%s * DVDD;\n" nm nm)))))

; ------------------------------------------------------------------
; Whole-file builder: returns the complete veriloga.va string.
; ------------------------------------------------------------------

(defun dgen_buildVAText (spec moduleName "gt")
  (let (enabled portList portDecls params analogs dvdd)
    ; Filter to enabled pins only -- disabled pins are dropped entirely.
    (setq enabled nil)
    (foreach p (get spec 'pins)
      (when (get p 'enabled) (setq enabled (cons p enabled))))
    (setq enabled (reverse enabled))

    ; DVDD value -- string in spec, want a float for the parameter literal.
    ; Ref: sklangref.pdf p.34 (atof)
    (let ((s (get spec 'dvddDefault)))
      (setq dvdd (cond ((null s) 0.9)
                       ((stringp s) (atof s))
                       (t 0.9))))

    ; Build the comma-separated port list.
    (setq portList "")
    (let ((first t))
      (foreach p enabled
        (setq portList
          (cond
            (first (dgen_emitPortListItem p))
            (t (strcat portList ", " (dgen_emitPortListItem p)))))
        (setq first nil)))

    ; Concatenate the per-pin pieces.
    (setq portDecls "")
    (foreach p enabled
      (setq portDecls (strcat portDecls (dgen_emitPortDecl p))))

    (setq params "")
    (foreach p enabled
      (setq params (strcat params (dgen_emitPinParam p))))

    (setq analogs "")
    (foreach p enabled
      (setq analogs (strcat analogs (dgen_emitPinAnalog p))))

    (strcat
      "`include \"constants.vams\"\n"
      "`include \"disciplines.vams\"\n"
      "\n"
      (sprintf nil "module %s (%s);\n" moduleName portList)
      portDecls
      "\n"
      (sprintf nil "    parameter real    DVDD = %g;\n" dvdd)
      params
      "\n"
      "    analog begin\n"
      analogs
      "    end\n"
      "endmodule\n")))

; ------------------------------------------------------------------
; Filesystem helpers
; ------------------------------------------------------------------

; Resolve the on-disk path for a library. Prefer writePath (where new cells
; should land), fall back to readPath if writePath is nil.
; Ref: skdfref.pdf p.1760 (ddGetObj), property notation ~>writePath / ~>readPath.
(defun dgen_libPath (libName "t")
  (let ((libObj (ddGetObj libName)))
    (cond
      ((null libObj) nil)
      (t (or libObj~>writePath libObj~>readPath)))))

; Ensure cell + cell/veriloga directories exist; return the veriloga dir.
; Ref: sklangref.pdf p.631 (isDir), p.616 (createDir)
(defun dgen_ensureCellViewDir (libPath cellName "tt")
  (let ((cellDir (strcat libPath "/" cellName)))
    (unless (isDir cellDir) (createDir cellDir))
    (let ((vaDir (strcat cellDir "/veriloga")))
      (unless (isDir vaDir) (createDir vaDir))
      vaDir)))

; Write `text` to `path`. Returns t on success, nil on failure.
; Ref: sklangref.pdf p.450 (outfile), p.409 (fprintf), p.117 (close)
(defun dgen_writeStringToFile (path text "tt")
  (let ((p (outfile path "w")))
    (cond
      ((null p) nil)
      (t (fprintf p "%s" text) (close p) t))))

; ------------------------------------------------------------------
; Library Manager category placement
; ------------------------------------------------------------------

; Add `cellName` to category `catName` in library `libName`. Creates the
; category if it doesn't exist (ddCatOpen with mode "a" works for both
; create and append). Returns t on success, nil on failure.
; Ref: skdfref.pdf p.1937 (ddCatOpen), p.1941 (ddCatAddItem),
;      p.1943 (ddCatSave), p.1945 (ddCatClose).
(defun dgen_addCellToCategory (libName catName cellName "ttt")
  (let ((libObj (ddGetObj libName)) cat ok)
    (cond
      ((null libObj) nil)
      (t
        ; Mode "a" (append) creates the category if absent and opens for edit
        ; otherwise. The example on skdfref.pdf p.1937 uses exactly this idiom.
        (setq cat (ddCatOpen libObj catName "a"))
        (cond
          ((null cat) nil)
          (t
            (setq ok (ddCatAddItem cat cellName "cell"))
            (ddCatSave cat)
            (ddCatClose cat)
            ok))))))

; ------------------------------------------------------------------
; Public entry point
; ------------------------------------------------------------------

; dgenWriteVerilogA(spec outputLib outputCell)
;   spec       -- plist as produced by step 1 (see README)
;   outputLib  -- string, overrides spec~>target~>lib if non-nil
;   outputCell -- string, overrides spec~>target~>cell if non-nil
; Side effects:
;   * writes <libPath>/<cell>/veriloga/veriloga.va
;   * writes <libPath>/<cell>/veriloga/master.tag
;   * calls ddUpdateLibList() so Cadence re-reads the library list
;   * adds <cell> to a "dreg" category in the library
; Returns t on success, nil on failure.
;
; Ref: skdfref.pdf p.1849 (ddUpdateLibList) -- closest verified API to the
;      "ddUpdateLib" mentioned in informal docs; refreshes the in-memory
;      cds.lib view so newly-written cell directories become visible.
(defun dgenWriteVerilogA (spec outputLib outputCell "ggg")
  (let (target libName cellName libPath vaDir vaText vaPath tagPath)
    (setq target (get spec 'target))
    (setq libName  (or outputLib  (get target 'lib)))
    (setq cellName (or outputCell (get target 'cell)))
    (cond
      ((or (null libName) (null cellName))
        (error "dgenWriteVerilogA: missing target lib/cell (lib=%L cell=%L)"
          libName cellName))
      (t
        (setq libPath (dgen_libPath libName))
        (cond
          ((null libPath)
            (error "dgenWriteVerilogA: cannot resolve path for lib %s" libName))
          (t
            (setq vaDir (dgen_ensureCellViewDir libPath cellName))
            (setq vaText (dgen_buildVAText spec cellName))
            (setq vaPath  (strcat vaDir "/veriloga.va"))
            (setq tagPath (strcat vaDir "/master.tag"))
            (cond
              ((null (dgen_writeStringToFile vaPath vaText))
                (error "dgenWriteVerilogA: cannot write %s" vaPath))
              ((null (dgen_writeStringToFile tagPath
                       "-- Master.tag File, Rev:1.0\nveriloga.va\n"))
                (error "dgenWriteVerilogA: cannot write %s" tagPath))
              (t
                ; Re-scan libs so the new cellview is visible.
                (ddUpdateLibList)
                ; Place in the "dreg" category. Failure here is non-fatal --
                ; the cellview is already on disk and registered; category
                ; placement is a UX nicety.
                (unless (dgen_addCellToCategory libName "dreg" cellName)
                  (warn "dgenWriteVerilogA: could not add %s to category 'dreg' in %s"
                    cellName libName))
                t))))))))
