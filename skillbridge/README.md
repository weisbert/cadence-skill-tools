# skillbridge

Generic launcher for the [skillbridge](https://github.com/unihd-cag/skillbridge) Python ↔ SKILL channel.
Drop this directory anywhere, point `.cdsinit` at `sbStart.il`, and you have a live bridge to a running Virtuoso.

## Files

| File | Purpose |
|------|---------|
| `sbStart.il` | Launcher. Self-locates via `get_filename(piport)`, loads the sibling `python_server.il`, then calls `pyStartServer` with a sane Python path. |
| `python_server.il` | Stock skillbridge SKILL server (verbatim from `skillbridge install-skill`). Defines `pyStartServer / pyKillServer / pyShowLog / pyRunScript`. |
| `python_server.py` | Stock skillbridge Python helper. `pyStartServer` spawns this as a subprocess; it owns the Unix socket. |

## Install

In the Virtuoso launch directory's `.cdsinit`:

```skill
load("/abs/path/to/skill_tools/skillbridge/sbStart.il")
```

The path must be absolute — the script self-locates from `piport`, which works whether loaded from `.cdsinit` or pasted into CIW, but only with an absolute argument to `load`.

## Environment overrides

| Var | Default | Notes |
|-----|---------|-------|
| `SKILLBRIDGE_PYTHON` | `/usr/bin/python3` | Must be an absolute path. Bare `python` will fail on hosts that ship only `python3`. |
| `SKILLBRIDGE_LOG_DIRECTORY` | `.` | Where `skillbridge_skill.log` lands (read by stock `python_server.il`). |

## Behavior

1. `sbStart.il` resolves its own directory.
2. Loads `python_server.il` (re-defines all `py*` SKILL functions).
3. Calls `pyStartServer(?python …)` once.
4. Resulting Unix socket: `/tmp/skill-server-default.sock`.

`pyStartServer` is idempotent — re-loading `sbStart.il` does **not** restart the server. To restart explicitly:

```skill
pyKillServer()
load("/abs/path/to/skill_tools/skillbridge/sbStart.il")
```

## Python client

```python
from skillbridge import Workspace
ws = Workspace.open()                       # connects to default socket
cv = ws.ge.get_edit_cell_view()
print(ws['dbGetq'](cv, 'cellName'))
```

## Caveats

- Bridge dies when Virtuoso exits — auto-recreated on next launch.
- Stale socket after a Python client crash: recover by re-loading `sbStart.il` in CIW.
- `hiCreateAppForm` + `hiDisplayForm` over the bridge **blocks** the evaluator until the form closes. Do not panic-kill clients in that state — see `MyRunner` history for the cascade. Prefer `(hiFormCancel formSym)` immediately after construction in scripted form tests.
