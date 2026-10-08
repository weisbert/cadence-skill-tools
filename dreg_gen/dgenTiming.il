; dgenTiming.il -- transient ("trans") timing for Dreg Generator signals.
;
; WHAT. Each emitted signal (enabled DUT pin or customVar) can carry a list
; of timed events. Semantics follow Cadence's own sources (vpulse / vpwl:
; a "DC voltage" for DC analyses, a waveform for transient):
;   * DC analyses (dc op / dc sweep / ac / noise / stb ...) use the DC value
;     -- the per-pin "value" field, i.e. CDF parameter d_<N> / v_<N> (often
;     a design variable such as rx_en). Timers never fire there.
;   * Transient starts from the signal's INIT value written in the timing
;     table and then follows its edges. The init row may say DC, meaning
;     "start from the DC value" (also what a table without an init row,
;     i.e. made before init rows existed, does).
; Signals with no events emit exactly the same Verilog-A as before this
; feature (pure DC), so regenerating an old dreg is a no-op.
;
; ROW SHAPE. The timing table lives on the spec as 'timing -- a flat list
; of rows, keyed by signal base name (no bus suffix):
;     (nil 'signal "EN" 'time "init"   'edge ""   'value "0")   <- init row
;     (nil 'signal "EN" 'time "T1+70n" 'edge "TR" 'value "")
;   'time  -- edge START time (absolute, from t=0 of the transient), or
;             "init" for the signal's transient start value (one per signal)
;   'edge  -- ramp duration, linear 0->100% (same for rise and fall)
;   'value -- 1-bit digital: "" = TOGGLE, or 0 / 1 / a variable / DC
;             bus:    new integer value (bit-decomposed like the DC path)
;             analog: new voltage
;             "DC" (any case) in any value / init cell = the DC value.
; A flat list (rather than per-pin event lists) keeps rows alive when a
; pin is temporarily disabled or a customVar is renamed -- such rows are
; skipped at emit time and reported as warnings, never silently dropped
; from the table.
;
; EXPRESSIONS + VARIABLES. Every time / edge / value cell is an
; expression: terms joined by + or -, each term a literal or a variable
; name -- "5n", "T_1", "T_1+70n", "VDDH-0.1", "BV+1". Any identifier typed
; in a cell IS a variable: nothing has to be declared first. Each variable
; an emitted row uses becomes a Verilog-A parameter tv_<NAME> and a CDF
; parameter tv_<NAME> whose default is the CEL reference <NAME> -- so ADE /
; Maestro "Copy From Cellview" pulls NAME into the design-variables table
; and it can be set / swept. The tv_ prefix keeps the .va / CDF names
; clear of pins and of d_ / v_ parameters; the design variable is exactly
; what the user typed.
; Optional TABLE VALUES live on the spec as 'timingVars:
;     (nil 'name "T_1" 'default "5n")
; They only order the GUI (the By-time view asks for them; a variable
; without one sorts as 0, i.e. first) and serve as the .va fallback
; (else 0). Cells using variables get syntax / reserved-name checks only;
; range and ordering checks apply to plain-literal cells.

; EMITTED VERILOG-A (one block per timed signal):
;     @(initial_step) begin nedge_EN = 0; edge_EN = 50p; end
;     if (nedge_EN == 0) lvl_EN = analysis("tran") ? 0 : (d_EN != 0);
;     @(timer(5n))    begin lvl_EN = !lvl_EN; edge_EN = 50p; nedge_EN = nedge_EN + 1; end
;     @(timer(max(tv_T1+70n, 1f))) begin lvl_EN = (d_EN != 0); edge_EN = max(tv_TR, 1f); nedge_EN = nedge_EN + 1; end
;     V(EN) <+ transition(lvl_EN * DVDD, 0, edge_EN, edge_EN);
; analysis("tran") is already true at the transient's t=0 operating point
; and false in dc / dc-sweep / ac (verified, Spectre 18.1, 2026-10-07), so
; transient starts at the init value while DC analyses see d_EN. Until the
; first edge the level is re-derived every evaluation (a DC sweep inside
; one run never re-runs initial_step).
; Verified on Spectre 18.1 (2026-10-06): transition() picks up the edge_X
; value assigned in the same event block, so every edge gets its own ramp
; time; parameter expressions work inside timer() / max(). An event at
; exactly t=0 must NOT use timer(0): Spectre fires it while solving the
; initial operating point and the ramp collapses into a step (the IC
; already sits at the new level). Literal t=0 events are emitted as
; timer(1f); variable expressions are clamped with max(.., 1f) (times AND
; edges), so a swept T0=0 / TR=0 still ramps from the initial level.
;
; Pure data layer: no GUI, no db writes. Called by dgenVerilogA.il /
; dgenCDF.il (emit), dgenGui.il / dgenTimingGui.il (validation, display).
; Regex uses pcre only (see feedback in dgenStore.il dgen_emitDefaultStr).

; ---------------------------------------------------------------------------
; Literal helpers
; ---------------------------------------------------------------------------

; Strip leading/trailing whitespace. Own copy (dgenPat_trim lives in
; dgenGui.il, which loads after the emitters).
; Ref: sklangref.pdf p.167 (pcreCompile), p.191 (pcreReplace).
(defun dgen_tmTrim (s "t")
  (pcreReplace (pcreCompile "^\\s+|\\s+$") s "" 0))

; Normalize a user-typed time ("5ns", "50ps", "1.2u", "0", "1e-9") to a
; canonical Verilog-A real literal ("5n", "50p", "1.2u", "0", "1e-9"), or
; nil if it isn't a (non-negative) time literal.
;   * case-insensitive; one trailing "s" (seconds) is dropped: 5ns -> 5n
;   * scale suffix f p n u m. Lower-casing makes "5M" milli -- the SPICE
;     reading, and the only sensible one for a time (Verilog-A would read
;     an uppercase M as mega). The emitted literal is always lowercase.
;   * exponent form allowed but not combined with a suffix
; Ref: sklangref.pdf p.161 (lowerCase), p.186 (pcreMatchp), p.223 (substring).
(defun dgen_timeNorm (str "g")
  (let (s n)
    (cond
      ((not (stringp str)) nil)
      (t
        (setq s (lowerCase (dgen_tmTrim str)))
        (setq n (strlen s))
        (when (and (greaterp n 1) (equal (substring s n 1) "s"))
          (setq s (substring s 1 (sub1 n))))
        (cond
          ((pcreMatchp "^[0-9]+(\\.[0-9]+)?([fpnum]|e[-+]?[0-9]+)?$" s) s)
          (t nil))))))

