; dgenPinScan.il -- Step 1 of Dreg Generator: scan source-cell terminals and parse bus syntax.

(defun dgenParseBusName (termName "t")
  (cond
    ((rexMatchp "^[^<]+<[0-9]+:[0-9]+>$" termName)
      (rexCompile "^\\([^<]+\\)<\\([0-9]+\\):\\([0-9]+\\)>$")
      (rexExecute termName)
      (list nil
        'name (rexSubstitute "\\1")
        'isBus t
        'busHi (atoi (rexSubstitute "\\2"))
        'busLo (atoi (rexSubstitute "\\3"))))
    ((rexMatchp "^[^<]+<[0-9]+>$" termName)
      (rexCompile "^\\([^<]+\\)<\\([0-9]+\\)>$")
      (rexExecute termName)
      (let ((bit (atoi (rexSubstitute "\\2"))))
        (list nil
          'name (rexSubstitute "\\1")
          'isBus t
          'busHi bit
          'busLo bit)))
    (t
      (list nil 'name termName 'isBus nil))))

; If two descriptors share the same base name and both are buses, merge into one
; covering descriptor (max hi, min lo). Handles the case where cv~>terminals
; exposes a bus as N single-bit terms instead of one D<hi:lo> term.
(defun dgen_mergeBusBits (descs "l")
  (let (tbl order out)
    (setq tbl (makeTable 'dgen_bus_tbl nil))
    (foreach d descs
      (let ((nm (get d 'name)))
        (unless (member nm order) (setq order (cons nm order)))
        ; Ref: sklangref.pdf p.87 (setarray). SKILL setq only accepts a symbol
        ; as its first argument; for table[key] = value use setarray instead.
        (let ((cur tbl[nm]))
          (cond
            ((null cur) (setarray tbl nm d))
            ((and (get cur 'isBus) (get d 'isBus))
              (setarray tbl nm
                (list nil
                  'name nm
                  'isBus t
                  'busHi (max (get cur 'busHi) (get d 'busHi))
                  'busLo (min (get cur 'busLo) (get d 'busLo))
                  'srcDirection (or (get cur 'srcDirection) (get d 'srcDirection)))))
            (t nil)))))
    (setq order (reverse order))
    (foreach nm order (setq out (cons tbl[nm] out)))
    (reverse out)))

; Ref: skdfref.pdf p.900 (dbOpenCellViewByType), p.873 (dbClose) -- physical PDF pages, match function_index.tsv
; Property notation cv~>terminals yields the list of terminal dbObjects for a cellview;
; term~>name is the terminal name string, term~>direction the direction string.
; Bus terminals normally come back as a single term named "D<7:0>"; this code also
; tolerates bit-decomposed forms (D<7>..D<0>) by merging them post-scan.
(defun dgenScanPins (libName cellName viewName "ttt")
  (let (cv raw)
    (setq cv (dbOpenCellViewByType libName cellName viewName nil "r"))
    (unless cv (error "dgenScanPins: cannot open %s/%s/%s" libName cellName viewName))
    (foreach term cv~>terminals
      (let ((parsed (dgenParseBusName term~>name))
            (dir (or term~>direction "input")))
        (setq raw (cons (append parsed (list 'srcDirection dir)) raw))))
    (dbClose cv)
    (dgen_mergeBusBits (reverse raw))))
