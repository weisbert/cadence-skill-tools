; relkit.il -- plugin entry for relkit: MyTool > "RelStudio..." (RelStudio
; reliability flow driven from Maestro: aging / DEOS / EMIR).
;
; Load (the skill_tools.il umbrella does this for you):
;
;     load("/abs/path/to/skill_tools/relkit/relkit.il")
;
; The directory is self-located from the load() path via get_filename(piport)
; (same trick as skill_tools.il / skillbridge/sbStart.il). Fallbacks, in order:
; a pre-bound relkitDir (setq in .cdsinit), then skillTools_root + "relkit/".
; The resolved directory (WITH trailing "/") is stored in the global relkitDir.
;
; Loads the rk*.il modules in dependency order, then registers the MyTool entry.
; Safe to load repeatedly: modules guard their globals with boundp, and
; mtRegister refuses duplicate labels. Loading never needs Python (plan D12):
; Python runs only as a subprocess when the user presses a button.
;
; Modules (docs/CONTRACT.md section 6 lists every public function):
;   rkSite.il    site config + JSON/TSV/path utilities
;   rkMae.il     Maestro context: session/test/design/corners/vars/netlist
;   rkResults.il result tables, schematic jump, DUT picker, open reports
;   rkAged.il    R1: aged corners in Maestro, delta table
;   rkIpc.il     run relkit.py subcommands asynchronously
;   rkGui.il     the panel (rkOpenPanel)

(setq rk_version "0.1.0")

(let ((selfRaw (errset (get_filename piport) nil))
      (prior (and (boundp 'relkitDir) relkitDir))
      selfPath selfDir resolved)
  (when selfRaw
    (setq selfPath (car selfRaw))
    (when (stringp selfPath)
      (setq selfPath (pcreReplace (pcreCompile "^ +| +$") selfPath "" 0))
      (setq selfDir (pcreReplace (pcreCompile "/[^/]+$") selfPath "" 1))
      ; A relative load() path -> make it absolute (Python subprocesses need it).
      (when (and (nequal selfDir "") (nequal (substring selfDir 1 1) "/"))
        (setq selfDir (strcat (getWorkingDir) "/" selfDir)))))
  (cond
    ((and selfDir (nequal selfDir "") (isFile (strcat selfDir "/rkSite.il")))
      (setq resolved (strcat selfDir "/")))
    ((and (stringp prior) (nequal prior ""))
      (setq resolved (if (pcreMatchp "/$" prior) prior (strcat prior "/"))))
    ((and (boundp 'skillTools_root) (stringp skillTools_root))
      (setq resolved (strcat skillTools_root "relkit/")))
    (t
      (error "relkit.il: cannot locate the relkit directory. load() relkit.il by its absolute path, or setq relkitDir first.")))
  (unless (isFile (strcat resolved "rkSite.il"))
    (error (strcat "relkit.il: relkitDir=" resolved
                   " does not contain rkSite.il. Point relkitDir at the directory"
                   " that DIRECTLY contains the rk*.il files, with a trailing slash.")))
  (setq relkitDir resolved))

(let ((d relkitDir))
  (load (strcat d "rkSite.il"))     ; site config + JSON/TSV utilities (no deps)
  (load (strcat d "rkMae.il"))      ; Maestro context
  (load (strcat d "rkResults.il"))  ; result tables / schematic jump / DUT pick
  (load (strcat d "rkAged.il"))     ; R1 aged corners
  (load (strcat d "rkIpc.il"))      ; Python subprocess calls
  (load (strcat d "rkGui.il")))     ; panel

(printf "[relkit] v%s loaded from %s\n" rk_version relkitDir)

; MyTool plugin registration. getd guard so relkit still loads without the
; mytool framework; mtRegister itself refuses a duplicate label on reload.
(when (and (getd 'mtRegister)
           (not (and (getd 'mtListRegistered)
                     (exists e (mtListRegistered) (equal (car e) "RelStudio...")))))
  (mtRegister "RelStudio..." 'rkOpenPanel "Open the relkit RelStudio panel (aging / DEOS / EMIR)"))
