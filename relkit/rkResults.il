; rkResults.il -- result tables, schematic jump, DUT picker, open reports
; (plan sections 3, 4.5; decision D13).
;
; OWNER: SKILL results & jump agent.
;
; Public API (docs/CONTRACT.md section 6):
;
;   Result tables (rows for hiCreateReportField / list boxes)
;   rkResultsReadTable(t_tsv)              -> (l_header l_rows)     CONTRACT 5.2
;   rkResultsLoadResults(g_src)            -> o_results             summary.json / collect out.json
;   rkResultsSummaryTable(o_results)       -> (l_header l_rows)     one row per corner / Stress
;   rkResultsDeviceTable(g_src)            -> (l_header l_rows)     device table (TSV); DEOS sorted by DPM desc
;   rkResultsSortRows(l_table t_col [g_desc]) -> (l_header l_rows)  numeric-aware sort
;   rkResultsColIndex(l_header t_col)      -> x_index / nil
;   rkResultsCell(l_table l_row t_col)     -> t_cell / nil
;   rkResultsReportSpec(l_table)           -> (l_headers l_choices) for hiCreateReportField
;   rkResultsListBoxItems(l_table)         -> l_strings             for hiCreateListBoxField
;   rkResultsShowTable(t_title g_src g_ctx [g_noDisplay]) -> r_form  modeless table window
;                                          (src: summary.json path/table, TSV path or table)
;
;   Schematic jump
;   rkResultsParsePath(t_path)             -> (t_style l_segments)  "dot" (I0.X1.M3) / "dspf" (XI0/XX1/MM3@2)
;   rkResultsResolveInstance(t_path g_ctx) -> o_result              pure DB walk, no window
;   rkResultsJumpToInstance(t_path g_ctx)  -> t / nil               open + descend + select + zoom + halo
;   rkResultsHighlightAll(l_paths g_ctx)   -> x_count               halo every hit on the current page
;   rkResultsClearHighlight()              -> x_count               remove relkit highlights
;   rkResultsLastMessage()                 -> t_message             why the last jump stopped
;   rkResultsWindow()                      -> w_window / nil        the window relkit opened for jumps
;   rkResultsCloseWindow()                 -> t / nil
;
;   DUT pick (D13)
;   rkResultsListTopInstances(t_lib t_cell t_view [l_skipLibs]) -> list of tables {inst lib cell view terms}
;   rkResultsOpenTop(g_ctx)                -> w_window              TB top (config bindings applied)
;   rkResultsPickDut(g_ctx s_doneFn)       -> o_dut / t / nil       async; calls (doneFn dut) or (doneFn nil)
;   rkResultsDutFromInst(d_inst g_ctx)     -> o_dut
;
;   Reports
;   rkResultsOpenFile(t_path)              -> t / nil               html -> browser, other -> text viewer
;
; ctx keys used: design{lib cell view is_config} (falls back to maestro{lib cell}
; + "schematic"), dut.inst (paths relative to the DUT), history.netlist_dir and
; netlist.map_dir (netlist-name -> schematic-name translation).
;
; How a jump works (plan 4.5):
;   1. The path is split into segments. DSPF style ("/" separated) drops "@n"
;      finger suffixes and also tries each segment without up to two leading
;      element letters (X M R C D Q L): XXI0 -> XI0 -> I0, MPM1 -> PM1.
;   2. rkResultsResolveInstance walks the design level by level in the DB,
;      binding every instance the way the netlister did: through the config
;      (hdbBind, sub-configs followed) when the test's design is a config view,
;      else through the view list rk_resDescendViews. A segment is looked up
;      as: exact name, bus member of an iterated instance (XB<1> in XB<0:3>),
;      case-insensitive, then via the netlist map files (ihnl/cds*/map, map/*:
;      every ("sch" "net") string pair), for each candidate spelling.
;   3. Only verified levels are pushed, in ONE deOpen call with a hierarchy
;      spec ("/I0(schematic):r/X2(schematic):r") and configL (so the window
;      keeps the config bindings and Shift-B returns level by level). Because
;      every level is verified first, deOpen never needs its Open File form.
;   4. The last instance is selected, zoomed to and given a halo highlight.
;      A segment that cannot be found (or bound to a non-schematic view) stops
;      the walk: the window shows the deepest level reached and
;      rkResultsLastMessage() says which segment failed.
;   RelStudio's own ana_rel_hiligh_inc.il re-opens the top and pushes one level
;   per call and ignores the config; this module does neither.
;
; Window policy: relkit opens ONE design window (rk_resWin) and reuses it for
; later jumps; it never touches the user's other windows. Read mode only.
;
; SKILL rules (eda-test-workarea memory feedback_skill_gotchas): no let*, no
; prefix arithmetic, no defvar, identifiers [A-Za-z0-9_], no setq on slots
; (putpropq / setarray), ~> only on db objects, hi*/hdb* handles. Forms use
; Pattern A (fresh name per table window; callbacks find the form via the
; rk_resForms table). No ?closeCallback.
;
; Ref (IC6.1.8 PDFs, checked): skdfref deOpen p.2007 (configL, hierarchy
;   spec), deGetConfigId p.2078, deGetEditLevel, deReturn p.2039,
;   geGetEditCellView, geGetInstHier p.108, geGetInstHierPath p.109,
;   geSelectFig p.212, geDeselectAll, geGetSelSet, geCreateHilightSet p.280,
;   geAddHilightFig p.263, geSetHilightSetHaloParameters p.305,
;   geDeleteHilightSet, geIsValidHilightSet p.297, dbFindAnyInstByName p.958,
;   dbGetOverlaps, hdbOpen p.671, hdbCreatePathVector, hdbBind p.649,
;   hdbPushCell p.682, hdbIsAtStopPoint, hdbIsConfig, hdbGetTop*Name,
;   hdbDestroyPathVector, hdbClose p.670 (example tools/hdb/examples/hdbTraverse.il);
;   skuiref hiCreateReportField p.? (?headers ?choices ?doubleClickCB),
;   hiCreateButton p.524, hiCreateAppForm, hiZoomIn, enterPoint (?doneProc
;   gets (w done pts)), hiLaunchBrowser p.775, view p.1265;
;   sklangref lineread p.437, rindex, alphaNumCmp.

(unless (boundp 'rk_resWin)       (setq rk_resWin nil))
(unless (boundp 'rk_resHlSets)    (setq rk_resHlSets nil))
(unless (boundp 'rk_resLastMsg)   (setq rk_resLastMsg ""))
(unless (boundp 'rk_resLast)      (setq rk_resLast nil))
(unless (boundp 'rk_resFormCount) (setq rk_resFormCount 0))
(unless (boundp 'rk_resForms)     (setq rk_resForms (makeTable "rk_resForms" nil)))
(unless (boundp 'rk_resPick)      (setq rk_resPick nil))
(unless (boundp 'rk_resMapCache)  (setq rk_resMapCache (makeTable "rk_resMapCache" nil)))

; Views tried, in order, to descend into an instance when the design is NOT a
; config (with a config, hdbBind decides).
(setq rk_resDescendViews (list "schematic" "cmos_sch" "cmos.sch"))
; Libraries never offered as DUT candidates (pins, sources, probes).
(setq rk_resDutSkipLibs (list "basic" "analogLib" "ahdlLib" "functional" "rfLib"
                              "sbaLib" "cdsDefTechLib" "US_8ths"))
(setq rk_resHlLayer (list "y3" "drawing"))
(setq rk_resMaxPaths 500)

; ---------------------------------------------------------------------------
; Small helpers
; ---------------------------------------------------------------------------

(defun rk_resSay (msg)
  (setq rk_resLastMsg msg)
  (printf "[relkit] %s\n" msg)
  msg)

(defun rkResultsLastMessage () rk_resLastMsg)

(defun rk_resTrim (s)
  (if (stringp s) (pcreReplace (pcreCompile "^\\s+|\\s+$") s "" 0) ""))

(defun rk_resUnescape (s)
  (pcreReplace (pcreCompile "[\\\\]") s "" 0))

(defun rk_resCall (fn arg)
  (cond
    ((null fn) nil)
    ((stringp fn) (funcall (stringToSymbol fn) arg))
    (t (funcall fn arg))))

; append for any number of lists (SKILL append takes exactly two).
(defun rk_resConcat (@rest lists)
  (let (out)
    (foreach l lists (foreach x l (setq out (cons x out))))
    (reverse out)))

; First n elements of a list.
(defun rk_resFirstN (lst n)
  (let (out (i 0))
    (while (and lst (lessp i n))
      (setq out (cons (car lst) out))
      (setq lst (cdr lst))
      (setq i (add1 i)))
    (reverse out)))

(defun rk_resWinValid (w)
  (and w (windowp w) (memq w (hiGetWindowList)) t))

(defun rkResultsWindow ()
  (if (rk_resWinValid rk_resWin) rk_resWin nil))

(defun rkResultsCloseWindow ()
  (let ((w (rkResultsWindow)))
    (rkResultsClearHighlight)
    (setq rk_resWin nil)
    (when w (hiCloseWindow w))
    (and w t)))

; Is s a number literal?
(defun rk_resNumP (s)
  (and (stringp s)
       (pcreMatchp "^\\s*[-+]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?\\s*$" s)))

(defun rk_resNum (s)
  (cond
    ((numberp s) s)
    ((rk_resNumP s) (atof (rk_resTrim s)))
    (t nil)))

(defun rk_resFmt (v)
  (cond
    ((null v) "")
    ((eq v t) "true")
    ((eq v rkJsonFalse) "false")
    ((stringp v) v)
    ((integerp v) (sprintf nil "%d" v))
    ((floatp v) (sprintf nil "%g" v))
    ((listp v) (buildString (mapcar 'rk_resFmt v) ","))
    (t (sprintf nil "%L" v))))

; Bus name "XB<0:3>" -> ("XB" "0:3"); anything else -> nil.
(defun rk_resSplitBus (name)
  (let ((n (strlen name)) tail base spec)
    (when (and (greaterp n 3) (equal (substring name n 1) ">"))
      (setq tail (rindex name "<"))
      (when (and tail (greaterp (strlen tail) 2))
        (setq base (substring name 1 (difference n (strlen tail))))
        (setq spec (substring tail 2 (difference (strlen tail) 2)))
        (when (and (stringp base) (nequal base "") (stringp spec) (nequal spec ""))
          (list base spec))))))

; "0:3" "3:0" "1,4,6:7" "0:6:2" -> list of integers; nil if not numeric.
(defun rk_resBusBits (spec)
  (let ((ok t) bits parts a b st i)
    (foreach item (parseString spec ",")
      (setq parts (parseString item ":"))
      (cond
        ((not (and parts (lessp (length parts) 4)
                   (forall p parts (pcreMatchp "^\\s*-?[0-9]+\\s*$" p))))
          (setq ok nil))
        (t
          (setq a (atoi (car parts)))
          (setq b (if (cdr parts) (atoi (cadr parts)) a))
          (setq st (if (cddr parts) (abs (atoi (caddr parts))) 1))
          (when (zerop st) (setq st 1))
          (setq i a)
          (if (leqp a b)
            (while (and (leqp i b) (lessp (length bits) 100000))
              (setq bits (cons i bits)) (setq i (plus i st)))
            (while (and (geqp i b) (lessp (length bits) 100000))
              (setq bits (cons i bits)) (setq i (difference i st)))))))
    (and ok (reverse bits))))

; ---------------------------------------------------------------------------
; Path parsing
; ---------------------------------------------------------------------------

(defun rkResultsParsePath (path)
  (let ((s (rk_resTrim path)) style segs out)
    (setq style (if (index s "/") "dspf" "dot"))
    (setq segs (parseString s (if (equal style "dspf") "/" ".")))
    (foreach seg segs
      (setq seg (rk_resUnescape (rk_resTrim seg)))
      (setq seg (pcreReplace (pcreCompile "@[0-9]+$") seg "" 0))
      (when (nequal seg "") (setq out (cons seg out))))
    (list style (reverse out))))

; Spellings to try for one segment, most literal first.
(defun rk_resCandidates (seg style)
  (let ((c (list seg)) (s seg) (k 0))
    (when (equal style "dspf")
      (while (and (lessp k 2) (greaterp (strlen s) 1)
                  (member (upperCase (substring s 1 1)) (list "X" "M" "R" "C" "D" "Q" "L")))
        (setq s (substring s 2))
        (setq c (cons s c))
        (setq k (add1 k))))
    (reverse c)))

; ---------------------------------------------------------------------------
; Netlist map files -> table lowercase(netlist name) -> list of schematic names
; ---------------------------------------------------------------------------

(defun rk_resMapAdd (tbl sch net)
  (let ((k (lowerCase (rk_resUnescape net))))
    (unless (member sch (arrayref tbl k))
      (setarray tbl k (cons sch (arrayref tbl k))))))

(defun rk_resMapWalk (x tbl)
  (cond
    ((and (listp x) x (stringp (car x)) (cdr x) (stringp (cadr x)) (null (cddr x)))
      (rk_resMapAdd tbl (car x) (cadr x)))
    ((and (listp x) x)
      (foreach y x (rk_resMapWalk y tbl)))))

(defun rk_resMapReadFile (path tbl)
  (let ((p (infile path)) form (n 0))
    (when p
      (errset
        (while (and (setq form (lineread p)) (lessp n 200000))
          (when (listp form) (rk_resMapWalk form tbl))
          (setq n (add1 n)))
        nil)
      (close p))
    t))

; Map files of a netlist dir: <dir>/map/*, <dir>/ihnl/*/map; ctx.netlist.map_dir
; may name the map dir itself (its files + its parent netlist dir) or a file.
(defun rk_resMapFiles (ctx)
  (let (dirs files nd md sub seen out)
    (setq nd (rkGet ctx "history.netlist_dir"))
    (setq md (rkGet ctx "netlist.map_dir"))
    (when (stringp md)
      (cond
        ((isFile md) (setq files (cons md files)))
        ((isDir md)
          (foreach f (getDirFiles md)
            (when (isFile (rkPathJoin md f)) (setq files (cons (rkPathJoin md f) files))))
          (setq dirs (cons (pcreReplace (pcreCompile "/+[^/]+/*$") md "" 0) dirs)))))
    (when (and (stringp nd) (isDir nd)) (setq dirs (cons nd dirs)))
    (foreach d dirs
      (setq sub (rkPathJoin d "map"))
      (when (isDir sub)
        (foreach f (getDirFiles sub)
          (when (isFile (rkPathJoin sub f)) (setq files (cons (rkPathJoin sub f) files)))))
      (setq sub (rkPathJoin d "ihnl"))
      (when (isDir sub)
        (foreach c (getDirFiles sub)
          (when (isFile (rkPathJoin (rkPathJoin sub c) "map"))
            (setq files (cons (rkPathJoin (rkPathJoin sub c) "map") files))))))
    ; de-duplicate, keep order
    (foreach f (reverse files)
      (unless (member f seen) (setq seen (cons f seen)) (setq out (cons f out))))
    (reverse out)))

; Cached per file set.
(defun rk_resMapTable (ctx)
  (let ((files (rk_resMapFiles ctx)) key tbl)
    (when files
      (setq key (buildString files "|"))
      (setq tbl (arrayref rk_resMapCache key))
      (unless tbl
        (setq tbl (makeTable "rk_resMap" nil))
        (foreach f files (rk_resMapReadFile f tbl))
        (setarray rk_resMapCache key tbl)))
    tbl))

; ---------------------------------------------------------------------------
; Instance lookup inside one cellview
; ---------------------------------------------------------------------------

; -> (inst bit) ; bit = member number for an iterated instance, else nil.
(defun rk_resFindInst (cv name)
  (let (inst found sb tb lname bits)
    (setq inst (dbFindAnyInstByName cv name))
    (cond
      (inst (list inst nil))
      (t
        (setq lname (lowerCase name))
        (setq tb (rk_resSplitBus name))
        (foreach i cv~>instances
          (unless found
            (cond
              ((equal (lowerCase i~>name) lname) (setq found (list i nil)))
              ((and tb (setq sb (rk_resSplitBus i~>name))
                    (equal (lowerCase (car sb)) (lowerCase (car tb)))
                    (rk_resBusBits (cadr tb)) (null (cdr (rk_resBusBits (cadr tb))))
                    (setq bits (rk_resBusBits (cadr sb)))
                    (member (car (rk_resBusBits (cadr tb))) bits))
                (setq found (list i (car (rk_resBusBits (cadr tb)))))))))
        found))))

; Segment -> (inst bit spelledAs) via candidates, then the netlist map.
(defun rk_resLookup (cv seg style mapTbl)
  (let (hit cands)
    (setq cands (rk_resCandidates seg style))
    (foreach c cands
      (unless hit
        (setq hit (rk_resFindInst cv c))
        (when hit (setq hit (append hit (list c))))))
    (when (and (null hit) mapTbl)
      (foreach c cands
        (foreach sch (arrayref mapTbl (lowerCase c))
          (unless hit
            (setq hit (rk_resFindInst cv sch))
            (when hit (setq hit (append hit (list sch))))))))
    hit))

; ---------------------------------------------------------------------------
; Design + binding
; ---------------------------------------------------------------------------

; ctx -> (lib cell view isConfig)
(defun rk_resDesignOf (ctx)
  (let (lib cell view isCfg r)
    (setq lib (rkGet ctx "design.lib"))
    (setq cell (rkGet ctx "design.cell"))
    (setq view (rkGet ctx "design.view"))
    (unless (and lib cell)
      (setq lib (rkGet ctx "maestro.lib"))
      (setq cell (rkGet ctx "maestro.cell"))
      (setq view nil))
    (unless view (setq view "schematic"))
    (setq isCfg (rkGet ctx "design.is_config"))
    (when (eq isCfg rkJsonFalse) (setq isCfg nil))
    (unless isCfg
      (setq r (errset (hdbIsConfig lib cell view) nil))
      (setq isCfg (and r (car r))))
    (list lib cell view (and isCfg t))))

(defun rk_resOpenCv (lib cell view)
  (let ((r (errset (dbOpenCellViewByType lib cell view nil "r") nil)))
    (and r (car r))))

(defun rk_resIsSchematic (lib cell view)
  (let ((cv (rk_resOpenCv lib cell view)) ok)
    (when cv
      (setq ok (equal cv~>cellViewType "schematic"))
      (dbClose cv))
    ok))

; No config: first view of rk_resDescendViews that is a schematic.
(defun rk_resPlainBind (lib cell)
  (let (hit)
    (foreach v rk_resDescendViews
      (unless hit
        (when (and (ddGetObj lib cell v) (rk_resIsSchematic lib cell v))
          (setq hit (list lib cell v)))))
    hit))

; Walk state: a table with keys "pv" "cfgs" (opened configs) "pvs".
(defun rk_resHdbBind (st inst)
  (let (r)
    (setq r (errset (hdbBind (arrayref st "pv") inst~>libName inst~>cellName inst~>viewName
                             inst~>name t t nil) nil))
    (setq r (and r (car r)))
    (when (and r (stringp (car r)) (nequal (car r) ""))
      (list (nth 0 r) (nth 1 r) (nth 2 r)))))

(defun rk_resCloseState (st)
  (foreach pv (arrayref st "pvs") (errset (hdbDestroyPathVector pv) nil))
  (foreach c (arrayref st "cfgs") (errset (hdbClose c) nil))
  t)

; ---------------------------------------------------------------------------
; Resolve: path -> levels (no window)
; ---------------------------------------------------------------------------

(defun rk_resMakeLevel (seg hit bound)
  (let ((lv (rkMakeObj)) inst sb)
    (setq inst (car hit))
    (rkPut lv "seg" seg)
    (rkPut lv "name" inst~>name)
    (rkPut lv "bit" (cadr hit))
    (rkPut lv "spelled" (caddr hit))
    (setq sb (rk_resSplitBus inst~>name))
    (rkPut lv "item" (if (and (cadr hit) sb)
                         (sprintf nil "%s<%d>" (car sb) (cadr hit))
                         inst~>name))
    (rkPut lv "lib" inst~>libName)
    (rkPut lv "cell" inst~>cellName)
    (rkPut lv "view" inst~>viewName)
    (rkPut lv "bound" bound)
    (rkPut lv "descend" nil)
    lv))

; Walk segs from (lib cell view) [config cfg]. -> (levels message)
(defun rk_resWalk (top cfgL segs style mapTbl)
  (let ((st (rkMakeObj)) (lib (nth 0 top)) (cell (nth 1 top)) (view (nth 2 top))
        levels msg cv hit lv bound (i 0) (n (length segs)) stop cfg sub pv r)
    (when cfgL
      (setq cfg (car (errset (hdbOpen (nth 0 cfgL) (nth 1 cfgL) (nth 2 cfgL) "r") nil)))
      (cond
        ((null cfg) (setq msg (sprintf nil "cannot open config %s/%s/%s" (nth 0 cfgL) (nth 1 cfgL) (nth 2 cfgL))))
        (t
          (rkPut st "cfgs" (list cfg))
          (setq pv (hdbCreatePathVector cfg))
          (rkPut st "pv" pv)
          (rkPut st "pvs" (list pv)))))
    (while (and (null msg) (lessp i n))
      (setq cv (rk_resOpenCv lib cell view))
      (cond
        ((null cv)
          (setq msg (sprintf nil "cannot open %s/%s/%s" lib cell view)))
        (t
          (setq hit (rk_resLookup cv (nth i segs) style mapTbl))
          (cond
            ((null hit)
              (setq msg (sprintf nil "'%s' not found in %s/%s/%s" (nth i segs) lib cell view)))
            (t
              (setq bound (if cfgL (rk_resHdbBind st (car hit))
                              (rk_resPlainBind (car hit)~>libName (car hit)~>cellName)))
              (setq lv (rk_resMakeLevel (nth i segs) hit bound))
              (setq levels (cons lv levels))
              (when (lessp (add1 i) n)
                ; need to go below this instance
                (setq stop nil)
                (cond
                  ((null bound) (setq stop "no schematic view to descend into"))
                  (cfgL
                    ; guarded: an error here must not skip rk_resCloseState
                    ; (open configs / path vectors) nor the dbClose below
                    (unless (car (errset (hdbPushCell (arrayref st "pv") (car hit)~>name
                                                      (nth 0 bound) (nth 1 bound) (nth 2 bound)) nil))
                      (setq stop "hdbPushCell failed"))
                    (setq r (errset (hdbIsConfig (nth 0 bound) (nth 1 bound) (nth 2 bound)) nil))
                    (cond
                      (stop nil)
                      ((and r (car r))
                        ; sub-config: continue with its top cell view and its own path vector
                        (setq sub (car (errset (hdbOpen (nth 0 bound) (nth 1 bound) (nth 2 bound) "r") nil)))
                        (cond
                          ((null sub) (setq stop "cannot open sub-config"))
                          (t
                            (rkPut st "cfgs" (cons sub (arrayref st "cfgs")))
                            (setq pv (hdbCreatePathVector sub))
                            (rkPut st "pv" pv)
                            (rkPut st "pvs" (cons pv (arrayref st "pvs")))
                            (setq bound (car (errset (list (hdbGetTopLibName sub) (hdbGetTopCellName sub)
                                                           (hdbGetTopViewName sub)) nil)))
                            (unless (and bound (car bound)) (setq stop "cannot read the sub-config top"))
                            (rkPut lv "bound" bound))))
                      ((car (errset (hdbIsAtStopPoint (arrayref st "pv")) nil))
                        (setq stop (sprintf nil "bound to %s/%s/%s, a stop view" (nth 0 bound) (nth 1 bound) (nth 2 bound)))))
                    (when (and (null stop) (not (rk_resIsSchematic (nth 0 bound) (nth 1 bound) (nth 2 bound))))
                      (setq stop (sprintf nil "bound to %s/%s/%s, not a schematic" (nth 0 bound) (nth 1 bound) (nth 2 bound))))))
                (cond
                  (stop
                    (setq msg (sprintf nil "cannot descend into '%s' (%s)" (rkGet lv "name") stop)))
                  (t
                    (rkPut lv "descend" t)
                    (setq lib (nth 0 bound))
                    (setq cell (nth 1 bound))
                    (setq view (nth 2 bound)))))))
          (dbClose cv)))
      (setq i (add1 i)))
    (rk_resCloseState st)
    (list (reverse levels) msg)))

(defun rkResultsResolveInstance (instPath ctx)
  (let ((res (rkMakeObj)) parsed style segs design top cfgL mapTbl walk levels msg dutInst walk2)
    (setq parsed (rkResultsParsePath instPath))
    (setq style (car parsed))
    (setq segs (cadr parsed))
    (setq design (rk_resDesignOf ctx))
    (cond
      ((nth 3 design)
        (setq cfgL (list (nth 0 design) (nth 1 design) (nth 2 design)))
        (setq top (car (errset
                         (let ((c (hdbOpen (nth 0 design) (nth 1 design) (nth 2 design) "r")) t3)
                           (when c
                             (setq t3 (list (hdbGetTopLibName c) (hdbGetTopCellName c) (hdbGetTopViewName c)))
                             (hdbClose c))
                           t3)
                         nil))))
      (t (setq top (list (nth 0 design) (nth 1 design) (nth 2 design)))))
    (rkPut res "path" instPath)
    (rkPut res "style" style)
    (rkPut res "segs" segs)
    (rkPut res "config" cfgL)
    (rkPut res "prefixed" nil)
    (cond
      ((null segs) (setq msg "empty instance path"))
      ((null top) (setq msg (sprintf nil "cannot open design %L" design)))
      (t
        (rkPut res "top" top)
        (setq mapTbl (rk_resMapTable ctx))
        ; a leading segment naming the top cell itself is dropped
        (when (and (cdr segs) (equal (lowerCase (car segs)) (lowerCase (nth 1 top))))
          (setq segs (cdr segs)))
        (setq walk (rk_resWalk top cfgL segs style mapTbl))
        ; first segment unknown at the TB top -> maybe relative to the DUT
        (setq dutInst (rkGet ctx "dut.inst"))
        (when (and (null (car walk)) (stringp dutInst) (nequal dutInst ""))
          (setq walk2 (rk_resWalk top cfgL (cons dutInst segs) style mapTbl))
          (when (car walk2)
            (setq walk walk2)
            (setq segs (cons dutInst segs))
            (rkPut res "prefixed" t)))
        (setq levels (car walk))
        (setq msg (cadr walk))))
    (rkPut res "segs" segs)
    (rkPut res "levels" levels)
    (rkPut res "matched" (length levels))
    (rkPut res "total" (length segs))
    (rkPut res "ok" (and segs (null msg) (equal (length levels) (length segs))))
    (rkPut res "message" (or msg "ok"))
    res))

; ---------------------------------------------------------------------------
; Window, selection, highlight
; ---------------------------------------------------------------------------

(defun rk_resHierSpec (levels)
  (let (pieces)
    (foreach lv levels
      (setq pieces (cons (sprintf nil "/%s(%s):r" (rkGet lv "item") (nth 2 (rkGet lv "bound"))) pieces)))
    (if pieces (buildString (reverse pieces) "") nil)))

; Install top [+ descend levels] in rk_resWin (or a new window). -> window / nil
(defun rk_resOpenWindow (top cfgL descLevels)
  (let (fs hier r w)
    (setq fs (list nil 'libName (nth 0 top) 'cellName (nth 1 top) 'viewName (nth 2 top)
                   'accessMode "r"))
    (when cfgL
      (setq fs (append fs (list 'configL (list (nth 0 cfgL) (nth 1 cfgL) (nth 2 cfgL) "r")))))
    (setq hier (rk_resHierSpec descLevels))
    (when hier
      (setq fs (append fs (list 'hierarchy hier))))
    (rkResultsClearHighlight)
    (setq r (errset (deOpen fs (if (rk_resWinValid rk_resWin) rk_resWin nil) "r") t))
    (setq w (and r (car r)))
    (when (and w (windowp w))
      (setq rk_resWin w)
      w)))

(defun rk_resZoomBox (bb)
  (let ((x1 (car (car bb))) (y1 (cadr (car bb))) (x2 (car (cadr bb))) (y2 (cadr (cadr bb))) m)
    (setq m (plus 0.25 (times 1.5 (max (difference x2 x1) (difference y2 y1)))))
    (list (list (difference x1 m) (difference y1 m)) (list (plus x2 m) (plus y2 m)))))

(defun rk_resNewHlSet (cv)
  (let ((hl (car (errset (geCreateHilightSet cv rk_resHlLayer) nil))))
    (when hl
      (errset (geSetHilightSetHaloParameters hl "over" "fadeout" "thin" 20 nil) nil)
      (setq rk_resHlSets (cons hl rk_resHlSets)))
    hl))

(defun rk_resEnable (hl w)
  (when hl (putpropq hl t enable))
  (when (rk_resWinValid w) (hiRedraw w))
  t)

; Select + zoom + halo one instance of the window's edit cellview.
(defun rk_resShowInst (w inst)
  (let (cv hl)
    (setq cv (geGetEditCellView w))
    (geDeselectAll w)
    (geSelectFig inst)
    (errset (hiZoomIn w (rk_resZoomBox inst~>bBox)) nil)
    (setq hl (rk_resNewHlSet cv))
    (when hl (geAddHilightFig hl inst nil))
    (rk_resEnable hl w)
    t))

(defun rkResultsJumpToInstance (instPath ctx)
  (let (res levels n matched desc sel w cv inst msg ok lastLv)
    (setq res (rkResultsResolveInstance instPath ctx))
    (setq rk_resLast res)
    (setq levels (rkGet res "levels"))
    (setq n (length levels))
    (setq matched (rkGet res "matched"))
    (cond
      ((rkGet res "ok")
        (setq desc (rk_resFirstN levels (sub1 n)))
        (setq sel (nth (sub1 n) levels)))
      ((zerop matched) nil)
      (t
        (setq lastLv (nth (sub1 n) levels))
        (cond
          ((rkGet lastLv "descend") (setq desc levels))
          (t (setq desc (rk_resFirstN levels (sub1 n))) (setq sel lastLv)))))
    (cond
      ((null (rkGet res "top"))
        (rk_resSay (sprintf nil "jump %s: %s" instPath (rkGet res "message"))))
      (t
        (setq w (rk_resOpenWindow (rkGet res "top") (rkGet res "config") desc))
        (cond
          ((null w)
            (rk_resSay (sprintf nil "jump %s: could not open %L" instPath (rkGet res "top"))))
          (t
            (when sel
              (setq cv (geGetEditCellView w))
              (setq inst (and cv (dbFindAnyInstByName cv (rkGet sel "name"))))
              (when inst (rk_resShowInst w inst)))
            (setq ok (and (rkGet res "ok") inst t))
            (setq msg (cond
                        (ok (sprintf nil "jump %s: selected %s in %s/%s" instPath (rkGet sel "item")
                                     cv~>libName cv~>cellName))
                        (t (sprintf nil "jump %s: stopped after %d of %d levels -- %s"
                                    instPath matched (rkGet res "total") (rkGet res "message")))))
            (rk_resSay msg)))))
    ok))

; Names on the window's current descend path, e.g. ("I0" "XB<1>").
; geGetInstHierPath gives (dbInst memInst row col); for an iterated instance
; memInst is the bit NUMBER (verified: XB<2:3> member 3 -> memInst 3).
(defun rk_resWinPath (w)
  (let (out sb inst)
    (foreach e (geGetInstHierPath w)
      (setq inst (car e))
      (setq sb (rk_resSplitBus inst~>name))
      (setq out (cons (if (and sb (integerp (cadr e)))
                          (sprintf nil "%s<%d>" (car sb) (cadr e))
                          inst~>name)
                      out)))
    (reverse out)))

(defun rkResultsHighlightAll (instPaths ctx)
  (let (w cv here d hl seen (count 0) res levels names ok target inst (k 0))
    (setq w (or (rkResultsWindow)
                (let ((cw (hiGetCurrentWindow))) (and cw (geGetEditCellView cw) cw))))
    (cond
      ((null w) (rk_resSay "highlight: no schematic window") 0)
      (t
        (setq cv (geGetEditCellView w))
        (setq here (rk_resWinPath w))
        (setq d (length here))
        (setq seen (makeTable "rk_resSeen" nil))
        (foreach p instPaths
          (when (and (stringp p) (nequal p "") (lessp k rk_resMaxPaths))
            (setq k (add1 k))
            (setq res (rkResultsResolveInstance p ctx))
            (setq levels (rkGet res "levels"))
            (setq names (mapcar (lambda (lv) (rkGet lv "item")) levels))
            (setq ok (greaterp (length names) d))
            (let ((i 0))
              (while (and ok (lessp i d))
                (unless (equal (nth i names) (nth i here)) (setq ok nil))
                (setq i (add1 i))))
            (when ok
              (setq target (rkGet (nth d levels) "name"))
              (unless (arrayref seen target)
                (setq inst (dbFindAnyInstByName cv target))
                (when inst
                  (setarray seen target t)
                  (unless hl (setq hl (rk_resNewHlSet cv)))
                  (when hl (geAddHilightFig hl inst nil))
                  (setq count (add1 count)))))))
        (rk_resEnable hl w)
        (rk_resSay (sprintf nil "highlighted %d instance(s) on %s/%s" count cv~>libName cv~>cellName))
        count))))

(defun rkResultsClearHighlight ()
  (let ((n 0))
    (foreach hl rk_resHlSets
      (when (car (errset (geIsValidHilightSet hl) nil))
        (errset (geDeleteHilightSet hl) nil)
        (setq n (add1 n))))
    (setq rk_resHlSets nil)
    (when (rk_resWinValid rk_resWin) (hiRedraw rk_resWin))
    n))

; ---------------------------------------------------------------------------
; DUT pick (D13)
; ---------------------------------------------------------------------------

(defun rk_resTerms (inst)
  (let ((m inst~>master))
    (sort (if m (mapcar (lambda (x) x~>name) m~>terminals) nil) 'alphalessp)))

(defun rkResultsDutFromInst (inst ctx)
  (let ((dut (rkMakeObj)) res lv view)
    (setq res (rkResultsResolveInstance inst~>name ctx))
    (setq lv (car (rkGet res "levels")))
    (setq view (or (and lv (nth 2 (rkGet lv "bound"))) "schematic"))
    (rkPut dut "inst" inst~>name)
    (rkPut dut "lib" inst~>libName)
    (rkPut dut "cell" inst~>cellName)
    (rkPut dut "view" view)
    (rkPut dut "terms" (or (rk_resTerms inst) rkJsonEmptyArray))
    dut))

(defun rkResultsListTopInstances (lib cell view @optional skipLibs)
  (let (top cfgL r cv out bound st (skip (or skipLibs rk_resDutSkipLibs)) e cfg)
    (setq r (errset (hdbIsConfig lib cell view) nil))
    (cond
      ((and r (car r))
        (setq cfgL (list lib cell view))
        (setq cfg (car (errset (hdbOpen lib cell view "r") nil)))
        (when cfg
          (setq top (list (hdbGetTopLibName cfg) (hdbGetTopCellName cfg) (hdbGetTopViewName cfg)))
          (setq st (rkMakeObj))
          (rkPut st "cfgs" (list cfg))
          (rkPut st "pv" (hdbCreatePathVector cfg))
          (rkPut st "pvs" (list (arrayref st "pv")))))
      (t (setq top (list lib cell view))))
    (setq cv (and top (rk_resOpenCv (nth 0 top) (nth 1 top) (nth 2 top))))
    (when cv
      (foreach i cv~>instances
        (unless (member i~>libName skip)
          (setq bound (if st (rk_resHdbBind st i) (rk_resPlainBind i~>libName i~>cellName)))
          (when (and bound (rk_resIsSchematic (nth 0 bound) (nth 1 bound) (nth 2 bound)))
            (setq e (rkMakeObj))
            (rkPut e "inst" i~>name)
            (rkPut e "lib" i~>libName)
            (rkPut e "cell" i~>cellName)
            (rkPut e "view" (nth 2 bound))
            (rkPut e "terms" (or (rk_resTerms i) rkJsonEmptyArray))
            (setq out (cons e out)))))
      (dbClose cv))
    (when st (rk_resCloseState st))
    (sort out (lambda (a b) (lessp (alphaNumCmp (rkGet a "inst") (rkGet b "inst")) 0)))))

; A window showing the TB top: the current window if it does, else rk_resWin
; re-installed at the top (config bindings applied).
(defun rkResultsOpenTop (ctx)
  (let (design top cfgL cw tcv)
    (setq design (rk_resDesignOf ctx))
    (cond
      ((nth 3 design)
        (setq cfgL (list (nth 0 design) (nth 1 design) (nth 2 design)))
        (setq top (car (errset
                         (let ((c (hdbOpen (nth 0 design) (nth 1 design) (nth 2 design) "r")) t3)
                           (when c
                             (setq t3 (list (hdbGetTopLibName c) (hdbGetTopCellName c) (hdbGetTopViewName c)))
                             (hdbClose c))
                           t3)
                         nil))))
      (t (setq top (list (nth 0 design) (nth 1 design) (nth 2 design)))))
    (setq cw (hiGetCurrentWindow))
    (setq tcv (and cw (car (errset cw~>topCellView nil))))
    (cond
      ((and tcv (dbobjectp tcv) (equal tcv~>libName (nth 0 top)) (equal tcv~>cellName (nth 1 top))
            (equal tcv~>viewName (nth 2 top)))
        cw)
      (top (rk_resOpenWindow top cfgL nil))
      (t nil))))

; Selection / descend path of a TB window -> DUT table or nil.
(defun rk_resDutFromWindow (w ctx)
  (let (path sel)
    (setq path (geGetInstHierPath w))
    (cond
      (path (rkResultsDutFromInst (car (car path)) ctx))
      (t
        (setq sel (setof x (geGetSelSet w) (equal x~>objType "inst")))
        (when (and sel (null (cdr sel)))
          (rkResultsDutFromInst (car sel) ctx))))))

; The instance under a point of the window's edit cellview (top level only).
(defun rk_resInstAtPoint (w pt)
  (let (cv box hits best area a bb)
    (setq cv (geGetEditCellView w))
    (when (and cv pt)
      (setq box (list (list (difference (car pt) 0.01) (difference (cadr pt) 0.01))
                      (list (plus (car pt) 0.01) (plus (cadr pt) 0.01))))
      (setq hits (setof x (dbGetOverlaps cv box nil) (and (dbobjectp x) (equal x~>objType "inst"))))
      (foreach h hits
        (setq bb h~>bBox)
        (setq a (times (difference (car (cadr bb)) (car (car bb)))
                       (difference (cadr (cadr bb)) (cadr (car bb)))))
        (when (or (null best) (lessp a area))
          (setq best h)
          (setq area a))))
    best))

; enterPoint ?doneProc: the clicked top-level instance (or, in a descended
; window, the top-level instance on its descend path) becomes the DUT.
(defun rk_resPickPointDone (w done pts)
  (let ((st rk_resPick) inst dut path)
    (setq rk_resPick nil)
    (when st
      (when (and done pts)
        (setq path (geGetInstHierPath (nth 0 st)))
        (setq inst (if path (car (car path)) (rk_resInstAtPoint (nth 0 st) (car pts))))
        (when inst (setq dut (rkResultsDutFromInst inst (nth 1 st)))))
      (if dut
        (rk_resSay (sprintf nil "DUT picked: %s (%s/%s)" (rkGet dut "inst") (rkGet dut "lib") (rkGet dut "cell")))
        (rk_resSay "DUT pick: no instance under the point"))
      (rk_resCall (nth 2 st) dut))
    dut))

(defun rkResultsPickDut (ctx doneFn)
  (let (w dut)
    (setq w (rkResultsOpenTop ctx))
    (cond
      ((null w)
        (rk_resSay "DUT pick: cannot open the testbench schematic")
        (rk_resCall doneFn nil)
        nil)
      ((setq dut (rk_resDutFromWindow w ctx))
        (rk_resSay (sprintf nil "DUT picked: %s (%s/%s)" (rkGet dut "inst") (rkGet dut "lib") (rkGet dut "cell")))
        (rk_resCall doneFn dut)
        dut)
      (t
        (setq rk_resPick (list w ctx doneFn))
        (hiSetCurrentWindow w)
        (enterPoint ?prompts (list "relkit: click the DUT instance in the testbench schematic")
                    ?doneProc "rk_resPickPointDone"
                    ?cmdName "relkit DUT pick")
        t))))

; ---------------------------------------------------------------------------
; Result tables
; ---------------------------------------------------------------------------

(defun rkResultsReadTable (tsvPath) (rkTsvRead tsvPath))

(defun rkResultsLoadResults (src)
  (cond
    ((tablep src) src)
    ((stringp src) (rkJsonReadKeepFalse src))
    (t (error "rkResultsLoadResults: expected a path or a table, got %L" src))))

(defun rkResultsColIndex (header col)
  (let ((i 0) hit)
    (foreach h header
      (when (and (null hit) (equal h col)) (setq hit i))
      (setq i (add1 i)))
    hit))

(defun rkResultsCell (table row col)
  (let ((i (rkResultsColIndex (car table) col)))
    (and i (nth i row))))

; Preferred metric columns per run type (others follow, sorted).
(defun rk_resMetricOrder (type keys)
  (let ((pref (cond
                ((equal type "deos") (list "Total_DPM"))
                ((equal type "aging") (list "didsat" "didsat%" "dvth"))
                (t nil)))
        out)
    (foreach p pref (when (member p keys) (setq out (cons p out))))
    (foreach k keys (unless (member k pref) (setq out (cons k out))))
    (reverse out)))

; Parsed results (CONTRACT 5.1) -> (header rows): one row per corner/Stress.
; Hidden columns: _key _inst _sev _table (device table path, SKILL-only).
(defun rkResultsSummaryTable (results)
  (let (r type corners keys mkeys header rows row pass m isAging)
    (setq r (rkResultsLoadResults results))
    (setq type (or (rkGet r "type") ""))
    (setq isAging (equal type "aging"))
    (setq corners (rkGet r "corners"))
    (foreach c corners
      (setq m (rkGet c "metrics"))
      (when (tablep m)
        (foreach k (rkKeys m) (unless (member k keys) (setq keys (cons k keys))))))
    (setq mkeys (rk_resMetricOrder type (sort keys 'alphalessp)))
    (setq header (rk_resConcat (list "_key" "_inst" "_sev" "_table" "Corner")
                         (if isAging (list "Stress") nil)
                         (list "Pass")
                         mkeys
                         (list "Worst device" "Worst model")))
    (foreach c corners
      (setq pass (arrayref c "pass"))
      (setq m (rkGet c "metrics"))
      (setq row (rk_resConcat
                  (list (rk_resFmt (rkGet c "key"))
                        (rk_resFmt (rkGet c "worst_device"))
                        (cond ((eq pass rkJsonFalse) "fail") (t ""))
                        (rk_resFmt (rkGet c "table_path"))
                        (rk_resFmt (rkGet c "corner")))
                  (if isAging (list (rk_resFmt (rkGet c "stress_id"))) nil)
                  (list (cond ((eq pass t) "PASS") ((eq pass rkJsonFalse) "FAIL") (t "?")))
                  (mapcar (lambda (k) (if (tablep m) (rk_resFmt (arrayref m k)) "")) mkeys)
                  (list (rk_resFmt (rkGet c "worst_device"))
                        (rk_resFmt (rkGet c "worst_model")))))
      (setq rows (cons row rows)))
    (list header (reverse rows))))

; Numeric-aware sort: numbers by value, then non-numbers by text.
(defun rkResultsSortRows (table col @optional desc)
  (let ((i (rkResultsColIndex (car table) col)) rows)
    (cond
      ((null i) table)
      (t
        (setq rows (sort (copy (cadr table))
                         (lambda (a b)
                           (let ((x (rk_resNum (nth i a))) (y (rk_resNum (nth i b))))
                             (cond
                               ((and x y) (if desc (greaterp x y) (lessp x y)))
                               (x t)
                               (y nil)
                               (t (alphalessp (or (nth i a) "") (or (nth i b) ""))))))))
        (list (car table) rows)))))

; The DPM column of a DEOS device table, if any.
(defun rk_resDpmCol (header)
  (let (hit)
    (foreach pat (list "^DPM_EOS$" "^DPM$" "^Total_DPM$" "^DPM")
      (unless hit
        (foreach h header
          (when (and (null hit) (pcreMatchp pat h)) (setq hit h)))))
    hit))

; Device table: TSV path or (header rows); DEOS tables come back sorted by
; DPM descending. Rows keep their _sev (fail/warn) flag.
(defun rkResultsDeviceTable (src)
  (let (table col)
    (setq table (if (stringp src) (rkTsvRead src) src))
    (setq col (rk_resDpmCol (car table)))
    (if col (rkResultsSortRows table col t) table)))

(defun rk_resHiddenCol (h)
  (member h (list "_inst" "_key" "_table" "_run_dir")))

(defun rk_resSevText (s)
  (cond ((equal s "fail") "FAIL") ((equal s "warn") "WARN") (t "")))

; Comparison function for numeric report columns (userData = column index).
(defun rk_resCmpNum (a b col)
  (let ((x (rk_resNum (nth col a))) (y (rk_resNum (nth col b))))
    (cond
      ((and x y) (cond ((lessp x y) -1) ((greaterp x y) 1) (t 0)))
      (x -1)
      (y 1)
      (t (let ((s (or (nth col a) "")) (u (or (nth col b) "")))
           (cond ((alphalessp s u) -1) ((equal s u) 0) (t 1)))))))

; (header rows) -> (headers choices) for hiCreateReportField. Reserved columns
; are kept (so callbacks can read them) but hidden (width 0); _sev is shown
; as a narrow "Flag" column (FAIL / WARN).
(defun rkResultsReportSpec (table)
  (let ((header (car table)) (rows (cadr table)) headers choices (i 0) w nNum nTxt sevI)
    (setq sevI (rkResultsColIndex header "_sev"))
    (setq choices
      (mapcar (lambda (row)
                (let ((j 0) out)
                  (foreach c row
                    (setq out (cons (if (and sevI (equal j sevI)) (rk_resSevText c) (or c "")) out))
                    (setq j (add1 j)))
                  ; short rows are padded so every row has every column
                  (while (lessp (length out) (length header)) (setq out (cons "" out)))
                  (reverse out)))
              rows))
    (foreach h header
      (cond
        ((rk_resHiddenCol h)
          (setq headers (cons (list h 0 'left 'string t) headers)))
        ((equal h "_sev")
          (setq headers (cons (list "Flag" 45 'left 'string t) headers)))
        (t
          (setq w (strlen h))
          (setq nNum 0)
          (setq nTxt 0)
          (foreach row choices
            (setq w (max w (strlen (nth i row))))
            (cond
              ((equal (nth i row) "") nil)
              ((rk_resNumP (nth i row)) (setq nNum (add1 nNum)))
              (t (setq nTxt (add1 nTxt)))))
          (setq w (min 320 (max 50 (plus 16 (times 8 w)))))
          ; numeric column (mostly numbers): sorted by value, text cells last
          (setq headers (cons (if (and (greaterp nNum 0) (geqp nNum nTxt))
                                  (list h w 'right 'string t "rk_resCmpNum" i)
                                  (list h w 'left 'string t))
                              headers))))
      (setq i (add1 i)))
    (list (reverse headers) choices)))

; (header rows) -> strings for a list box: visible columns joined, failing
; rows prefixed with "! ".
(defun rkResultsListBoxItems (table)
  (let ((header (car table)) out sevI)
    (setq sevI (rkResultsColIndex header "_sev"))
    (foreach row (cadr table)
      (let ((j 0) cells)
        (foreach h header
          (unless (or (rk_resHiddenCol h) (equal h "_sev"))
            (setq cells (cons (or (nth j row) "") cells)))
          (setq j (add1 j)))
        (setq out (cons (strcat (if (and sevI (equal (nth sevI row) "fail")) "! " "  ")
                                (buildString (reverse cells) " | "))
                        out))))
    (reverse out)))

; ---------------------------------------------------------------------------
; Table window (modeless; Pattern A)
; ---------------------------------------------------------------------------

; Row of the report the user acted on: selected item, read back from the
; field's current choices (so column sorting cannot misalign it).
(defun rk_resFormRow (formSym)
  (let ((st (arrayref rk_resForms formSym)) form fld idx)
    (when st
      (setq form (rkGet st "form"))
      (setq fld (get form 'rk_resRep))
      (setq idx (car fld->value))
      (when (listp idx) (setq idx (car idx)))
      (and (integerp idx) (nth idx fld->choices)))))

(defun rk_resFormStatus (formSym msg)
  (let ((st (arrayref rk_resForms formSym)))
    (when st (putpropq (get (rkGet st "form") 'rk_resStatus) msg value))
    msg))

; Double-click / [Open]: a summary row opens its device table, a device row jumps.
(defun rk_resTableActivate (formSym)
  (let ((st (arrayref rk_resForms formSym)) row header inst tbl r)
    (when st
      (setq header (rkGet st "header"))
      (setq row (rk_resFormRow formSym))
      (cond
        ((null row) (rk_resFormStatus formSym "select a row first"))
        ((and (setq tbl (nth (or (rkResultsColIndex header "_table") 999) row))
              (nequal tbl "") (isFile tbl))
          (setq r (rkResultsShowTable (sprintf nil "%s -- %s" (rkGet st "title")
                                               (or (nth (or (rkResultsColIndex header "Corner") 999) row) ""))
                                      (rkResultsDeviceTable tbl) (rkGet st "ctx") (rkGet st "noDisplay")))
          (rkPut st "child" r)
          r)
        (t (rk_resTableJump formSym))))))

(defun rk_resTableJump (formSym)
  (let ((st (arrayref rk_resForms formSym)) row inst)
    (when st
      (setq row (rk_resFormRow formSym))
      (setq inst (and row (nth (or (rkResultsColIndex (rkGet st "header") "_inst") 999) row)))
      (cond
        ((or (null inst) (equal inst "")) (rk_resFormStatus formSym "this row has no instance path"))
        (t
          (rkResultsJumpToInstance inst (rkGet st "ctx"))
          (rk_resFormStatus formSym rk_resLastMsg)
          (rkGet rk_resLast "ok"))))))

(defun rk_resTableHiliteAll (formSym)
  (let ((st (arrayref rk_resForms formSym)) i paths n)
    (when st
      (setq i (rkResultsColIndex (rkGet st "header") "_inst"))
      (when i
        (foreach row (rkGet st "rows")
          (when (and (nth i row) (nequal (nth i row) "")) (setq paths (cons (nth i row) paths)))))
      (setq n (rkResultsHighlightAll (reverse paths) (rkGet st "ctx")))
      (rk_resFormStatus formSym rk_resLastMsg)
      n)))

(defun rk_resTableClear (formSym)
  (let ((n (rkResultsClearHighlight)))
    (rk_resFormStatus formSym (sprintf nil "cleared %d highlight set(s)" n))
    n))

(defun rk_resTableClose (formSym)
  (setarray rk_resForms formSym nil)
  t)

; title; src = parsed results (summary.json / collect out.json path, or the
; table) -> summary rows, a TSV path, or (header rows); ctx for jumps.
; noDisplay = build + instantiate only (headless tests).
(defun rkResultsShowTable (title src ctx @optional noDisplay)
  (let (table spec nm sym fRep fOpen fJump fHi fClr fStat form st h)
    (setq table (cond
                  ((tablep src) (rkResultsSummaryTable src))
                  ((and (stringp src) (pcreMatchp "\\.json$" src)) (rkResultsSummaryTable src))
                  ((stringp src) (rkTsvRead src))
                  (t src)))
    (setq spec (rkResultsReportSpec table))
    (setq rk_resFormCount (add1 rk_resFormCount))
    (setq nm (sprintf nil "rk_resTable_%d" rk_resFormCount))
    (setq sym (stringToSymbol nm))
    (setq fRep (hiCreateReportField ?name 'rk_resRep
                 ?headers (car spec)
                 ?choices (cadr spec)
                 ?selectMode 'single
                 ?altRowHilight t
                 ?doubleClickCB (sprintf nil "(rk_resTableActivate '%s)" nm)))
    (setq fOpen (hiCreateButton ?name 'rk_resBtnOpen ?buttonText "Open / Jump"
                  ?callback (sprintf nil "(rk_resTableActivate '%s)" nm)))
    (setq fJump (hiCreateButton ?name 'rk_resBtnJump ?buttonText "Jump to instance"
                  ?callback (sprintf nil "(rk_resTableJump '%s)" nm)))
    (setq fHi (hiCreateButton ?name 'rk_resBtnHi ?buttonText "Highlight all on page"
                ?callback (sprintf nil "(rk_resTableHiliteAll '%s)" nm)))
    (setq fClr (hiCreateButton ?name 'rk_resBtnClr ?buttonText "Clear highlight"
                 ?callback (sprintf nil "(rk_resTableClear '%s)" nm)))
    (setq fStat (hiCreateStringField ?name 'rk_resStatus ?prompt "Status" ?value ""
                  ?editable nil))
    (setq h (min 600 (plus 80 (times 22 (length (cadr table))))))
    (setq form (hiCreateAppForm
                 ?name sym
                 ?formTitle (sprintf nil "relkit: %s" title)
                 ?fields (list
                           (list fRep (list 5 5) (list 790 h) 0)
                           (list fOpen (list 5 (plus h 10)) (list 130 26))
                           (list fJump (list 140 (plus h 10)) (list 150 26))
                           (list fHi (list 295 (plus h 10)) (list 170 26))
                           (list fClr (list 470 (plus h 10)) (list 130 26))
                           (list fStat (list 5 (plus h 42)) (list 790 26) 60))
                 ?callback (list (sprintf nil "(rk_resTableClose '%s)" nm)
                                 (sprintf nil "(rk_resTableClose '%s)" nm))
                 ?buttonLayout 'Close
                 ?dialogStyle 'modeless
                 ?dontBlock t          ; else hiDisplayForm blocks until closed
                 ?initialSize (list 800 (plus h 110))))
    (hiInstantiateForm form)
    (setq st (rkMakeObj))
    (rkPut st "form" form)
    (rkPut st "title" title)
    (rkPut st "header" (car table))
    (rkPut st "rows" (cadr table))
    (rkPut st "ctx" ctx)
    (rkPut st "noDisplay" noDisplay)
    (setarray rk_resForms sym st)
    (unless noDisplay (hiDisplayForm form))
    form))

; ---------------------------------------------------------------------------
; Reports
; ---------------------------------------------------------------------------

(defun rkResultsOpenFile (path)
  (let (r)
    (cond
      ((not (and (stringp path) (isFile path)))
        (rk_resSay (sprintf nil "open: no such file %L" path))
        nil)
      ((pcreMatchp "\\.html?$" path)
        (setq r (errset (hiLaunchBrowser (strcat "file://" path)) nil))
        (cond
          ((and r (car r)) t)
          (t (and (car (errset (view path 'default path) nil)) t))))
      (t (and (car (errset (view path 'default path) nil)) t)))))
