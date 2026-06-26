#!/usr/bin/env bash
# vh_dump_debug.sh -- dump the MINIMAL set needed to REPRODUCE a verilog_helper build
# off-site, as ONE copy-pasteable .txt written INTO the build dir (air-gap: no tarball, no
# /tmp). Reconstruct with vh_undump_debug.py, then re-run locally.
#
# Minimal = exactly what xrun needs to re-elaborate: the compiled sources (export/), the sim
# glue that carries the TB + the exact xrun flags (run.sh/setup_env.sh/ext_libs + sim *.vams),
# and the PATHS of the external -v libs. NOT included (regenerable / not needed to reproduce):
# orig/, _work/, xrun.log, manifests, vh_diag.txt -- ask for a specific PDK -v file only if a
# repro actually needs it.
#
#   bash vh_dump_debug.sh <build-dir> [out.txt]
#   e.g. bash vh_dump_debug.sh /data/.../workarea/verilogBox/LPBT_NDIV
#   -> <build-dir>/vh_debug.txt   ; `cat` it, select all, paste it back.
set -u
BUILD="${1:?usage: bash vh_dump_debug.sh <build-dir> [out.txt]}"
[ -d "$BUILD" ] || { echo "ERROR: not a dir: $BUILD" >&2; exit 1; }
BUILD="$(cd "$BUILD" && pwd)"
OUT="${2:-$BUILD/vh_debug.txt}"

emit() {  # emit <label> <file>
  local label="$1" f="$2"
  [ -f "$f" ] || return 0
  echo "===== FILE: $label  ($(wc -l < "$f" 2>/dev/null) lines, $(wc -c < "$f" 2>/dev/null) bytes) ====="
  cat "$f"
  echo "===== END: $label ====="
  echo
}

{
  echo "########## VH DEBUG DUMP (minimal repro set) ##########"
  echo "build: $BUILD"
  echo "host : $(hostname 2>/dev/null)   user: ${USER:-?}"
  for v in "$BUILD/../../skill_tools/VERSION" "$BUILD/../../../skill_tools/VERSION"; do
    [ -f "$v" ] && { echo "VERSION:"; cat "$v"; break; }
  done
  echo "######################################################"
  echo

  # export/ -- the compiled sources: struct + every gathered leaf (incl. div2). REQUIRED.
  for f in "$BUILD"/export/*; do [ -f "$f" ] && emit "export/$(basename "$f")" "$f"; done

  # sim glue -- exact xrun command, -v flags, the TB and any stubs. REQUIRED.
  for f in run.sh setup_env.sh ext_libs.list; do emit "sim/$f" "$BUILD/sim/$f"; done
  for f in "$BUILD"/sim/*.vams; do [ -f "$f" ] && emit "sim/$(basename "$f")" "$f"; done

  # referenced external -v libs: PATHS only (so I know the externals; ask for a file if needed)
  echo "===== referenced -v libs (paths) ====="
  grep -rhoE '/[A-Za-z0-9_./+-]+\.(v|va|vams)' \
    "$BUILD/sim/run.sh" "$BUILD/sim/setup_env.sh" "$BUILD/sim/ext_libs.list" 2>/dev/null | sort -u
  echo "===== END -v libs ====="
} > "$OUT"

echo "=== wrote $OUT  ($(wc -l < "$OUT") lines, $(du -h "$OUT" 2>/dev/null | cut -f1)) ==="
echo "cat it, select ALL, paste it back."
