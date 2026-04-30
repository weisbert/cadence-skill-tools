; skill_tools.il -- single-line entry point for the entire skill_tools collection.
;
; ============================================================================
; HOW TO LOAD -- pick whichever works for your machine.
; The simplest single-line .cdsinit options come first.
; ============================================================================
;
; Option 1 -- $WORK_ROOT2 already points at the workarea dir (the convention
; on this team's dev + work machines):
;
;     load(strcat(getShellEnvVar("WORK_ROOT2") "/skill_tools/skill_tools.il"))
;
; This file then auto-derives skillTools_root from $WORK_ROOT2 -- no setq
; needed in .cdsinit.
;
; Option 2 -- shell env var SKILL_TOOLS_ROOT (most portable for distribution):
;
;     # in ~/.bashrc or ~/.cshrc:
;     export SKILL_TOOLS_ROOT=/path/to/skill_tools/      # bash
;     setenv SKILL_TOOLS_ROOT /path/to/skill_tools/      # csh
;     # ~/.cdsinit:
;     load(strcat(getShellEnvVar("SKILL_TOOLS_ROOT") "skill_tools.il"))
;
; Option 3 -- absolute path in .cdsinit (no env var needed):
;
;     setq( skillTools_root "/abs/path/to/skill_tools/" )
;     load( strcat(skillTools_root "skill_tools.il") )
;
; In all options, skillTools_root MUST end with a trailing "/". Loaders use
; strcat to splice paths and do NOT auto-insert separators (auto-fix below).
;
; ============================================================================
; RESOLUTION PRIORITY (highest first):
;   1. skillTools_root already bound (via setq in .cdsinit)
;   2. env var SKILL_TOOLS_ROOT (if non-empty)
;   3. env var WORK_ROOT2 (if non-empty) -> "$WORK_ROOT2/skill_tools/"
;   4. compile-time fallback to dev-machine path
; ============================================================================
;
; Loads:
;   1. mytool framework (provides MyTool banner pulldown + plugin registry)
;   2. dreg_gen plugin (auto-registers under MyTool -> Dreg Generator)
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

(unless (boundp 'skillTools_root)
  (let ((skill_env (getShellEnvVar "SKILL_TOOLS_ROOT"))
        (work_env  (getShellEnvVar "WORK_ROOT2")))
    (cond
      ((and skill_env (nequal skill_env ""))
        (setq skillTools_root skill_env))
      ((and work_env (nequal work_env ""))
        (setq skillTools_root (strcat work_env "/skill_tools/")))
      (t
        (setq skillTools_root "/home/yusheng/cadence_work/Test/workarea/skill_tools/")))))

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
; subdirs (mytool/, dreg_gen/, skillbridge/). The most common failure mode
; is pointing one level too high (e.g. workarea/ instead of workarea/skill_tools/).
; Bail with a clear message rather than letting the cryptic "load: error
; while loading file" cascade from an inner load() call.
; ---------------------------------------------------------------------------

(unless (isFile (strcat skillTools_root "mytool/mytool.il"))
  (error
    (strcat
      "skill_tools.il: skillTools_root=" skillTools_root
      " does not contain mytool/mytool.il.\n"
      "  Most common cause: pointing one level too high (e.g. at workarea/\n"
      "  instead of workarea/skill_tools/). The path you set must be the\n"
      "  directory that DIRECTLY contains skill_tools.il, mytool/, dreg_gen/,\n"
      "  with a trailing slash. See workarea/skill_tools/skill_tools.il\n"
      "  header for the three supported configuration styles.")))

; ---------------------------------------------------------------------------
; Propagate to child loaders BEFORE they load. Each child uses
; `(unless (boundp ...))` internally, so an explicit setq in .cdsinit
; (e.g. setq mt_dir "/somewhere/else/") still wins over the umbrella.
; ---------------------------------------------------------------------------

(unless (boundp 'mt_dir)
  (setq mt_dir (strcat skillTools_root "mytool/")))

(unless (boundp 'dreg_genDir)
  (setq dreg_genDir (strcat skillTools_root "dreg_gen/")))

; ---------------------------------------------------------------------------
; Load framework + plugins in dependency order.
; ---------------------------------------------------------------------------

(let ((r skillTools_root))
  (load (strcat r "mytool/mytool.il"))       ; framework first (defines mtRegister)
  (load (strcat r "dreg_gen/dreg_gen.il")))  ; plugin (calls mtRegister at end)
