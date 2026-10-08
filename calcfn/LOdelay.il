; LOdelay.il -- LOdelay(): edge-to-edge delay between two transient signals,
; for Maestro outputs and the Calculator (Function Panel template: LOdelay_ui.ocn).
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
