# deploy — air-gapped update pipeline for `skill_tools`

The red zone (production Linux) has **no network and no git**, so it can't
`git pull`. This pipeline ships the committed code across three zones as a plain
tarball:

```
dev (linux8) ──git push──▶ GitHub ──git pull──▶ yellow (Windows) ──upload──▶ red (linux7)
                                                   pack.ps1                    deploy.sh
```

The package is built with `git archive`, so it is **100% git-free** (no `.git/`,
no `.gitattributes`/`.gitignore`, no `pack.ps1`, no `PLAN.md` — all
`export-ignore`d) and immune to the classic Windows→Linux traps: paths are
always `/`, text is LF (read from committed blobs, not the Windows working
tree), and the exec bit on `deploy.sh` is preserved.

## 1. Yellow zone (Windows) — pack

After `git pull`, in the `skill_tools` repo:

```powershell
powershell -ExecutionPolicy Bypass -File deploy\pack.ps1
```

Produces, under `deploy\dist\`:

- `skill_tools_<shorthash>.tar.gz`
- `skill_tools_<shorthash>.tar.gz.sha256`

Needs only **git + PowerShell** (no Python, no external tar). It packages the
committed `HEAD` — commit & push first; uncommitted changes are *not* included
(you'll get a warning).

Upload **both** files to the red zone, into `.../workarea/skill_tools/`.

## 2. Red zone (Linux) — deploy

```bash
cd .../workarea/skill_tools
./deploy/deploy.sh skill_tools_<shorthash>.tar.gz
```

It verifies the sha256, extracts to staging, **backs up** the current install to
`.deploy/backups/<timestamp>/` (keeps the newest 3), then swaps the new content
in place. **Only `skill_tools/` is touched — the parent dir is never modified.**
On any failure during the swap it auto-rolls-back to the backup.

Then, in the Virtuoso CIW:

```skill
load(".../workarea/skill_tools/skill_tools.il")
```

## First-time bootstrap (no `deploy.sh` on the box yet)

`deploy.sh` ships *inside* the package, so it self-refreshes on every update —
but the very first time there's nothing to run it with. Once:

```bash
cd .../workarea
tar -xzf skill_tools_<shorthash>.tar.gz   # yields ./skill_tools/
# move/merge ./skill_tools into place as .../workarea/skill_tools
```

After that, `deploy/deploy.sh` is in place and handles every future update.

## Rollback

Each deploy backs up the previous install to `.deploy/backups/<timestamp>/`.
To revert manually:

```bash
cd .../workarea/skill_tools
# remove current contents (everything except .deploy), then:
mv .deploy/backups/<timestamp>/* .
```

Or simply re-deploy an older tarball.

## Layout (all runtime state stays under `skill_tools/`)

```
skill_tools/
├── deploy/{pack.ps1, deploy.sh, README.md}
├── VERSION                       # stamped by git archive; `cat` to see commit+date
└── .deploy/                      # runtime only (gitignored), never leaves red zone
    ├── incoming/                 # uploaded tarball + .sha256
    ├── staging/                  # full extract before swap
    └── backups/<timestamp>/      # previous installs (last 3)
```
