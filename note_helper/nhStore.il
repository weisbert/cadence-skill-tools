; nhStore.il -- note-helper config + module state.
;
; v1 keeps styling config in a default plist (no file persistence yet --
; the per-run table TEXT is intentionally transient, like dreg_gen's
; customVars; only durable STYLE preferences would ever be persisted, and
; that is deferred to a later milestone). See REQUIREMENTS.md s.13 item 6.
;
; SKILL note: no let* (use nested let / let+setq); plists are nil-headed
; DPLs read with get (Ref dreg_gen/dgenStore.il convention).

; ---------------------------------------------------------------------------
; Module-global state (idempotent: never clobber on reload).
; ---------------------------------------------------------------------------

; Deferred ghost-placement state. All three Output modes now place by dragging
; a SYMBOL master with the native schHiCreateInst ghost (so a live preview
; follows the cursor, exactly like pressing i to insert a symbol). The button
; callback only ARMS the placement and stashes these globals; the interactive
; command is launched from an hiRegTimer tick (nh_launchPlace) AFTER the form
; callback returns -- starting an enterfunction directly inside a form callback
; silently fails to arm, which was the "click does nothing" bug.
;   nh_plLib/nh_plCell/nh_plView -- master to drag (lib + cell + "symbol")
;   nh_plCv  -- target schematic cellview
;   nh_plWin -- its window (set current before schHiCreateInst so the command
;               targets the schematic, not the still-focused form)
;   nh_plTmp -- loose mode only: the throwaway temp symbol cell name to flatten
;               into loose note shapes + delete after placement; nil otherwise
;   nh_plPoll-- idle-tick counter for the loose flatten poll (nh_loosePoll)
(unless (boundp 'nh_plLib)    (setq nh_plLib nil))
(unless (boundp 'nh_plCell)   (setq nh_plCell nil))
(unless (boundp 'nh_plView)   (setq nh_plView "symbol"))
(unless (boundp 'nh_plCv)     (setq nh_plCv nil))
(unless (boundp 'nh_plWin)    (setq nh_plWin nil))
(unless (boundp 'nh_plTmp)    (setq nh_plTmp nil))
(unless (boundp 'nh_plMaster) (setq nh_plMaster nil))   ; temp master cv (loose)
(unless (boundp 'nh_plPoll)   (setq nh_plPoll 0))
; Monotonic counter so each loose placement gets a unique temp cell name
; (no clash with a leftover temp cell from a prior, still-cleaning placement).
(unless (boundp 'nh_looseSeq) (setq nh_looseSeq 0))

; Top-level scratch global for the evalstring form-field write idiom
; (mirrors dgen's nh_tmpFieldVal; see nhGui.il nh_setFieldVal).
(unless (boundp 'nh_tmpVal) (setq nh_tmpVal nil))

; Stashed Tab-page field handles + scratch handle for nh_setHandleVal. Fields
; inside a hiCreateTabField page are not reachable as form->name, so the GUI
; keeps their handles here and the callbacks read/write them directly.
; Default folder for the GUI file-browse buttons. nil => resolve at open time:
; $WORK_ROOT2 (the company workarea), else the workarea derived from
; note_helperDir, else ".". setq this to pin a fixed browse directory.
(unless (boundp 'nh_browseDir)  (setq nh_browseDir nil))

(unless (boundp 'nh_fInput)    (setq nh_fInput nil))
(unless (boundp 'nh_fMdPath)   (setq nh_fMdPath nil))
(unless (boundp 'nh_fSvg)      (setq nh_fSvg nil))
(unless (boundp 'nh_fVecW)     (setq nh_fVecW nil))
(unless (boundp 'nh_tmpHandle) (setq nh_tmpHandle nil))

; Feature-A (vector import, M4) external-parser wiring. The SVG parser is a
; standalone, Cadence-independent Python CLI (note_helper/svg2ir/nh_svg2ir.py)
; invoked via system(); it writes a SKILL list literal of IR DPLs that the IL
; side reads back with infile/read. Both are overridable (a site python3, a
; relocated script) by setq-ing the global before/after loading.
;   nh_pythonCmd   -- shell command that runs Python 3 (default "python3").
;   nh_svg2irScript-- absolute path to nh_svg2ir.py; nil => derive from
;                     note_helperDir at call time (nh_svg2irScriptPath).
;   nh_toolboxScript-- absolute path to the Python toolbox GUI (toolbox.py);
;                     nil => derive from note_helperDir (nh_toolboxScriptPath).
;   nh_pyEnvScrub  -- controls the shell-env prefix used to launch a system
;                     Python GUI. The right answer is SITE-DEPENDENT, and is
;                     OPPOSITE on our two boxes:
;                       * a SELF-CONTAINED Python ships its own Tcl/Tk, which
;                         Cadence's LD_LIBRARY_PATH + TCL_LIBRARY otherwise
;                         SHADOW -- it needs the env STRIPPED;
;                       * a GRID-INTEGRATED Python GETS its libtcl/libtk AND
;                         its init.tcl/tk.tcl THROUGH Cadence's env -- it needs
;                         the env LEFT ALONE; stripping LD_LIBRARY_PATH breaks
;                         the loader ("libtk8.6.so: cannot open shared object
;                         file") and stripping TCL_LIBRARY breaks the script
;                         lookup ("Can't find a usable init.tcl").
;                     Values: nil => AUTO (default): preflight both -- inherit
;                       first, then strip -- and use whichever makes tkinter
;                       usable (nhLaunchToolbox/nh_pyPickEnv); "" => force
;                       inherit (no scrub); "env -u LD_LIBRARY_PATH -u
;                       TCL_LIBRARY -u TK_LIBRARY" => force strip.
(unless (boundp 'nh_pythonCmd)     (setq nh_pythonCmd "python3"))
(unless (boundp 'nh_svg2irScript)  (setq nh_svg2irScript nil))
(unless (boundp 'nh_toolboxScript) (setq nh_toolboxScript nil))
(unless (boundp 'nh_pyEnvScrub)    (setq nh_pyEnvScrub nil))

; ---------------------------------------------------------------------------
; Default styling config.
;   fontHeight  -- note label height, user units (schCreateNoteLabel default
;                  is 0.0625; 0.125 reads better for a table).
;   charAspect  -- monospace glyph-advance / fontHeight. MEASURED on live
;                  IC6.1.8: the "fixed" font (the only true monospace among
;                  the note fonts) advances 1.435*height per glyph; 1.45 adds
;                  a hair of margin so glyphs never touch the grid lines.
;   paddingRatio-- cell inset as a FRACTION of font height. Keeping it
;                  proportional makes the whole table scale uniformly with
;                  font height (text + columns + rows + gaps all together),
;                  so font height alone is the master "size" knob.
;   gridStyle   -- 'full (box + all rules) | 'hrules (box + horizontal) |
;                  'boxheader (box + header rule only).
;   maxColWidth -- max chars per column before truncating with "~"; 0 = off.
;   headerScale -- header-row font multiplier (no bold available).
; ---------------------------------------------------------------------------

(defun nh_cfgDefault ()
  (list nil
    'fontHeight   0.125
    'charAspect   1.45
    'paddingRatio 0.4
    'gridStyle    'full
    'maxColWidth  0
    'headerScale  1.15))

; nh_cfgGet: value of key from cfg, falling back to nh_cfgDefault. A key
; absent from cfg (get -> nil) takes the default; an explicit value (incl.
; the integer 0 for maxColWidth) is honored.
(defun nh_cfgGet (cfg key)
  (let ((v (and cfg (get cfg key))))
    (if (null v) (get (nh_cfgDefault) key) v)))
