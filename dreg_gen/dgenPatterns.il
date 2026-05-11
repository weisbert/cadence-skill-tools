; dgenPatterns.il -- pin classification engine for dreg_gen.
;
; Classifies each DUT pin into one of three categories so the GUI can:
;   1. label rows visibly (buttonText prefix [PWR] / [DREG]),
;   2. drive one-click mode buttons (All / None / Only DREG / Auto Suggest),
;   3. let users edit the keyword dictionary via a secondary form.
;
; Categories (returned as symbols):
;   'power -- supply/ground rail (don't auto-check)
;   'dreg  -- digital control input (auto-check)
;   'other -- everything else; falls back to direction-based default
;
; Dictionary file: ~/.skill_tools/dreg_gen.patterns (parallel to dreg_gen.last).
; Format is a SKILL plist that round-trips via %L + lineread (same pattern as
; dgenSaveLastState):
;
;   (nil 'schemaVersion 1
;        'power ("VDD" "VSS" ...)
;        'dreg  ("EN" "RST" ...))
;
; Matching: case-insensitive PCRE with prefix word-boundary -- `\bKEYWORD`.
; "VDD" matches VDD / VDDA / VDD_core / core_VDD ; does NOT match XVDD or
; myVDD (no word boundary before V). Each keyword is escaped before being
; injected into the pattern so user-typed metachars can't break compilation.
;
; Ref: sklangref.pdf p.186 (pcreMatchp), p.450 (outfile), p.437 (lineread).

; ---------------------------------------------------------------------------
; Built-in defaults
; ---------------------------------------------------------------------------
;
; Conservative defaults: VREF/VBG/VBIAS/IBIAS are intentionally NOT in the
; power list because they're often DC-swept analog inputs in characterization
; testbenches, not true supplies. User can add them via the Edit Patterns
; form if their flow treats them as untouchable.

(defun dgenPatternsDefaultPower ()
  (list
    "VDD" "VDDA" "VDDD" "VDDH" "VDDL" "VDDIO"
    "VCC" "VCCA" "VCCD" "AVDD" "DVDD" "VPP" "VPWR"
    "VSS" "VSSA" "VSSD" "GND" "AGND" "DGND" "PGND"
    "VSUB" "VBB" "VNW" "VPW" "VBP" "VBN"))

(defun dgenPatternsDefaultDreg ()
  (list
    "EN" "ENB" "ENABLE" "DIS" "PD" "PDB" "PWRDN" "SLEEP" "STBY"
    "RST" "RSTN" "RESET" "RESETN" "NRST"
    "CTRL" "CTL" "CFG" "SEL" "MODE" "TRIM"
    "CLK" "CLKEN"
    "TEST" "TM" "TMODE" "SCAN" "SE" "SI" "SO"))

(defun dgenPatternsDefault ()
  (list nil
    'schemaVersion 1
    'power (dgenPatternsDefaultPower)
    'dreg  (dgenPatternsDefaultDreg)))

; ---------------------------------------------------------------------------
; File I/O
; ---------------------------------------------------------------------------
;
; Reuses the same ~/.skill_tools/ directory as dreg_gen.last; ensures it
; exists via dgen_ensureLastDir (defined in dgenStore.il, loaded before
; this module per dreg_gen.il ordering).

(defun dgenPat_filePath ()
  (let ((home (getShellEnvVar "HOME")))
    (unless home (error "dgenPat_filePath: $HOME unset"))
    (strcat home "/.skill_tools/dreg_gen.patterns")))

; Save: write plist as a single %L line. Returns t.
; Ref: sklangref.pdf p.450 (outfile), p.409 (fprintf), p.214 (sprintf %L).
(defun dgenPatternsSave (pats "g")
  (dgen_ensureLastDir)
  (let ((p (outfile (dgenPat_filePath) "w")))
    (unless p (error "dgenPatternsSave: cannot write %s" (dgenPat_filePath)))
    (fprintf p "%L\n" pats)
    (close p)
    t))

; Load: read plist via lineread. On any failure (file absent, parse error,
; missing required keys), fall back to defaults silently. A printf warning
; surfaces a corrupt file without making the GUI un-openable.
; Ref: sklangref.pdf p.428 (isFile), p.423 (infile), p.437 (lineread).
(defun dgenPatternsLoad ()
  (let ((path (dgenPat_filePath)) p result loaded power dreg)
    (cond
      ((null (isFile path))
        (dgenPatternsDefault))
      (t
        (setq p (infile path))
        (cond
          ((null p)
            (printf "[dreg-gen] cannot read %s; using default patterns\n" path)
            (dgenPatternsDefault))
          (t
            (setq result (errset (lineread p) t))
            (close p)
            (setq loaded (and result (listp result) (car result) (caar result)))
            ; lineread returns a list-of-forms; we want the first form. errset
            ; wraps that in another list on success: ((plist)). So caar.
            (cond
              ((null loaded)
                (printf "[dreg-gen] %s did not parse; using default patterns\n" path)
                (dgenPatternsDefault))
              (t
                (setq power (get loaded 'power))
                (setq dreg  (get loaded 'dreg))
                (cond
                  ((or (null (listp power)) (null (listp dreg)))
                    (printf "[dreg-gen] %s missing 'power or 'dreg list; using defaults\n" path)
                    (dgenPatternsDefault))
                  (t loaded))))))))))

; ---------------------------------------------------------------------------
; Matching
; ---------------------------------------------------------------------------

; Escape PCRE metacharacters in a literal keyword. Defense in depth -- in
; practice keywords are alphanumeric + underscore (this no-ops) but a
; user-typed entry like "VDD(core)" must not break the pattern.
;
; Metachars escaped: \ ^ $ . | ? * + ( ) [ ] { }
(defun dgenPat_escape (kw "t")
  (let ((out "") (n (strlen kw)) (i 0) c)
    (while (lessp i n)
      (setq c (substring kw (plus i 1) 1))
      (when (member c '("\\" "^" "$" "." "|" "?" "*" "+" "(" ")" "[" "]" "{" "}"))
        (setq out (strcat out "\\")))
      (setq out (strcat out c))
      (setq i (add1 i)))
    out))

; Return t if `name` matches any keyword in kwList (token-boundary-anchored,
; case-insensitive). Empty / blank keywords are skipped so a stray empty
; line in the dictionary doesn't match every name.
;
; Boundary definition: PCRE's `\b` treats `_` as a word character, so
; `\bVDD` would NOT match `core_VDD` even though semantically `_` is the
; obvious token separator in pin names. We use `(?:^|[\W_])` instead --
; start of string OR a non-word-or-underscore char before the keyword --
; which catches `_VDD` while still rejecting `myVDD` / `XVDD`.
;
; Ref: sklangref.pdf p.186 (pcreMatchp). (?i) is PCRE's inline case-insensitive
; flag (example on p.187 uses ((?i)rah)).
(defun dgenPatternsMatchKw (name kwList "tl")
  (let ((hit nil))
    (foreach kw kwList
      (when (and (null hit) (stringp kw) (greaterp (strlen kw) 0))
        (let ((pat (sprintf nil "(?i)(?:^|[\\W_])%s" (dgenPat_escape kw))))
          (when (pcreMatchp pat name)
            (setq hit t)))))
    hit))

; Classify a pin descriptor into one of 'power / 'dreg / 'other.
; Pin shape: (nil 'name N 'isBus t/nil 'busHi H 'busLo L 'srcDirection D ...)
; from dgenScanPins. The classifier is pure -- no I/O, no side effects --
; so it's safe to call inside form-build loops and callbacks.
;
; Priority (first match wins, listed in order from dgenPatterns plan):
;   1. direction == "output"            -> 'other  (outputs aren't drivable inputs)
;   2. name matches power keyword       -> 'power
;   3. isBus = t                        -> 'dreg   (multi-bit -> digital bus)
;   4. name matches dreg keyword        -> 'dreg
;   5. direction == "inout" or "inputOutput" -> 'power  (likely a rail)
;   6. otherwise                        -> 'other
;
; Step 1 (output -> other) is intentionally above step 2 so a hypothetical
; output named "vss_mon" doesn't get a [PWR] label slapped on it. In Cadence,
; cv~>direction strings come through as "input" / "output" / "inputOutput"
; (camelCase) per the OpenAccess termAttributes; we tolerate "inout" as a
; synonym in case some flows emit lowercase.
(defun dgenPatternsClassify (pin pats "gg")
  (let ((nm (or (get pin 'name) ""))
        (dir (or (get pin 'srcDirection) "input"))
        (isBus (get pin 'isBus))
        (powerKws (get pats 'power))
        (dregKws  (get pats 'dreg)))
    (cond
      ((equal dir "output") 'other)
      ((dgenPatternsMatchKw nm powerKws) 'power)
      (isBus 'dreg)
      ((dgenPatternsMatchKw nm dregKws) 'dreg)
      ((or (equal dir "inputOutput") (equal dir "inout")) 'power)
      (t 'other))))
