; rk_testlib.il -- tiny assertion helpers for relkit SKILL smoke tests.
;
; Driven by tests/run_skill_test.py over skillbridge:
;   1. load relkit/relkit.il  2. load this file  3. load tests/test_<x>.il
;   4. read rkTestReport() with a one-line evalstring.
; Each test file calls (rkTestBegin "name") first, then rkCheck for each
; assertion. Errors inside a check are caught (errset) and count as failures.

(setq rk_tName "")
(setq rk_tPass 0)
(setq rk_tFail nil)

(defun rkTestBegin (name)
  (setq rk_tName name)
  (setq rk_tPass 0)
  (setq rk_tFail nil)
  t)

; rkCheck("label" value) -- passes when value is non-nil.
(defun rkCheck (label value)
  (cond
    (value (setq rk_tPass (add1 rk_tPass)) t)
    (t (setq rk_tFail (cons label rk_tFail)) nil)))

; rkCheckEqual("label" got expected)
(defun rkCheckEqual (label got expected)
  (cond
    ((equal got expected) (setq rk_tPass (add1 rk_tPass)) t)
    (t (setq rk_tFail (cons (sprintf nil "%s: got %L expected %L" label got expected) rk_tFail))
       nil)))

(defun rkTestReport ()
  (sprintf nil "%s: %s pass=%d fail=%d%s"
           rk_tName (if rk_tFail "FAIL" "PASS") rk_tPass (length rk_tFail)
           (if rk_tFail (sprintf nil " :: %L" (reverse rk_tFail)) "")))