; Canonical numeric literal -> float. Handles a leading "-", one scale
; suffix (f p n u m k) or an exponent. Caller guarantees the literal came
; out of one of the normalizers below.
; Ref: sklangref.pdf p.229 (atof).
(defun dgen_tmLitVal (canon "t")
  (let ((s canon) (sign 1.0) n last scale)
    (when (equal (substring s 1 1) "-")
      (setq sign -1.0)
      (setq s (substring s 2 (sub1 (strlen s)))))
    (setq n (strlen s))
    (setq last (substring s n 1))
    (setq scale
      (cond
        ((equal last "f") 1e-15)
        ((equal last "p") 1e-12)
        ((equal last "n") 1e-9)
        ((equal last "u") 1e-6)
        ((equal last "m") 1e-3)
        ((equal last "k") 1e3)
        (t nil)))
    (times sign
      (cond
        (scale (times (atof (substring s 1 (sub1 n))) scale))
        (t     (times 1.0 (atof s)))))))

; Time literal -> seconds (kept for callers / tests of the literal path).
(defun dgen_timeVal (canon "t")
  (dgen_tmLitVal canon))

; Analog value literal: real, optional sign, exponent OR one Verilog-A
; scale suffix (k m u n p f). No uppercase M (see dgen_timeNorm).
(defun dgen_tmAnalogValueP (s "g")
  (and (stringp s)
       (pcreMatchp "^-?[0-9]+(\\.[0-9]+)?([eE][-+]?[0-9]+|[kmunpf])?$" s)))

; One literal TERM of an expression, normalized for the cell kind:
;   "time"   -> dgen_timeNorm ("5ns" -> "5n")
;   "bus"    -> decimal integer
;   "analog" -> real literal, lower-cased suffix ("900M" -> "900m")
(defun dgen_tmLitNorm (term kind "tt")
  (let (l)
    (cond
      ((equal kind "time") (dgen_timeNorm term))
      ((member kind (list "bus" "bit")) (and (pcreMatchp "^[0-9]+$" term) term))
      (t
        (setq l (lowerCase term))
        (and (dgen_tmAnalogValueP l) l)))))

; Variable default: a time literal ("5ns") or any analog literal ("1.8",
; "-0.5", "10"). Returns the canonical literal or nil.
(defun dgen_tmVarDefaultNorm (s "g")
  (cond
    ((not (stringp s)) nil)
    (t (or (dgen_timeNorm s) (dgen_tmLitNorm (dgen_tmTrim s) "analog")))))

; Legal design-variable / Verilog identifier.
(defun dgen_tmIdentP (s "g")
  (and (stringp s) (pcreMatchp "^[A-Za-z_][A-Za-z0-9_]*$" s)))

; Fresh row plist.
(defun dgen_tmRow (signal time edge value "tttt")
  (list nil 'signal signal 'time time 'edge edge 'value value))

; Fresh variable plist.
(defun dgen_tmVar (name default "tt")
  (list nil 'name name 'default default))

