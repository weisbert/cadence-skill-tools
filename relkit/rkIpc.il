; rkIpc.il -- run relkit.py subcommands as subprocesses (plan section 2,
; CONTRACT sections 3.0 and 6).
;
; OWNER: SKILL panel & IPC agent.
;
; Everything here is asynchronous: rkIpcRun starts the child with
; ipcBeginProcess and returns at once; the child's exit handler (called by
; Virtuoso at the top level, never inside another evaluation) reads out.json
; and calls the caller's callback. The UI never waits on Python, except in
; rkIpcRunSync (tests / scripts only).
;
; Command line (CONTRACT 3.0):
;   /bin/sh -c 'exec <site python> <relkit>/py/relkit.py <subcmd> [--ctx C] --out O [args] 2>O.log'
; Wrapped in /bin/sh -c so the 2> redirect also works when the user's login
; shell (which ipcBeginProcess may use) is csh; `exec` makes the python process
; the child itself, so ipcKillProcess (SIGKILL) reaches it. Long-running work
; (submit / extract) detaches itself in Python, so killing or losing this child
; never kills a run.
;
; Public API:
;   rkIpcCommandLine(t_subcmd t_ctxFile t_outFile [l_extraArgs]) -> t_cmd (python argv, quoted)
;   rkIpcShellCommand(t_subcmd t_ctxFile t_outFile [l_extraArgs]) -> t_cmd (what is run)
;   rkIpcNewCtxFile(o_ctx t_tag)   -> t_path  ; <persist_root>/_ipc/<user>_<ts>_<n>_<tag>_ctx.json
;   rkIpcNewOutFile(t_tag)         -> t_path  ; same dir, ..._<tag>_out.json
;   rkIpcRun(t_subcmd t_ctxFile t_outFile g_callback [l_extraArgs] [x_timeoutSec]) -> o_handle / nil
;       g_callback: symbol, function object or function-name string; called with
;       ONE argument, the result table: out.json + "_exit" "_out" "_log"
;       (+ "_timeout" t / "_cancelled" t). out.json missing or invalid ->
;       "ok" nil and "error" text. Errors inside the callback are caught and
;       printed (they never break the IPC bookkeeping).
;   rkIpcRunSync(t_subcmd t_ctxFile t_outFile [l_extraArgs] [x_timeoutSec]) -> o_result
;   rkIpcCancel(o_handle)          -> t / nil ; kill the child, callback gets "_cancelled" t
;   rkIpcBusy(o_handle)            -> t / nil
;   rkIpcActive()                  -> list of live handles
;   rkIpcEnv / rkIpcSetEnv(l_assignments) ; extra "NAME=value" put in front of
;       every command (tests: fake-tool switches); nil = none
;   rkIpcLaunch(t_shellCommand [t_logFile]) -> o_childId ; fire-and-forget (GUIs,
;       file browsers); output ignored
;
;   Pollers (status refresh for long runs; never two requests in flight):
;   rkIpcPollStart(t_name t_subcmd t_ctxFile l_extraArgs x_intervalSec g_callback) -> o_poller
;       Runs the subcommand every intervalSec (first run immediately). The
;       callback gets the result table and returns non-nil to keep polling, nil
;       to stop. Starting a poller with an existing name replaces it.
;   rkIpcPollStop(t_name)  -> t / nil
;   rkIpcPollNow(t_name)   -> t / nil      ; run now (unless a request is in flight)
;   rkIpcPollActive([t_prefix]) -> list of names
;   rkIpcPollStopAll([t_prefix]) -> count
;
; Timer safety ("stale armed-state flags"): hiRegTimer has no cancel, so every
; poller carries a generation number and every armed timer carries the
; generation it was armed for; a timer firing for an old generation, a stopped
; poller or a poller whose request is still in flight does nothing. A poller
; re-arms only from the result callback of its own request (never from the
; tick), so ticks cannot pile up. If a request's result never arrives, the
; request timeout (2 * interval + 60 s, at least 120 s) kills it and the
; callback chain continues. rkIpcPollNow / restarting is always safe.
;
; Ref: skipcref.pdf (IC6.1.8) ipcBeginProcess p.31 (handlers get (cid data),
;      postFunc gets (cid exitStatus), called at SKILL top level),
;      ipcIsAliveProcess, ipcKillProcess (SIGKILL), ipcWait(cid [interval timeout]),
;      ipcGetExitStatus; skuiref.pdf hiRegTimer p.84 (string, tenths of a second);
;      sklangref.pdf setShellEnvVar / unsetShellEnvVar, outfile, isFile,
;      deleteFile, funcall, evalstring.
;
; SKILL rules (memory feedback_skill_gotchas): no let*, no prefix arithmetic,
; no defvar, identifiers [A-Za-z0-9_], tables via setarray / rkPut.

