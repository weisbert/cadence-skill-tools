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

; Repeat the string s n times (for markdown separator rules / padding).
(defun nh_repeatStr (s n)
  (let ((out "") (i 0))
    (while (lessp i n) (setq out (strcat out s)) (setq i (add1 i)))
    out))

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
; Interactive placement (M5): drag a SYMBOL master with the native ghost
; (schHiCreateInst) so a live preview follows the cursor and one click drops
; it -- exactly like the i bindkey "insert symbol" flow. All three Output
; modes share this single path:
;   loose      -> build a throwaway temp note-symbol, drag+drop it, then
;                 dbFlattenInst it into LOOSE note shapes and delete the temp
;   symbol     -> build/reuse a non-netlisting note symbol, drop instance(s)
;   resizable  -> build/reuse a self-contained resizable (pcell) symbol
;
; schHiCreateInst is schematic-only, acts on the CURRENT window, and must run
; OUTSIDE the form button callback: an enterfunction/command armed from inside
; a form callback never engages (this WAS the "click does nothing" bug). So the
; GUI only ARMS placement (stash globals) and defers the actual launch to an
; hiRegTimer tick (nh_launchPlace), which first makes the schematic the current
; window (the form steals focus otherwise).
;
; Refs: schHiCreateInst skcompref.pdf p.65 ("drags the requested symbol until
;   you click to place it"); hiRegTimer skuiref.pdf p.84; hiGetWindowList p.945
;   + hiSetCurrentWindow p.958 (target the schematic, not the form); hiRedraw
;   p.1015; dbFlattenInst skdfref.pdf p.882 (1 level, pcells NOT flattened ->
;   leaves loose note shapes); ddDeleteObj / dbClose (temp-cell cleanup).
; ===========================================================================

; Resolve the schematic cellview to draw into (current edit cellview).
; geGetEditCellView() -> d_cellview  (skdfref.pdf p.106)
(defun nh_targetCv (@optional cv)
  (or cv (geGetEditCellView)))

; The window currently displaying cellview cv, so we can make it current before
; launching the schematic command. hiGetWindowList skuiref.pdf p.945.
(defun nh_windowForCv (cv)
  (let ((found nil) w)
    (foreach w (hiGetWindowList)
      (when (and (null found) (equal w~>cellView cv)) (setq found w)))
    found))

; Map the GUI Output string (or a symbol) to a mode symbol.
(defun nh_modeSym (mode)
  (cond
    ((or (eq mode 'symbol)    (equal mode "symbol"))             'symbol)
    ((or (eq mode 'resizable) (equal mode "symbol (resizable)")) 'resizable)
    (t                                                           'loose)))

; Build the symbol/pcell master to drag for a given mode. Returns the master
; cellview (usable as a schHiCreateInst source) or nil on failure. For loose
; mode the cell is a uniquely named throwaway (flattened + deleted after
; placement); for symbol/resizable it is the user-chosen cell (default
; "nh_note"). The master is created in the target schematic's own library.
(defun nh_buildMasterForMode (ir lib modeSym userCell)
  (let (cell)
    (cond
      ((eq modeSym 'resizable)
        (setq cell (if (and userCell (not (equal userCell ""))) userCell "nh_note"))
        (nh_buildResizableFromIR ir lib cell))
      ((eq modeSym 'symbol)
        (setq cell (if (and userCell (not (equal userCell ""))) userCell "nh_note"))
        (nh_buildSymbolFromIR ir lib cell))
      (t
        (setq nh_looseSeq (add1 nh_looseSeq))
        (setq cell (sprintf nil "nh_loose_tmp_%d" nh_looseSeq))
        (nh_buildSymbolFromIR ir lib cell)))))

; Arm a ghost placement of IR per mode, then defer the interactive launch to an
; hiRegTimer tick. Returns t when armed, nil (with a warn) when it cannot place.
(defun nhPlaceIRGhost (ir modeSym @optional userCell userLib cv)
  (let (target lib master)
    (setq target  (nh_targetCv cv))
    (setq modeSym (nh_modeSym modeSym))
    (cond
      ((null ir)
        (warn "note-helper: empty IR -- nothing to place.\n") nil)
      ((null target)
        (warn "note-helper: open a schematic first (nothing to place into).\n") nil)
      ((not (equal target~>cellViewType "schematic"))
        (warn "note-helper: the drag-place ghost needs a SCHEMATIC window.\n") nil)
      (t
        ; symbol/resizable may target a user-named library (cross-lib instance
        ; placement is fine); loose always uses the schematic's own lib (its
        ; throwaway temp cell is built and deleted there).
        (setq lib (if (and (not (eq modeSym 'loose)) userLib (not (equal userLib "")))
                      userLib target~>libName))
        (setq master (car (errset (nh_buildMasterForMode ir lib modeSym userCell) t)))
        (cond
          ((null master)
            (warn "note-helper: building the placement master failed -- see CIW.\n") nil)
          (t
            (setq nh_plLib    lib)
            (setq nh_plCell   master~>cellName)
            (setq nh_plView   "symbol")
            (setq nh_plCv     target)
            (setq nh_plWin    (nh_windowForCv target))
            (setq nh_plTmp    (if (eq modeSym 'loose) master~>cellName nil))
            (setq nh_plMaster (if (eq modeSym 'loose) master nil))
            (setq nh_plPoll   0)
            (hiRegTimer "nh_launchPlace()" 1)   ; launch after the callback returns
            t))))))

; hiRegTimer tick: make the schematic window current, then start the native
; instance-drag (live ghost). For loose mode also start the flatten poll.
(defun nh_launchPlace ()
  (when (and nh_plLib nh_plCell nh_plCv)
    (when nh_plWin (errset (hiSetCurrentWindow nh_plWin) t))
    (errset
      (schHiCreateInst                                   ; skcompref.pdf p.65
        ?libraryName nh_plLib ?cellName nh_plCell ?viewName nh_plView)
      t)
    (when nh_plTmp
      (setq nh_plPoll 0)
      (hiRegTimer "nh_loosePoll()" 2)))
  t)

; Instances of the pending temp cell currently sitting in the target cellview.
(defun nh_looseInsts ()
  (let ((out nil) inst)
    (when (and nh_plCv nh_plTmp)
      (foreach inst nh_plCv~>instances
        (when (and (equal inst~>cellName nh_plTmp)
                   (equal inst~>libName  nh_plLib))
          (setq out (cons inst out)))))
    out))

; Close + delete the throwaway temp symbol cell (loose mode), after its
; instances were flattened away. dbClose first to drop the open master handle.
(defun nh_looseCleanupTmp ()
  (when nh_plMaster (errset (dbClose nh_plMaster) t))
  (when (and nh_plLib nh_plTmp)
    (let ((cid (ddGetObj nh_plLib nh_plTmp)))
      (when cid (errset (ddDeleteObj cid) t))))
  t)

; Reset the pending-placement globals (no disk side-effects -- cleanup of the
; temp cell is nh_looseCleanupTmp's job).
(defun nh_plClear ()
  (setq nh_plLib nil)  (setq nh_plCell nil) (setq nh_plCv nil)
  (setq nh_plWin nil)  (setq nh_plTmp nil)  (setq nh_plMaster nil)
  (setq nh_plPoll 0)
  t)

; Loose-mode flatten poll. schHiCreateInst gives no completion callback, so we
; watch the cellview: each newly dropped temp instance is flattened in place
; into loose note shapes (the create command keeps repeating in Virtuoso, so we
; handle multiple drops); after ~60s with no new drop we assume the user is
; done (or pressed Esc) and delete the temp cell. Re-registers itself each tick.
(defun nh_loosePoll ()
  (when nh_plTmp
    (let ((insts (nh_looseInsts)))
      (cond
        (insts
          (foreach inst insts (errset (dbFlattenInst inst 1 nil) t))   ; p.882
          (when nh_plWin (errset (hiRedraw nh_plWin) t))
          (setq nh_plPoll 0)                      ; activity -> reset idle budget
          (hiRegTimer "nh_loosePoll()" 2))        ; keep watching for more drops
        (t
          (setq nh_plPoll (add1 nh_plPoll))
          (cond
            ((lessp nh_plPoll 300)                ; ~60s @ 0.2s ticks idle budget
              (hiRegTimer "nh_loosePoll()" 2))
            (t
              (nh_looseCleanupTmp)
              (nh_plClear)))))))
  t)

; Back-compat: drag-place IR as loose note shapes (CIW convenience).
(defun nhPlaceIR (ir @optional cv)
  (nhPlaceIRGhost ir 'loose nil nil cv))

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

; Top-level: build the symbol from text, then drag-place an instance with the
; native ghost (schHiCreateInst). The master is created in the target
; schematic's own library; symLib is kept for back-compat but the ghost places
; from the schematic's library. Mode 'symbol -> reusable non-netlisting symbol.
(defun nhPlaceTableAsSymbol (text symLib symCell @optional cfg schematicCv)
  (nhPlaceIRGhost (nh_buildIR (nhParseText text) cfg) 'symbol symCell symLib schematicCv))

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
; Feature A -- vector import (M4): SVG -> note lines.
;
; Decision #5 (Python integration), now LOCKED: the SVG/DXF parser is a
; standalone, Cadence-independent Python CLI. The IL side stays the driver --
; it shells out with system(), the parser writes a SKILL list literal of IR
; DPLs (the SAME IR the table path emits) to a temp file, and we infile/read it
; straight back and hand it to the shared place/emit core. No IR translation in
; SKILL, no skillbridge needed at runtime (skillbridge is Python->SKILL, the
; wrong direction for a tool that must run unattended).
;
; Refs: system sklangref.pdf p.638 (spawns a UNIX process, returns exit code,
;   0 = ok); makeTempFileName p.446; infile p.423; read p.461 (returns one
;   s-expression -- our whole IR is a single top-level list); close p.391;
;   deleteFile p.620; isFile p.428.
; ===========================================================================

; Resolve the parser path: explicit override, else relative to note_helperDir.
(defun nh_svg2irScriptPath ()
  (cond
    ((and (boundp 'nh_svg2irScript) nh_svg2irScript) nh_svg2irScript)
    ((and (boundp 'note_helperDir) note_helperDir)
      (strcat note_helperDir "svg2ir/nh_svg2ir.py"))
    (t "nh_svg2ir.py")))

; Build the shell command. Paths are double-quoted for spaces; width/font are
; passed as parser options (aspect is always preserved by the parser).
(defun nh_svg2irCmd (svgPath outPath width fontHeight)
  (let ((script (nh_svg2irScriptPath)) (extra ""))
    (when (and fontHeight (greaterp fontHeight 0))
      (setq extra (sprintf nil " --font-height %f" fontHeight)))
    (sprintf nil "%s \"%s\" \"%s\" \"%s\" --width %f%s"
      nh_pythonCmd script svgPath outPath width extra)))

; Read the single top-level IR list back from the parser's output file.
(defun nh_irFileToIR (path)
  (let (port ir)
    (setq port (infile path))                       ; sklangref.pdf p.423
    (unless port (error (strcat "note-helper: cannot open IR file " path)))
    (setq ir (read port))                           ; sklangref.pdf p.461 (one s-expr)
    (close port)                                    ; sklangref.pdf p.391
    (if (or (null ir) (eq ir t)) nil ir)))

; Parse an SVG file into note-helper IR (loose-shape polylines + any text
; labels), scaled uniformly to `width` user units (aspect preserved). Returns
; the IR list (consumable by nhPlaceIR / nh_buildSymbolFromIR / nh_emitIR), or
; nil if the SVG had no drawable geometry.
(defun nhImportVector (svgPath @optional width fontHeight)
  (let (outPath cmd rc ir)
    (unless (and (stringp svgPath) (isFile svgPath))
      (error (strcat "note-helper: SVG file not found: "
                     (if (stringp svgPath) svgPath "(nil)"))))
    (when (or (null width) (leqp width 0)) (setq width 5.0))
    (setq outPath (makeTempFileName "/tmp/nh_svgir"))   ; sklangref.pdf p.446
    (setq cmd (nh_svg2irCmd svgPath outPath width fontHeight))
    (setq rc  (system cmd))                             ; sklangref.pdf p.638
    (unless (equal rc 0)
      (error (sprintf nil "note-helper: SVG parser exited %d\n  %s" rc cmd)))
    (unless (isFile outPath)
      (error "note-helper: SVG parser produced no output file"))
    (setq ir (nh_irFileToIR outPath))
    (errset (deleteFile outPath) t)                    ; sklangref.pdf p.620 (tidy)
    ir))

; Top-level: import an SVG and place it as loose note shapes at one click.
(defun nhPlaceVector (svgPath @optional width fontHeight cv)
  (nhPlaceIR (nhImportVector svgPath width fontHeight) cv))

; ---------------------------------------------------------------------------
; Launch the standalone Python data-prep toolbox GUI (Image->SVG + Table->
; Markdown) as an INDEPENDENT, non-blocking window. It is a file producer: the
; user prepares a .svg / .md, then points the SVG-path / Table-file fields at it
; -- no live data bridge needed. Same shell-out plumbing as the SVG parser.
; ---------------------------------------------------------------------------

; Resolve the toolbox GUI path: explicit override, else relative to note_helperDir.
(defun nh_toolboxScriptPath ()
  (cond
    ((and (boundp 'nh_toolboxScript) nh_toolboxScript) nh_toolboxScript)
    ((and (boundp 'note_helperDir) note_helperDir)
      (strcat note_helperDir "toolbox/toolbox.py"))
    (t "toolbox.py")))

; Start the toolbox. A SYNCHRONOUS system() would freeze ALL of Virtuoso until
; the Tk window closed, so we (1) verify the script exists, (2) preflight that
; this Python actually has tkinter (the toolbox is Tk-based; a bare deploy host
; may lack it -- catch it here with a clear message instead of a silent dead
; click), then (3) background-launch with a trailing "&" so the SKILL thread
; returns immediately. Returns a status symbol: 'ok / 'no-script / 'no-tk /
; 'launch-failed -- the caller maps it to a GUI message.
; Refs: system sklangref.pdf p.638 (spawns a UNIX process, returns exit code,
;   0 = ok); isFile p.428.
(defun nhLaunchToolbox ()
  (let ((script (nh_toolboxScriptPath)))
    (cond
      ((not (isFile script)) 'no-script)
      ((not (equal 0 (system (sprintf nil "%s -c \"import tkinter\" > /dev/null 2>&1"
                                      nh_pythonCmd))))
        'no-tk)
      ((equal 0 (system (sprintf nil "%s \"%s\" > /dev/null 2>&1 &"
                                 nh_pythonCmd script)))
        'ok)
      (t 'launch-failed))))

; ===========================================================================
; Markdown / TSV file import + export (Cadence-side, symmetric with the Python
; tsv2md/toolbox tools). Read a table file into the form, or write the current
; table back out as a normalized aligned Markdown file.
;
; Refs: infile sklangref.pdf p.423; gets p.420 (reads a line, KEEPS the newline,
;   nil at EOF -> concatenating the lines rebuilds the file); outfile p.450
;   ("w" mode creates/overwrites); fprintf p.409 ("%s" prints a string, the
;   data is the ARG so any '%' in it is literal); close p.391.
; ===========================================================================

; Read a whole text file into a string (preserving newlines).
(defun nh_readFile (path)
  (let (port line out)
    (setq port (infile path))
    (unless port (error (strcat "note-helper: cannot read file " path)))
    (setq out "")
    (while (gets line port) (setq out (strcat out line)))
    (close port)
    out))

; Write a string to a file (overwriting). Returns t.
(defun nh_writeFile (path str)
  (let (port)
    (setq port (outfile path "w"))
    (unless port (error (strcat "note-helper: cannot write file " path)))
    (fprintf port "%s" (or str ""))
    (close port)
    t))

; --- normalized Markdown emit from the canonical table model ----------------

; Escape a cell so it can't break a Markdown pipe row ("|" -> "\|").
(defun nh_mdEsc (s)
  (if (stringp s) (buildString (parseString s "|" t) "\\|") s))

; Separator-row cell of visible width w for the given alignment symbol.
(defun nh_md_sepCell (w align)
  (let ((n (max w 3)))
    (cond
      ((eq align 'center) (strcat ":" (nh_repeatStr "-" (difference n 2)) ":"))
      ((eq align 'right)  (strcat (nh_repeatStr "-" (sub1 n)) ":"))
      ((eq align 'left)   (strcat ":" (nh_repeatStr "-" (sub1 n))))
      (t                  (nh_repeatStr "-" n)))))

; Pad a cell to width w per alignment (pretty source; parsers ignore padding).
(defun nh_md_pad (cell w align)
  (let ((gap (difference w (strlen cell))) l)
    (cond
      ((leqp gap 0) cell)
      ((eq align 'right)  (strcat (nh_repeatStr " " gap) cell))
      ((eq align 'center) (setq l (quotient gap 2))
                          (strcat (nh_repeatStr " " l) cell (nh_repeatStr " " (difference gap l))))
      (t                  (strcat cell (nh_repeatStr " " gap))))))

(defun nh_md_row (cells widths aligns)
  (let ((out "|") (j 0) cell)
    (for j 0 (sub1 (length widths))
      (setq cell (or (nth j cells) ""))
      (setq out (strcat out " " (nh_md_pad cell (nth j widths) (or (nth j aligns) 'left)) " |")))
    out))

(defun nh_md_sepRow (widths aligns)
  (let ((out "|") (j 0))
    (for j 0 (sub1 (length widths))
      (setq out (strcat out " " (nh_md_sepCell (nth j widths) (or (nth j aligns) 'left)) " |")))
    out))

; Canonical table model -> a normalized aligned GitHub-style Markdown string.
; A headerless model gets synthesized "Col1..ColN" headers (Markdown needs a
; header row). Reuses the declared per-column alignment.
(defun nh_tableToMarkdown (table)
  (let (rows ncols aligns header hdr body widths j w row cell lines)
    (setq rows   (get table 'rows))
    (setq ncols  (get table 'ncols))
    (setq aligns (get table 'aligns))
    (setq header (get table 'header))
    (cond
      (header (setq hdr (car rows)) (setq body (cdr rows)))
      (t      (for j 0 (sub1 ncols) (setq hdr (cons (sprintf nil "Col%d" (add1 j)) hdr)))
              (setq hdr (reverse hdr)) (setq body rows)))
    (setq hdr  (foreach mapcar cell hdr (nh_mdEsc cell)))
    (setq body (foreach mapcar row body (foreach mapcar cell row (nh_mdEsc cell))))
    (setq widths nil)
    (for j 0 (sub1 ncols)
      (setq w (strlen (or (nth j hdr) "")))
      (foreach row body (setq w (max w (strlen (or (nth j row) "")))))
      (setq widths (cons (max w 3) widths)))
    (setq widths (reverse widths))
    (setq lines (cons (nh_md_row hdr widths aligns)
                      (cons (nh_md_sepRow widths aligns)
                            (foreach mapcar row body (nh_md_row row widths aligns)))))
    (strcat (buildString lines "\n") "\n")))

; Parse a Markdown/TSV string and re-emit it as normalized Markdown.
(defun nhTextToMarkdown (text)
  (nh_tableToMarkdown (nhParseText text)))

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
