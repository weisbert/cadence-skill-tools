; mtCore.il -- MyTool framework: registry storage + pulldown-menu construction.
;
; Load order: this file must be loaded BEFORE mtInstall.il (mtInstall calls
; mt_buildMenu and mtRefresh, both defined here). mytool.il enforces order.
;
; The registry mt_registry is a list of (label callbackSym statusTip) triples.
; Registration order = display order in the MyTool pulldown.
;
; Public API exported from this file:
;   mtRegister(label callbackSym [statusTip])  -> t / nil
;   mtUnregister(label)                        -> t / nil
;   mtListRegistered()                         -> list (treat read-only)
;   mtRefresh()                                -> t   ; rebuild on every attached window
;
; Private:
;   mt_registry   -- module-global list of triples
;   mt_menu       -- menu handle symbol (used by hiCreatePulldownMenu)
;   mt_buildMenu()-- build the hi menu object from current mt_registry

; ---------------------------------------------------------------------------
; Module globals -- idempotent init (no defvar in SKILL).
; Identifier: mt_registry (snake_case; no *foo* — parser splits on *).
; ---------------------------------------------------------------------------

(unless (boundp 'mt_registry) (setq mt_registry nil))

; ---------------------------------------------------------------------------
; Registry mutation
; ---------------------------------------------------------------------------

; mtRegister: append (label callbackSym statusTip) to mt_registry.
; Reject duplicate labels (string-equal). Refresh menus on success.
(defun mtRegister (label callbackSym @optional statusTip "tsg")
  (cond
    ((not (stringp label))
      (warn "mtRegister: label must be a string, got %L\n" label) nil)
    ((not (symbolp callbackSym))
      (warn "mtRegister: callbackSym must be a symbol, got %L\n" callbackSym) nil)
    ((exists e mt_registry (equal (car e) label))
      (warn "mtRegister: label %L already registered; refusing duplicate.\n" label)
      nil)
    (t
      (setq mt_registry (append mt_registry (list (list label callbackSym (or statusTip label)))))
      (mtRefresh)
      t)))

; mtUnregister: remove first entry whose label string-equals `label`. Refresh.
(defun mtUnregister (label "t")
  (let ((before (length mt_registry)))
    (setq mt_registry (setof e mt_registry (nequal (car e) label)))
    (cond
      ((equal (length mt_registry) before)
        (warn "mtUnregister: label %L not found.\n" label) nil)
      (t (mtRefresh) t))))

; Defensive read-only accessor. SKILL has no real immutability; callers
; should not mutate the returned list. We hand back the registry directly
; (copy would force callers to retain only the snapshot).
(defun mtListRegistered ()
  mt_registry)

; ---------------------------------------------------------------------------
; Menu construction
; ---------------------------------------------------------------------------

; Produce the list of menu-item handles for the current registry. If
; mt_registry is empty, return a single disabled placeholder so the
; MyTool menu is always visible (even before plugins load).
;
; Each callback symbol is wrapped in a one-line string "<sym>()" because
; hiCreateMenuItem's ?callback argument is a STRING that gets evaluated
; (skuiref.pdf p.202).
(defun mt_buildMenuItems ()
  (cond
    ((null mt_registry)
      (list
        (hiCreateMenuItem        ; Ref: skuiref.pdf p.200
          ?name      'mt_placeholder
          ?itemText  "No tools registered"
          ?disable   t)))
    (t
      (mapcar
        (lambda (entry)
          (let ((label   (nth 0 entry))
                (cbSym   (nth 1 entry))
                (tip     (nth 2 entry))
                (handle  (concat 'mt_item_ (gensym))))
            (hiCreateMenuItem    ; Ref: skuiref.pdf p.200
              ?name     handle
              ?itemText label
              ?callback (strcat (symbolToString cbSym) "()")
              ?statusTip (or tip label))))
        mt_registry))))

; mt_buildMenu: returns a hi pulldown-menu struct keyed on the fixed symbol
; mt_menu. Re-using the same symbol is safe; hiCreatePulldownMenu rebinds
; the menu in-place.
(defun mt_buildMenu ()
  (hiCreatePulldownMenu          ; Ref: skuiref.pdf p.204
    'mt_menu
    "MyTool"
    (mt_buildMenuItems)))

; ---------------------------------------------------------------------------
; Refresh: walk every attachable window, drop any existing MyTool menu,
; then re-attach so the new entry list shows up.
;
; Removal must check existence first -- hiDeleteBannerMenu on an empty
; slot raises an error per skuiref.pdf p.1104.
;
; mt_iterAttachable + mt_attachToWindow live in mtUtil.il / mtInstall.il.
; ---------------------------------------------------------------------------
(defun mtRefresh ()
  (mt_iterAttachable
    (lambda (w)
      (mt_detachFromWindow w)
      (mt_attachToWindow w)))
  t)

; mt_detachFromWindow: if 'mt_menu is in this window's banner menu list,
; delete it by position. Safe if not present.
(defun mt_detachFromWindow (w "g")
  (let ((menus (hiGetBannerMenus w))   ; Ref: skuiref.pdf p.1107
        (idx 0) (found nil))
    (when menus
      (foreach m menus
        (when (and (not found) (equal m 'mt_menu))
          (setq found idx))
        (setq idx (plus idx 1)))
      (when found
        (hiDeleteBannerMenu w found)))) ; Ref: skuiref.pdf p.1104
  t)
