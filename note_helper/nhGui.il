; nhGui.il -- note-helper minimal hi* form + MyTool self-registration.
;
; Mirrors dreg_gen/dgenGui.il patterns:
;   - field list entries: (fieldHandle (x y) (w h) promptWidth)
;   - hiCreateAppForm -> hiInstantiateForm -> hiSetFormSize -> hiDisplayForm
;   - hiSetFormSize AFTER instantiate fixes the MLT/outer double-scroll
;     (Motif wheel hits both the inner MLT and the outer form scrollbar;
;      sizing the viewport to clear the stacked panels retracts the outer
;      bar). Wrapped in errset (no-op-with-warn on the rare un-realized form).
;   - dynamic field WRITE goes through evalstring + a scratch global
;     (form->field->value = only binds with a literal symbol).
;
; Ref: skuiref.pdf hiCreateAppForm p.502, hiInstantiateForm p.767,
;      hiSetFormSize p.813, hiDisplayForm p.688, hiCreateMLTextField p.602,
;      hiCreateStringField p.650, hiCreateCyclicField p.536,
;      hiCreateButton p.524.

(unless (boundp 'nh_guiSample)
  (setq nh_guiSample "|Net|Val|Unit|\n|:--|--:|:-:|\n|Vdd|3.3|V|\n|Gnd|0|V|"))

; ---------------------------------------------------------------------------
; Field read/write helpers
; ---------------------------------------------------------------------------

; Write a value into a named field via the evalstring idiom (proven in
; dgenGui.il -- the infix `->...->value =` needs a literal field name, so we
; route the dynamic name through a scratch global).
(defun nh_setFieldVal (formName fieldSym val)
  (let ((fname (if (symbolp fieldSym) (symbolToString fieldSym) fieldSym)))
    (setq nh_tmpVal val)
    (errset
      (evalstring (sprintf nil "%s->%s->value = nh_tmpVal" formName fname))
      t)))

; Write a value into a stashed field HANDLE. Fields that live inside a Tab page
; are NOT reachable as form->name (verified: form->tabField->name => nil), so
; the GUI stashes those handles in globals (nh_fInput etc.). The handle->value
; assignment still needs a literal symbol, so route through a scratch global.
(defun nh_setHandleVal (fld val)
  (when fld
    (setq nh_tmpHandle fld)
    (setq nh_tmpVal val)
    (errset (evalstring "nh_tmpHandle->value = nh_tmpVal") t)))

; ---------------------------------------------------------------------------
; Build the styling cfg plist from the form fields.
; ---------------------------------------------------------------------------
(defun nh_guiReadCfg (form)
  (let (fh mc gridStr grid)
    (setq fh (atof (or form->nh_fontHeight->value "0.125")))
    (when (or (null fh) (leqp fh 0)) (setq fh 0.125))
    (setq mc (fix (atof (or form->nh_maxCols->value "0"))))
    (setq gridStr form->nh_grid->value)
    (setq grid (cond
                 ((equal gridStr "hrules")     'hrules)
                 ((equal gridStr "box+header") 'boxheader)
                 (t                            'full)))
    (list nil 'fontHeight fh 'maxColWidth mc 'gridStyle grid)))

; ---------------------------------------------------------------------------
; Callbacks
; ---------------------------------------------------------------------------

; Parse: report row x col count (or an error) on the status line.
(defun nh_guiParseCB (form)
  (let (res table)
    (setq res (errset (nhParseText nh_fInput->value) t))
    (cond
      ((null res)
        (nh_setFieldVal "nh_form" 'nh_status "parse error -- see CIW"))
      (t
        (setq table (car res))
        (nh_setFieldVal "nh_form" 'nh_status
          (sprintf nil "%d rows x %d cols%s"
            (length (get table 'rows)) (get table 'ncols)
            (if (get table 'header) " (header)" "")))))
    t))

; Place a built IR via the shared ghost placement (nhPlaceIRGhost): all three
; Output modes drag a SYMBOL master with a live cursor preview, one click to
; drop (loose flattens to note shapes afterward). Shared by the table Place
; button and the SVG Import button so vector figures get the same three modes.
(defun nh_guiDispatchIR (form ir)
  (let (sym)
    (setq sym (nh_modeSym (or form->nh_mode->value "loose shapes")))
    (cond
      ((nhPlaceIRGhost ir sym form->nh_symCell->value form->nh_symLib->value)
        (nh_setFieldVal "nh_form" 'nh_status
          (cond
            ((eq sym 'loose)
              "drag the note in the schematic, click to drop (loose shapes)")
            ((eq sym 'resizable)
              "drag the note, click to drop -- resizable, q to resize")
            (t
              "drag the note symbol in the schematic, click to drop"))))
      (t
        (nh_setFieldVal "nh_form" 'nh_status
          "cannot place -- open a SCHEMATIC window first (see CIW)")))
    t))

; Enable the Symbol cell field only for the symbol/resizable Output modes (it
; has no meaning for loose shapes). Driven by the Output cyclic ?callback
; (nh_guiOnMode) and called once at form open. hiSetFieldEnabled skuiref p.806.
(defun nh_guiSyncFields (form @optional modeStr)
  (let (sym on)
    (setq sym (nh_modeSym (or modeStr form->nh_mode->value "loose shapes")))
    (setq on  (not (eq sym 'loose)))   ; Symbol lib/cell only matter for symbol modes
    (errset (hiSetFieldEnabled form->nh_symLib  on) t)
    (errset (hiSetFieldEnabled form->nh_symCell on) t)
    t))

; Output cyclic-field change callback (symbol form -> called as fn(field scope
; item); item is the newly selected string). Re-applies the grey-out state.
(defun nh_guiOnMode (field scope item)
  (nh_guiSyncFields nh_form item)
  t)

; Place (table): parse + build IR, then dispatch by Output mode.
(defun nh_guiPlaceCB (form)
  (let (res table cfg ir)
    (setq res (errset (nhParseText nh_fInput->value) t))
    (cond
      ((null res)
        (nh_setFieldVal "nh_form" 'nh_status "parse error -- see CIW"))
      (t
        (setq table (car res))
        (setq cfg   (nh_guiReadCfg form))
        (setq ir    (errset (nh_buildIR table cfg) t))
        (cond
          ((null ir)
            (nh_setFieldVal "nh_form" 'nh_status "layout error -- see CIW"))
          (t
            (nh_guiDispatchIR form (car ir))))))
    t))

; Import SVG (Feature A): run the external parser, then dispatch by Output mode
; (a vector figure can go in as loose shapes, a symbol, or a resizable symbol).
(defun nh_guiImportCB (form)
  (let (svg width res)
    (setq svg nh_fSvg->value)
    (cond
      ((or (null svg) (equal svg ""))
        (nh_setFieldVal "nh_form" 'nh_status "enter an SVG file path to import"))
      ((not (isFile svg))
        (nh_setFieldVal "nh_form" 'nh_status "SVG file not found -- check the path"))
      (t
        (setq width (atof (or nh_fVecW->value "5")))
        (when (or (null width) (leqp width 0)) (setq width 5.0))
        (nh_setFieldVal "nh_form" 'nh_status "parsing SVG...")
        (setq res (errset (nhImportVector svg width) t))
        (cond
          ((null res)
            (nh_setFieldVal "nh_form" 'nh_status "SVG import failed -- see CIW"))
          ((null (car res))
            (nh_setFieldVal "nh_form" 'nh_status "no drawable geometry in the SVG"))
          (t
            (nh_guiDispatchIR form (car res))))))
    t))

; OK/close: nothing to persist (table text is transient by design).
(defun nh_guiCloseCB (form)
  t)

; Load file: read the path in nh_mdPath into the input MLT (Markdown or TSV;
; the parser auto-detects either on Parse/Place).
(defun nh_guiLoadFileCB (form)
  (let (path txt)
    (setq path nh_fMdPath->value)
    (cond
      ((or (null path) (equal path ""))
        (nh_setFieldVal "nh_form" 'nh_status "enter a file path to load"))
      ((not (isFile path))
        (nh_setFieldVal "nh_form" 'nh_status "file not found -- check the path"))
      (t
        (setq txt (errset (nh_readFile path) t))
        (cond
          ((null txt)
            (nh_setFieldVal "nh_form" 'nh_status "read failed -- see CIW"))
          (t
            (nh_setHandleVal nh_fInput (car txt))
            (nh_setFieldVal "nh_form" 'nh_status
              (sprintf nil "loaded %s -- click Parse" path))))))
    t))

; Save .md: parse the input (Markdown or TSV) and write it back out as a
; normalized, aligned Markdown file at nh_mdPath.
(defun nh_guiSaveMdCB (form)
  (let (path res ok)
    (setq path nh_fMdPath->value)
    (cond
      ((or (null path) (equal path ""))
        (nh_setFieldVal "nh_form" 'nh_status "enter a file path to save to"))
      (t
        (setq res (errset (nhTextToMarkdown nh_fInput->value) t))
        (cond
          ((null res)
            (nh_setFieldVal "nh_form" 'nh_status "parse/convert error -- see CIW"))
          (t
            (setq ok (errset (nh_writeFile path (car res)) t))
            (if (and ok (car ok))
                (nh_setFieldVal "nh_form" 'nh_status (sprintf nil "saved %s" path))
                (nh_setFieldVal "nh_form" 'nh_status "write failed -- see CIW"))))))
    t))

; ---------------------------------------------------------------------------
; Form
; ---------------------------------------------------------------------------
; Default folder for the Browse buttons: explicit nh_browseDir override, else
; $WORK_ROOT2 (the company workarea), else the workarea derived from
; note_helperDir, else ".". getShellEnvVar sklangref p.627; isDir p.631.
(defun nh_defaultDir ()
  (let (w)
    (cond
      ((and nh_browseDir (isDir nh_browseDir)) nh_browseDir)
      ((and (setq w (getShellEnvVar "WORK_ROOT2")) (not (equal w "")) (isDir w)) w)
      ((and (boundp 'note_helperDir) note_helperDir
            (setq w (pcreReplace (pcreCompile "skill_tools/note_helper/?$") note_helperDir "" 0))
            (isDir w)) w)
      (t "."))))

; Configure a hiCreateFileSelectorField's Browse dialog: open in the default
; folder, set its caption + file filter, and return an ABSOLUTE path in the
; field (hiSimplifyFilename = t) so isFile/parsers get a usable path.
; These are set as properties on the field handle (skuiref p.540).
(defun nh_cfgFileSel (fld caption filter)
  (let ((dir (nh_defaultDir)))
    (when fld
      fld->hiFileDialogWorkingDir = dir
      fld->hiFileDialogCaption    = caption
      fld->hiFileDialogFilter     = filter
      fld->hiSimplifyFilename     = t))
  t)

; The form is laid out 2D (each entry = (fieldHandle (x y) (w h) promptWidth)).
; A Tab field at the top separates the two SOURCES -- Table (Markdown/TSV) vs
; SVG (vector import) -- so only the relevant inputs show per source. The
; styling + Output mode + action buttons are SHARED below the tab. The Symbol
; cell field greys out unless Output is a symbol mode (nh_guiSyncFields).
(defun nh_guiBuild (@optional initialText)
  (let (fInput fMdPath fLoad fSaveMd tablePage
        fSvg fW svgPage tabF
        fStatus fFont fMax fGrid fMode fSymLib fSym fParse fPlace fImport
        form sample rowH mlW mlH tabW tabH)
    (setq rowH 28) (setq mlW 360) (setq mlH 150)
    (setq tabW 410) (setq tabH 250)
    (setq sample (or initialText nh_guiSample))
    ; ===== Tab page: Table (MLT input + .md/.tsv file load/save) =====
    (setq fInput  (hiCreateMLTextField
                    ?name 'nh_input ?prompt "Table (Markdown / TSV)"
                    ?value sample
                    ?hasVerticalScrollbar t ?hasHorizontalScrollbar nil
                    ?enableWordWrap nil))
    (setq fMdPath (hiCreateFileSelectorField ?name 'nh_mdPath ?mode 'anyFile
                    ?prompt "Table file (.md / .tsv)" ?value ""))
    (nh_cfgFileSel fMdPath "Choose a table file" "Markdown/TSV (*.md *.tsv);;All Files (*)")
    (setq fLoad   (hiCreateButton ?name 'nh_btnLoad ?buttonText "Load file"
                    ?callback "(nh_guiLoadFileCB nh_form)"))
    (setq fSaveMd (hiCreateButton ?name 'nh_btnSaveMd ?buttonText "Save .md"
                    ?callback "(nh_guiSaveMdCB nh_form)"))
    (setq tablePage (list
      (list fInput  (list 0 0)    (list mlW mlH)  0)
      (list fMdPath (list 0 158)  (list 370 rowH) 140)
      (list fLoad   (list 0 190)  (list 90 rowH)  0)
      (list fSaveMd (list 100 190) (list 90 rowH) 0)))
    ; ===== Tab page: SVG (vector import path + target width) =====
    (setq fSvg (hiCreateFileSelectorField ?name 'nh_svgPath ?mode 'existingFile
                 ?prompt "SVG file (vector import)" ?value ""))
    (nh_cfgFileSel fSvg "Choose an SVG file" "SVG (*.svg);;All Files (*)")
    (setq fW   (hiCreateStringField ?name 'nh_vecWidth
                 ?prompt "Figure width (user units)" ?value "5"))
    (setq svgPage (list
      (list fSvg (list 0 0)  (list 370 rowH) 160)
      (list fW   (list 0 34) (list 300 rowH) 190)))
    ; ===== the source Tab field =====
    (setq tabF (hiCreateTabField
                 ?name 'nh_src
                 ?fields (list tablePage svgPage)
                 ?tabs (list "Table" "SVG")
                 ?value 1))
    ; Stash the Tab-page field handles: fields inside a Tab are NOT reachable
    ; as form->name, so callbacks read/write them through these globals.
    (setq nh_fInput  fInput)
    (setq nh_fMdPath fMdPath)
    (setq nh_fSvg    fSvg)
    (setq nh_fVecW   fW)
    ; ===== shared fields (apply to whichever source) =====
    (setq fStatus (hiCreateStringField ?name 'nh_status ?prompt "Status"
                    ?value "(not parsed)" ?editable nil))
    (setq fFont (hiCreateStringField ?name 'nh_fontHeight
                  ?prompt "Size = text height (scales whole table)" ?value "0.125"))
    (setq fMax  (hiCreateStringField ?name 'nh_maxCols
                  ?prompt "Max col chars (0=off)" ?value "0"))
    (setq fGrid (hiCreateCyclicField ?name 'nh_grid ?prompt "Grid"
                  ?choices (list "full" "hrules" "box+header") ?value "full"))
    (setq fMode (hiCreateCyclicField ?name 'nh_mode ?prompt "Output"
                  ?choices (list "loose shapes" "symbol" "symbol (resizable)")
                  ?value "loose shapes" ?callback 'nh_guiOnMode))
    (setq fSymLib (hiCreateStringField ?name 'nh_symLib
                    ?prompt "Symbol library (blank=schematic)" ?value ""))
    (setq fSym  (hiCreateStringField ?name 'nh_symCell
                  ?prompt "Symbol cell (symbol mode)" ?value "nh_note"))
    ; ===== shared action buttons =====
    (setq fParse  (hiCreateButton ?name 'nh_btnParse ?buttonText "Parse"
                    ?callback "(nh_guiParseCB nh_form)"))
    (setq fPlace  (hiCreateButton ?name 'nh_btnPlace ?buttonText "Place..."
                    ?callback "(nh_guiPlaceCB nh_form)"))
    (setq fImport (hiCreateButton ?name 'nh_btnImport ?buttonText "Import SVG..."
                    ?callback "(nh_guiImportCB nh_form)"))
    ; ===== assemble the 2D form =====
    (setq form (hiCreateAppForm
      ?name 'nh_form
      ?formTitle "Note Helper"
      ?fields (list
        (list tabF    (list 0 0)    (list tabW tabH) 0)
        (list fStatus (list 0 262)  (list 380 rowH) 80)
        (list fFont   (list 0 296)  (list 320 rowH) 200)
        (list fMax    (list 0 330)  (list 220 rowH) 140)
        (list fGrid   (list 0 364)  (list 220 rowH) 110)
        (list fMode   (list 0 398)  (list 260 rowH) 110)
        (list fSymLib (list 0 432)  (list 340 rowH) 190)
        (list fSym    (list 0 466)  (list 340 rowH) 190)
        (list fParse  (list 0 504)  (list 90 rowH)  0)
        (list fPlace  (list 100 504) (list 90 rowH) 0)
        (list fImport (list 200 504) (list 120 rowH) 0))
      ?callback (list "(nh_guiCloseCB nh_form)" "(nh_guiCloseCB nh_form)")
      ?buttonLayout 'OKCancelDef))
    (hiInstantiateForm form)
    ; hiSetFormSize AFTER instantiate -- retracts the outer scrollbar so the MLT
    ; wheel does not double-scroll (Ref user feedback / dgenGui.il).
    (errset (hiSetFormSize form (list 500 660)) t)
    (nh_guiSyncFields form)        ; initial Symbol-cell grey-out (loose default)
    form))

; Open (build + display) the Note Helper form.
(defun nhOpenGUI (@optional initialText)
  (nh_guiBuild initialText)
  (hiDisplayForm 'nh_form)
  'nh_form)

; ---------------------------------------------------------------------------
; MyTool plugin self-registration (mirror dgenGui.il tail). getd guard so the
; plugin still loads when the mytool framework is absent. Ref mytool/README.md.
; ---------------------------------------------------------------------------
(when (getd 'mtRegister)
  (mtRegister "Note Helper" 'nhOpenGUI "Open the Note Helper GUI"))
