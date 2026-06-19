; nhStore.il -- note-helper config + module state.
;
; v1 keeps styling config in a default plist (no file persistence yet --
; the per-run table TEXT is intentionally transient, like dreg_gen's
; customVars; only durable STYLE preferences would ever be persisted, and
; that is deferred to a later milestone). See REQUIREMENTS.md s.13 item 6.
;
; SKILL note: no let* (use nested let / let+setq); plists are nil-headed
; DPLs read with get (Ref dreg_gen/dgenStore.il convention).

; ---------------------------------------------------------------------------
; Module-global state (idempotent: never clobber on reload).
; ---------------------------------------------------------------------------

; Pending placement state, stashed for the enterPoint done-callback (which
; runs later, after the user clicks). nh_pendingKind selects what the
; callback does: 'shapes -> emit IR directly; 'symbol -> instance a master.
(unless (boundp 'nh_pendingKind)   (setq nh_pendingKind nil))
(unless (boundp 'nh_pendingIR)     (setq nh_pendingIR nil))
(unless (boundp 'nh_pendingCv)     (setq nh_pendingCv nil))
(unless (boundp 'nh_pendingMaster) (setq nh_pendingMaster nil))

; Top-level scratch global for the evalstring form-field write idiom
; (mirrors dgen's nh_tmpFieldVal; see nhGui.il nh_setFieldVal).
(unless (boundp 'nh_tmpVal) (setq nh_tmpVal nil))

; ---------------------------------------------------------------------------
; Default styling config.
;   fontHeight  -- note label height, user units (schCreateNoteLabel default
;                  is 0.0625; 0.125 reads better for a table).
;   charAspect  -- monospace glyph-advance / fontHeight. MEASURED on live
;                  IC6.1.8: the "fixed" font (the only true monospace among
;                  the note fonts) advances 1.435*height per glyph; 1.45 adds
;                  a hair of margin so glyphs never touch the grid lines.
;   paddingRatio-- cell inset as a FRACTION of font height. Keeping it
;                  proportional makes the whole table scale uniformly with
;                  font height (text + columns + rows + gaps all together),
;                  so font height alone is the master "size" knob.
;   gridStyle   -- 'full (box + all rules) | 'hrules (box + horizontal) |
;                  'boxheader (box + header rule only).
;   maxColWidth -- max chars per column before truncating with "~"; 0 = off.
;   headerScale -- header-row font multiplier (no bold available).
; ---------------------------------------------------------------------------

(defun nh_cfgDefault ()
  (list nil
    'fontHeight   0.125
    'charAspect   1.45
    'paddingRatio 0.4
    'gridStyle    'full
    'maxColWidth  0
    'headerScale  1.15))

; nh_cfgGet: value of key from cfg, falling back to nh_cfgDefault. A key
; absent from cfg (get -> nil) takes the default; an explicit value (incl.
; the integer 0 for maxColWidth) is honored.
(defun nh_cfgGet (cfg key)
  (let ((v (and cfg (get cfg key))))
    (if (null v) (get (nh_cfgDefault) key) v)))
