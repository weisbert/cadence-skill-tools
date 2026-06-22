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

; Resolve the form a callback fired from. Prefer hiGetCurrentForm (the form
; being processed) so that if more than one Note Helper window is open -- which
; happens whenever the .il is reloaded and the form reopened during dev -- each
; window's buttons read ITS OWN fields. Falls back to the nh_form global.
; Ref: skuiref.pdf hiGetCurrentForm.
(defun nh_curForm ()
  (or (hiGetCurrentForm) (and (boundp 'nh_form) nh_form)))

; Set the (top-level) status line on the live form. Top-level fields ARE
; reachable as form->name and the path is all-literal, so it assigns directly
; (no evalstring/scratch-global dance) -- and it targets the SAME form the
; callback fired from, not a possibly-stale global.
(defun nh_setStatus (form msg)
  (errset (form->nh_status->value = msg) t))

; --- Tab-PAGE field access -------------------------------------------------
; Fields INSIDE a Tab page are not reachable as form->name. They used to be
; stashed in globals (nh_fSvg etc.), but a stashed handle goes STALE the moment
; the form is rebuilt: a later build's global points at a different window, so a
; callback reads the WRONG window's value -- exactly why "Place" on the SVG tab
; reported an empty path after a live reload + reopen. Reach them through the
; LIVE form instead: form->nh_src->page<N>->field (Table = page1, SVG = page2;
; verified live, read AND write). Ref: skuiref.pdf hiCreateTabField p.656
; (form->tabField->tabPage->field).
(defun nh_tableVal    (form) (car (errset form->nh_src->page1->nh_input->value    t)))
(defun nh_mdPathVal   (form) (car (errset form->nh_src->page1->nh_mdPath->value   t)))
(defun nh_svgPathVal  (form) (car (errset form->nh_src->page2->nh_svgPath->value  t)))
(defun nh_vecWidthVal (form) (car (errset form->nh_src->page2->nh_vecWidth->value t)))
(defun nh_setTableVal (form txt) (errset (form->nh_src->page1->nh_input->value = txt) t))

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

; Which SOURCE tab is active? Returns 'svg when the SVG page shows, else 'table.
; The Tab field's value is the 1-based page index (1="Table", 2="SVG"). The tab
; field itself is a TOP-LEVEL form field, so -- unlike the fields INSIDE a page
; (reached via form->nh_src->page<N>->field, see the nh_*Val helpers) -- it IS
; reachable as form->nh_src. Defaults to 'table if the read ever errors.
; Ref: skuiref.pdf hiCreateTabField p.654 ("form->field->value" = page number).
(defun nh_guiActiveSrc (form)
  (let ((v (car (errset form->nh_src->value t))))
    (if (equal v 2) 'svg 'table)))

; Parse: report on the ACTIVE source -- table dims, or SVG-file readiness.
(defun nh_guiParseCB (form)
  (if (eq (nh_guiActiveSrc form) 'svg)
      (nh_guiParseSvgCB form)
      (nh_guiParseTableCB form))
  t)

; Parse (table): report row x col count (or an error) on the status line.
(defun nh_guiParseTableCB (form)
  (let (res table)
    (setq res (errset (nhParseText (nh_tableVal form)) t))
    (cond
      ((null res)
        (nh_setStatus form "parse error -- see CIW"))
      (t
        (setq table (car res))
        (nh_setStatus form
          (sprintf nil "%d rows x %d cols%s"
            (length (get table 'rows)) (get table 'ncols)
            (if (get table 'header) " (header)" "")))))
    t))

; Parse (SVG): validate the path is set + exists (the real parse runs on Place).
(defun nh_guiParseSvgCB (form)
  (let ((svg (nh_svgPathVal form)))
    (cond
      ((or (null svg) (equal svg ""))
        (nh_setStatus form "enter an SVG file path to import"))
      ((not (isFile svg))
        (nh_setStatus form "SVG file not found -- check the path"))
      (t
        (nh_setStatus form "SVG ready -- click Place"))))
  t)

; Place a built IR via the shared ghost placement (nhPlaceIRGhost): all three
; Output modes drag a SYMBOL master with a live cursor preview, one click to
; drop (loose flattens to note shapes afterward). Shared by both source paths
; (table + SVG) -- the Place button dispatches by tab -- so vector figures get
; the same three Output modes as tables.
(defun nh_guiDispatchIR (form ir)
  (let (sym)
    (setq sym (nh_modeSym (or form->nh_mode->value "loose shapes")))
    (cond
      ((nhPlaceIRGhost ir sym form->nh_symCell->value form->nh_symLib->value)
        (nh_setStatus form
          (cond
            ((eq sym 'loose)
              "drag the note in the schematic, click to drop (loose shapes)")
            ((eq sym 'resizable)
              "drag the note, click to drop -- resizable, q to resize")
            (t
              "drag the note symbol in the schematic, click to drop"))))
      (t
        (nh_setStatus form
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
  (nh_guiSyncFields scope item)        ; scope = the form this cyclic field is on
  t)

; Place: dispatch by the ACTIVE source tab. SVG tab -> import the vector file
; and place it; Table tab -> parse the table text, build the IR, place it.
; (Previously this was table-only, so it placed the table even while the SVG tab
; was showing -- the "I clicked Place and still got the table" bug.)
(defun nh_guiPlaceCB (form)
  (if (eq (nh_guiActiveSrc form) 'svg)
      (nh_guiImportCB form)
      (nh_guiPlaceTableCB form))
  t)

; Place (table): parse + build IR, then dispatch by Output mode.
(defun nh_guiPlaceTableCB (form)
  (let (res table cfg ir)
    (setq res (errset (nhParseText (nh_tableVal form)) t))
    (cond
      ((null res)
        (nh_setStatus form "parse error -- see CIW"))
      (t
        (setq table (car res))
        (setq cfg   (nh_guiReadCfg form))
        (setq ir    (errset (nh_buildIR table cfg) t))
        (cond
          ((null ir)
            (nh_setStatus form "layout error -- see CIW"))
          (t
            (nh_guiDispatchIR form (car ir))))))
    t))

; Import SVG (Feature A): run the external parser, then dispatch by Output mode
; (a vector figure can go in as loose shapes, a symbol, or a resizable symbol).
; Reached via the Place button when the SVG tab is active (nh_guiPlaceCB).
(defun nh_guiImportCB (form)
  (let (svg width res)
    (setq svg (nh_svgPathVal form))
    (cond
      ((or (null svg) (equal svg ""))
        (nh_setStatus form "enter an SVG file path to import"))
      ((not (isFile svg))
        (nh_setStatus form "SVG file not found -- check the path"))
      (t
        (setq width (atof (or (nh_vecWidthVal form) "5")))
        (when (or (null width) (leqp width 0)) (setq width 5.0))
        (nh_setStatus form "parsing SVG...")
        (setq res (errset (nhImportVector svg width) t))
        (cond
          ((null res)
            (nh_setStatus form "SVG import failed -- see CIW"))
          ((null (car res))
            (nh_setStatus form "no drawable geometry in the SVG"))
          (t
            (nh_guiDispatchIR form (car res))))))
    t))

; Toolbox...: launch the standalone Python data-prep GUI (Image->SVG, Table->
; Markdown) in its own non-blocking window. It writes .svg/.md files you then
; point the SVG-path / Table-file fields at -- no live data bridge needed.
(defun nh_guiToolboxCB (form)
  (let ((r (car (errset (nhLaunchToolbox) t))))
    (nh_setStatus form
      (cond
        ((eq r 'ok)        "toolbox launched -- prep a .svg/.md, then load it here")
        ((eq r 'no-script) "toolbox.py not found -- check note_helperDir")
        ((eq r 'no-tk)     "Python tkinter/Tcl unusable -- check python3-tkinter")
        ((eq r 'launch-failed) "toolbox launch failed -- see CIW")
        (t                 "toolbox launch error -- see CIW")))
    t))

; OK/close: nothing to persist (table text is transient by design).
(defun nh_guiCloseCB (form)
  t)

; Load file: read the path in nh_mdPath into the input MLT (Markdown or TSV;
; the parser auto-detects either on Parse/Place).
(defun nh_guiLoadFileCB (form)
  (let (path txt)
    (setq path (nh_mdPathVal form))
    (cond
      ((or (null path) (equal path ""))
        (nh_setStatus form "enter a file path to load"))
      ((not (isFile path))
        (nh_setStatus form "file not found -- check the path"))
      (t
        (setq txt (errset (nh_readFile path) t))
        (cond
          ((null txt)
            (nh_setStatus form "read failed -- see CIW"))
          (t
            (nh_setTableVal form (car txt))
            (nh_setStatus form
              (sprintf nil "loaded %s -- click Parse" path))))))
    t))

; Save .md: parse the input (Markdown or TSV) and write it back out as a
; normalized, aligned Markdown file at nh_mdPath.
(defun nh_guiSaveMdCB (form)
  (let (path res ok)
    (setq path (nh_mdPathVal form))
    (cond
      ((or (null path) (equal path ""))
        (nh_setStatus form "enter a file path to save to"))
      (t
        (setq res (errset (nhTextToMarkdown (nh_tableVal form)) t))
        (cond
          ((null res)
            (nh_setStatus form "parse/convert error -- see CIW"))
          (t
            (setq ok (errset (nh_writeFile path (car res)) t))
            (if (and ok (car ok))
                (nh_setStatus form (sprintf nil "saved %s" path))
                (nh_setStatus form "write failed -- see CIW"))))))
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
        fStatus fFont fMax fGrid fMode fSymLib fSym fParse fPlace fTool
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
    ; 'existingFile -> the Browse (...) dialog is an OPEN/file-PICKER, not a
    ; Save-As dialog ('anyFile was showing a save dialog). The field just holds
    ; a path; the Load file / Save .md buttons do the actual read/write. To Save
    ; to a NOT-yet-existing file, type/edit the name in the field (it's editable)
    ; -- the picker only lists existing files. skuiref hiCreateFileSelectorField
    ; p.542 ('existingFile = Open, 'anyFile = Save As).
    (setq fMdPath (hiCreateFileSelectorField ?name 'nh_mdPath ?mode 'existingFile
                    ?prompt "Table file (.md / .tsv)" ?value ""))
    (nh_cfgFileSel fMdPath "Choose a table file" "Markdown/TSV (*.md *.tsv);;All Files (*)")
    (setq fLoad   (hiCreateButton ?name 'nh_btnLoad ?buttonText "Load file"
                    ?callback "(nh_guiLoadFileCB (nh_curForm))"))
    (setq fSaveMd (hiCreateButton ?name 'nh_btnSaveMd ?buttonText "Save .md"
                    ?callback "(nh_guiSaveMdCB (nh_curForm))"))
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
    ; (No global stashing: callbacks reach the Tab-page fields through the live
    ; form -- form->nh_src->page<N>->field -- so a rebuilt form can't leave a
    ; stale handle behind. See the nh_*Val helpers above.)
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
                    ?callback "(nh_guiParseCB (nh_curForm))"))
    (setq fPlace  (hiCreateButton ?name 'nh_btnPlace ?buttonText "Place..."
                    ?callback "(nh_guiPlaceCB (nh_curForm))"))
    (setq fTool   (hiCreateButton ?name 'nh_btnToolbox ?buttonText "Toolbox..."
                    ?callback "(nh_guiToolboxCB (nh_curForm))"))
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
        (list fPlace  (list 100 504) (list 110 rowH) 0)
        (list fTool   (list 220 504) (list 110 rowH) 0))
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
