; verilog_helper.il -- single-file loader for the Verilog Helper plugin.
;
; The tool itself is Python (stdlib-only vh_*.py CLIs); the ONLY SKILL file is
; the thin launcher GUI (vhGui.il). This loader just resolves verilog_helperDir
; and sources vhGui.il. Source from .cdsinit (load mytool/mytool.il first if you
; want the MyTool menu wire-up; if absent this still loads, the registration
; just no-ops -- see vhGui.il tail):
;
;     load("/home/yusheng/cadence_work/Test/workarea/skill_tools/verilog_helper/verilog_helper.il")
;
; To deploy elsewhere, set the dir BEFORE loading:
;
;     setq( verilog_helperDir "/work/path/to/verilog_helper/" )
;     load( strcat(verilog_helperDir "verilog_helper.il") )
;
; Safe to load multiple times (vhGui.il top-level setq's are guarded with
; `unless boundp`; mtRegister refuses duplicate-label re-registration).

(unless (boundp 'verilog_helperDir)
  (setq verilog_helperDir "/home/yusheng/cadence_work/Test/workarea/skill_tools/verilog_helper/"))

; Auto-fix trailing slash (prefer pcre over rex, per user feedback).
(unless (pcreMatchp "/$" verilog_helperDir)
  (setq verilog_helperDir (strcat verilog_helperDir "/")))

; Existence check: bail with a clear error rather than a cryptic load failure.
(unless (isFile (strcat verilog_helperDir "vhGui.il"))
  (error
    (strcat
      "verilog_helper.il: verilog_helperDir=" verilog_helperDir
      " does not contain vhGui.il. Set verilog_helperDir (or skillTools_root "
      "via the umbrella) to the directory that DIRECTLY contains vhGui.il and "
      "the vh_*.py CLIs, with a trailing slash.")))

(load (strcat verilog_helperDir "vhGui.il"))
