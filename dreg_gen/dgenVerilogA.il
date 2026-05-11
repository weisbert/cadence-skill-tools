; dgenVerilogA.il -- Step 2 of Dreg Generator: emit veriloga.va + master.tag
; for the dreg cell described by the spec plist, drop them into the target
; library's cell directory, refresh Cadence's lib list, and place the new
; cell in a "dreg" category so the user can find it in Library Manager.

; ------------------------------------------------------------------
; Emit-item helpers -- one helper per piece of the Verilog-A template.
; Each returns a string. dgen_buildVAText concatenates them.
;
; "Item" means "auto-discovered pin OR user-added customVar" (see
; dgen_specEmitList in dgenStore.il). Each item has a 'kind of "digital"
; (pins + digital customVars) or "analog" (analog customVars). The
; per-piece functions branch on 'kind so the same emit loop in
; dgen_buildVAText handles both kinds.
; ------------------------------------------------------------------

; Port-list piece: just the bare name (port-list parens).
; Same for scalar and bus -- bus dimensions go in the dimension brackets,
; not in the port-list reference -- and same for digital and analog.
(defun dgen_emitPortListItem (item "g")
  (get item 'name))

; "output ..." + "electrical ..." declarations for one item. Analog items
; are always scalar; defensively ignore any spurious 'isBus on them so a
; hand-crafted bad spec can't emit "output [3:0] VDD1P8" which would parse
; as a vector net but get driven by a single analog source.
(defun dgen_emitPortDecl (item "g")
  (let ((nm (get item 'name)))
    (cond
      ((and (get item 'isBus) (nequal (get item 'kind) "analog"))
        (sprintf nil "    output [%d:%d] %s;\n    electrical [%d:%d] %s;\n"
          (get item 'busHi) (get item 'busLo) nm
          (get item 'busHi) (get item 'busLo) nm))
      (t
        (sprintf nil "    output %s;\n    electrical %s;\n" nm nm)))))

; Parse the spec's `default` string as an integer (digital). Spec doc says
; v1 is a numeric string; "DVDD" or non-numeric falls back to 0. atoi
; returns 0 for non-numeric input, which is exactly what we want here.
; Ref: sklangref.pdf p.36 (atoi)
(defun dgen_pinDefaultInt (item "g")
  (let ((d (get item 'default)))
    (cond
      ((null d) 0)
      ((stringp d) (atoi d))
      ((integerp d) d)
      (t 0))))

; Parse the spec's `default` string as a real (analog). atof returns 0.0
; for non-numeric input, matching the digital fallback policy.
; Ref: sklangref.pdf p.34 (atof)
(defun dgen_emitDefaultReal (item "g")
  (let ((d (get item 'default)))
    (cond
      ((null d) 0.0)
      ((stringp d) (atof d))
      ((numberp d) d)
      (t 0.0))))

; Parameter declaration line for one item.
;   digital -> parameter integer d_<name> = <int literal>;
;   analog  -> parameter real    v_<name> = <real literal>;
; %g formats the real without trailing zeros (1.8, not 1.800000), matching
; the DVDD line emitted elsewhere in this file.
(defun dgen_emitPinParam (item "g")
  (cond
    ((equal (get item 'kind) "analog")
      (sprintf nil "    parameter real    %s = %g;\n"
        (dgen_emitParamName item) (dgen_emitDefaultReal item)))
    (t
      (sprintf nil "    parameter integer %s = %d;\n"
        (dgen_emitParamName item) (dgen_pinDefaultInt item)))))

; Analog-block lines for one item.
;   digital scalar -> V(X) <+ d_X * DVDD;
;   digital bus    -> one V(X[i]) <+ ((d_X >> i) & 1) * DVDD; per bit
;                     (iterates hi -> lo so reverse-numbered <0:7> works too
;                      -- the bit weight always matches the index)
;   analog  scalar -> V(X) <+ v_X;
; Analog customVars never carry bus dims (enforced in the GUI), so analog
; takes the scalar branch unconditionally.
(defun dgen_emitPinAnalog (item "g")
  (let ((nm (get item 'name)) (pn (dgen_emitParamName item)))
    (cond
      ((equal (get item 'kind) "analog")
        (sprintf nil "        V(%s) <+ %s;\n" nm pn))
      ((get item 'isBus)
        (let ((hi (get item 'busHi)) (lo (get item 'busLo))
              (out "") i step done)
          (setq i hi)
          (setq step (cond ((geqp hi lo) -1) (t 1)))
          (setq done nil)
          (while (null done)
            (setq out (strcat out
              (sprintf nil "        V(%s[%d]) <+ ((%s >> %d) & 1) * DVDD;\n"
                nm i pn i)))
            (cond ((equal i lo) (setq done t))
                  (t (setq i (plus i step)))))
          out))
      (t
        (sprintf nil "        V(%s) <+ %s * DVDD;\n" nm pn)))))

; ------------------------------------------------------------------
; Whole-file builder: returns the complete veriloga.va string.
; ------------------------------------------------------------------

(defun dgen_buildVAText (spec moduleName "gt")
  (let (items portList portDecls params analogs dvdd)
    ; Unified emit list: enabled pins (tagged digital) + customVars (carry
    ; own kind). See dgen_specEmitList in dgenStore.il.
    (setq items (dgen_specEmitList spec))

    ; DVDD value -- string in spec, want a float for the parameter literal.
    ; Ref: sklangref.pdf p.34 (atof)
    (let ((s (get spec 'dvddDefault)))
      (setq dvdd (cond ((null s) 0.9)
                       ((stringp s) (atof s))
                       (t 0.9))))

    ; Build the comma-separated port list.
    (setq portList "")
    (let ((first t))
      (foreach it items
        (setq portList
          (cond
            (first (dgen_emitPortListItem it))
            (t (strcat portList ", " (dgen_emitPortListItem it)))))
        (setq first nil)))

    ; Concatenate the per-item pieces.
    (setq portDecls "")
    (foreach it items
      (setq portDecls (strcat portDecls (dgen_emitPortDecl it))))

    (setq params "")
    (foreach it items
      (setq params (strcat params (dgen_emitPinParam it))))

    (setq analogs "")
    (foreach it items
      (setq analogs (strcat analogs (dgen_emitPinAnalog it))))

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
