; dreg_gen.il -- single-file loader for the Dreg Generator plugin.
;
; Source from .cdsinit (mytool.il MUST be loaded first if you want the
; MyTool menu wire-up; if mytool.il is absent this still loads cleanly,
; the menu registration just no-ops -- see dgenGui.il tail):
;
;     load("/home/yusheng/cadence_work/Test/workarea/skill_tools/dreg_gen/dreg_gen.il")
;
; To deploy to another machine, set the dir BEFORE loading:
;
;     setq( dreg_genDir "/work/path/to/dreg_gen/" )
;     load( strcat(dreg_genDir "dreg_gen.il") )
;
; Sources the seven dgen*.il modules in dependency order. Safe to load
; multiple times (each module's top-level setq's are guarded with
; `unless boundp`; mtRegister refuses duplicate-label re-registration).

(unless (boundp 'dreg_genDir)
  (setq dreg_genDir "/home/yusheng/cadence_work/Test/workarea/skill_tools/dreg_gen/"))

(let ((d dreg_genDir))
  (load (strcat d "dgenPinScan.il"))    ; data layer: scan DUT pins
  (load (strcat d "dgenStore.il"))      ; spec serialization + last-state
  (load (strcat d "dgenSymbol.il"))     ; symbol generator
  (load (strcat d "dgenVerilogA.il"))   ; .va writer
  (load (strcat d "dgenCDF.il"))        ; CDF parameter wirer
  (load (strcat d "dgenRun.il"))        ; orchestrator (symbol -> .va -> CDF)
  (load (strcat d "dgenGui.il")))       ; modeless GUI + MyTool plugin self-register
