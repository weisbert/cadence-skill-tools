; LOdelay.il -- LOdelay(): edge-to-edge delay between two transient signals,
; for Maestro outputs and the Calculator ("Skill User Defined Functions").
;
; Pairing rule (causal): every output edge is paired with the LATEST reference
; edge that lies at least ?tmin before it.  An output edge with no such
; reference edge -- e.g. the window starts between an input edge and the
; output edge it caused -- is dropped, so a clipped window never produces the
; negative "Tdelay - T" that first-out-minus-first-in gives.
;
;   LOdelay(VT("/in")   VT("/out"))                         ; buf, rise->rise, mean
;   LOdelay(VT("/in")   VT("/outb") ?outEdge "falling")     ; inverting stage
;   LOdelay(VT("/clk")  VT("/div2") ?tmin 150p)             ; clk->Q longer than T_clk
;   LOdelay(VT("/rstn") VT("/div2") ?stat "first")          ; one-shot reset
;   LOdelay(VT("/inp")-VT("/inn") VT("/outp")-VT("/outn") ?refThr 0 ?outThr 0)
;
; Keys
;   ?refEdge ?outEdge  "rising" | "falling" | "either"              (default "rising")
;   ?refThr  ?outThr   crossing level; nil = (ymax+ymin)/2 of that waveform,
;                      taken over [from, to] when those are given -- so a
;                      startup spike or settling ramp outside the window
;                      does not drag the mid level away
;   ?tmin              smallest plausible delay; only needed when the delay can
;                      exceed one reference period (default 0)
;   ?from ?to          measure only output edges inside [from, to].  Reference
;                      edges always come from the whole waveform, so the window
;                      may start anywhere without the "Tdelay - T" artefact.
;   ?skip              drop the first N measured pairs (startup), default 0
;   ?stat              "mean" "min" "max" "std" "pp" "first" "last" "count"
;                      or "wave" (delay vs output-edge time)      (default "mean")
;
; Ref: oceanref.pdf p.384 cross(), p.358 clip(), p.589 ymax/ymin;
;      skartistref.pdf p.739-752 drCreateVec/drCreateWaveform, p.757 famIsFamily.

