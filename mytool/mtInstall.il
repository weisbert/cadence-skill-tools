; mtInstall.il -- MyTool framework: window attachment + lifecycle.
;
; Load order: load AFTER mtCore.il and mtUtil.il. mytool.il enforces order.
;
; Public:
;   mtBootstrap()               -- idempotent; auto-called from mytool.il
;
; Private (snake_case):
;   mt_attachToWindow(w)        -- de-dups, then hiInsertBannerMenu rightmost
;   mt_userPostInstallTrigger(w)-- registered with deRegUserTriggers

; mt_attachToWindow: idempotent attach. If 'mt_menu already in this
; window's banner-menu symbol list (per skuiref.pdf p.1107 the list
; contains symbols, e.g. (schEditMenu schAddMenu ...)), this is a no-op.
; Otherwise build the menu via mt_buildMenu and insert at a position
; greater than the current menu count: per skuiref.pdf p.1110 this places
; the new menu "to the right of all other menus (except the Help button or
; menu)" -- i.e. just before Help, the Cadence convention for plugin menus.
(defun mt_attachToWindow (w "g")
  (cond
    ((not (mt_isAttachable w)) nil)
    ((memq 'mt_menu (hiGetBannerMenus w))   ; Ref: skuiref.pdf p.1107
      t)
    (t
      (hiInsertBannerMenu                   ; Ref: skuiref.pdf p.1109
        w
        (mt_buildMenu)
        (plus (hiGetNumMenus w) 1)))))      ; Ref: skuiref.pdf p.1108

; mt_userPostInstallTrigger: would be invoked by Cadence after a new
; schematic / maestro / adexl window finishes installing. Per skdfref.pdf
; p.2057 (userPostInstallTrigger) the function receives a single l_args
; list with the window as first element. NOT ACTUALLY FIRED under IC6.1.8
; (user-confirmed 2026-04-29: every freshly-opened editor required manual
; mtBootstrap until the hiRegTimer poll in mt_poll was added). Kept and
; registered in mtBootstrap on the chance that future IC versions honor it;
; if/when it does fire, it forwards to mt_attachToWindow which already
; de-dups via hiGetBannerMenus.
(defun mt_userPostInstallTrigger (args "l")
  (let ((w (car args)))
    (when w (mt_attachToWindow w)))
  t)

; mt_poll: timer callback. Sweeps all attachable windows so any newly-opened
; schematic / maestro / adexl gets its menu. Necessary because under IC6.1.8
; the userPostInstallTrigger registers without complaint (DEBASE-102203
; confirms) but does not actually fire on new-window installs in practice
; (user-confirmed 2026-04-29: every freshly-opened editor required manual
; mtBootstrap until the poll was added). Self-rearms because hiRegTimer is
; one-shot per skuiref.pdf p.84. The attach helper de-dups via memq on
; hiGetBannerMenus, so the steady-state cost is only the per-window
; symbol-list scan (~sub-ms across <10 windows).
;
; Each tick is wrapped in errset so a transient failure on one window
; (e.g. a window in the middle of being torn down) doesn't break the
; re-arm and kill the chain.
(defun mt_poll ()
  (errset (mt_iterAttachable 'mt_attachToWindow) t)
  (hiRegTimer "mt_poll()" 20)            ; Ref: skuiref.pdf p.84 (tenths-of-seconds, NOT ms; 20 = 2s)
  t)

; mtBootstrap: idempotent setup. Steps:
;   1. (Re)register the post-install trigger for each in-scope view type
;      (schematic, maestro, adexl). Per skdfref.pdf p.1962 deRegUserTriggers
;      signature is (viewType [appTrigger [menuTrigger [postInstallTrigger]]]),
;      so we pass nil/nil for the first two slots and our symbol for the
;      third. Re-registering for the same view type warns (DEBASE-102203)
;      but reaches the desired end state. Each call is wrapped in errset:
;      if a view type is unknown on this Cadence install, that registration
;      fails but does not block the others. (Trigger does not actually fire
;      under IC6.1.8 -- see mt_poll for the workaround -- but we register
;      anyway in case future IC versions fix it.)
;   2. Walk currently-open windows; attach to in-scope ones. The attach
;      helper de-dups via hiGetBannerMenus, so re-running is safe.
;   3. Arm the mt_poll timer chain (idempotent across reloads via
;      mt_pollArmed sentinel). This is the actual auto-mount mechanism
;      since the post-install trigger is unreliable.
;   4. Return t.
(defun mtBootstrap ()
  (errset (deRegUserTriggers "schematic" nil nil 'mt_userPostInstallTrigger) t)  ; Ref: skdfref.pdf p.1962
  (errset (deRegUserTriggers "maestro"   nil nil 'mt_userPostInstallTrigger) t)
  (errset (deRegUserTriggers "adexl"     nil nil 'mt_userPostInstallTrigger) t)
  (mt_iterAttachable 'mt_attachToWindow)
  (unless (and (boundp 'mt_pollArmed) mt_pollArmed)  ; covers unbound AND bound-to-nil cases
    (setq mt_pollArmed t)
    (hiRegTimer "mt_poll()" 20))         ; Ref: skuiref.pdf p.84
  t)
