; skill_tools.il -- single-line entry point for the entire skill_tools collection.
;
; Source from .cdsinit:
;
;     load("/home/yusheng/cadence_work/Test/workarea/skill_tools/skill_tools.il")
;
; To deploy to another machine, set the root BEFORE loading:
;
;     setq( skillTools_root "/work/path/to/skill_tools/" )
;     load( strcat(skillTools_root "skill_tools.il") )
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

(unless (boundp 'skillTools_root)
  (setq skillTools_root "/home/yusheng/cadence_work/Test/workarea/skill_tools/"))

(let ((r skillTools_root))
  (load (strcat r "mytool/mytool.il"))       ; framework first (defines mtRegister)
  (load (strcat r "dreg_gen/dreg_gen.il")))  ; plugin (calls mtRegister at end)
