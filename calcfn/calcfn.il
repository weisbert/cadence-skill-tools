; calcfn.il -- loader for the calcfn library: functions for Maestro outputs and
; the Calculator.  Load this one file, e.g. from .cdsinit:
;
;     load("/abs/path/to/skill_tools/calcfn/calcfn.il")
;
; It needs neither mytool nor a GUI, so it can be loaded wherever Maestro
; evaluates output expressions.  One function per file, file name = function
; name; add a line to calcfn_files for each new one.

(setq calcfn_files '("LOdelay.il"))

; Self-locate from the load() path, same trick as skill_tools.il.
(let ((self (car (errset (get_filename piport) t))) dir)
  (when (stringp self)
    (setq self (pcreReplace (pcreCompile "^ +| +$") self "" 0))
    (setq dir (if (index self "/") (pcreReplace (pcreCompile "/[^/]+$") self "" 1) ".")))
  (cond
    (dir (setq calcfn_dir (strcat dir "/")))
    ((and (boundp 'calcfn_dir) (stringp calcfn_dir)))
    (t (error "calcfn.il: cannot tell where it was loaded from; setq(calcfn_dir \"/path/to/calcfn/\") first\n")))
  (foreach f calcfn_files (load (strcat calcfn_dir f)))
  (printf "[calcfn] %d function file(s) loaded from %s\n" (length calcfn_files) calcfn_dir))