(unless (boundp 'rk_ipcJobs)    (setq rk_ipcJobs nil))     ; live handles (tables)
(unless (boundp 'rk_ipcSeq)     (setq rk_ipcSeq 0))
(unless (boundp 'rk_ipcFileSeq) (setq rk_ipcFileSeq 0))
(unless (boundp 'rk_ipcPollers) (setq rk_ipcPollers (makeTable "rk_ipcPollers" nil)))
(unless (boundp 'rk_ipcPollGen) (setq rk_ipcPollGen 0))
(unless (boundp 'rkIpcEnv)      (setq rkIpcEnv nil))
(unless (boundp 'rk_ipcLastErr) (setq rk_ipcLastErr nil))

; Shell-quote one argument for /bin/sh (alias of rkShellQuote in rkSite.il).
(defun rk_shq (s) (rkShellQuote s))

(defun rkIpcSetEnv (assignments)
  (setq rkIpcEnv assignments)
  t)

; <site python> <relkitDir>py/relkit.py <subcmd> [--ctx <ctx>] --out <out> <extra...>
(defun rkIpcCommandLine (subcmd ctxFile outFile @optional extraArgs)
  (let ((parts (list (rk_shq (rkSiteGet "python" "python3"))
                     (rk_shq (strcat (rkRelkitDir) "py/relkit.py"))
                     (rk_shq subcmd))))
    (when ctxFile (setq parts (append parts (list "--ctx" (rk_shq ctxFile)))))
    (setq parts (append parts (list "--out" (rk_shq outFile))))
    (foreach a extraArgs (setq parts (append parts (list (rk_shq a)))))
    (buildString parts " ")))

(defun rk_ipcLogOf (outFile)
  (strcat (pcreReplace (pcreCompile "\\.json$") outFile "" 1) ".log"))

; The full command handed to ipcBeginProcess.
(defun rkIpcShellCommand (subcmd ctxFile outFile @optional extraArgs)
  (let ((env ""))
    (when rkIpcEnv
      (setq env (strcat "env " (buildString (mapcar 'rk_shq rkIpcEnv) " ") " ")))
    (strcat "/bin/sh -c "
            (rk_shq (strcat "exec " env (rkIpcCommandLine subcmd ctxFile outFile extraArgs)
                            " 2>" (rk_shq (rk_ipcLogOf outFile)))))))

; ---------------------------------------------------------------------------
; Scratch files: <persist_root>/_ipc/
; ---------------------------------------------------------------------------

(defun rk_ipcDir ()
  (let ((root (rkSiteGet "persist_root")) dir)
    (unless (stringp root) (error "relkit: site key persist_root is not set"))
    (setq dir (rkPathJoin root "_ipc"))
    (unless (rkMkdirs dir) (error "relkit: cannot create %s" dir))
    dir))

(defun rk_ipcStem (tag)
  (setq rk_ipcFileSeq (add1 rk_ipcFileSeq))
  (rkPathJoin (rk_ipcDir)
              (sprintf nil "%s_%s_%d_%s" (rkUser) (rkTimestamp) rk_ipcFileSeq
                       (pcreReplace (pcreCompile "[^A-Za-z0-9_.-]") (or tag "x") "_" 0))))

(defun rkIpcNewCtxFile (ctx tag)
  (let ((path (strcat (rk_ipcStem tag) "_ctx.json")))
    (rkJsonWrite ctx path)
    path))

(defun rkIpcNewOutFile (tag)
  (strcat (rk_ipcStem tag) "_out.json"))

; ---------------------------------------------------------------------------
; Result table
; ---------------------------------------------------------------------------

(defun rk_ipcReadResult (h status)
  (let ((out (rkGet h "out")) r res)
    (setq r (and (isFile out) (errset (rkJsonRead out) nil)))
    (cond
      ((and r (tablep (car r))) (setq res (car r)))
      (t
        (setq res (rkMakeObj))
        (rkPut res "ok" nil)
        (rkPut res "cmd" (rkGet h "subcmd"))
        (rkPut res "error"
               (cond
                 ((arrayref h "timeout_hit")
                   (sprintf nil "%s timed out after %d s (log %s)" (rkGet h "subcmd")
                            (rkGet h "timeout" 0) (rkGet h "log")))
                 ((arrayref h "cancelled") (sprintf nil "%s cancelled" (rkGet h "subcmd")))
                 ((isFile out) (sprintf nil "%s wrote an unreadable %s (exit %L)"
                                        (rkGet h "subcmd") out status))
                 (t (sprintf nil "%s exited %L without writing %s; see %s"
                             (rkGet h "subcmd") status out (rkGet h "log")))))))
    (rkPut res "_exit" status)
    (rkPut res "_out" out)
    (rkPut res "_log" (rkGet h "log"))
    (when (arrayref h "timeout_hit") (rkPut res "_timeout" t))
    (when (arrayref h "cancelled") (rkPut res "_cancelled" t))
    (when (arrayref h "stdout") (rkPut res "_stdout" (rkGet h "stdout")))
    res))

(defun rk_ipcCall (cb arg)
  (let (r)
    (setq r (errset
              (cond
                ((null cb) nil)
                ((stringp cb) (funcall (stringToSymbol cb) arg))
                (t (funcall cb arg)))
              t))
    (unless r
      (setq rk_ipcLastErr (sprintf nil "callback %L failed: %L" cb errset.errset))
      (printf "[relkit] ipc: %s\n" rk_ipcLastErr))
    (and r (car r))))

; Finish a handle exactly once: drop it from the live list, build the result,
; call the callback.
(defun rk_ipcFinish (h status)
  (let (res)
    (unless (arrayref h "done")
      (rkPut h "done" t)
      (rkPut h "exit" status)
      (setq rk_ipcJobs (setof x rk_ipcJobs (not (eq x h))))
      (setq res (rk_ipcReadResult h status))
      (rkPut h "result" res)
      (if (arrayref h "poll")
        (rk_ipcPollResult (car (arrayref h "poll")) (cadr (arrayref h "poll")) res)
        (rk_ipcCall (arrayref h "callback") res)))
    (arrayref h "result")))

(defun rk_ipcFind (cid)
  (car (setof x rk_ipcJobs (eq (arrayref x "cid") cid))))

(defun rk_ipcFindId (id)
  (car (setof x rk_ipcJobs (equal (arrayref x "id") id))))

; ipcBeginProcess handlers (cid data) / postFunc (cid exitStatus)
(defun rk_ipcData (cid data)
  (let ((h (rk_ipcFind cid)) prev)
    (when h
      (setq prev (or (arrayref h "stdout") ""))
      (when (lessp (strlen prev) 20000)
        (rkPut h "stdout" (strcat prev data))))
    t))

(defun rk_ipcErr (cid data)
  (rk_ipcData cid data))

(defun rk_ipcPost (cid status)
  (let ((h (rk_ipcFind cid)))
    (when h (rk_ipcFinish h status))
    t))

(defun rk_ipcTimeoutCheck (id)
  (let ((h (rk_ipcFindId id)))
    (when (and h (not (arrayref h "done")))
      (rkPut h "timeout_hit" t)
      (errset (ipcKillProcess (arrayref h "cid")) nil)
      (rk_ipcFinish h -1))
    t))

; ---------------------------------------------------------------------------
; Run
; ---------------------------------------------------------------------------

(defun rkIpcRun (subcmd ctxFile outFile callback @optional extraArgs timeoutSec)
  (rk_ipcStart subcmd ctxFile outFile callback extraArgs timeoutSec nil))

; poll = (name gen) for poller requests: the result goes to rk_ipcPollResult
; (SKILL lambdas do not close over local variables, so no closures here).
(defun rk_ipcStart (subcmd ctxFile outFile callback extraArgs timeoutSec poll)
  (let (h cmd cid)
    (setq rk_ipcSeq (add1 rk_ipcSeq))
    (when (isFile outFile) (deleteFile outFile))  ; a stale out.json must never be read
    (setq cmd (rkIpcShellCommand subcmd ctxFile outFile extraArgs))
    (setq h (rkMakeObj))
    (rkPut h "id" rk_ipcSeq)
    (rkPut h "subcmd" subcmd)
    (rkPut h "ctx" ctxFile)
    (rkPut h "out" outFile)
    (rkPut h "log" (rk_ipcLogOf outFile))
    (rkPut h "cmd" cmd)
    (rkPut h "callback" callback)
    (rkPut h "poll" poll)
    (rkPut h "started" (rkTimestamp))
    (rkPut h "timeout" timeoutSec)
    (setq rk_ipcJobs (cons h rk_ipcJobs))
    (setq cid (ipcBeginProcess cmd "" 'rk_ipcData 'rk_ipcErr 'rk_ipcPost))
    (cond
      ((null cid)
        (rkPut h "cid" nil)
        (rk_ipcFinish h -1)
        h)
      (t
        (rkPut h "cid" cid)
        (when (and timeoutSec (greaterp timeoutSec 0))
          (hiRegTimer (sprintf nil "(rk_ipcTimeoutCheck %d)" rk_ipcSeq)
                      (fix (times 10 timeoutSec))))
        h))))

; Blocking variant (tests / scripts). Never use from a GUI callback.
(defun rkIpcRunSync (subcmd ctxFile outFile @optional extraArgs timeoutSec)
  (let (cmd cid h status)
    (when (isFile outFile) (deleteFile outFile))
    (setq cmd (rkIpcShellCommand subcmd ctxFile outFile extraArgs))
    (setq h (rkMakeObj))
    (rkPut h "subcmd" subcmd)
    (rkPut h "out" outFile)
    (rkPut h "log" (rk_ipcLogOf outFile))
    (rkPut h "timeout" timeoutSec)
    (setq cid (ipcBeginProcess cmd ""))
    (cond
      ((null cid) (setq status -1))
      (t
        ; ipcWait's 2nd argument is the interval of its "Waiting for ... to
        ; terminate" CIW message (skipcref ipcWait), not a poll period: 1 s
        ; would print one line per second.
        (if (and timeoutSec (greaterp timeoutSec 0))
          (ipcWait cid (max 30 (fix timeoutSec)) (fix timeoutSec))
          (ipcWait cid))
        (cond
          ((ipcIsAliveProcess cid)
            (rkPut h "timeout_hit" t)
            (ipcKillProcess cid)
            (setq status -1))
          (t (setq status (ipcGetExitStatus cid))))))
    (rk_ipcReadResult h status)))

(defun rkIpcBusy (handle)
  (and (tablep handle) (not (arrayref handle "done"))))

(defun rkIpcActive () rk_ipcJobs)

(defun rkIpcCancel (handle)
  (cond
    ((not (rkIpcBusy handle)) nil)
    (t
      (rkPut handle "cancelled" t)
      (when (arrayref handle "cid") (errset (ipcKillProcess (arrayref handle "cid")) nil))
      (rk_ipcFinish handle -1)
      t)))

; Fire-and-forget (RelStudio GUI, file browser). Output goes to logFile or
; /dev/null; the child is not tracked.
(defun rkIpcLaunch (shellCmd @optional logFile)
  (ipcBeginProcess (strcat "/bin/sh -c "
                           (rk_shq (strcat shellCmd " >" (rk_shq (or logFile "/dev/null")) " 2>&1 &")))
                   ""))

; ---------------------------------------------------------------------------
; Pollers
; ---------------------------------------------------------------------------

(defun rk_ipcPoller (name) (arrayref rk_ipcPollers name))

(defun rkIpcPollStart (name subcmd ctxFile extraArgs intervalSec callback)
  (let ((p (rkMakeObj)))
    (rkIpcPollStop name)
    (setq rk_ipcPollGen (add1 rk_ipcPollGen))
    (rkPut p "name" name)
    (rkPut p "gen" rk_ipcPollGen)
    (rkPut p "subcmd" subcmd)
    (rkPut p "ctx" ctxFile)
    (rkPut p "args" extraArgs)
    (rkPut p "interval" (max 1 (or intervalSec 30)))
    (rkPut p "callback" callback)
    (rkPut p "active" t)
    (rkPut p "count" 0)
    (setarray rk_ipcPollers name p)
    (rk_ipcPollFire p)
    p))

(defun rkIpcPollStop (name)
  (let ((p (rk_ipcPoller name)))
    (when p
      (rkPut p "active" nil)
      (rkPut p "gen" -1)
      (when (rkIpcBusy (arrayref p "handle")) (rkIpcCancel (arrayref p "handle")))
      (setarray rk_ipcPollers name nil)
      t)))

(defun rkIpcPollActive (@optional prefix)
  (let (out)
    (foreach k rk_ipcPollers
      (when (and (arrayref rk_ipcPollers k)
                 (or (null prefix) (equal (substring k 1 (strlen prefix)) prefix)))
        (setq out (cons k out))))
    (sort out 'alphalessp)))

(defun rkIpcPollStopAll (@optional prefix)
  (let ((n 0))
    (foreach k (rkIpcPollActive prefix)
      (when (rkIpcPollStop k) (setq n (add1 n))))
    n))

(defun rkIpcPollNow (name)
  (let ((p (rk_ipcPoller name)))
    (cond
      ((null p) nil)
      ((rkIpcBusy (arrayref p "handle")) nil)
      (t (rk_ipcPollFire p) t))))

; Start one request of poller p (no-op if one is in flight).
(defun rk_ipcPollFire (p)
  (let (out tmo name gen)
    (when (and (arrayref p "active") (not (rkIpcBusy (arrayref p "handle"))))
      (setq name (arrayref p "name"))
      (setq gen (arrayref p "gen"))
      (setq out (or (arrayref p "out")
                    (rkIpcNewOutFile (sprintf nil "poll_%s" (arrayref p "subcmd")))))
      (rkPut p "out" out)
      (setq tmo (max 120 (plus 60 (times 2 (arrayref p "interval")))))
      (rkPut p "fired" (rkTimestamp))
      (rkPut p "handle"
             (rk_ipcStart (arrayref p "subcmd") (arrayref p "ctx") out nil
                          (arrayref p "args") tmo (list name gen))))
    t))

(defun rk_ipcPollResult (name gen res)
  (let ((p (rk_ipcPoller name)) keep)
    (when (and p (arrayref p "active") (equal (arrayref p "gen") gen))
      (rkPut p "count" (add1 (arrayref p "count")))
      (rkPut p "last" res)
      (setq keep (rk_ipcCall (arrayref p "callback") res))
      ; the callback may have stopped / replaced this poller
      (setq p (rk_ipcPoller name))
      (when (and p (arrayref p "active") (equal (arrayref p "gen") gen))
        (cond
          (keep
            (hiRegTimer (sprintf nil "(rk_ipcPollTick %L %d)" name gen)
                        (fix (times 10 (arrayref p "interval")))))
          (t
            (rkPut p "active" nil)
            (setarray rk_ipcPollers name nil)))))
    t))

(defun rk_ipcPollTick (name gen)
  (let ((p (rk_ipcPoller name)))
    (when (and p (arrayref p "active") (equal (arrayref p "gen") gen))
      (rk_ipcPollFire p))
    t))
