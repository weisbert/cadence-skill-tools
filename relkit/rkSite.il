; rkSite.il -- relkit site configuration + shared utilities (JSON, TSV, paths).
;
; Loaded first by relkit.il. Everything here is pure SKILL: loading relkit
; never needs Python (plan D12).
;
; Site lookup / merge / expansion is the SAME algorithm as py/rk_site.py
; (docs/CONTRACT.md section 1):
;   lookup : $RELKIT_SITE -> <workarea>/.relkit_site.json -> <relkit>/site.json
;            (none -> defaults only + warning; $RELKIT_SITE set but missing -> error)
;   merge  : <relkit>/site_defaults.json deep-merged with the site file
;   expand : "${NAME}" in strings; NAME from {WORKAREA USER RELKIT_DIR} then env;
;            unknown names kept verbatim (+ warning); bare "$NAME" never expanded
;   relstudio_home null -> getShellEnvVar("RELSTUDIO_HOME")  (plan D6)
;
; JSON mapping (reader):  object -> association table (makeTable, default nil;
;   keys are strings), array -> list, string -> string, integer -> fixnum,
;   real -> flonum, true -> t, false -> nil, null -> nil.
; JSON mapping (writer):  table -> object (keys sorted), list -> array,
;   nil -> null, t -> true, rkJsonFalse -> false, rkJsonEmptyArray -> [],
;   string/number as-is, other symbols -> their name, anything else -> "%L".
;   NOTE: a hand-built plist (list nil 'k v) is written as an ARRAY.
;   Python must treat null like [] / {} wherever a list / object is expected.
;
; Public API:
;   rkSiteLoad([t_workarea] [g_force]) -> o_table  ; cached merged+expanded site
;   rkSiteGet(t_dottedKey [g_default]) -> value    ; e.g. "emir.license_policy"
;   rkSitePath()          -> t_path / nil   ; site file used by the last load
;   rkSiteWarnings()      -> l_strings      ; warnings of the last load
;   rkWorkarea()          -> t_dir          ; $RELKIT_WORKAREA or cwd, no trailing /
;   rkUser()              -> t_user
;   rkRelkitDir()         -> t_dir          ; relkit dir WITH trailing /
;   rkRelstudioHome()     -> t_dir / nil    ; site value or Virtuoso's $RELSTUDIO_HOME
;   rkJsonRead(t_path)    -> value          ; error on missing file / bad JSON
;   rkJsonParse(t_text)   -> value
;   rkJsonParseKeepFalse(t_text) / rkJsonReadKeepFalse(t_path) -> value with
;                           JSON false as rkJsonFalse instead of nil
;   rkJsonWrite(g_value t_path) -> t        ; pretty, UTF-8 bytes passed through
;   rkJsonToString(g_value) -> t_json
;   rkMakeObj()           -> o_table        ; empty JSON object
;   rkJsonBool(g_x)       -> t / rkJsonFalse ; explicit boolean for the writer
;   rkJsonFalse, rkJsonEmptyArray            ; writer constants (false, [])
;   rkGet(g_obj t_dottedKey [g_default]) -> value ; tables by key, lists by 0-based index
;   rkPut(o_table t_key g_value) -> g_value
;   rkKeys(o_table)       -> l_sortedStringKeys
;   rkTsvRead(t_path)     -> (l_header l_rows) ; CONTRACT section 5.2
;   rkReadFileText(t_path) -> t_text
;   rkExpandVars(t_string [o_vars]) -> t_string
;   rkMkdirs(t_dir)       -> t / nil
;   rkTimestamp()         -> "YYYYMMDD-HHMMSS" (local time)
;   rkPathJoin(t_a t_b)   -> t_path
;   rkShellQuote(t_s)     -> t_quoted       ; for /bin/sh command lines
;
; SKILL rules followed (eda-test-workarea memory feedback_skill_gotchas):
;   no let*, no prefix arithmetic, no defvar, identifiers [A-Za-z0-9_] only,
;   no setq on table slots (setarray instead), no ~> on hand-built data.
; Ref: sklangref.pdf getchar p.159, intToChar p.144, charToInt, substring p.223,
;      makeTable p.84, buildString, getWorkingDir, getShellEnvVar,
;      createDirHier, getCurrentTime, infile/gets/outfile.

(unless (boundp 'rk_siteCache)    (setq rk_siteCache nil))
(unless (boundp 'rk_sitePathUsed) (setq rk_sitePathUsed nil))
(unless (boundp 'rk_siteWarns)    (setq rk_siteWarns nil))
(setq rkJsonFalse 'rk_false)
(setq rkJsonEmptyArray 'rk_emptyArray)

; ---------------------------------------------------------------------------
; Small string helpers
; ---------------------------------------------------------------------------

; Character code at 1-based index i, or nil past the end.
(defun rk_chr (s i)
  (let ((c (getchar s i)))
    (and c (charToInt c))))

; One-character string from an ASCII code.
(defun rk_chrStr (code)
  (symbolToString (intToChar code)))

; substring that tolerates empty ranges: chars [from, to) 1-based.
(defun rk_sub (s from to)
  (cond
    ((leqp to from) "")
    (t (or (substring s from (difference to from)) ""))))

(defun rk_joinPieces (pieces)
  (if pieces (buildString pieces "") ""))

(defun rk_stripTrailingSlash (p)
  (let ((n (strlen p)))
    (while (and (greaterp n 1) (equal (rk_chr p n) 47))
      (setq p (substring p 1 (sub1 n)))
      (setq n (strlen p)))
    p))

; Quote one argument for /bin/sh: wrap in single quotes; each embedded
; single quote becomes: quote, backslash, quote, quote.
(defun rkShellQuote (s)
  (let ((n (strlen s)) (i 1) (start 1) (pieces (list "'")))
    (while (leqp i n)
      (when (equal (rk_chr s i) 39)
        (setq pieces (cons "'\\''" (cons (rk_sub s start i) pieces)))
        (setq start (add1 i)))
      (setq i (add1 i)))
    (setq pieces (cons "'" (cons (rk_sub s start (add1 n)) pieces)))
    (rk_joinPieces (reverse pieces))))

(defun rkPathJoin (a b)
  (strcat (rk_stripTrailingSlash a) "/" b))

(defun rkRelkitDir ()
  (cond
    ((and (boundp 'relkitDir) (stringp relkitDir)) relkitDir)
    (t (error "rkRelkitDir: relkitDir is not set -- load relkit/relkit.il"))))

(defun rkWorkarea ()
  (let ((w (getShellEnvVar "RELKIT_WORKAREA")))
    (unless (and w (nequal w ""))
      (setq w (getWorkingDir)))
    ; getWorkingDir may return "~/..." -- expand it.
    (when (equal (rk_chr w 1) 126)
      (setq w (simplifyFilename w)))
    (rk_stripTrailingSlash w)))

(defun rkUser ()
  (let ((u (getShellEnvVar "USER")))
    (if (and u (nequal u "")) u (getLogin))))

(defun rkMkdirs (dir)
  (cond
    ((isDir dir) t)
    (t (createDirHier dir) (isDir dir))))

(defun rk_pad2 (n)
  (if (lessp n 10) (sprintf nil "0%d" n) (sprintf nil "%d" n)))

; getCurrentTime() => "Jan 26 18:15:18 1994"
(defun rkTimestamp ()
  (let ((parts (parseString (getCurrentTime) " "))
        (months (list "Jan" "Feb" "Mar" "Apr" "May" "Jun"
                      "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))
        mon day hms year)
    (setq mon (add1 (difference (length months)
                                (length (member (nth 0 parts) months)))))
    (setq day (atoi (nth 1 parts)))
    (setq hms (parseString (nth 2 parts) ":"))
    (setq year (nth 3 parts))
    (sprintf nil "%s%s%s-%s%s%s" year (rk_pad2 mon) (rk_pad2 day)
             (nth 0 hms) (nth 1 hms) (nth 2 hms))))

(defun rkReadFileText (path)
  (let ((p (infile path)) line lines)
    (unless p (error "rkReadFileText: cannot open %s" path))
    (while (gets line p)
      (setq lines (cons line lines)))
    (close p)
    (rk_joinPieces (reverse lines))))

; ---------------------------------------------------------------------------
; JSON reader
; ---------------------------------------------------------------------------

(unless (boundp 'rk_js) (setq rk_js ""))
(unless (boundp 'rk_jp) (setq rk_jp 1))

(defun rkMakeObj ()
  (makeTable "rkjson" nil))

(defun rk_jsErr (msg)
  (error "rkJsonParse: %s at offset %d" msg rk_jp))

(defun rk_jsSkipWs ()
  (let ((c (rk_chr rk_js rk_jp)))
    (while (and c (member c (list 32 9 10 13)))
      (setq rk_jp (add1 rk_jp))
      (setq c (rk_chr rk_js rk_jp)))))

(defun rk_jsLit (word)
  (let ((n (strlen word)))
    (cond
      ((equal (substring rk_js rk_jp n) word)
        (setq rk_jp (plus rk_jp n))
        t)
      (t nil))))

(defun rk_hexToInt (h)
  (let ((v 0) c d (i 1) (n (strlen h)))
    (while (leqp i n)
      (setq c (rk_chr h i))
      (setq d (cond
                ((and (geqp c 48) (leqp c 57)) (difference c 48))
                ((and (geqp c 97) (leqp c 102)) (difference c 87))
                ((and (geqp c 65) (leqp c 70)) (difference c 55))
                (t (rk_jsErr "bad \\u escape"))))
      (setq v (plus (times v 16) d))
      (setq i (add1 i)))
    v))

; Code point -> UTF-8 byte string. Falls back to "?" if the build refuses
; to make a symbol from a byte > 127.
(defun rk_utf8 (cp)
  (let (bytes r)
    (setq bytes
      (cond
        ((lessp cp 128) (list cp))
        ((lessp cp 2048)
          (list (plus 192 (quotient cp 64)) (plus 128 (mod cp 64))))
        (t
          (list (plus 224 (quotient cp 4096))
                (plus 128 (mod (quotient cp 64) 64))
                (plus 128 (mod cp 64))))))
    (setq r (errset (rk_joinPieces (mapcar 'rk_chrStr bytes)) nil))
    (if r (car r) "?")))

(defun rk_jsSimpleEscape (c)
  (cond
    ((equal c 34) "\"")
    ((equal c 92) "\\")
    ((equal c 47) "/")
    ((equal c 98) (rk_chrStr 8))
    ((equal c 102) (rk_chrStr 12))
    ((equal c 110) "\n")
    ((equal c 114) (rk_chrStr 13))
    ((equal c 116) "\t")
    (t (rk_jsErr "bad escape"))))

(defun rk_jsString ()
  (let (pieces start c done)
    (setq rk_jp (add1 rk_jp))            ; skip opening quote
    (setq start rk_jp)
    (while (not done)
      (setq c (rk_chr rk_js rk_jp))
      (cond
        ((null c) (rk_jsErr "unterminated string"))
        ((equal c 34)
          (setq pieces (cons (rk_sub rk_js start rk_jp) pieces))
          (setq rk_jp (add1 rk_jp))
          (setq done t))
        ((equal c 92)
          (setq pieces (cons (rk_sub rk_js start rk_jp) pieces))
          (setq c (rk_chr rk_js (add1 rk_jp)))
          (cond
            ((equal c 117)
              (setq pieces (cons (rk_utf8 (rk_hexToInt (rk_sub rk_js (plus rk_jp 2) (plus rk_jp 6))))
                                 pieces))
              (setq rk_jp (plus rk_jp 6)))
            (t
              (setq pieces (cons (rk_jsSimpleEscape c) pieces))
              (setq rk_jp (plus rk_jp 2))))
          (setq start rk_jp))
        (t (setq rk_jp (add1 rk_jp)))))
    (rk_joinPieces (reverse pieces))))

(defun rk_jsNumber ()
  (let ((start rk_jp) c isFloat txt)
    (setq c (rk_chr rk_js rk_jp))
    (while (and c (or (and (geqp c 48) (leqp c 57)) (member c (list 43 45 46 69 101))))
      (when (member c (list 46 69 101)) (setq isFloat t))
      (setq rk_jp (add1 rk_jp))
      (setq c (rk_chr rk_js rk_jp)))
    (setq txt (rk_sub rk_js start rk_jp))
    (if isFloat (atof txt) (atoi txt))))

(defun rk_jsArray ()
  (let (items done c)
    (setq rk_jp (add1 rk_jp))
    (rk_jsSkipWs)
    (when (equal (rk_chr rk_js rk_jp) 93)
      (setq rk_jp (add1 rk_jp))
      (setq done t))
    (while (not done)
      (setq items (cons (rk_jsValue) items))
      (rk_jsSkipWs)
      (setq c (rk_chr rk_js rk_jp))
      (cond
        ((equal c 44) (setq rk_jp (add1 rk_jp)))
        ((equal c 93) (setq rk_jp (add1 rk_jp)) (setq done t))
        (t (rk_jsErr "expected ',' or ']'"))))
    (reverse items)))

(defun rk_jsObject ()
  (let ((tbl (rkMakeObj)) key val done c)
    (setq rk_jp (add1 rk_jp))
    (rk_jsSkipWs)
    (when (equal (rk_chr rk_js rk_jp) 125)
      (setq rk_jp (add1 rk_jp))
      (setq done t))
    (while (not done)
      (rk_jsSkipWs)
      (unless (equal (rk_chr rk_js rk_jp) 34) (rk_jsErr "expected string key"))
      (setq key (rk_jsString))
      (rk_jsSkipWs)
      (unless (equal (rk_chr rk_js rk_jp) 58) (rk_jsErr "expected ':'"))
      (setq rk_jp (add1 rk_jp))
      (setq val (rk_jsValue))
      (setarray tbl key val)
      (rk_jsSkipWs)
      (setq c (rk_chr rk_js rk_jp))
      (cond
        ((equal c 44) (setq rk_jp (add1 rk_jp)))
        ((equal c 125) (setq rk_jp (add1 rk_jp)) (setq done t))
        (t (rk_jsErr "expected ',' or '}'"))))
    tbl))

(defun rk_jsValue ()
  (let (c)
    (rk_jsSkipWs)
    (setq c (rk_chr rk_js rk_jp))
    (cond
      ((null c) (rk_jsErr "unexpected end of input"))
      ((equal c 123) (rk_jsObject))
      ((equal c 91) (rk_jsArray))
      ((equal c 34) (rk_jsString))
      ((or (equal c 45) (and (geqp c 48) (leqp c 57))) (rk_jsNumber))
      ((rk_jsLit "true") t)
      ((rk_jsLit "false") rk_jsFalseAs)     ; nil unless rkJsonParseKeepFalse
      ((rk_jsLit "null") nil)
      (t (rk_jsErr (sprintf nil "unexpected character code %d" c))))))

(defun rkJsonParse (text)
  (let (v)
    (setq rk_js text)
    (setq rk_jp 1)
    (setq v (rk_jsValue))
    (rk_jsSkipWs)
    (when (rk_chr rk_js rk_jp) (rk_jsErr "trailing characters"))
    (setq rk_js "")
    v))

(defun rkJsonRead (path)
  (unless (isFile path) (error "rkJsonRead: no such file %s" path))
  (rkJsonParse (rkReadFileText path)))

; Like rkJsonParse / rkJsonRead, but JSON false -> rkJsonFalse (so a reader can
; tell pass:false from pass:null). Added by the results agent (CONTRACT log).
(unless (boundp 'rk_jsFalseAs) (setq rk_jsFalseAs nil))
(defun rkJsonParseKeepFalse (text)
  (let (r)
    (setq rk_jsFalseAs rkJsonFalse)
    (setq r (errset (rkJsonParse text) nil))
    (setq rk_jsFalseAs nil)
    ; re-raise with the parser's own message (offset), not a generic one
    (unless r (error "rkJsonParseKeepFalse: %L" (car errset.errset)))
    (car r)))
(defun rkJsonReadKeepFalse (path)
  (unless (isFile path) (error "rkJsonReadKeepFalse: no such file %s" path))
  (rkJsonParseKeepFalse (rkReadFileText path)))

; ---------------------------------------------------------------------------
; JSON writer
; ---------------------------------------------------------------------------

(unless (boundp 'rk_jw) (setq rk_jw nil))

(defun rk_jwEmit (s) (setq rk_jw (cons s rk_jw)))

(defun rk_spaces (n)
  (let ((pieces nil) (i 0))
    (while (lessp i n)
      (setq pieces (cons " " pieces))
      (setq i (add1 i)))
    (rk_joinPieces pieces)))

(defun rk_jsQuote (s)
  (let ((pieces (list "\"")) (n (strlen s)) (i 1) (start 1) c esc)
    (while (leqp i n)
      (setq c (rk_chr s i))
      (setq esc
        (cond
          ((equal c 34) "\\\"")
          ((equal c 92) "\\\\")
          ((equal c 10) "\\n")
          ((equal c 13) "\\r")
          ((equal c 9) "\\t")
          ((or (lessp c 32) (equal c 127)) (sprintf nil "\\u%04x" c))
          (t nil)))
      (when esc
        (setq pieces (cons esc (cons (rk_sub s start i) pieces)))
        (setq start (add1 i)))
      (setq i (add1 i)))
    (setq pieces (cons "\"" (cons (rk_sub s start (add1 n)) pieces)))
    (rk_joinPieces (reverse pieces))))

(defun rk_keyString (k)
  (cond
    ((stringp k) k)
    ((symbolp k) (symbolToString k))
    (t (sprintf nil "%L" k))))

(defun rkKeys (tbl)
  (let (keys)
    (foreach k tbl (setq keys (cons (rk_keyString k) keys)))
    (sort keys 'alphalessp)))

(defun rk_jwObject (tbl ind)
  (let (pairs (pad (rk_spaces (plus ind 2))) (first t))
    (foreach k tbl (setq pairs (cons (list (rk_keyString k) k) pairs)))
    (setq pairs (sort pairs (lambda (a b) (alphalessp (car a) (car b)))))
    (cond
      ((null pairs) (rk_jwEmit "{}"))
      (t
        (rk_jwEmit "{")
        (foreach p pairs
          (rk_jwEmit (if first "\n" ",\n"))
          (setq first nil)
          (rk_jwEmit pad)
          (rk_jwEmit (rk_jsQuote (car p)))
          (rk_jwEmit ": ")
          (rk_jwValue (arrayref tbl (cadr p)) (plus ind 2)))
        (rk_jwEmit "\n")
        (rk_jwEmit (rk_spaces ind))
        (rk_jwEmit "}")))))

(defun rk_jwArray (lst ind)
  (let ((pad (rk_spaces (plus ind 2))) (first t))
    (rk_jwEmit "[")
    (foreach v lst
      (rk_jwEmit (if first "\n" ",\n"))
      (setq first nil)
      (rk_jwEmit pad)
      (rk_jwValue v (plus ind 2)))
    (rk_jwEmit "\n")
    (rk_jwEmit (rk_spaces ind))
    (rk_jwEmit "]")))

(defun rk_jwValue (v ind)
  (cond
    ((null v) (rk_jwEmit "null"))
    ((eq v t) (rk_jwEmit "true"))
    ((eq v 'rk_false) (rk_jwEmit "false"))
    ((eq v 'rk_emptyArray) (rk_jwEmit "[]"))
    ((stringp v) (rk_jwEmit (rk_jsQuote v)))
    ((integerp v) (rk_jwEmit (sprintf nil "%d" v)))
    ((floatp v) (rk_jwEmit (sprintf nil "%.12g" v)))
    ((tablep v) (rk_jwObject v ind))
    ((listp v) (rk_jwArray v ind))
    ((symbolp v) (rk_jwEmit (rk_jsQuote (symbolToString v))))
    (t (rk_jwEmit (rk_jsQuote (sprintf nil "%L" v))))))

(defun rkJsonToString (v)
  (let (s)
    (setq rk_jw nil)
    (rk_jwValue v 0)
    (setq s (rk_joinPieces (reverse rk_jw)))
    (setq rk_jw nil)
    s))

(defun rkJsonWrite (v path)
  (let ((text (rkJsonToString v)) p)
    (setq p (outfile path "w"))
    (unless p (error "rkJsonWrite: cannot write %s" path))
    (fprintf p "%s\n" text)
    (close p)
    t))

; ---------------------------------------------------------------------------
; Generic accessors
; ---------------------------------------------------------------------------

; Explicit JSON boolean for the writer: t -> true, nil -> false (CONTRACT 2.0:
; booleans in ctx.json must never be written as null).
(defun rkJsonBool (x)
  (if x t rkJsonFalse))

(defun rkPut (tbl key val)
  (setarray tbl key val)
  val)

(defun rk_isDigits (s)
  (and (stringp s) (nequal s "") (pcreMatchp "^[0-9]+$" s)))

(defun rkGet (obj path @optional default)
  (let ((cur obj) (ok t))
    (foreach part (parseString path ".")
      (when ok
        (cond
          ((tablep cur) (setq cur (arrayref cur part)))
          ((and (listp cur) (rk_isDigits part)) (setq cur (nth (atoi part) cur)))
          (t (setq ok nil)))))
    (if (and ok (not (null cur))) cur default)))

; ---------------------------------------------------------------------------
; TSV reader (CONTRACT section 5.2): first line header, tab separated.
; ---------------------------------------------------------------------------

(defun rk_chomp (s)
  (let ((n (strlen s)))
    (while (and (greaterp n 0) (member (rk_chr s n) (list 10 13)))
      (setq n (sub1 n)))
    (rk_sub s 1 (add1 n))))

(defun rk_splitTabs (s)
  (let ((n (strlen s)) (i 1) (start 1) cells)
    (while (leqp i n)
      (when (equal (rk_chr s i) 9)
        (setq cells (cons (rk_sub s start i) cells))
        (setq start (add1 i)))
      (setq i (add1 i)))
    (setq cells (cons (rk_sub s start (add1 n)) cells))
    (reverse cells)))

(defun rkTsvRead (path)
  (let ((p (infile path)) line rows)
    (unless p (error "rkTsvRead: cannot open %s" path))
    (while (gets line p)
      (setq rows (cons (rk_splitTabs (rk_chomp line)) rows)))
    (close p)
    (setq rows (reverse rows))
    (list (car rows) (cdr rows))))

; ---------------------------------------------------------------------------
; ${VAR} expansion
; ---------------------------------------------------------------------------

(defun rkExpandVars (str @optional vars)
  (let ((n (strlen str)) (i 1) (start 1) pieces j name val)
    (while (leqp i n)
      (cond
        ((and (equal (rk_chr str i) 36) (equal (rk_chr str (add1 i)) 123))
          (setq j (plus i 2))
          (while (and (leqp j n) (nequal (rk_chr str j) 125))
            (setq j (add1 j)))
          (cond
            ((greaterp j n) (setq i (add1 n)))          ; no closing brace: literal
            (t
              (setq name (rk_sub str (plus i 2) j))
              (setq val nil)
              (when (and vars (tablep vars)) (setq val (arrayref vars name)))
              (unless (and val (nequal val ""))
                (setq val (and (pcreMatchp "^[A-Za-z_][A-Za-z0-9_]*$" name)
                               (getShellEnvVar name))))
              (cond
                ((and val (nequal val ""))
                  (setq pieces (cons val (cons (rk_sub str start i) pieces)))
                  (setq start (add1 j)))
                (t
                  (setq rk_siteWarns
                    (cons (sprintf nil "unknown variable ${%s} left unexpanded" name)
                          rk_siteWarns))))
              (setq i (add1 j)))))
        (t (setq i (add1 i)))))
    (setq pieces (cons (rk_sub str start (add1 n)) pieces))
    (rk_joinPieces (reverse pieces))))

(defun rk_expandTree (v vars)
  (cond
    ((stringp v) (rkExpandVars v vars))
    ((tablep v)
      (let ((out (rkMakeObj)))
        (foreach k v (setarray out k (rk_expandTree (arrayref v k) vars)))
        out))
    ((and v (listp v)) (mapcar (lambda (x) (rk_expandTree x vars)) v))
    (t v)))

; ---------------------------------------------------------------------------
; Deep merge (objects recurse; any other value, nil included, replaces)
; ---------------------------------------------------------------------------

(defun rk_copyTree (v)
  (cond
    ((tablep v)
      (let ((out (rkMakeObj)))
        (foreach k v (setarray out k (rk_copyTree (arrayref v k))))
        out))
    ((and v (listp v)) (mapcar 'rk_copyTree v))
    (t v)))

(defun rk_deepMerge (base over)
  (let ((out (rk_copyTree base)) bv ov)
    (foreach k over
      (setq ov (arrayref over k))
      (setq bv (arrayref out k))
      (cond
        ((and (tablep ov) (tablep bv)) (setarray out k (rk_deepMerge bv ov)))
        (t (setarray out k (rk_copyTree ov)))))
    out))

; ---------------------------------------------------------------------------
; Site lookup + load
; ---------------------------------------------------------------------------

(defun rk_siteFind (workarea)
  (let ((env (getShellEnvVar "RELKIT_SITE")) cand)
    (cond
      ((and env (nequal env ""))
        (unless (isFile env)
          (error "rkSiteLoad: RELKIT_SITE=%s does not exist" env))
        env)
      ((isFile (setq cand (rkPathJoin workarea ".relkit_site.json"))) cand)
      ((isFile (setq cand (strcat (rkRelkitDir) "site.json"))) cand)
      (t nil))))

(defun rkSiteLoad (@optional workarea force)
  (let (wa path defaults site merged vars rsh)
    (cond
      ((and rk_siteCache (not force) (null workarea)) rk_siteCache)
      (t
        (setq rk_siteWarns nil)
        (setq wa (rk_stripTrailingSlash (or workarea (rkWorkarea))))
        (setq path (rk_siteFind wa))
        (setq defaults (rkJsonRead (strcat (rkRelkitDir) "site_defaults.json")))
        (cond
          (path (setq site (rkJsonRead path))
                (unless (tablep site)
                  (error "rkSiteLoad: site file %s must contain a JSON object" path)))
          (t (setq site (rkMakeObj))
             (setq rk_siteWarns (cons "no site file found; using built-in defaults only"
                                      rk_siteWarns))))
        (setq merged (rk_deepMerge defaults site))
        (setq vars (rkMakeObj))
        (setarray vars "WORKAREA" wa)
        (setarray vars "USER" (rkUser))
        (setarray vars "RELKIT_DIR" (rk_stripTrailingSlash (rkRelkitDir)))
        (setq merged (rk_expandTree merged vars))
        (unless (and (stringp (arrayref merged "relstudio_home"))
                     (nequal (arrayref merged "relstudio_home") ""))
          (setq rsh (getShellEnvVar "RELSTUDIO_HOME"))
          (setarray merged "relstudio_home" (and rsh (nequal rsh "") rsh)))
        (setq rk_siteWarns (reverse rk_siteWarns))
        (setq rk_sitePathUsed path)
        (setq rk_siteCache merged)
        (foreach w rk_siteWarns (printf "[relkit] site: %s\n" w))
        merged))))

(defun rkSiteGet (key @optional default)
  (rkGet (rkSiteLoad) key default))

(defun rkSitePath () rk_sitePathUsed)

(defun rkSiteWarnings () rk_siteWarns)

(defun rkRelstudioHome ()
  (rkSiteGet "relstudio_home"))