; Init rows ('time "init") hold a signal's transient start value.
(defun dgen_tmInitP (r "g") (equal (get r 'time) "init"))

; Edge rows only.
(defun dgen_tmEdgeRows (timing "g")
  (setof r timing (not (dgen_tmInitP r))))

; The init row of signal `name`, or nil.
(defun dgen_tmInitRow (timing name "gt")
  (car (setof r timing (and (dgen_tmInitP r) (equal (get r 'signal) name)))))

; The "DC" keyword (any case) of a value / init cell.
(defun dgen_tmDcP (s "g")
  (and (stringp s) (equal (upperCase (dgen_tmTrim s)) "DC")))

; ---------------------------------------------------------------------------
; Expressions: TERM { (+|-) TERM }, TERM = literal | variable
; ---------------------------------------------------------------------------

; Split an expression into ((sign term) ...), sign "+" or "-". A + or -
; right after a numeric term ending in e/E is an exponent sign, not an
; operator ("1e-9"). Blanks are ignored. Leading signs are folded into the
; first term's sign. Returns nil on a syntax error (empty term, "a+-b",
; trailing operator).
(defun dgen_tmExprTokens (s "t")
  (let (str n i ch cur sign out bad)
    (setq str (dgen_tmTrim s))
    (setq n (strlen str))
    (setq i 1)
    (setq cur "")
    (setq sign "+")
    (while (and (leqp i n) (null bad))
      (setq ch (substring str i 1))
      (cond
        ((member ch (list " " "\t")) nil)
        ((and (member ch (list "+" "-"))
              (not (and (nequal cur "")
                        (pcreMatchp "^[0-9]" cur)
                        (member (substring cur (strlen cur) 1) (list "e" "E")))))
          (cond
            ((nequal cur "")
              (setq out (cons (list sign cur) out))
              (setq cur "")
              (setq sign ch))
            ((null out)
              ; leading sign(s): "-x" / "+x" / "--x"
              (when (equal ch "-")
                (setq sign (cond ((equal sign "-") "+") (t "-")))))
            (t (setq bad t))))
        (t (setq cur (strcat cur ch))))
      (setq i (add1 i)))
    (cond
      ((or bad (equal cur "")) nil)
      (t (reverse (cons (list sign cur) out))))))

; Canonical form of an expression cell for `kind` ("time" | "bus" |
; "analog"): literals normalized, variables kept verbatim, no blanks,
; "-" only where needed: " t1 + 70ns " -> "t1+70n". nil if not parseable.
; A plain literal comes back exactly as dgen_timeNorm / the literal rule
; gives it, so pre-variable tables normalize unchanged.
(defun dgen_tmExprNorm (s kind "gt")
  (let (toks out bad lit first)
    (cond
      ((not (stringp s)) nil)
      (t
        (setq toks (dgen_tmExprTokens s))
        (setq out "")
        (setq first t)
        (foreach tk toks
          (setq lit (cond
                      ((dgen_tmIdentP (cadr tk)) (cadr tk))
                      (t (dgen_tmLitNorm (cadr tk) kind))))
          (cond
            ((null lit) (setq bad t))
            (first (setq out (strcat (cond ((equal (car tk) "-") "-") (t "")) lit)))
            (t (setq out (strcat out (car tk) lit))))
          (setq first nil))
        (cond
          ((or bad (null toks)) nil)
          (t out))))))

; Variable names used by a canonical expression (in order, may repeat).
(defun dgen_tmExprVars (canon "g")
  (cond
    ((not (stringp canon)) nil)
    (t (mapcar 'cadr (setof tk (dgen_tmExprTokens canon) (dgen_tmIdentP (cadr tk)))))))

(defun dgen_tmHasVars (canon "g")
  (and (dgen_tmExprVars canon) t))

; Default literal of variable `name` in a 'timingVars list, or nil.
(defun dgen_tmVarDefault (vars name "gt")
  (let ((v (car (setof x vars (equal (get x 'name) name)))))
    (and v (dgen_tmVarDefaultNorm (get v 'default)))))

; First variable of `canon` that `vars` doesn't define, or nil.
(defun dgen_tmUndefVar (canon vars "gg")
  (car (setof nm (dgen_tmExprVars canon) (null (dgen_tmVarDefault vars nm)))))

; Value of a canonical expression with variables at their defaults, or
; nil when a variable is undefined.
(defun dgen_tmExprVal (canon vars "gg")
  (let ((sum 0.0) bad v)
    (foreach tk (dgen_tmExprTokens canon)
      (setq v (cond
                ((dgen_tmIdentP (cadr tk))
                  (let ((d (dgen_tmVarDefault vars (cadr tk))))
                    (and d (dgen_tmLitVal d))))
                (t (dgen_tmLitVal (cadr tk)))))
      (cond
        ((null v) (setq bad t))
        ((equal (car tk) "-") (setq sum (difference sum v)))
        (t (setq sum (plus sum v)))))
    (cond (bad nil) (t sum))))

; Verilog-A text of a canonical expression: variables -> tv_<NAME>.
(defun dgen_tmExprVA (canon "t")
  (let ((out "") (first t) term)
    (foreach tk (dgen_tmExprTokens canon)
      (setq term (cond
                   ((dgen_tmIdentP (cadr tk)) (strcat "tv_" (cadr tk)))
                   (t (cadr tk))))
      (cond
        (first (setq out (strcat (cond ((equal (car tk) "-") "-") (t "")) term)))
        (t (setq out (strcat out (car tk) term))))
      (setq first nil))
    out))

; Engineering text for a number: time -> "120n" / "1.5u"; bus -> "10";
; analog -> "%g".
(defun dgen_tmFmtNum (v kind "nt")
  (let (scales found)
    (cond
      ((member kind (list "bus" "bit")) (sprintf nil "%d" (round v)))
      ((equal kind "analog") (sprintf nil "%g" v))
      ((zerop v) "0")
      (t
        (setq scales (list (list 1.0 "") (list 1e-3 "m") (list 1e-6 "u")
                           (list 1e-9 "n") (list 1e-12 "p") (list 1e-15 "f")))
        (foreach sc scales
          (when (and (null found) (geqp (abs v) (times 0.999999 (car sc))))
            (setq found (sprintf nil "%g%s" (quotient v (car sc)) (cadr sc)))))
        (or found (sprintf nil "%g" v))))))

; Cell text for the table: the expression, plus "= value at defaults"
; when it uses variables ("T1+70n = 120n").
(defun dgen_tmExprDisplay (canon vars kind "ggt")
  (let (v)
    (cond
      ((not (stringp canon)) "")
      ((not (dgen_tmHasVars canon)) canon)
      (t
        (setq v (dgen_tmExprVal canon vars))
        (cond
          (v (sprintf nil "%s = %s" canon (dgen_tmFmtNum v kind)))
          (t canon))))))

; Sort value of a canonical expression: variables at their table values,
; variables WITHOUT a value count as 0 (so such rows sort first). Used only
; for ordering / display -- never as the simulation value.
(defun dgen_tmSortVal (canon vars "gg")
  (let ((sum 0.0) v)
    (foreach tk (dgen_tmExprTokens canon)
      (setq v (cond
                ((dgen_tmIdentP (cadr tk))
                  (let ((d (dgen_tmVarDefault vars (cadr tk))))
                    (cond (d (dgen_tmLitVal d)) (t 0.0))))
                (t (dgen_tmLitVal (cadr tk)))))
      (cond
        ((equal (car tk) "-") (setq sum (difference sum v)))
        (t (setq sum (plus sum v)))))
    sum))

; Seconds of a row's time (or edge) cell for ORDERING: variables at their
; table values, unset variables as 0; 0.0 when the cell doesn't parse, so
; sorting never crashes on a half-typed row (validation reports it).
(defun dgen_tmFieldSec (row key @optional vars)
  (let ((c (dgen_tmExprNorm (get row key) "time")))
    (cond
      ((dgen_tmInitP row) -1.0)
      (c (dgen_tmSortVal c vars))
      (t 0.0))))

; ---------------------------------------------------------------------------
; Variables list (the [Timing Table...] "Variables" box, import files)
; ---------------------------------------------------------------------------

; "NAME = default" lines -> (vars errors). Blank and # lines are skipped.
(defun dgen_tmVarsFromText (text "t")
  (let (vars errs lineNo ln parts nm df)
    (setq lineNo 0)
    (foreach line (parseString (or text "") "\n" t)
      (setq lineNo (add1 lineNo))
      (setq ln (dgen_tmTrim line))
      (unless (or (equal ln "") (equal (substring ln 1 1) "#"))
        (setq parts (parseString ln "="))
        (setq nm (and (equal (length parts) 2) (dgen_tmTrim (car parts))))
        (setq df (and (equal (length parts) 2) (dgen_tmTrim (cadr parts))))
        (cond
          ((or (null nm) (equal nm "") (null df) (equal df ""))
            (setq errs (cons (sprintf nil "Variables line %d: expected 'NAME = default', got '%s'" lineNo ln) errs)))
          (t (setq vars (cons (dgen_tmVar nm df) vars))))))
    (list (reverse vars) (reverse errs))))

(defun dgen_tmVarsToText (vars "l")
  (let ((out ""))
    (foreach v vars
      (setq out (strcat out (sprintf nil "%s = %s\n" (get v 'name) (get v 'default)))))
    out))

; Words that are netlist keywords / built-ins on the Spectre side and
; would not work as design-variable names.
(defun dgen_tmReservedP (name "t")
  (member (lowerCase name)
    (list "time" "temp" "tnom" "freq" "scale" "scalem" "pi" "dvdd" "dc" "init")))

; Validate the variables list. nil or an error string.
(defun dgen_tmVarsError (vars "l")
  (let (err seen nm)
    (foreach v vars
      (unless err
        (setq nm (get v 'name))
        (cond
          ((not (dgen_tmIdentP nm))
            (setq err (sprintf nil "Variable name '%s' is not a legal identifier (letters, digits, underscore; no leading digit)." nm)))
          ((dgen_tmReservedP nm)
            (setq err (sprintf nil "Variable name '%s' is reserved -- pick another name." nm)))
          ((member nm seen)
            (setq err (sprintf nil "Variable '%s' is defined twice." nm)))
          ((null (dgen_tmVarDefaultNorm (get v 'default)))
            (setq err (sprintf nil "Variable %s: value '%s' is not a number (e.g. 5n, 50ps, 1.8, 10)."
                        nm (or (get v 'default) "")))))
        (setq seen (cons nm seen))))
    err))

(defun dgen_tmVarKey (v "g")
  (sprintf nil "%s=%s" (get v 'name)
    (or (dgen_tmVarDefaultNorm (get v 'default)) (get v 'default) "")))

(defun dgen_tmVarsEqual (a b "gg")
  (equal (sort (mapcar 'dgen_tmVarKey a) 'alphalessp)
         (sort (mapcar 'dgen_tmVarKey b) 'alphalessp)))

; ---------------------------------------------------------------------------
; Signal classification + lookup
; ---------------------------------------------------------------------------

; "scalar" (1-bit digital, toggles), "bus" (digital, integer values),
; "analog" (voltage values). Analog is always scalar (GUI + emitters
; force it), so the bus check only applies to digital items.
(defun dgen_tmKindOf (item "g")
  (cond
    ((equal (get item 'kind) "analog") "analog")
    ((get item 'isBus)                 "bus")
    (t                                 "scalar")))

; Short label for the table's Type column.
(defun dgen_tmKindLabel (item "g")
  (let ((k (dgen_tmKindOf item)))
    (cond
      ((equal k "analog") "analog")
      ((equal k "bus")
        (sprintf nil "bus<%d:%d>" (get item 'busHi) (get item 'busLo)))
      (t "1-bit"))))

; Find the emit item called `name` in an emit list (dgen_specEmitList).
(defun dgen_tmFindItem (items name "lt")
  (car (setof it items (equal (get it 'name) name))))

; Rows of `timing` for signal `name`, sorted by time (ascending, at
; default variable values). setof returns a fresh list, so sort's
; destructive behaviour is safe.
; Ref: sklangref.pdf p.381 (setof), p.273 (sort).
(defun dgen_tmRowsFor (timing name @optional vars)
  (sort (setof r timing (and (equal (get r 'signal) name) (not (dgen_tmInitP r))))
        (lambda (a b) (lessp (dgen_tmFieldSec a 'time vars) (dgen_tmFieldSec b 'time vars)))))

; Whole table sorted by time (ties keep table order -> stable enough for
; display; emit never depends on cross-signal order).
(defun dgen_tmSortByTime (timing @optional vars)
  (sort (copy timing)
        (lambda (a b) (lessp (dgen_tmFieldSec a 'time vars) (dgen_tmFieldSec b 'time vars)))))

; Signal names that carry at least one row, in first-seen order.
(defun dgen_tmSignalNames (timing "g")
  (let (out)
    (foreach r timing
      (unless (member (get r 'signal) out)
        (setq out (cons (get r 'signal) out))))
    (reverse out)))

; Accept "D", "D<7:0>" or "D<3>" from the user / import file; rows are
; keyed by base name.
(defun dgen_tmBaseName (s "t")
  (car (parseString (dgen_tmTrim s) "<")))

; Per-instance master switch of a timed dreg: instance / CDF parameter,
; default 1. 0 = timing off -- edges never fire, so the transient also
; sits at the DC values. A plain number, so the user can type 0 / 1 or a
; design variable in q and flip it from Maestro / corners.
(unless (boundp 'dgen_tmEnName) (setq dgen_tmEnName "timing_en"))

; Does the cell carry timing -- this view, or (dgenRun's 'viewTimed) any
; of its timing views? Then every view declares the switch.
(defun dgen_tmCellTimed (spec "g")
  (or (and (dgen_tmTimedPairs spec) t) (get spec 'viewTimed)))

; Internal Verilog-A variable names for a timed item.
(defun dgen_tmVarLvl  (item "g") (sprintf nil "lvl_%s"  (get item 'name)))
(defun dgen_tmVarEdge (item "g") (sprintf nil "edge_%s" (get item 'name)))
(defun dgen_tmVarCnt  (item "g") (sprintf nil "nedge_%s" (get item 'name)))

; Value-cell kind for an item: "bus" / "analog" (nil for 1-bit toggles).
(defun dgen_tmValueKind (item "g")
  (let ((k (dgen_tmKindOf item)))
    (cond ((equal k "scalar") nil) (t k))))

; Expression kind of value / init cells: "bit" (1-bit: 0 or 1), "bus",
; "analog".
(defun dgen_tmCellKind (item "g")
  (or (dgen_tmValueKind item) "bit"))

; Canonical value / init cell: "DC", "" (1-bit toggle -- edge rows only)
; or an expression of the item's cell kind. nil when it doesn't parse.
(defun dgen_tmValueNorm (s item @optional isInit "ggg")
  (let ((v (dgen_tmTrim (or s ""))))
    (cond
      ((dgen_tmDcP v) "DC")
      ((equal v "")
        (and (null isInit) (equal (dgen_tmCellKind item) "bit") ""))
      (t (dgen_tmExprNorm v (dgen_tmCellKind item))))))

; Range / reserved-name problem of a canonical value or init cell, or nil.
(defun dgen_tmValueRangeErr (canon item "gg")
  (let (ck rv vv)
    (setq ck (dgen_tmCellKind item))
    (cond
      ((member canon (list "" "DC")) nil)
      ((setq rv (dgen_tmReservedVar canon)) (dgen_tmReservedMsg rv))
      ((dgen_tmHasVars canon) nil)
      ((and (equal ck "bit") (not (member canon (list "0" "1"))))
        (sprintf nil "1-bit value %s must be 0 or 1" canon))
      ((and (equal ck "bus")
            (setq vv (dgen_tmExprVal canon nil))
            (or (lessp vv 0) (greaterp vv (dgen_tmBusMax item))))
        (sprintf nil "bus value %s is outside 0..%d" canon (dgen_tmBusMax item)))
      (t nil))))

; Message for a value / init cell that doesn't parse.
(defun dgen_tmValueSyntaxMsg (s item isInit "ggg")
  (let ((ck (dgen_tmCellKind item)) (txt (or s "")))
    (cond
      ((equal ck "bit")
        (cond
          (isInit (sprintf nil "init '%s' must be 0, 1, a variable or DC" txt))
          (t (sprintf nil "value '%s' must be empty (toggle), 0, 1, a variable or DC" txt))))
      ((equal ck "bus")
        (sprintf nil "%s '%s' must be an integer, a variable, a sum (e.g. 10, BV, BV+1) or DC"
          (cond (isInit "init") (t "bus value")) txt))
      (t
        (sprintf nil "%s '%s' must be a number, a variable, a sum (e.g. 1.8, 900m, VDDH-0.1) or DC"
          (cond (isInit "init") (t "analog value")) txt)))))

; Validate an init row (its value only). nil or a message.
(defun dgen_tmInitError (row item "gg")
  (let ((ve (dgen_tmValueNorm (get row 'value) item t)))
    (cond
      ((null ve) (dgen_tmValueSyntaxMsg (get row 'value) item t))
      (t (dgen_tmValueRangeErr ve item)))))

; ---------------------------------------------------------------------------
; Validation
; ---------------------------------------------------------------------------

; Upper bound for a bus value. The DC path drives bit i from
; ((d >> i) & 1), i.e. bit weights are the ABSOLUTE indices, so the
; widest legal value covers bit max(hi,lo). Capped at 31 bits (Verilog-A
; integer is 32-bit signed).
(defun dgen_tmBusMax (item "g")
  (let ((top (max (get item 'busHi) (get item 'busLo))))
    (cond
      ((geqp top 30) 2147483647)
      (t (sub1 (leftshift 1 (add1 top)))))))

; First reserved name used as a variable in `canon`, or nil.
(defun dgen_tmReservedVar (canon "g")
  (car (setof nm (dgen_tmExprVars canon) (dgen_tmReservedP nm))))

(defun dgen_tmReservedMsg (name "t")
  (sprintf nil "'%s' can't be used as a variable name (reserved) -- pick another name" name))

; Validate one row against its emit item. Returns nil when OK, else a
; one-line message (no row prefix -- callers add "EN @ 5n: ").
; Cells with variables are only checked for syntax + reserved names: their
; real values come from ADE / Maestro at simulation time, so range checks
; (time >= 0, edge > 0, bus range) apply to plain-literal cells only.
; `vars` (table values) is accepted for call-compatibility but unused.
; Ref: sklangref.pdf p.249 (leftshift), round.
(defun dgen_tmRowError (row item @optional vars)
  (let (te ee ve rv tv ev)
    (cond
      ((dgen_tmInitP row) (dgen_tmInitError row item))
      (t
        (setq te (dgen_tmExprNorm (get row 'time) "time"))
        (setq ee (dgen_tmExprNorm (get row 'edge) "time"))
        (setq ve (dgen_tmValueNorm (get row 'value) item))
        (cond
          ((null te)
            (sprintf nil "time '%s' is not a time or expression (examples: 5n, T_1, T_1+70n)"
              (or (get row 'time) "")))
          ((setq rv (dgen_tmReservedVar te)) (dgen_tmReservedMsg rv))
          ((and (null (dgen_tmHasVars te))
                (lessp (setq tv (dgen_tmExprVal te nil)) 0.0))
            (sprintf nil "time %s is negative" te))
          ((null ee)
            (sprintf nil "edge '%s' is not a time or expression (examples: 50p, TR, TR+10p)"
              (or (get row 'edge) "")))
          ((setq rv (dgen_tmReservedVar ee)) (dgen_tmReservedMsg rv))
          ((and (null (dgen_tmHasVars ee))
                (leqp (setq ev (dgen_tmExprVal ee nil)) 0.0))
            "edge time must be > 0")
          ((null ve) (dgen_tmValueSyntaxMsg (get row 'value) item nil))
          (t (dgen_tmValueRangeErr ve item)))))))

; Copy of `row` with canonical time/edge/value expressions (value forced
; to "" for 1-bit toggles). Assumes the row validated.
(defun dgen_tmNormRow (row item "gg")
  (cond
    ((dgen_tmInitP row)
      (dgen_tmRow (get row 'signal) "init" "" (dgen_tmValueNorm (get row 'value) item t)))
    (t
      (dgen_tmRow
        (get row 'signal)
        (dgen_tmExprNorm (get row 'time) "time")
        (dgen_tmExprNorm (get row 'edge) "time")
        (dgen_tmValueNorm (get row 'value) item)))))

; Variable names referenced by a row's cells.
(defun dgen_tmRowVarNames (row item "gg")
  (let (out v)
    (unless (dgen_tmInitP row)
      (setq out (append (dgen_tmExprVars (dgen_tmExprNorm (get row 'time) "time"))
                        (dgen_tmExprVars (dgen_tmExprNorm (get row 'edge) "time")))))
    (setq v (dgen_tmValueNorm (get row 'value) item (dgen_tmInitP row)))
    (unless (member v (list nil "" "DC"))
      (setq out (append out (dgen_tmExprVars v))))
    out))

; Validate a whole spec's 'timing (+ 'timingVars table values) against its
; emit list. Returns (errorString warningList):
;   errorString -- first hard error (cell that doesn't parse, reserved
;                  variable name, literal out of range, two LITERAL edges
;                  of one signal at the same time, bad table value, name
;                  clash) or nil. Generation must not proceed.
;   warningList -- strings: rows for signals that are not enabled/present
;                  (skipped at emit) and literal ramps still running when
;                  the next literal edge starts.
; Variables never need a table value: unset ones become design variables
; all the same (.va fallback 0). Edges whose times involve variables are
; not compared -- their order is only known at simulation time.
(defun dgen_validateTiming (spec "g")
  (let (items timing vars err warns names item rows prev tv pv pe portNames
        lit prevLit)
    (setq items  (dgen_specEmitList spec))
    (setq timing (get spec 'timing))
    (setq vars   (get spec 'timingVars))
    (setq names  (dgen_tmSignalNames timing))
    (setq portNames (mapcar (lambda (it) (get it 'name)) items))
    (setq err (dgen_tmVarsError vars))
    (when (and (null err) (dgen_tmEdgeRows timing) (member dgen_tmEnName portNames))
      (setq err (sprintf nil "A port named %s already exists -- it is the timing on/off switch; rename the port before adding timing" dgen_tmEnName)))
    (foreach nm names
      (setq item (dgen_tmFindItem items nm))
      (cond
        (err nil)
        ((null item)
          (setq warns (cons
            (sprintf nil "%s: not an enabled signal -- its %d timing row(s) are ignored"
              nm (length (setof r timing (and (equal (get r 'signal) nm) (not (dgen_tmInitP r))))))
            warns)))
        (t
          (setq rows (dgen_tmRowsFor timing nm vars))
          (foreach r (setof x timing (and (dgen_tmInitP x) (equal (get x 'signal) nm)))
            (cond
              (err nil)
              ((not (eq r (dgen_tmInitRow timing nm)))
                (setq err (sprintf nil "%s: more than one init line" nm)))
              ((dgen_tmInitError r item)
                (setq err (sprintf nil "%s init: %s" nm (dgen_tmInitError r item))))
              ((null rows)
                (setq warns (cons (sprintf nil "%s: init value but no edges -- the signal stays DC" nm)
                                  warns)))))
          (foreach r rows
            (unless err
              (let ((m (dgen_tmRowError r item vars)))
                (when m
                  (setq err (sprintf nil "%s @ %s: %s" nm (or (get r 'time) "?") m))))))
          ; Internal lvl_/edge_/nedge_ variables must not shadow a port.
          (unless err
            (when (or (member (dgen_tmVarLvl item) portNames)
                      (member (dgen_tmVarEdge item) portNames)
                      (member (dgen_tmVarCnt item) portNames))
              (setq err (sprintf nil
                "%s: a port named %s, %s or %s already exists; rename it before adding timing"
                nm (dgen_tmVarLvl item) (dgen_tmVarEdge item) (dgen_tmVarCnt item)))))
          ; Consecutive edges whose time AND edge are plain literals: same
          ; start time -> error (a typo); ramp still running -> warning.
          (unless err
            (setq prev nil)
            (setq prevLit nil)
            (foreach r rows
              (setq lit (and (null (dgen_tmHasVars (dgen_tmExprNorm (get r 'time) "time")))
                             (null (dgen_tmHasVars (dgen_tmExprNorm (get r 'edge) "time")))))
              (when (and prev prevLit lit (null err))
                (setq tv (dgen_tmFieldSec r 'time))
                (setq pv (dgen_tmFieldSec prev 'time))
                (setq pe (dgen_tmFieldSec prev 'edge))
                (cond
                  ((lessp (abs (difference tv pv)) 1e-18)
                    (setq err (sprintf nil "%s: two edges at the same time %s"
                      nm (get r 'time))))
                  ((greaterp (plus pv pe) (plus tv 1e-18))
                    (setq warns (cons
                      (sprintf nil "%s: edge at %s (%s) is still ramping when the next edge starts at %s"
                        nm (get prev 'time) (get prev 'edge) (get r 'time))
                      warns)))))
              (setq prev r)
              (setq prevLit lit))))))
    (list err (reverse warns))))

; ---------------------------------------------------------------------------
; Display helpers (table "After" column, per-signal summaries)
; ---------------------------------------------------------------------------

; Initial level as the user should read it: the CDF default that will be
; on a fresh instance. Literal mode -> the number ("1" / "0" for 1-bit,
; since the .va tests d != 0); variable modes -> the design-variable name
; (EN, d_EN, ...); empty mode -> "init" (filled per instance).
; dgen_resolveDefValue / dgen_emitDefaultStr live in dgenCDF.il /
; dgenStore.il (runtime calls; load order doesn't matter).
(defun dgen_tmInitDisplay (spec item "gg")
  (let (mode lit res)
    (setq mode (or (get spec 'defaultMode) "literal"))
    (setq lit  (dgen_emitDefaultStr item))
    (setq res  (dgen_resolveDefValue mode (get spec 'defaultPattern)
                 (dgen_emitParamName item) (get item 'name) nil lit))
    (cond
      ((or (null res) (equal res "")) "init")
      ((and (equal (dgen_tmKindOf item) "scalar") (pcreMatchp "^-?[0-9]+$" res))
        (cond ((zerop (atoi res)) "0") (t "1")))
      (t res))))

; Display text of a canonical value / init cell: "DC" -> dcStr (the DC
; value as the user reads it, see dgen_tmInitDisplay); expressions with
; variables keep only the expression (values are shown elsewhere).
(defun dgen_tmLevelText (canon item dcStr vars "gggg")
  (cond
    ((or (null canon) (equal canon "DC")) dcStr)
    ((dgen_tmHasVars canon) canon)
    (t (dgen_tmExprDisplay canon vars (dgen_tmCellKind item)))))

; 1-bit toggle of a level text: 0 <-> 1, X <-> !X.
(defun dgen_tmToggleText (s "t")
  (cond
    ((equal s "0") "1")
    ((equal s "1") "0")
    ((pcreMatchp "^!" s) (substring s 2 (sub1 (strlen s))))
    (t (strcat "!" s))))

; Transient start level text of a signal: its init cell, else the DC value.
(defun dgen_tmStartText (item initCell dcStr vars "gggg")
  (dgen_tmLevelText (and initCell (dgen_tmValueNorm initCell item t)) item dcStr vars))

; Level AFTER each row of `rows` (sorted edge rows), as display strings,
; starting from `startText` (dgen_tmStartText). 1-bit: an empty value
; toggles; 0 / 1 / variable / DC set the level. Bus / analog: the row's
; value. dcStr renders DC.
(defun dgen_tmAfterList (item rows startText @optional dcStr vars)
  (let (out cur v)
    (setq cur startText)
    (foreach r rows
      (setq v (dgen_tmValueNorm (get r 'value) item))
      (setq cur
        (cond
          ((equal v "") (dgen_tmToggleText cur))
          ((null v) (or (get r 'value) ""))
          (t (dgen_tmLevelText v item dcStr vars))))
      (setq out (cons cur out)))
    (reverse out)))

; One-line summary of a signal's rows for the main-form row column.
(defun dgen_tmSummary (rows "l")
  (let ((n (length rows)))
    (cond
      ((zerop n) "DC")
      ((equal n 1)
        (sprintf nil "1 edge @%s" (get (car rows) 'time)))
      (t
        (sprintf nil "%d edges %s..%s" n
          (get (car rows) 'time) (get (car (last rows)) 'time))))))

; Order-insensitive comparison of two timing tables, after normalization
; ("5ns" == "5n", " T1 + 70n " == "T1+70n"). Used to decide whether
; regenerating an existing dreg changes its timing (-> overwrite confirm).
; Ref: sklangref.pdf p.273 (sort), alphalessp.
(defun dgen_tmRowKey (r "g")
  (sprintf nil "%s|%s|%s|%s"
    (or (get r 'signal) "")
    (or (dgen_tmExprNorm (get r 'time) "time") (get r 'time) "")
    (or (dgen_tmExprNorm (get r 'edge) "time") (get r 'edge) "")
    ; no lower-casing: variable names are case-sensitive on the Spectre side
    (dgen_tmTrim (or (get r 'value) ""))))

(defun dgen_tmTimingEqual (a b "gg")
  (equal (sort (mapcar 'dgen_tmRowKey a) 'alphalessp)
         (sort (mapcar 'dgen_tmRowKey b) 'alphalessp)))

; Unique variable names used anywhere in a timing table (all cells), in
; first-seen order. 1-bit rows carry "" values, so scanning every value
; cell regardless of kind is safe.
(defun dgen_tmTimingVarNames (timing "g")
  (let (out c)
    (foreach r timing
      (foreach cell (cond ((dgen_tmInitP r) (list (get r 'value)))
                          (t (list (get r 'time) (get r 'edge) (get r 'value))))
        (setq c (and (stringp cell) (not (dgen_tmDcP cell)) (dgen_tmExprTokens cell)))
        (foreach tk c
          (when (and (dgen_tmIdentP (cadr tk)) (not (member (cadr tk) out)))
            (setq out (cons (cadr tk) out))))))
    (reverse out)))

; Unique variable names used in TIME cells (the ones that decide the
; By-time order), first-seen order.
(defun dgen_tmTimeVarNames (timing "g")
  (let (out)
    (foreach r (dgen_tmEdgeRows timing)
      (foreach nm (dgen_tmExprVars (dgen_tmExprNorm (get r 'time) "time"))
        (unless (member nm out) (setq out (cons nm out)))))
    (reverse out)))

; Whole-table summary for the [Timing Table...] row.
(defun dgen_tmTableSummary (timing @optional vars)
  (let ((n (length (dgen_tmEdgeRows timing)))
        (s (length (dgen_tmSignalNames (dgen_tmEdgeRows timing))))
        (nv (length (dgen_tmTimingVarNames timing))) out)
    (setq out
      (cond
        ((zerop n) "No timing -- every signal is DC")
        (t (sprintf nil "%d edge%s on %d signal%s"
             n (cond ((equal n 1) "") (t "s"))
             s (cond ((equal s 1) "") (t "s"))))))
    (cond
      ((zerop nv) out)
      (t (sprintf nil "%s, %d variable%s" out nv (cond ((equal nv 1) "") (t "s")))))))

; ---------------------------------------------------------------------------
; Verilog-A emission
; ---------------------------------------------------------------------------

; Module-level variable declarations for one timed item.
(defun dgen_tmEmitDecls (item "g")
  (sprintf nil "    %s %s;\n    real    %s;\n    integer %s;\n"
    (cond ((equal (dgen_tmKindOf item) "analog") "real   ") (t "integer"))
    (dgen_tmVarLvl item) (dgen_tmVarEdge item) (dgen_tmVarCnt item)))

; timer() argument for a canonical time expression:
;   variables -> max(<expr>, 1f) (a swept 0 / negative still ramps)
;   literal 0 -> 1f (timer(0) is absorbed into the initial OP, see header)
;   else      -> the literal expression
(defun dgen_tmTimerLit (canon "t")
  (cond
    ((dgen_tmHasVars canon) (sprintf nil "max(%s, 1f)" (dgen_tmExprVA canon)))
    ((leqp (or (dgen_tmExprVal canon nil) 0.0) 0.0) "1f")
    (t (dgen_tmExprVA canon))))

; Edge (ramp) expression: variables clamped to 1f like times.
(defun dgen_tmEdgeLit (canon "t")
  (cond
    ((dgen_tmHasVars canon) (sprintf nil "max(%s, 1f)" (dgen_tmExprVA canon)))
    (t (dgen_tmExprVA canon))))

; Analog-block lines for one timed item. `rows` are normalized + sorted.
; Verilog-A expression of a canonical value / init cell for item: "DC" ->
; the DC parameter; 1-bit -> 0 / 1 or ((expr) != 0); bus / analog -> the
; expression with variables as tv_<NAME>.
(defun dgen_tmLevelVA (canon item "tg")
  (let ((pn (dgen_emitParamName item)) (k (dgen_tmKindOf item)))
    (cond
      ((equal canon "DC")
        (cond ((equal k "scalar") (sprintf nil "(%s != 0)" pn)) (t pn)))
      ((and (equal k "scalar") (member canon (list "0" "1"))) canon)
      ((equal k "scalar") (sprintf nil "((%s) != 0)" (dgen_tmExprVA canon)))
      (t (dgen_tmExprVA canon)))))

; Level before the first edge: DC analyses use the DC parameter, the
; transient (analysis("tran"), true from its t=0 operating point on)
; starts at `init` -- unless init is "DC" or the instance switch
; timing_en is 0 (then no timer acts either: the DC value throughout). Re-derived on every evaluation
; while no edge has fired (nedge_X == 0), not latched at initial_step: a
; DC sweep inside one Spectre run (dc param=...) never re-runs initial_step
; (verified 2026-10-07). Timers only fire in transient.
(defun dgen_tmEmitAnalog (item rows @optional (init "DC") "glt")
  (let (nm lv ev cv k out hi lo i step done dcExpr)
    (setq nm (get item 'name))
    (setq lv (dgen_tmVarLvl item))
    (setq ev (dgen_tmVarEdge item))
    (setq cv (dgen_tmVarCnt item))
    (setq k  (dgen_tmKindOf item))
    (setq dcExpr (dgen_tmLevelVA "DC" item))
    (setq out (sprintf nil "        // %s: %d timed edge%s (dreg_gen timing table)\n"
                nm (length rows) (cond ((equal (length rows) 1) "") (t "s"))))
    (setq out (strcat out
      (sprintf nil "        @(initial_step) begin %s = 0; %s = %s; end\n"
        cv ev (dgen_tmEdgeLit (get (car rows) 'edge)))
      (cond
        ((equal init "DC")
          (sprintf nil "        if (%s == 0) %s = %s;\n" cv lv dcExpr))
        (t
          (sprintf nil "        if (%s == 0) %s = (analysis(\"tran\") && %s != 0) ? %s : %s;\n"
            cv lv dgen_tmEnName (dgen_tmLevelVA init item) dcExpr)))))
    (foreach r rows
      (setq out (strcat out
        (sprintf nil "        @(timer(%s)) if (%s != 0) begin %s = %s; %s = %s; %s = %s + 1; end\n"
          (dgen_tmTimerLit (get r 'time))
          dgen_tmEnName
          lv
          (cond
            ((equal (get r 'value) "") (strcat "!" lv))
            (t (dgen_tmLevelVA (get r 'value) item)))
          ev (dgen_tmEdgeLit (get r 'edge))
          cv cv))))
    (cond
      ((equal k "analog")
        (setq out (strcat out
          (sprintf nil "        V(%s) <+ transition(%s, 0, %s, %s);\n" nm lv ev ev))))
      ((equal k "bus")
        ; Same hi -> lo walk as the DC path (dgen_emitPinAnalog) so
        ; reverse-numbered buses keep absolute bit weights.
        (setq hi (get item 'busHi))
        (setq lo (get item 'busLo))
        (setq i hi)
        (setq step (cond ((geqp hi lo) -1) (t 1)))
        (setq done nil)
        (while (null done)
          (setq out (strcat out
            (sprintf nil "        V(%s[%d]) <+ transition(((%s >> %d) & 1) * DVDD, 0, %s, %s);\n"
              nm i lv i ev ev)))
          (cond ((equal i lo) (setq done t))
                (t (setq i (plus i step))))))
      (t
        (setq out (strcat out
          (sprintf nil "        V(%s) <+ transition(%s * DVDD, 0, %s, %s);\n" nm lv ev ev)))))
    out))

; Variables referenced by the rows that will actually be emitted, as
; plists (nil 'name N 'default D 'given t|nil) in first-use order. D is the
; table value when the user gave one, else "0" (.va fallback only -- the
; CDF default is always the design variable itself). Each becomes .va +
; CDF parameter tv_<NAME>.
(defun dgen_tmUsedVars (spec "g")
  (let (names vars d own)
    (setq vars (get spec 'timingVars))
    (foreach pr (dgen_tmTimedPairs spec)
      (unless (equal (caddr pr) "DC")
        (foreach nm (dgen_tmExprVars (caddr pr))
          (unless (member nm names) (setq names (cons nm names)))))
      (foreach r (cadr pr)
        (foreach nm (dgen_tmRowVarNames r (car pr))
          (unless (member nm names) (setq names (cons nm names))))))
    (setq own names)
    ; 'viewVars (set by dgenRun): variables of the cell's OTHER timing
    ; views. Every view declares the union, so the shared cell CDF can pass
    ; all tv_ parameters to whichever view is netlisted (Spectre would
    ; otherwise warn "not a valid parameter ... Ignored").
    (foreach nm (get spec 'viewVars)
      (unless (member nm names) (setq names (cons nm names))))
    (mapcar
      (lambda (nm)
        (setq d (dgen_tmVarDefault vars nm))
        (list nil 'name nm 'default (or d "0") 'given (and d t)
              'otherView (not (member nm own))))
      (reverse names))))

; .va parameter declarations for the used variables.
(defun dgen_tmEmitVarDecls (vars "l")
  (let ((out ""))
    (foreach v vars
      (setq out (strcat out
        (sprintf nil "    parameter real    tv_%s = %s;\n"
          (get v 'name) (dgen_tmVarDefaultNorm (get v 'default))))))
    out))

; Header comment listing the timing table (and variables), so a .va
; reader sees the stimulus without opening the GUI. `pairs` is a list of
; (item rows); `vars` the used variables (dgen_tmUsedVars).
(defun dgen_tmEmitHeader (pairs @optional vars)
  (let (out)
    (setq out (strcat
      "// ------------------------------------------------------------------\n"
      "// dreg_gen timing table -- generated; edit it in MyTool > Dreg\n"
      "// Generator > Timing Table and regenerate (manual edits here are\n"
      "// overwritten). Edge = ramp starting at `time`, linear 0->100%.\n"
      "// DC analyses use the DC parameter (d_<pin> / v_<pin>); the\n"
      "// transient starts at the init value (DC = that parameter) and\n"
      "// follows the edges. 1-bit value \"toggle\" inverts the level.\n"
      "// Instance parameter timing_en = 0 turns all timing off (DC values\n"
      "// in transient too); 1 (default) turns it on.\n"))
    (when vars
      (setq out (strcat out
        "// Variables -> instance parameter tv_<NAME>, CDF default = design\n"
        "// variable <NAME> (ADE/Maestro Copy From Cellview picks it up);\n"
        "// the .va default below is only a fallback:\n"))
      (foreach v vars
        (setq out (strcat out
          (sprintf nil "//   %-14s %s\n" (get v 'name)
            (cond
              ((get v 'otherView) "fallback 0 (used by another timing view)")
              ((get v 'given) (sprintf nil "fallback %s" (dgen_tmVarDefaultNorm (get v 'default))))
              (t "fallback 0 (no table value)")))))))
    (setq out (strcat out
      (sprintf nil "//   %-14s %-12s %-10s %s\n" "signal" "time" "edge" "value")))
    (foreach pr pairs
      (setq out (strcat out
        (sprintf nil "//   %-14s %-12s %-10s %s\n"
          (get (car pr) 'name) "init" "-" (or (caddr pr) "DC"))))
      (foreach r (cadr pr)
        (setq out (strcat out
          (sprintf nil "//   %-14s %-12s %-10s %s\n"
            (get (car pr) 'name) (get r 'time) (get r 'edge)
            (cond ((equal (get r 'value) "") "toggle")
                  (t (get r 'value))))))))
    (strcat out
      "// ------------------------------------------------------------------\n")))

; (item normalizedSortedRows init) for every emit item that has at least
; one VALID edge row; init = canonical init value or "DC". Items without
; edge rows are absent (they stay pure DC).
; Rows are normalized here so emitters never see "5ns" / "50 ps".
(defun dgen_tmTimedPairs (spec "g")
  (let (items timing vars out rows init)
    (setq items  (dgen_specEmitList spec))
    (setq timing (get spec 'timing))
    (setq vars   (get spec 'timingVars))
    (foreach it items
      (setq rows (setof r (dgen_tmRowsFor timing (get it 'name) vars)
                   (null (dgen_tmRowError r it vars))))
      (setq init (dgen_tmInitRow timing (get it 'name)))
      (when rows
        (setq out (cons
          (list it (mapcar (lambda (r) (dgen_tmNormRow r it)) rows)
                ; transient start value; "DC" when absent or invalid
                (cond
                  ((and init (null (dgen_tmInitError init it)))
                    (dgen_tmValueNorm (get init 'value) it t))
                  (t "DC")))
          out))))
    (reverse out)))

; ---------------------------------------------------------------------------
; Text import / export (same columns as the .va header)
; ---------------------------------------------------------------------------
;
;   # comment
;   T0 = 5n                      <- variable (NAME = default)
;   EN       init    -       0    <- transient start value (or DC)
;   EN       T0      50p
;   EN       T0+45n  100p
;   N_ctrl   30n     50p   10
;   VDD      0       10u   VDDH
; Row columns split on blanks, tabs or commas -- so an expression must not
; contain blanks in a file ("T0+45n", not "T0 + 45n"). Value may be
; omitted, "-" or "toggle" for 1-bit signals. Signal may carry a bus
; suffix (D<7:0>).

; text -> (rows errors vars). errors is a list of "line N: ..." strings
; for unparseable lines; literal checks happen later in
; dgen_validateTiming against the actual signal kinds.
; Ref: sklangref.pdf p.165 (parseString).
(defun dgen_tmFromText (text "t")
  (let (rows errs vars lineNo cols ln val vres)
    (setq lineNo 0)
    ; 3rd arg t keeps empty lines as "" so lineNo matches the file.
    (foreach line (parseString text "\n" t)
      (setq lineNo (add1 lineNo))
      (setq ln (dgen_tmTrim line))
      (cond
        ((or (equal ln "") (equal (substring ln 1 1) "#")) nil)
        ((index ln "=")
          (setq vres (dgen_tmVarsFromText ln))
          (cond
            ((car vres) (setq vars (append vars (car vres))))
            (t (setq errs (cons (sprintf nil "line %d: expected 'NAME = default', got '%s'" lineNo ln) errs)))))
        (t
          (setq cols (parseString ln " \t,"))
          (cond
            ((or (lessp (length cols) 3) (greaterp (length cols) 4))
              (setq errs (cons
                (sprintf nil "line %d: expected 'signal time edge [value]', got '%s'" lineNo ln)
                errs)))
            (t
              (setq val (or (nth 3 cols) ""))
              (when (member (lowerCase val) (list "-" "toggle")) (setq val ""))
              (setq rows (cons
                (cond
                  ((equal (lowerCase (nth 1 cols)) "init")
                    (dgen_tmRow (dgen_tmBaseName (nth 0 cols)) "init" "" val))
                  (t (dgen_tmRow (dgen_tmBaseName (nth 0 cols)) (nth 1 cols) (nth 2 cols) val)))
                rows)))))))
    (list (reverse rows) (reverse errs) vars)))

(defun dgen_tmToText (timing @optional vars)
  (let (out)
    (setq out (strcat
      "# dreg_gen timing table\n"
      "# NAME = default            -- variable (ADE design variable)\n"
      "# signal  time  edge  [value]   -- time = edge start; 1-bit value:\n"
      "# omitted / - = toggle, or 0 / 1; integer for buses, volts for analog.\n"
      "# signal  init  -  value        -- transient start value (DC = DC value)\n"
      "# DC in a value cell = the signal's DC value (main form / d_<pin>).\n"
      "# Cells may be numbers, variables or sums without blanks (T0+45n).\n"))
    (setq out (strcat out (dgen_tmVarsToText vars)))
    (foreach r timing
      (setq out (strcat out
        (sprintf nil "%-14s %-12s %-10s %s\n"
          (get r 'signal) (get r 'time)
          (cond ((dgen_tmInitP r) "-") (t (get r 'edge)))
          (cond ((equal (or (get r 'value) "") "") "-") (t (get r 'value)))))))
    out))

; Read a timing text file -> (rows errors vars); errors = ("cannot read
; ...") when the file is missing. ~ is NOT expanded (callers pass what the
; file selector returns, which is absolute).
; Ref: sklangref.pdf p.428 (isFile), p.423 (infile), gets.
(defun dgen_tmReadFile (path "t")
  (let (p line text)
    (cond
      ((not (isFile path))
        (list nil (list (sprintf nil "cannot read %s" path)) nil))
      (t
        (setq p (infile path))
        (setq text "")
        (while (gets line p)
          (setq text (strcat text line)))
        (close p)
        (dgen_tmFromText text)))))

(defun dgen_tmWriteFile (path timing @optional vars)
  (let ((p (outfile path "w")))
    (cond
      ((null p) nil)
      (t (fprintf p "%s" (dgen_tmToText timing vars)) (close p) t))))
