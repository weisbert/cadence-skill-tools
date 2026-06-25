; skill_tools.il -- single-line entry point for the entire skill_tools collection.
;
; ============================================================================
; HOW TO LOAD -- pick whichever works for your machine.
; The simplest single-line .cdsinit options come first.
; ============================================================================
;
; Option 1 -- absolute path, NO env var, NO setq (recommended; works for
; any user on any machine without coordinating environment setup):
;
;     load("/abs/path/to/skill_tools/skill_tools.il")
;
; The umbrella self-locates from the load path via get_filename(piport),
; same trick as skillbridge/sbStart.il. The path you pass to load() can
; live anywhere the user has read access; nothing else has to be set up.
;
; Option 2 -- $WORK_ROOT2 already points at the workarea dir (the
; convention on this team's dev + work machines):
;
;     load(strcat(getShellEnvVar("WORK_ROOT2") "/skill_tools/skill_tools.il"))
;
; Option 3 -- shell env var SKILL_TOOLS_ROOT:
;
;     # in ~/.bashrc or ~/.cshrc:
;     export SKILL_TOOLS_ROOT=/path/to/skill_tools/      # bash
;     setenv SKILL_TOOLS_ROOT /path/to/skill_tools/      # csh
;     # ~/.cdsinit:
;     load(strcat(getShellEnvVar("SKILL_TOOLS_ROOT") "skill_tools.il"))
;
; Option 4 -- absolute path with explicit setq in .cdsinit (FALLBACK
; only; self-locate still wins when load() hands an absolute path):
;
;     setq( skillTools_root "/abs/path/to/skill_tools/" )
;     load( strcat(skillTools_root "skill_tools.il") )
;
; In Options 2-4, skillTools_root MUST end with a trailing "/". The
; loader auto-fixes a missing trailing slash (see normalize step below)
; but env vars / setq are clearer when they get the slash right.
;
; ============================================================================
; RESOLUTION PRIORITY (highest first):
;   1. self-locate via get_filename(piport) -- ALWAYS wins when load()
;      handed an absolute path AND mytool/mytool.il sits alongside.
;      The user's load("/X/skill_tools.il") is an unambiguous "load FROM
;      HERE"; a stale skillTools_root in .cdsinit or a colleague's
;      SKILL_TOOLS_ROOT/WORK_ROOT2 pointing at a local copy must not
;      redirect away.
;   2. If self-locate finds a real directory but mytool/mytool.il is
;      missing there, ERROR at that path (do NOT silently fall through
;      to env vars -- the user told us where to look).
;   3. skillTools_root already bound (Option 4 fallback; used when
;      piport gives nothing usable, e.g. code pasted into CIW)
;   4. env var SKILL_TOOLS_ROOT (if non-empty)
;   5. env var WORK_ROOT2 (if non-empty) -> "$WORK_ROOT2/skill_tools/"
;   6. compile-time fallback to dev-machine path
;
; The loader prints "[skill_tools] skillTools_root=<X> (via <Y>)" after
; resolving, so a mis-routed load is one glance at the CIW away.
; ============================================================================
;
; Loads:
;   1. mytool framework (provides MyTool banner pulldown + plugin registry)
;   2. dreg_gen plugin (auto-registers under MyTool -> Dreg Generator)
;   3. note_helper plugin (auto-registers under MyTool -> Note Helper)
;   4. verilog_helper plugin (auto-registers under MyTool -> Verilog Helper)
;
; skillbridge/ is NOT loaded here. It's a dev-only Python<->SKILL channel;
; opt in separately if you want it:
;     load(strcat(skillTools_root "skillbridge/sbStart.il"))
;
; Idempotent: re-running this file does not double-mount menus and does
; not double-register plugins (mtRegister refuses duplicate labels).

; ---------------------------------------------------------------------------
; Resolve skillTools_root by priority.
; ---------------------------------------------------------------------------

; Self-locate via piport: while this file is being load()-ed, piport is
; bound to its input port and get_filename(piport) returns the absolute
; path of the file currently being parsed. Strip the filename to get the
; directory; validate it (isDir + mytool/mytool.il alongside) before
; trusting it. If piport is bound to something else (e.g. the file
; contents were pasted into CIW rather than load-ed), self_dir is not a
; real directory and we silently fall through to the env-var paths.
;
; errset wraps the call because piport may be unbound or get_filename
; may raise on non-file ports; we want a silent fallthrough there, not
; a cdsinit-aborting error.
;
; Same pattern as skillbridge/sbStart.il -- proven in production there
; since 8a6b3ef.
;
; Re-resolve on every load (no boundp guard). When the user load()s a
; new path, that's the authoritative intent -- any prior binding (from
; .cdsinit setq, or from an earlier failed load in the same session)
; must not silently override. We capture the prior value into prior_root
; and only use it as a fallback when self-locate produces nothing.
;
; Ref: sklangref.pdf p.167 (pcreCompile), p.191 (pcreReplace), p.428
; (isFile), p.555 (errset), p.631 (isDir), p.479 (boundp).