(setq LOdelay_edgeTypes '("rising" "falling" "either"))
(setq LOdelay_stats '("mean" "min" "max" "std" "pp" "first" "last" "count" "wave"))

; Crossing times of w at level thr, ascending.  cross() with x_n = 0 returns
; every occurrence as a plain list (verified on IC618).
(procedure (LOdelay_edges w thr edge)
  (let ((r (cross w thr 0 (stringToSymbol edge))))
    (cond ((listp r) r)
          ((numberp r) (list r))
          (t nil))))

(procedure (LOdelay_midLevel w tFrom tTo)
  (when (or tFrom tTo) (setq w (clip w tFrom tTo)))
  (quotient (plus (ymax w) (ymin w)) 2.0))

; Causal pairing.  refT/outT ascending.  Returns ((tOut delay) ...) ascending.
(procedure (LOdelay_pair refT outT tmin tFrom tTo)
  (let (prev pairs)
    (foreach o outT
      (when (and (or (null tFrom) (geqp o tFrom))
                 (or (null tTo)   (leqp o tTo)))
        (while (and refT (leqp (car refT) (difference o tmin)))
          (setq prev (car refT))
          (setq refT (cdr refT)))
        (when prev
          (setq pairs (cons (list o (difference o prev)) pairs)))))
    (reverse pairs)))

(procedure (LOdelay_sum l) (apply 'plus (cons 0.0 l)))

(procedure (LOdelay_reduce pairs stat)
  (let ((d (mapcar 'cadr pairs)) n mean)
    (setq n (length d))
    (setq mean (quotient (LOdelay_sum d) n))
    (cond
      ((equal stat "mean")  mean)
      ((equal stat "min")   (apply 'min d))
      ((equal stat "max")   (apply 'max d))
      ((equal stat "pp")    (difference (apply 'max d) (apply 'min d)))
      ((equal stat "std")   (sqrt (quotient
                                    (LOdelay_sum (mapcar (lambda (x) (expt (difference x mean) 2)) d))
                                    n)))
      ((equal stat "first") (car d))
      ((equal stat "last")  (car (last d)))
      ((equal stat "count") n)
      ((equal stat "wave")  (drCreateWaveform (drCreateVec 'double (mapcar 'car pairs))
                                              (drCreateVec 'double d))))))

(procedure (LOdelay wRef wOut @key (refEdge "rising") (outEdge "rising")
                                   (refThr nil) (outThr nil) (tmin 0.0)
                                   (from nil) (to nil) (skip 0) (stat "mean"))
  (cond
    ((or (famIsFamily wRef) (famIsFamily wOut))
      (error "LOdelay: got a family of waveforms; evaluate per point (Maestro does this) or pick one sweep value first\n"))
    ((not (and (drIsWaveform wRef) (drIsWaveform wOut)))
      (error "LOdelay: both arguments must be waveforms, got %L and %L (signal not saved?)\n" wRef wOut))
    ((not (and (member refEdge LOdelay_edgeTypes) (member outEdge LOdelay_edgeTypes)))
      (error "LOdelay: ?refEdge/?outEdge must be one of %L\n" LOdelay_edgeTypes))
    ((not (member stat LOdelay_stats))
      (error "LOdelay: ?stat must be one of %L\n" LOdelay_stats)))
  (let (refT outT pairs)
    (setq refT (LOdelay_edges wRef (or refThr (LOdelay_midLevel wRef from to)) refEdge))
    (setq outT (LOdelay_edges wOut (or outThr (LOdelay_midLevel wOut from to)) outEdge))
    (setq pairs (LOdelay_pair refT outT tmin from to))
    (for i 1 skip (setq pairs (cdr pairs)))
    (cond
      ((null refT) (warn "LOdelay: no %s edge on the reference signal\n" refEdge) nil)
      ((null outT) (warn "LOdelay: no %s edge on the output signal\n" outEdge) nil)
      ((null pairs) (warn "LOdelay: no output edge has a reference edge before it\n") nil)
      (t (LOdelay_reduce pairs stat)))))

; ---------------------------------------------------------------------------
; Calculator: Function Panel -> "Skill User Defined Functions" -> LOdelay
; (that exact spelling is the IC618 combo-box label; the manual says "SKILL").
; The form takes both signals as text ("/net" or any expression containing
; "(", e.g. VT("/inp")-VT("/inn")) and writes the finished LOdelay(...) call
; into the Buffer -- the same line you would type into a Maestro output.
; Ref: vivaxlug appendix E; vivaxlskill.pdf p.264-267, p.271;
;      ahiCreate*Field as in vivaxlug appendix E (plain hiCreate*Field fields make
;      calCreateSpecialFunctionsForm fail: "get/getq: second arg must be a symbol");
;      skuiref.pdf p.536 hiCreateCyclicField, p.650 hiCreateStringField (same keys),
;      p.700 hiFormDone (unmapAfterCB=t => callback must set status t).
; ---------------------------------------------------------------------------

(procedure (LOdelay_formInit)
  (let ((y -30) fields)
    (foreach spec
      (list
        (ahiCreateStringField ?name 'refNet ?prompt "Ref signal"  ?value "/in")
        (ahiCreateStringField ?name 'outNet ?prompt "Out signal"  ?value "/out")
        (ahiCreateCyclicField ?name 'refEdge ?prompt "Ref edge"   ?choices LOdelay_edgeTypes)
        (ahiCreateCyclicField ?name 'outEdge ?prompt "Out edge"   ?choices LOdelay_edgeTypes)
        (ahiCreateStringField ?name 'refThr ?prompt "Ref threshold (blank=mid)" ?value "")
        (ahiCreateStringField ?name 'outThr ?prompt "Out threshold (blank=mid)" ?value "")
        (ahiCreateStringField ?name 'tmin   ?prompt "tmin (blank=0)"   ?value "")
        (ahiCreateStringField ?name 'from   ?prompt "from (blank=start)" ?value "")
        (ahiCreateStringField ?name 'to     ?prompt "to (blank=end)"   ?value "")
        (ahiCreateStringField ?name 'skip   ?prompt "skip first N"     ?value "")
        (ahiCreateCyclicField ?name 'stat   ?prompt "stat"         ?choices LOdelay_stats))
      (setq y (plus y 30))
      (setq fields (cons (list spec 5:y 420:25 170) fields)))
    (calCreateSpecialFunctionsForm 'LOdelayForm (reverse fields))))

; "/net" -> VT("/net"); text containing "(" is already an expression.
(procedure (LOdelay_sigExpr s)
  (if (index s "(") s (sprintf nil "VT(\"%s\")" (car (parseString s)))))

(procedure (LOdelay_blankp s) (null (parseString s)))

; The LOdelay(...) call text for the current form values (only non-default
; keys are written, so the line stays short enough to read in a Maestro table).
(procedure (LOdelay_buildExpr f)
  (let (expr)
    (setq expr (sprintf nil "LOdelay(%s %s"
                        (LOdelay_sigExpr f->refNet->value) (LOdelay_sigExpr f->outNet->value)))
    (foreach k '(refEdge outEdge)
      (unless (equal (get f k)->value "rising")
        (setq expr (sprintf nil "%s ?%s \"%s\"" expr k (get f k)->value))))
    (foreach k '(refThr outThr tmin from to skip)
      (unless (LOdelay_blankp (get f k)->value)
        (setq expr (sprintf nil "%s ?%s %s" expr k (car (parseString (get f k)->value))))))
    (unless (equal f->stat->value "mean")
      (setq expr (sprintf nil "%s ?stat \"%s\"" expr f->stat->value)))
    (strcat expr ")")))

; calCreateSpecialFunctionsForm does not bind 'LOdelayForm to the form (on
; IC618 the handle lives in an internal _ahiiUniqueSymbol...LOdelayForm<n>).
; When OK is clicked the form is the current one; the name lookup is the
; fallback for driving it from a script.
(procedure (LOdelay_form)
  (let ((f (hiGetCurrentForm)))
    (if (and f (car (errset f->refNet)))
      f
      (car (setof x (mapcar (lambda (s) (and (boundp s) (symeval s)))
                            (listVariables "LOdelayForm"))
                  (and x (car (errset x->refNet))))))))

(procedure (LOdelay_formCB)
  (let ((f (LOdelay_form)))
    (if (or (LOdelay_blankp f->refNet->value) (LOdelay_blankp f->outNet->value))
      (warn "LOdelay: fill in both Ref signal and Out signal\n")
      (progn
        (calSetBuffer (LOdelay_buildExpr f))
        (hiSetCallbackStatus f t)))))

(procedure (LOdelay_specialCB)
  (calCreateSpecialFunction
    ?formSym      'LOdelayForm
    ?formInitProc 'LOdelay_formInit
    ?formTitle    "LOdelay -- edge-to-edge delay"
    ?formCallback "LOdelay_formCB()"))

(when (isCallable 'calRegisterSpecialFunction)
  (calRegisterSpecialFunction (list "LOdelay" 'LOdelay_specialCB)))
