; mytool.il -- MyTool framework loader.
;
; Single entry point. Source from ~/.cdsinit:
;     load("/home/yusheng/cadence_work/Test/workarea/skill_tools/mytool/mytool.il")
;
; Loads the three module files in dependency order, then calls mtBootstrap().
; Safe to load multiple times: registry init is guarded with `unless boundp`,
; mt_attachToWindow de-dups via hiGetBannerMenus, and deRegUserTriggers is
; tolerant of re-registration (warns, idempotent end state).

(let ((mt_dir "/home/yusheng/cadence_work/Test/workarea/skill_tools/mytool/"))
  (load (strcat mt_dir "mtCore.il"))     ; registry + menu construction
  (load (strcat mt_dir "mtUtil.il"))     ; window classifiers (depends on nothing in mtCore)
  (load (strcat mt_dir "mtInstall.il"))  ; attach helpers + bootstrap (depends on both above)
  (mtBootstrap))
