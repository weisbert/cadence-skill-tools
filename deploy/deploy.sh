#!/usr/bin/env bash
#
# deploy.sh -- red-zone (Linux) deployer for skill_tools.
#
# Verifies a packed tarball (from deploy/pack.ps1 on the yellow zone), backs up
# the current install, and swaps in the new one *in place*. Everything stays
# under skill_tools/ -- the PARENT directory is NEVER touched. No git, no
# network, no Python: only bash + tar + sha256sum (all base Linux 7).
#
# Managed layout (all inside skill_tools/):
#   skill_tools/.deploy/incoming/             uploaded tarball + .sha256
#   skill_tools/.deploy/staging/              full extract happens here first
#   skill_tools/.deploy/backups/<timestamp>/  previous install (keeps last N)
#
# Usage (after the one-time bootstrap below):
#   cd .../workarea/skill_tools
#   bash deploy/deploy.sh skill_tools_<hash>.tar.gz
#
# Invoke via `bash` (not ./deploy.sh): the red zone's login shell is often
# tcsh/csh, and an upload channel may drop the exec bit. `bash` needs neither.
# Run it as a script -- never `source` it (it is bash, and it exits on success).
#
# The tarball + its .sha256 sidecar should be uploaded together (typically into
# skill_tools/ itself); both are copied into .deploy/incoming/ before the swap.
#
# FIRST-TIME BOOTSTRAP (no deploy.sh on the box yet):
#   tar -xzf skill_tools_<hash>.tar.gz          # yields ./skill_tools/
#   # move ./skill_tools into place as .../workarea/skill_tools
#   # thereafter deploy/deploy.sh lives in place and handles every update.
#
# ROLLBACK: each run backs up the previous install to .deploy/backups/<ts>/.
# To revert: delete the new contents (everything but .deploy) and
#   mv .deploy/backups/<ts>/* .  (or just re-deploy an older tarball).
#
set -euo pipefail

KEEP_BACKUPS=3
SENTINEL="skill_tools.il"   # must exist at the install root -- guards against
                            # running in the wrong dir or extracting a bad archive

# --- locate ourselves: deploy.sh lives at skill_tools/deploy/deploy.sh -------
SELF="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SELF")"
TARGET="$(dirname "$SCRIPT_DIR")"     # .../skill_tools
DEPLOY="$TARGET/.deploy"
INCOMING="$DEPLOY/incoming"
STAGING="$DEPLOY/staging"
BACKUPS="$DEPLOY/backups"

die() { echo "ERROR: $*" >&2; exit 1; }
print_version() { while IFS= read -r _l; do echo "     $_l"; done < "$1"; }

# --- args --------------------------------------------------------------------
[[ $# -ge 1 ]] || die "usage: $(basename "$0") <tarball.tar.gz>"
TARBALL_SRC="$(readlink -f "$1")"
[[ -f "$TARBALL_SRC" ]] || die "tarball not found: $1"
[[ -f "$TARGET/$SENTINEL" ]] || die \
  "$TARGET/$SENTINEL missing -- not a skill_tools install. Do the one-time bootstrap first (see header)."

mkdir -p "$INCOMING" "$STAGING" "$BACKUPS"

# --- stage the tarball + sidecar into .deploy/incoming -----------------------
TAR_NAME="$(basename "$TARBALL_SRC")"
rm -rf "${INCOMING:?}/"* 2>/dev/null || true
cp -f "$TARBALL_SRC" "$INCOMING/$TAR_NAME"
[[ -f "$TARBALL_SRC.sha256" ]] && cp -f "$TARBALL_SRC.sha256" "$INCOMING/$TAR_NAME.sha256"

# --- verify checksum (abort before touching the install) ---------------------
if [[ -f "$INCOMING/$TAR_NAME.sha256" ]]; then
  sed -i 's/\r$//' "$INCOMING/$TAR_NAME.sha256"   # tolerate a CRLF sidecar (Windows-edited)
  if command -v sha256sum >/dev/null 2>&1; then
    echo ">> verifying sha256..."
    ( cd "$INCOMING" && sha256sum -c "$TAR_NAME.sha256" ) \
      || die "checksum FAILED -- aborting, install untouched."
  else
    echo "WARN: sha256sum not found; skipping checksum verification" >&2
  fi
else
  echo "WARN: no .sha256 sidecar next to the tarball; skipping checksum verification" >&2
fi

# --- extract to staging (full extract BEFORE touching the install) -----------
echo ">> extracting to staging..."
rm -rf "${STAGING:?}/"*
tar -xzf "$INCOMING/$TAR_NAME" -C "$STAGING"
NEW="$STAGING/skill_tools"
[[ -d "$NEW" ]]           || die "archive has no skill_tools/ root."
[[ -f "$NEW/$SENTINEL" ]] || die "staged package missing $SENTINEL -- bad archive."

if [[ -f "$NEW/VERSION" ]]; then echo ">> incoming version:"; print_version "$NEW/VERSION"; fi

# --- backup + swap (the only non-atomic window; rollback on any failure) -----
TS="$(date +%Y%m%d-%H%M%S)"
BK="$BACKUPS/$TS"
mkdir -p "$BK"

shopt -s dotglob nullglob

rollback() {
  trap - ERR
  echo "!! swap failed -- rolling back from $BK" >&2
  for _it in "$TARGET"/*; do
    [[ "$(basename "$_it")" == ".deploy" ]] && continue
    rm -rf "$_it"
  done
  for _it in "$BK"/*; do mv "$_it" "$TARGET"/; done
  echo "!! rollback complete -- install restored." >&2
  exit 1
}
trap rollback ERR

echo ">> backing up current install -> $BK"
for _it in "$TARGET"/*; do
  [[ "$(basename "$_it")" == ".deploy" ]] && continue
  mv "$_it" "$BK"/
done

echo ">> installing new version..."
for _it in "$NEW"/*; do
  mv "$_it" "$TARGET"/
done

# post-swap integrity check -- a bare failing test trips the ERR trap -> rollback
if [[ ! -f "$TARGET/$SENTINEL" ]]; then echo "post-swap sentinel missing" >&2; false; fi

trap - ERR
shopt -u dotglob nullglob

# --- rotate backups ----------------------------------------------------------
echo ">> rotating backups (keeping newest $KEEP_BACKUPS)..."
mapfile -t _allbk < <(ls -1dt "$BACKUPS"/*/ 2>/dev/null || true)
if (( ${#_allbk[@]} > KEEP_BACKUPS )); then
  for _old in "${_allbk[@]:KEEP_BACKUPS}"; do rm -rf "$_old"; done
fi

rm -rf "${STAGING:?}/"*

# --- done --------------------------------------------------------------------
echo
echo "OK  deployed."
if [[ -f "$TARGET/VERSION" ]]; then echo "    installed version:"; print_version "$TARGET/VERSION"; fi
echo "    previous install backed up at: $BK"
echo
echo "    NEXT -- reload in the Virtuoso CIW:"
echo "       load(\"$TARGET/$SENTINEL\")"
