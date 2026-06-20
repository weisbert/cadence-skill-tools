; nhCore.il -- note-helper core engine (v1 / M1: table -> loose note shapes).
;
; Pipeline:  text --(parse)--> table model --(layout)--> IR --(emit)--> notes
;
;   table model = (nil 'rows <list of rows>          ; each row = list of cell strings
;                      'ncols <int>
;                      'aligns <list of 'left|'right|'center>
;                      'header t|nil)                ; row 0 is a header row?
;
;   IR element  = (nil 'kind 'shape 'stype <str> 'lstyle <str>
;                                  'points <list of (x y)> 'width <n|nil>)
;               | (nil 'kind 'label 'point (x y) 'text <str> 'height <n>
;                                  'just <str> 'orient "R0" 'font "fixed"
;                                  'ltype "normalLabel")
;
; Emit primitives (verified IC6.1.8):
;   schCreateNoteShape(cv t_type t_lineStyle l_points [n_width])  skcompref.pdf p.242
;   schCreateNoteLabel(cv l_point t_text t_just t_orient t_font n_height t_type) skcompref.pdf p.240
; Both are NON-electrical (do not affect connectivity) and work in a
; schematic OR symbol cellview.
;
; SKILL conventions: no let* (single let + ordered setq); pcreMatchp /
; pcreReplace over rex (Ref user feedback); plists are nil-headed DPLs.

; ===========================================================================
; String helpers
; ===========================================================================

; Trim leading/trailing whitespace (incl. stray \r from CRLF input).
; Ref: skill_tools.il proven pcreReplace(obj subject repl index) usage.
(defun nh_trim (s)
  (if (stringp s)
      (pcreReplace (pcreCompile "^\\s+|\\s+$") s "" 0)
      s))

; True if the 1-char string ch occurs anywhere in str.
; parseString(str "") splits into single-char strings (sklangref p.165).
(defun nh_strHasChar (str ch)
  (let ((found nil) c)
    (foreach c (parseString str "") (when (equal c ch) (setq found t)))
    found))

; True if any line contains the 1-char string ch.
(defun nh_anyContains (lines ch)
  (let ((found nil) ln)
    (foreach ln lines (when (nh_strHasChar ln ch) (setq found t)))
    found))

; Truncate string c to cap chars, marking truncation with a trailing "~".
; substring is 1-indexed (sklangref p.223).
(defun nh_truncate (c cap)
  (cond
    ((not (stringp c)) c)
    ((leqp cap 0) c)
    ((greaterp (strlen c) cap)
      (if (greaterp cap 1)
          (strcat (substring c 1 (sub1 cap)) "~")
          (substring c 1 1)))
    (t c)))

; ===========================================================================
; List helpers
; ===========================================================================

(defun nh_repeatList (elt n)
  (let (out) (for i 1 n (setq out (cons elt out))) out))

; Pad (with fill) or truncate lst to exactly n elements.
(defun nh_padList (lst n fill)
  (let ((len (length lst)) out)
    (cond
      ((equal len n) lst)
      ((greaterp len n)
        (for i 0 (sub1 n) (setq out (cons (nth i lst) out)))
        (reverse out))
      (t
        (setq out (reverse lst))
        (for i (add1 len) n (setq out (cons fill out)))
        (reverse out)))))

; ===========================================================================
; Parsing:  text -> table model
; ===========================================================================

; Split into trimmed, non-empty lines.
(defun nh_splitLines (text)
  (let ((raw (parseString text "\n")) out ln)
    (foreach ln raw
      (setq ln (nh_trim ln))
      (unless (equal ln "") (setq out (cons ln out))))
    (reverse out)))

; Alignment from a Markdown separator cell: :--:/:-: center, --: right,
; :-- left, --- default(left).
(defun nh_alignOf (c)
  (let ((s (nh_trim c)))
    (cond
      ((pcreMatchp "^:-*:$" s) 'center)
      ((pcreMatchp "^-+:$"  s) 'right)
      ((pcreMatchp "^:-+$"  s) 'left)
      (t 'left))))

; A separator row: every cell is only dashes with optional colon ends.
(defun nh_isSepRow (cells)
  (and cells
    (let ((ok t) c)
      (foreach c cells
        (unless (pcreMatchp "^:?-+:?$" (nh_trim c)) (setq ok nil)))
      ok)))

; Split one Markdown pipe row into trimmed cells, dropping the empty cells
; produced by the surrounding pipes. parseString(... "|" t) keeps interior
; empty cells (the t flag preserves empties -- sklangref p.166).
(defun nh_splitPipeRow (line)
  (let (cells out c)
    (setq cells (parseString line "|" t))
    (setq out (foreach mapcar c cells (nh_trim c)))
    (when (and out (equal (car out) "")) (setq out (cdr out)))
    (when (and out (equal (car (last out)) ""))
      (setq out (reverse (cdr (reverse out)))))
    out))

; Assemble final table model from optional header cells + data rows + aligns.
(defun nh_assembleTable (headerCells rows aligns)
  (let (allRows ncols hdrFlag r)
    (cond
      (headerCells (setq allRows (cons headerCells rows)) (setq hdrFlag t))
      (t           (setq allRows rows)                    (setq hdrFlag nil)))
    (setq ncols 0)
    (foreach r allRows (setq ncols (max ncols (length r))))
    (when (equal ncols 0) (error "note-helper: no columns parsed"))
    (unless aligns (setq aligns (nh_repeatList 'left ncols)))
    (setq aligns  (nh_padList aligns ncols 'left))
    (setq allRows (foreach mapcar r allRows (nh_padList r ncols "")))
    (list nil 'rows allRows 'ncols ncols 'aligns aligns 'header hdrFlag)))

; Markdown pipe table -> model. Header = row above the separator (if any);
; alignment from the separator; rows below are data. No separator -> every
; line is a headerless data row.
(defun nh_parseMarkdown (lines)
  (let (sepIdx aligns header rows i ln c)
    (setq i 0)
    (foreach ln lines
      (when (and (null sepIdx) (nh_isSepRow (nh_splitPipeRow ln))) (setq sepIdx i))
      (setq i (add1 i)))
    (cond
      (sepIdx
        (setq aligns (foreach mapcar c (nh_splitPipeRow (nth sepIdx lines)) (nh_alignOf c)))
        (when (greaterp sepIdx 0)
          (setq header (nh_splitPipeRow (nth (sub1 sepIdx) lines))))
        (setq rows nil)
        (for k (add1 sepIdx) (sub1 (length lines))
          (setq rows (cons (nh_splitPipeRow (nth k lines)) rows)))
        (setq rows (reverse rows)))
      (t
        (setq rows (foreach mapcar ln lines (nh_splitPipeRow ln)))
        (setq aligns nil)
        (setq header nil)))
    (nh_assembleTable header rows aligns)))

; TSV -> model. First row is taken as the header; alignment defaults to left.
; parseString(... "\t" t) preserves empty cells between tabs.
(defun nh_parseTsv (lines)
  (let (rows ln c)
    (setq rows (foreach mapcar ln lines
                 (foreach mapcar c (parseString ln "\t" t) (nh_trim c))))
    (nh_assembleTable (car rows) (cdr rows) nil)))

; Auto-detect format and parse. Markdown if any line has '|', else TSV.
(defun nhParseText (text)
  (let (lines fmt)
    (setq lines (nh_splitLines text))
    (when (null lines) (error "note-helper: empty input"))
    (setq fmt (cond ((nh_anyContains lines "|") 'markdown) (t 'tsv)))
    (if (eq fmt 'markdown) (nh_parseMarkdown lines) (nh_parseTsv lines))))

; ===========================================================================
; IR constructors
; ===========================================================================

(defun nh_shape (stype lstyle points width)
  (list nil 'kind 'shape 'stype stype 'lstyle lstyle 'points points 'width width))

(defun nh_label (point text height just)
  (list nil 'kind 'label 'point point 'text text 'height height
        'just just 'orient "R0" 'font "fixed" 'ltype "normalLabel"))

; ===========================================================================
; Layout:  table model -> IR (built at origin; top-left at 0:0, rows go down)
; ===========================================================================

(defun nh_buildIR (table @optional cfg)
  (let (fontHeight charAspect pad paddingRatio gridStyle maxCols headerScale charW
        rows ncols aligns header nrows
        colW colX totalW acc
        rowHs rowTop accy totalH drawH drawV
        shapes labels i j y y2 w x xleft xright cell align h just
        midY rowTopI rowBotI hh r c cw ri)
    ; --- config ---
    (setq fontHeight   (nh_cfgGet cfg 'fontHeight))
    (setq charAspect   (nh_cfgGet cfg 'charAspect))
    (setq paddingRatio (nh_cfgGet cfg 'paddingRatio))
    (setq gridStyle    (nh_cfgGet cfg 'gridStyle))
    (setq maxCols      (nh_cfgGet cfg 'maxColWidth))
    (setq headerScale  (nh_cfgGet cfg 'headerScale))
    (when (or (null fontHeight) (leqp fontHeight 0)) (setq fontHeight 0.125))
    (setq charW (times fontHeight charAspect))   ; column glyph advance
    (setq pad   (times fontHeight paddingRatio)) ; proportional cell inset
    ; --- table ---
    (setq rows   (get table 'rows))
    (setq ncols  (get table 'ncols))
    (setq aligns (get table 'aligns))
    (setq header (get table 'header))
    (when (and maxCols (greaterp maxCols 0))
      (setq rows (foreach mapcar r rows
                   (foreach mapcar c r (nh_truncate c maxCols)))))
    (setq nrows (length rows))
    (when (equal nrows 0) (error "note-helper: no rows to render"))
    ; --- column widths (use the larger of data vs scaled-header text) -> edges ---
    (setq colW nil)
    (for j 0 (sub1 ncols)
      (setq w 0)   ; max scaled text width in column j
      (for ri 0 (sub1 nrows)
        (setq cell (or (nth j (nth ri rows)) ""))
        (setq w (max w (times (strlen cell) charW
                              (if (and header (equal ri 0)) headerScale 1.0)))))
      (setq colW (cons (plus w (times 2 pad)) colW)))
    (setq colW (reverse colW))
    (setq colX nil) (setq acc 0)
    (foreach cw colW (setq colX (cons acc colX)) (setq acc (plus acc cw)))
    (setq colX (reverse colX))
    (setq totalW acc)
    ; --- row heights + top y of each row ---
    (setq rowHs nil)
    (for i 0 (sub1 nrows)
      (setq hh (plus (if (and header (equal i 0)) (times fontHeight headerScale) fontHeight)
                     (times 2 pad)))
      (setq rowHs (cons hh rowHs)))
    (setq rowHs (reverse rowHs))
    (setq rowTop nil) (setq accy 0)
    (for i 0 (sub1 nrows)
      (setq rowTop (cons accy rowTop))
      (setq accy (difference accy (nth i rowHs))))
    (setq rowTop (reverse rowTop))
    (setq totalH (minus accy))
    ; --- grid flags ---
    (setq drawH (memq gridStyle '(full hrules)))
    (setq drawV (eq gridStyle 'full))
    ; --- shapes (outer box, horizontal rules, header double-rule, verticals) ---
    (setq shapes nil)
    (setq shapes (cons (nh_shape "rectangle" "solid"
                         (list (list 0 (minus totalH)) (list totalW 0)) nil) shapes))
    (for i 1 (sub1 nrows)
      (setq y (nth i rowTop))
      (when (or drawH (and header (equal i 1)))
        (setq shapes (cons (nh_shape "line" "solid"
                             (list (list 0 y) (list totalW y)) nil) shapes))
        (when (and header (equal i 1))
          (setq y2 (plus y (times pad 0.4)))
          (setq shapes (cons (nh_shape "line" "solid"
                               (list (list 0 y2) (list totalW y2)) nil) shapes)))))
    (when drawV
      (for j 1 (sub1 ncols)
        (setq x (nth j colX))
        (setq shapes (cons (nh_shape "line" "solid"
                             (list (list x 0) (list x (minus totalH))) nil) shapes))))
    ; --- labels (one per non-empty cell, aligned within its column) ---
    (setq labels nil)
    (for i 0 (sub1 nrows)
      (setq rowTopI (nth i rowTop))
      (setq rowBotI (difference rowTopI (nth i rowHs)))
      (setq midY (times 0.5 (plus rowTopI rowBotI)))
      (setq h (if (and header (equal i 0)) (times fontHeight headerScale) fontHeight))
      (for j 0 (sub1 ncols)
        (setq cell (or (nth j (nth i rows)) ""))
        (unless (equal cell "")
          (setq align  (nth j aligns))
          (setq xleft  (nth j colX))
          (setq xright (plus xleft (nth j colW)))
          (cond
            ((eq align 'right)  (setq x (difference xright pad)) (setq just "centerRight"))
            ((eq align 'center) (setq x (times 0.5 (plus xleft xright))) (setq just "centerCenter"))
            (t                  (setq x (plus xleft pad)) (setq just "centerLeft")))
          (setq labels (cons (nh_label (list x midY) cell h just) labels)))))
    ; shapes first (drawn under), labels second
    (append (reverse shapes) (reverse labels))))

; ===========================================================================
; Emit:  IR -> note primitives in cellview cv, translated by offset (x y)
; ===========================================================================

(defun nh_emitIR (cv ir offset)
  (let ((ox (car offset)) (oy (cadr offset)) (cnt 0) pts p w el pt)
    (foreach el ir
      (case (get el 'kind)
        (shape
          (setq pts (foreach mapcar pt (get el 'points)
                      (list (plus (car pt) ox) (plus (cadr pt) oy))))
          (setq w (get el 'width))
          (if w
              (schCreateNoteShape cv (get el 'stype) (get el 'lstyle) pts w)   ; skcompref.pdf p.242
              (schCreateNoteShape cv (get el 'stype) (get el 'lstyle) pts))
          (setq cnt (add1 cnt)))
        (label
          (setq p (get el 'point))
          (schCreateNoteLabel cv (list (plus (car p) ox) (plus (cadr p) oy))   ; skcompref.pdf p.240
            (get el 'text) (get el 'just) (get el 'orient)
            (get el 'font) (get el 'height) (get el 'ltype))
          (setq cnt (add1 cnt)))))
    cnt))

; ===========================================================================
; Interactive placement:  build at origin, place at one click
; ===========================================================================

; Resolve the schematic cellview to draw into (current edit cellview).
; geGetEditCellView() -> d_cellview  (skdfref.pdf p.104)
(defun nh_targetCv (@optional cv)
  (or cv (geGetEditCellView)))

; Stash IR + cv, then prompt for a single point. The actual emit happens in
; nh_placeDoneCB after the user clicks.
; enterPoint(?prompts ... ?doneProc "fn") ; skuiref.pdf p.1197 (callback (w done pts))
(defun nhPlaceIR (ir @optional cv)
  (let ((target (nh_targetCv cv)))
    (cond
      ((null ir)     (warn "nhPlaceIR: empty IR -- nothing to place.\n") nil)
      ((null target) (warn "nhPlaceIR: no editable cellview. Open a schematic first.\n") nil)
      (t
        (setq nh_pendingKind 'shapes)
        (setq nh_pendingIR ir)
        (setq nh_pendingCv target)
        (enterPoint
          ?prompts  (list "note-helper: click to place the note group")
          ?doneProc "nh_placeDoneCB")
        t))))

; enterPoint done-callback. done=t and car(pts) is the entered point.
; Dispatches on nh_pendingKind: 'shapes emits the IR; 'symbol instances the
; pending master (and stamps the instance non-netlisting too).
(defun nh_placeDoneCB (w done pts)
  (let (off kind inst)
    (when (and done pts)
      (setq off  (car pts))
      (setq kind (and (boundp 'nh_pendingKind) nh_pendingKind))
      (cond
        ((eq kind 'symbol)
          (when (and nh_pendingMaster nh_pendingCv)
            ; dbCreateInst(cv master name point orient) ; skdfref.pdf p.941
            (setq inst (errset (dbCreateInst nh_pendingCv nh_pendingMaster nil off "R0") t))
            (when (and inst (car inst))
              (errset (dbReplaceProp (car inst) "nlAction" "string" "ignore") t))
            (errset (hiRedraw w) t)))
        (t
          (when (and nh_pendingIR nh_pendingCv)
            (errset (nh_emitIR nh_pendingCv nh_pendingIR off) t)
            (errset (hiRedraw w) t))))))     ; hiRedraw(w) ; skuiref.pdf p.1015
  (setq nh_pendingKind nil)
  (setq nh_pendingIR nil)
  (setq nh_pendingCv nil)
  (setq nh_pendingMaster nil)
  t)

; ===========================================================================
; Symbol output mode (M3): encapsulate the table as a reusable, non-netlisting
; symbol, then place an instance.
; ===========================================================================

; Draw IR into a fresh symbol cellview and stamp it non-netlisting.
; Returns the symbol cellview (usable as an instance master).
; NOTE: opens the symbol view in "w" mode -- OVERWRITES symLib/symCell/symbol
; if it already exists. Pick a dedicated cell name.
(defun nh_buildSymbolFromIR (ir symLib symCell)
  (let (symCv)
    (when (null ir) (error "note-helper: empty IR for symbol"))
    ; dbOpenCellViewByType(lib cell viewName viewType mode) ; skdfref.pdf p.898
    (setq symCv (dbOpenCellViewByType symLib symCell "symbol" "schematicSymbol" "w"))
    (when (null symCv)
      (error (strcat "note-helper: cannot create symbol " symLib "/" symCell "/symbol")))
    (nh_emitIR symCv ir (list 0 0))
    ; nlAction="ignore": the netlister skips instances whose master carries it.
    ; Ref skartistref.pdf p.150; constraintsSKILL.pdf p.460; dbReplaceProp skdfref.pdf p.557
    (errset (dbReplaceProp symCv "nlAction" "string" "ignore") t)
    (dbSave symCv)
    symCv))

(defun nhBuildSymbol (text symLib symCell @optional cfg)
  (nh_buildSymbolFromIR (nh_buildIR (nhParseText text) cfg) symLib symCell))

; Place an instance of a (note) symbol into a schematic at one click.
(defun nhPlaceSymbolInst (master schematicCv)
  (cond
    ((null master)      (warn "nhPlaceSymbolInst: no symbol master.\n") nil)
    ((null schematicCv) (warn "nhPlaceSymbolInst: no schematic cellview.\n") nil)
    (t
      (setq nh_pendingKind 'symbol)
      (setq nh_pendingMaster master)
      (setq nh_pendingCv schematicCv)
      (enterPoint
        ?prompts  (list "note-helper: click to place the note symbol")
        ?doneProc "nh_placeDoneCB")
      t)))

; Top-level: build the symbol from text, then place an instance interactively.
(defun nhPlaceTableAsSymbol (text symLib symCell @optional cfg schematicCv)
  (let (target master)
    (setq target (or schematicCv (geGetEditCellView)))
    (when (null target) (error "nhPlaceTableAsSymbol: no schematic edit cellview"))
    (setq master (nhBuildSymbol text symLib symCell cfg))
    (nhPlaceSymbolInst master target)))

; ===========================================================================
; Resizable symbol output (M3b): encapsulate the table as a SELF-CONTAINED
; schematicSymbol PCELL whose single parameter `scale` proportionally resizes
; the whole note. Select the placed instance and press q (Edit Object
; Properties) -> edit "Size scale" -> the note re-renders at the new size.
;
; "Self-contained" = the pcell body bakes the base IR as a literal and draws
; it with db primitives only (dbCreateRect / dbCreateLine / dbCreateLabel). It
; calls NO nh_* helper, so a design carrying the note renders AND resizes
; without note_helper being loaded -- only the pcell master cell must be
; present, and it lives in the design's own library (same as any placed
; symbol). note_helper is needed only to CREATE the note.
;
; The base IR is built at scale 1; multiplying every coordinate and font
; height by `scale` is exactly a re-layout at fontHeight*scale, because
; nh_buildIR is linear in font height -- so one knob scales text, cells,
; padding and gaps together.
;
; Verified live IC6.1.8: a schematicSymbol pcell re-evaluates geometry from
; the scale parameter (box width 4 @ s=1 -> 8 @ s=2, text scales with it); the
; CDF param shows editable "Size scale" on the instance; dbCreateInst on the
; (super) master places a default-scale instance with 0 pins.
; Refs: pcDefinePCell skpcellref.pdf p.20 (schematicSymbol is a valid view
;   type; body restricted to db/dd/cdf/rod/tech + basic SKILL, p.27; pcCellView
;   is the body's cellview, p.29/143); dbCreateRect/Line/Label skdfref.pdf
;   p.518/516/524; cdfCreateBaseCellCDF/cdfCreateParam/cdfSaveCDF skartistref
;   p.952/955/963 (editable/display are STRING "t", not symbol t).
; ===========================================================================

; SKILL source of the self-contained pcell body. Only db + basic-SKILL calls
; appear, so the saved master evaluates with nothing else loaded. `irLit` is
; the base-scale IR rendered re-readably with %L; the body scales it by the
; `scale` parameter at evaluation time.
(defun nh_pcellSource (irLit symLib symCell)
  (buildString
    (list
      "pcDefinePCell("
      (strcat "  list( ddGetObj(\"" symLib "\") \"" symCell "\" \"symbol\" \"schematicSymbol\" )")
      "  ( (scale float 1.0) )"
      "  let( (cv s ir el p pts)"
      "    cv = pcCellView"
      "    s  = scale"
      (strcat "    ir = '" irLit)
      "    foreach( el ir"
      "      if( eq(get(el 'kind) 'shape) then"
      "        pts = foreach(mapcar p get(el 'points) list(times(s car(p)) times(s cadr(p))))"
      "        if( equal(get(el 'stype) \"rectangle\")"
      "          then dbCreateRect(cv list(\"text\" \"drawing\") pts)"
      "          else dbCreateLine(cv list(\"text\" \"drawing\") pts) )"
      "      else"
      "        p = get(el 'point)"
      "        dbCreateLabel(cv list(\"text\" \"drawing\")"
      "          list(times(s car(p)) times(s cadr(p)))"
      "          get(el 'text) get(el 'just) get(el 'orient) get(el 'font) times(s get(el 'height)))"
      "      )"
      "    )"
      "  )"
      ")")
    "\n"))

; Define the resizable-note pcell master from a base-scale IR, stamp it
; non-netlisting, and attach an editable "Size scale" CDF parameter so q
; (Edit Object Properties) exposes it. Returns the (super) master cellview,
; usable straight away as a dbCreateInst master.
(defun nh_buildResizableFromIR (ir symLib symCell)
  (let (irLit src master cellId cdf)
    (when (null ir) (error "note-helper: empty IR for resizable symbol"))
    (setq irLit  (sprintf nil "%L" ir))
    (setq src    (nh_pcellSource irLit symLib symCell))
    (setq master (evalstring src))           ; one form -> the super master
    (when (null master)
      (error (strcat "note-helper: pcell define failed for " symLib "/" symCell)))
    (errset (dbReplaceProp master "nlAction" "string" "ignore") t)
    (dbSave master)
    ; editable "Size scale" param (editable/display are strings, not symbol t)
    (setq cellId (ddGetObj symLib symCell))
    (when cellId
      (setq cdf (cdfGetBaseCellCDF cellId))
      (unless cdf (setq cdf (cdfCreateBaseCellCDF cellId)))
      (when cdf
        (errset (cdfCreateParam cdf ?name "scale" ?type "float" ?prompt "Size scale"
                  ?defValue 1.0 ?editable "t" ?display "t") t)
        (errset (cdfSaveCDF cdf) t)))
    master))

; Top-level: parse text -> base IR -> resizable pcell master (no placement).
(defun nhBuildResizableSymbol (text symLib symCell @optional cfg)
  (nh_buildResizableFromIR (nh_buildIR (nhParseText text) cfg) symLib symCell))

; ===========================================================================
; Top-level conveniences
; ===========================================================================

; Parse text + build IR + interactively place (the GUI Place path).
(defun nhPlaceTable (@optional text cfg cv)
  (let (table ir)
    (setq table (nhParseText text))
    (setq ir    (nh_buildIR table cfg))
    (nhPlaceIR ir cv)))

; Non-interactive: parse + build + emit directly at offset (for tests / scripts).
(defun nhEmitTableAt (text cv @optional offset cfg)
  (let (table ir)
    (setq table (nhParseText text))
    (setq ir    (nh_buildIR table cfg))
    (nh_emitIR cv ir (or offset (list 0 0)))))

; Smoke test: render a sample table at origin into the current edit cellview.
; Returns the primitive count. Intended to be driven over skillbridge once
; the bridge is live (Ref REQUIREMENTS.md s.12 M1).
(defun nhSelfTest (@optional cv)
  (let ((target (nh_targetCv cv))
        (sample "|Net|Val|Unit|\n|:--|--:|:-:|\n|Vdd|3.3|V|\n|Gnd|0|V|"))
    (when (null target) (error "nhSelfTest: no edit cellview"))
    (nhEmitTableAt sample target (list 0 0) nil)))