(let ((skill_env  (getShellEnvVar "SKILL_TOOLS_ROOT"))
      (work_env   (getShellEnvVar "WORK_ROOT2"))
      (self_raw   (errset (get_filename piport) t))
      (prior_root (and (boundp 'skillTools_root) skillTools_root))
      self_path self_dir resolved source)
  (when self_raw
    (setq self_path (car self_raw))
    (when (stringp self_path)
      (setq self_path (pcreReplace (pcreCompile "^ +| +$") self_path "" 0))
      (setq self_dir  (pcreReplace (pcreCompile "/[^/]+$") self_path "" 1))))
  (cond
    ; 1. self-locate succeeded and the install is complete -- highest priority.
    ((and self_dir (nequal self_dir "") (isDir self_dir)
          (isFile (strcat self_dir "/mytool/mytool.il")))
      (setq resolved (strcat self_dir "/"))
      (setq source "self-locate via load() path"))
    ; 2. self-locate found a real directory, but mytool/mytool.il is missing
    ;    there. Error AT that path rather than silently re-routing to env
    ;    vars: the user explicitly load()-ed from a specific location, so a
    ;    missing piece is a load() problem, not a config problem.
    ((and self_dir (nequal self_dir "") (isDir self_dir))
      (error
        (strcat
          "skill_tools.il: load()-ed from " self_dir
          "/skill_tools.il but " self_dir "/mytool/mytool.il is missing.\n"
          "  Either: (a) that directory is an incomplete install -- copy mytool/\n"
          "  alongside skill_tools.il, or (b) you intended to load a different\n"
          "  skill_tools.il -- check the path in your load() call.")))
    ; 3. self-locate produced no usable directory (piport unbound, code
    ;    pasted into CIW rather than load-ed, etc). Fall back through
    ;    pre-bound -> env vars -> compile-time default.
    ((and prior_root (stringp prior_root) (nequal prior_root ""))
      (setq resolved prior_root)
      (setq source "pre-bound skillTools_root (fallback)"))
    ((and skill_env (nequal skill_env ""))
      (setq resolved skill_env)
      (setq source "SKILL_TOOLS_ROOT env var"))
    ((and work_env (nequal work_env ""))
      (setq resolved (strcat work_env "/skill_tools/"))
      (setq source "WORK_ROOT2 env var"))
    (t
      (setq resolved "/home/yusheng/cadence_work/Test/workarea/skill_tools/")
      (setq source "compile-time fallback")))
  (setq skillTools_root resolved)
  (when (and prior_root (stringp prior_root) (nequal prior_root resolved))
    (printf "[skill_tools] note: prior skillTools_root=%s overridden by %s\n"
            prior_root source))
  (printf "[skill_tools] skillTools_root=%s (via %s)\n" skillTools_root source))

; ---------------------------------------------------------------------------
; Normalize: ensure trailing "/". A common mistake is forgetting the slash
; (e.g. setq skillTools_root "<path>/skill_tools") which then cascades into
; "<path>/skill_toolsmytool/mytool.il" via strcat in the load lines below.
; Auto-fix it here so the rest of the loader can assume it.
; ---------------------------------------------------------------------------

(unless (rexMatchp "/$" skillTools_root)
  (setq skillTools_root (strcat skillTools_root "/")))

; ---------------------------------------------------------------------------
; Sanity check: skillTools_root must point at the dir containing the three
; subdirs (mytool/, dreg_gen/, skillbridge/). At this point the self-locate
; branch has already verified mytool/mytool.il, so this check only fires for
; the pre-bound / env-var / compile-time-fallback branches -- typically a
; SKILL_TOOLS_ROOT or WORK_ROOT2 pointing at a local copy that is missing
; mytool/, or pointing one level too high (workarea/ vs workarea/skill_tools/).
; Bail with a clear message that names the resolution source (printed above
; on the "[skill_tools] skillTools_root=..." line) rather than letting the
; cryptic "load: error while loading file" cascade from an inner load().
; ---------------------------------------------------------------------------

(unless (isFile (strcat skillTools_root "mytool/mytool.il"))
  (error
    (strcat
      "skill_tools.il: skillTools_root=" skillTools_root
      " does not contain mytool/mytool.il.\n"
      "  See the [skill_tools] line printed above for which resolution source\n"
      "  produced this path (env var, pre-bound, or fallback).\n"
      "  Most common causes: (a) SKILL_TOOLS_ROOT / WORK_ROOT2 / skillTools_root\n"
      "  in .cdsinit points at a local copy that is missing mytool/; (b) the\n"
      "  path is one level too high (workarea/ instead of workarea/skill_tools/).\n"
      "  The path must be the directory that DIRECTLY contains mytool/, dreg_gen/,\n"
      "  with a trailing slash. See this file's header for the four supported\n"
      "  configuration styles. To force a specific install, load() its absolute\n"
      "  path -- self-locate now overrides any pre-bound skillTools_root/env vars.")))

; ---------------------------------------------------------------------------
; Propagate to child loaders BEFORE they load. The umbrella OVERRIDES any
; pre-bound mt_dir / dreg_genDir so children stay consistent with the
; current skillTools_root. (A previous design used boundp guards here, but
; that left stale values from earlier failed attempts in the same session
; sticking around -- after fixing skillTools_root, mt_dir would still
; point at the old broken path, producing concat artifacts like
; "$WORK_ROOT2/workareamytool/mytool.il" in mytool.il's existence check.)
;
; If you want a different mt_dir / dreg_genDir, override skillTools_root
; itself (umbrella usage), or load mytool/mytool.il and dreg_gen/dreg_gen.il
; directly without the umbrella (those files keep their own boundp guards).
; ---------------------------------------------------------------------------

(setq mt_dir        (strcat skillTools_root "mytool/"))
(setq dreg_genDir   (strcat skillTools_root "dreg_gen/"))
(setq note_helperDir (strcat skillTools_root "note_helper/"))
(setq verilog_helperDir (strcat skillTools_root "verilog_helper/"))

; ---------------------------------------------------------------------------
; Load framework + plugins in dependency order.
; ---------------------------------------------------------------------------

(let ((r skillTools_root))
  (load (strcat r "mytool/mytool.il"))                  ; framework first (defines mtRegister)
  (load (strcat r "dreg_gen/dreg_gen.il"))              ; plugin (calls mtRegister at end)
  (load (strcat r "note_helper/note_helper.il"))        ; plugin (calls mtRegister at end)
  (load (strcat r "verilog_helper/verilog_helper.il"))) ; plugin (calls mtRegister at end)
