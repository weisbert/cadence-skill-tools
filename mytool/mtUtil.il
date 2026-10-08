; mtUtil.il -- MyTool framework: window classification helpers.
;
; Load order: load anytime after mtCore.il. mtInstall.il calls
; mt_iterAttachable, so this file must be loaded before mtInstall.il.
;
; Helpers exported (private; module-internal snake_case):
;   mt_isAttachable(w)      -- t iff w is a schematic / Maestro / ADE-XL editor
;   mt_iterAttachable(proc) -- call proc(w) on every attachable window
;
; Classification uses banner-menu symbols (hiGetBannerMenus, p.1107) rather
; than geGetWindowCellView. Banner-menu probing is silent on non-graph
; windows (CIW, LM, plot, output viewers all just return their own menu
; lists), avoiding the GE-2067 UserWarning that geGetWindowCellView emits.
;
; In scope (PLAN.md scope iteration 2026-04-29): pure schematic editor,
; Maestro / ADE Assembler, ADE-XL, and hybrid Maestro+schematic-config.
; Excluded: CIW, Library Manager, Hierarchy Editor, Layout editor,
; output viewers, dockable side panes.

; mt_isAttachable: true iff w's banner-menu list contains a marker
; identifying it as a schematic / Maestro / ADE-XL editor.
;   schematic         -> 'schEditMenu (stable since IC5)
;   Maestro/Assembler -> 'maestroTools (also has axl* family)
;   ADE-XL            -> any 'axl*' menu (axlFileMenu, axlPulldownMenu*, ...)
; CIW only has 'ciw*' menus; HED only '_hed*'; Layout only 'le*'; LM has
; its own. None of those match the predicates below.
(defun mt_isAttachable (w "g")
  (let ((menus (errset (hiGetBannerMenus w) t))   ; Ref: skuiref.pdf p.1107
        (match nil))
    (when menus (setq menus (car menus)))         ; unwrap errset success
    (foreach m menus
      (when (and (not match) (symbolp m))
        (when (or (equal m 'schEditMenu)
                  (equal m 'maestroTools)
                  (rexMatchp "^axl" (symbolToString m)))
          (setq match t))))
    match))

; mt_iterAttachable: call proc(w) for each window in hiGetWindowList('window)
; where mt_isAttachable(w). 'window filter excludes session and dockable
; windows (skuiref.pdf p.945). proc may be a lambda, a symbol, or any
; callable; use g (any type).
(defun mt_iterAttachable (proc "g")
  (foreach w (hiGetWindowList 'window)   ; Ref: skuiref.pdf p.945
    (when (mt_isAttachable w)
      (funcall proc w)))
  t)
