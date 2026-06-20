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
    (setq res (errset (nhParseText form->nh_input->value) t))
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

; Place a built IR list per the Output cyclic field -- loose note shapes, a
; reusable non-netlisting symbol, or a self-contained resizable (pcell) symbol
; whose `scale` param resizes it later via q. Shared by the table Place button
; and the SVG Import button, so vector figures get the same three modes.
(defun nh_guiDispatchIR (form ir)
  (let (mode resizable schCv lib symCell master)
    (setq mode (or form->nh_mode->value "loose shapes"))
    (cond
      ((or (equal mode "symbol") (equal mode "symbol (resizable)"))
        (setq resizable (equal mode "symbol (resizable)"))
        (setq schCv (geGetEditCellView))
        (cond
          ((null schCv)
            (nh_setFieldVal "nh_form" 'nh_status
              "open a schematic first (need somewhere to place the symbol)"))
          (t
            (setq lib     schCv~>libName)
            (setq symCell (or form->nh_symCell->value "nh_note"))
            (when (equal symCell "") (setq symCell "nh_note"))
            (setq master (errset
              (if resizable
                  (nh_buildResizableFromIR ir lib symCell)
                  (nh_buildSymbolFromIR    ir lib symCell)) t))
            (cond
              ((null master)
                (nh_setFieldVal "nh_form" 'nh_status "symbol build failed -- see CIW"))
              (t
                (nh_setFieldVal "nh_form" 'nh_status
                  (sprintf nil "click to place %s %s/%s"
                    (if resizable "resizable symbol (q to resize)" "symbol") lib symCell))
                (nhPlaceSymbolInst (car master) schCv))))))
      (t
        (nh_setFieldVal "nh_form" 'nh_status "click in the schematic to place...")
        (nhPlaceIR ir)))
    t))

; Place (table): parse + build IR, then dispatch by Output mode.
(defun nh_guiPlaceCB (form)
  (let (res table cfg ir)
    (setq res (errset (nhParseText form->nh_input->value) t))
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
    (setq svg (form->nh_svgPath->value))
    (cond
      ((or (null svg) (equal svg ""))
        (nh_setFieldVal "nh_form" 'nh_status "enter an SVG file path to import"))
      ((not (isFile svg))
        (nh_setFieldVal "nh_form" 'nh_status "SVG file not found -- check the path"))
      (t
        (setq width (atof (or form->nh_vecWidth->value "5")))
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
    (setq path (form->nh_mdPath->value))
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
            (nh_setFieldVal "nh_form" 'nh_input (car txt))
            (nh_setFieldVal "nh_form" 'nh_status
              (sprintf nil "loaded %s -- click Parse" path))))))
    t))

; Save .md: parse the input (Markdown or TSV) and write it back out as a
; normalized, aligned Markdown file at nh_mdPath.
(defun nh_guiSaveMdCB (form)
  (let (path res ok)
    (setq path (form->nh_mdPath->value))
    (cond
      ((or (null path) (equal path ""))
        (nh_setFieldVal "nh_form" 'nh_status "enter a file path to save to"))
      (t
        (setq res (errset (nhTextToMarkdown form->nh_input->value) t))
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
(defun nhOpenGUI (@optional initialText)
  (let (fields form rowH y mlW mlH sample)
    (setq rowH 28) (setq mlW 360) (setq mlH 150) (setq y 0)
    (setq sample (or initialText nh_guiSample))
    (setq fields nil)
    ; --- input MLT (Markdown / TSV, auto-detected) ---
    (setq fields (cons
      (list (hiCreateMLTextField
              ?name 'nh_input ?prompt "Table (Markdown / TSV)"
              ?value sample
              ?hasVerticalScrollbar t ?hasHorizontalScrollbar nil
              ?enableWordWrap nil)
            (list 0 y) (list mlW mlH) 0)
      fields))
    (setq y (plus y mlH 6))
    ; --- status (read-only) ---
    (setq fields (cons
      (list (hiCreateStringField
              ?name 'nh_status ?prompt "Status" ?value "(not parsed)" ?editable nil)
            (list 0 y) (list mlW rowH) 80)
      fields))
    (setq y (plus y rowH 4))
    ; --- table file: path + Load/Save (import a .md/.tsv, export normalized .md) ---
    (setq fields (cons
      (list (hiCreateStringField ?name 'nh_mdPath
              ?prompt "Table file (.md / .tsv)" ?value "")
            (list 0 y) (list 280 rowH) 190)
      fields))
    (setq y (plus y rowH 4))
    (setq fields (cons
      (list (hiCreateButton ?name 'nh_btnLoad ?buttonText "Load file"
              ?callback "(nh_guiLoadFileCB nh_form)")
            (list 0 y) (list 90 rowH) 0)
      fields))
    (setq fields (cons
      (list (hiCreateButton ?name 'nh_btnSaveMd ?buttonText "Save .md"
              ?callback "(nh_guiSaveMdCB nh_form)")
            (list 100 y) (list 90 rowH) 0)
      fields))
    (setq y (plus y rowH 8))
    ; --- font height ---
    (setq fields (cons
      (list (hiCreateStringField ?name 'nh_fontHeight
              ?prompt "Size = text height (scales whole table)" ?value "0.125")
            (list 0 y) (list 280 rowH) 190)
      fields))
    (setq y (plus y rowH 4))
    ; --- max column chars (0 = off) ---
    (setq fields (cons
      (list (hiCreateStringField ?name 'nh_maxCols ?prompt "Max col chars (0=off)" ?value "0")
            (list 0 y) (list 200 rowH) 130)
      fields))
    (setq y (plus y rowH 4))
    ; --- grid style ---
    (setq fields (cons
      (list (hiCreateCyclicField ?name 'nh_grid ?prompt "Grid"
              ?choices (list "full" "hrules" "box+header") ?value "full")
            (list 0 y) (list 200 rowH) 110)
      fields))
    (setq y (plus y rowH 4))
    ; --- output mode ---
    (setq fields (cons
      (list (hiCreateCyclicField ?name 'nh_mode ?prompt "Output"
              ?choices (list "loose shapes" "symbol" "symbol (resizable)") ?value "loose shapes")
            (list 0 y) (list 230 rowH) 110)
      fields))
    (setq y (plus y rowH 4))
    ; --- symbol cell name (used only when Output = symbol) ---
    (setq fields (cons
      (list (hiCreateStringField ?name 'nh_symCell
              ?prompt "Symbol cell (symbol mode)" ?value "nh_note")
            (list 0 y) (list 280 rowH) 190)
      fields))
    (setq y (plus y rowH 8))
    ; --- Feature A: SVG vector import (file path + target width) ---
    (setq fields (cons
      (list (hiCreateStringField ?name 'nh_svgPath
              ?prompt "SVG file (vector import)" ?value "")
            (list 0 y) (list 280 rowH) 190)
      fields))
    (setq y (plus y rowH 4))
    (setq fields (cons
      (list (hiCreateStringField ?name 'nh_vecWidth
              ?prompt "Figure width (user units)" ?value "5")
            (list 0 y) (list 120 rowH) 190)
      fields))
    (setq y (plus y rowH 8))
    ; --- buttons: Parse / Place / Import SVG ---
    (setq fields (cons
      (list (hiCreateButton ?name 'nh_btnParse ?buttonText "Parse"
              ?callback "(nh_guiParseCB nh_form)")
            (list 0 y) (list 90 rowH) 0)
      fields))
    (setq fields (cons
      (list (hiCreateButton ?name 'nh_btnPlace ?buttonText "Place..."
              ?callback "(nh_guiPlaceCB nh_form)")
            (list 100 y) (list 90 rowH) 0)
      fields))
    (setq fields (cons
      (list (hiCreateButton ?name 'nh_btnImport ?buttonText "Import SVG..."
              ?callback "(nh_guiImportCB nh_form)")
            (list 200 y) (list 120 rowH) 0)
      fields))
    (setq y (plus y rowH 8))
    ; --- form ---
    (setq form (hiCreateAppForm
      ?name 'nh_form
      ?formTitle "Note Helper"
      ?fields (reverse fields)
      ?callback (list "(nh_guiCloseCB nh_form)" "(nh_guiCloseCB nh_form)")
      ?buttonLayout 'OKCancelDef))
    (hiInstantiateForm form)
    (errset (hiSetFormSize form (list (plus mlW 70) (plus y 80))) t)
    (hiDisplayForm 'nh_form)
    'nh_form))

; ---------------------------------------------------------------------------
; MyTool plugin self-registration (mirror dgenGui.il tail). getd guard so the
; plugin still loads when the mytool framework is absent. Ref mytool/README.md.
; ---------------------------------------------------------------------------
(when (getd 'mtRegister)
  (mtRegister "Note Helper" 'nhOpenGUI "Open the Note Helper GUI"))
