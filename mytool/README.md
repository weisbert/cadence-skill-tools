# MyTool Framework

A top-level "MyTool" pulldown menu that appears rightmost-before-Help on every schematic / Maestro (ADE Assembler) / ADE-XL / hybrid Maestro+config editor window in Cadence Virtuoso. Plugins call a single registration function to add an entry; new windows inherit the menu via a 2-second `hiRegTimer` poll (the post-install trigger does not fire on IC6.1.8 — user-confirmed 2026-04-29). CIW, Library Manager, Hierarchy Editor, Layout, output viewers, and dockable side panes are intentionally excluded.

## Loading

Add one line to `workarea/.cdsinit` (the active startup file when Virtuoso is launched from `workarea/`; `~/.cdsinit` is empty in this environment):

```skill
load("/home/yusheng/cadence_work/Test/workarea/skill_tools/mytool/mytool.il")
```

This sources `mtCore.il`, `mtUtil.il`, and `mtInstall.il` in dependency order, then calls `mtBootstrap()`. The loader is idempotent: running it twice does not double-mount the menu and does not double-arm the poll timer (`(and (boundp 'mt_pollArmed) mt_pollArmed)` guard).

## Public API

| Function | Args | Returns | Notes |
|---|---|---|---|
| `mtRegister` | `t_label s_callbackFn [t_statusTip]` | `t` / `nil` | Appends to registry, refreshes all attached windows. Rejects duplicate labels. |
| `mtUnregister` | `t_label` | `t` / `nil` | Removes the first entry whose label string-equals `t_label`. |
| `mtListRegistered` | (none) | list of `(label callbackSym statusTip)` triples | Treat as read-only. |
| `mtBootstrap` | (none) | `t` | Re-registers post-install triggers (schematic / maestro / adexl), walks open windows, and arms the `hiRegTimer` poll once. Safe to call multiple times. |
| `mtRefresh` | (none) | `t` | Rebuilds the MyTool menu on every attached window (detach + re-attach). Called automatically by `mtRegister` / `mtUnregister`. |

The registry is a list of `(label callbackSym statusTip)` triples; registration order equals display order in the pulldown.

## Plugin registration pattern

A plugin module registers itself at the bottom of its main `.il` file. Use `getd` (not `functionp`) to test whether `mtRegister` is currently defined, so the plugin still loads in environments where MyTool is absent:

```skill
when( getd('mtRegister)
  mtRegister("Dreg Generator" 'dgenOpenGUI "Open the Dreg-Generator GUI"))
```

The callback symbol must be a defined SKILL function that takes no required arguments. The framework wraps it as `"<sym>()"` and passes that string to `hiCreateMenuItem`'s `?callback` argument (which is evaluated when the menu item fires).

## Behavior

- **Empty registry**: the MyTool menu still appears on every attached window, with a single disabled placeholder item ("No tools registered"). This makes it obvious that the framework loaded successfully even before any plugin registers.
- **Menu position**: inserted at index `(plus (hiGetNumMenus w) 1)` so it lands rightmost on the banner. Cadence renders the Help menu always-last regardless of banner-list index, so MyTool ends up just before Help — the conventional plugin slot.
- **New window auto-mount**: a `hiRegTimer` chain calls `mt_poll` every 2 seconds; `mt_poll` walks attachable windows via `mt_iterAttachable` and re-arms itself (`hiRegTimer` is one-shot per skuiref.pdf p.84 — `x_tenthsofSeconds`, NOT ms). The walk is errset-wrapped so a transient single-window failure (e.g. mid-teardown) doesn't kill the chain. Already-attached windows are detected via `memq` on `hiGetBannerMenus` for the `mt_menu` symbol, so the steady-state cost is just the per-window symbol-list scan. The `userPostInstallTrigger` is also registered for `schematic` / `maestro` / `adexl` for completeness — under IC6.1.8 it does not actually fire on new opens (user-confirmed 2026-04-29), but registering it is cheap and may help on future IC versions.
- **Window classification**: `mt_isAttachable` checks `hiGetBannerMenus` for `'schEditMenu` (schematic), `'maestroTools` (Maestro/ADE Assembler), or any `axl*` symbol (ADE-XL). The hybrid Maestro+config window matches via `axl*`. CIW (`ciw*`), HED (`_hed*`), Layout (`le*`), and LM all carry their own marker symbols and are skipped silently. Banner-menu probing is chosen over `geGetWindowCellView` because the latter emits GE-2067 UserWarnings on every `mtRefresh` and mis-tags the hybrid window as schematic.

## Troubleshooting

- **Menu does not appear on a window you expect**: from the CIW, run `mt_isAttachable(<windowId>)`. If `nil`, the window's banner-menu list does not contain a recognized marker — confirm the window type. If `t` but no menu, run `mtBootstrap()`; if that fixes it the poll has not ticked yet (next sweep is within 2s).
- **Menu does not refresh after registration**: confirm `mtRegister` returned `t` (a duplicate label or non-string label returns `nil` with a warning). If it returned `t`, run `mtRefresh()` manually.
- **Callback fires the wrong function**: the callback symbol you passed must resolve to a defined function at click time. Check with `getd('yourFn)`.
- **Poll appears stalled** (no auto-attach on new opens, only manual `mtBootstrap` works): check `mt_pollArmed` — should be `t`. If `nil`, the chain was never armed: run `mtBootstrap()`. The chain is single-link — if a `hiRegTimer` re-arm ever fails (returns `nil`) the chain dies silently. To revive: `setq(mt_pollArmed nil); mtBootstrap()` re-arms.

## Files

- `mytool.il` -- loader; sources the three module files, calls `mtBootstrap`
- `mtCore.il` -- registry storage, `mt_buildMenu`, `mt_detachFromWindow`, `mtRegister` / `mtUnregister` / `mtListRegistered` / `mtRefresh`
- `mtInstall.il` -- `mt_attachToWindow`, `mt_userPostInstallTrigger`, `mt_poll`, `mtBootstrap`
- `mtUtil.il` -- banner-menu-based window classifier (`mt_isAttachable`, `mt_iterAttachable`)
