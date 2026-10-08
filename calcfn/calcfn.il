; calcfn.il -- loader for the calcfn library: functions for Maestro outputs and
; the Calculator.  Load this one file, e.g. from .cdsinit:
;
;     load("/abs/path/to/skill_tools/calcfn/calcfn.il")
;
; It needs neither mytool nor a GUI, so it can be loaded wherever Maestro
; evaluates output expressions.  One function per file, file name = function
; name; add a line to calcfn_files for each new one.
;
; A function with a <name>_ui.ocn next to it also gets a Calculator Function
; Panel entry (category "calcfn"), parameters shown in the panel like the
; built-in functions.  Template format: vivaxlug appendix F; registered with
; awvLoadCustomCalcFunction, whose real keys on IC6.1.8 are
; ?fileName ?templateFileName ?funcList (the manual's ?funcName returns nil).
; Viva also records the call in ~/.cadence/dfII/viva/customFunctions.ini and
; replays it at its next start.

(setq calcfn_files '("LOdelay.il"))
(setq calcfn_panel nil)        ; functions that got a Function Panel entry

;; Self-locate from the load() path, same trick as skill_tools.il.
(let ((self (car (errset (get_filename piport) t))) dir)
  (when (stringp self)
    (setq self (pcreReplace (pcreCompile "^ +| +$") self "" 0))
    (setq dir (if (index self "/") (pcreReplace (pcreCompile "/[^/]+$") self "" 1) ".")))
  (cond
    (dir (setq calcfn_dir (strcat dir "/")))
    ((and (boundp 'calcfn_dir) (stringp calcfn_dir)))
    (t (error "calcfn.il: cannot tell where it was loaded from; setq(calcfn_dir \"/path/to/calcfn/\") first\n"))))

(foreach f calcfn_files (load (strcat calcfn_dir f)))

; Function Panel templates; skipped where there is no Calculator (-nograph,
; Maestro job processes).
(foreach f calcfn_files
  (let ((name (substring f 1 (difference (strlen f) 3))) ui)
    (setq ui (simplifyFilename (strcat calcfn_dir name "_ui.ocn")))
    (when (and (isFile ui) (isCallable 'awvLoadCustomCalcFunction))
      (when (car (errset (awvLoadCustomCalcFunction
                           ?funcList (list name)
                           ?fileName (simplifyFilename (strcat calcfn_dir f))
                           ?templateFileName ui)))
        (setq calcfn_panel (append calcfn_panel (list name)))))))

(printf "[calcfn] %d function file(s) loaded from %s\n" (length calcfn_files) calcfn_dir)
