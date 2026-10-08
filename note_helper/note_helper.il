; note_helper.il -- single-file loader for the Note Helper plugin.
;
; Source from .cdsinit (mytool.il MUST be loaded first if you want the
; MyTool menu wire-up; if mytool.il is absent this still loads cleanly,
; the menu registration just no-ops -- see nhGui.il tail):
;
;     load("/home/yusheng/cadence_work/Test/workarea/skill_tools/note_helper/note_helper.il")
;
; To deploy elsewhere, set the dir BEFORE loading:
;
;     setq( note_helperDir "/work/path/to/note_helper/" )
;     load( strcat(note_helperDir "note_helper.il") )
;
; Sources the three nh*.il modules in dependency order. Safe to load
; multiple times (module top-level setq's are guarded with `unless boundp`;
; mtRegister refuses duplicate-label re-registration).

(unless (boundp 'note_helperDir)
  (setq note_helperDir "/home/yusheng/cadence_work/Test/workarea/skill_tools/note_helper/"))

; Auto-fix trailing slash (prefer pcre over rex, per user feedback).
(unless (pcreMatchp "/$" note_helperDir)
  (setq note_helperDir (strcat note_helperDir "/")))

; Existence check: bail with a clear error rather than a cryptic load failure.
(unless (isFile (strcat note_helperDir "nhCore.il"))
  (error
    (strcat
      "note_helper.il: note_helperDir=" note_helperDir
      " does not contain nhCore.il. Set note_helperDir (or skillTools_root "
      "via the umbrella) to the directory that DIRECTLY contains the three "
      "nh*.il files, with a trailing slash.")))

(let ((d note_helperDir))
  (load (strcat d "nhStore.il"))   ; config + module state
  (load (strcat d "nhCore.il"))    ; parse -> IR -> emit -> place
  (load (strcat d "nhGui.il")))    ; hi* form + MyTool self-register
