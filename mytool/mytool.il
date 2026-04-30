; mytool.il -- MyTool framework loader.
;
; Single entry point. Source from ~/.cdsinit:
;     load("/home/yusheng/cadence_work/Test/workarea/skill_tools/mytool/mytool.il")
;
; To deploy to another machine, override BEFORE loading:
;     setq( mt_dir "/work/path/to/mytool/" )
;     load( strcat(mt_dir "mytool.il") )
;
; The umbrella skill_tools.il propagates skillTools_root into mt_dir for you,
; so when loading via the umbrella you only need to set skillTools_root.
;
; Loads the three module files in dependency order, then calls mtBootstrap().
; Safe to load multiple times: registry init is guarded with `unless boundp`,
; mt_attachToWindow de-dups via hiGetBannerMenus, and deRegUserTriggers is
; tolerant of re-registration (warns, idempotent end state).

(unless (boundp 'mt_dir)
  (setq mt_dir "/home/yusheng/cadence_work/Test/workarea/skill_tools/mytool/"))

; Auto-fix trailing slash (common typo).
(unless (rexMatchp "/$" mt_dir)
  (setq mt_dir (strcat mt_dir "/")))

; Existence check: bail with a clear error rather than the cryptic
; "load: error while loading file" if mt_dir is wrong.
(unless (isFile (strcat mt_dir "mtCore.il"))
  (error
    (strcat
      "mytool.il: mt_dir=" mt_dir
      " does not contain mtCore.il. Set mt_dir (or skillTools_root via the umbrella) "
      "to the directory that DIRECTLY contains mtCore.il, mtUtil.il, and "
      "mtInstall.il, with a trailing slash.")))

(let ((d mt_dir))
  (load (strcat d "mtCore.il"))     ; registry + menu construction
  (load (strcat d "mtUtil.il"))     ; window classifiers (depends on nothing in mtCore)
  (load (strcat d "mtInstall.il"))  ; attach helpers + bootstrap (depends on both above)
  (mtBootstrap))
