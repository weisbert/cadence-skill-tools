#!/usr/bin/env bash
# vh_dump_debug.sh -- dump a verilog_helper BUILD dir into ONE copy-pasteable .txt so a
# dead/failed run can be mirrored + reproduced off-site. Air-gap friendly: NO tarball, just
# text you select + paste back. Reconstructed on the other side by splitting on the FILE
# markers. Bundles the gathered sources (export/ + orig/), the sim glue (run.sh, manifests,
# stubs, TB), the Stage-A manifest + vh_diag.txt, the referenced -v lib PATHS, and a capped
# tail of xrun.log.
#
#   bash vh_dump_debug.sh <build-dir> [out.txt]
#   e.g. bash vh_dump_debug.sh /data/.../workarea/verilogBox/LPBT_NDIV
#   -> /tmp/vh_debug_LPBT_NDIV.txt  ; open it, select all, paste it back.
set -u
BUILD="${1:?usage: bash vh_dump_debug.sh <build-dir> [out.txt]}"
[ -d "$BUILD" ] || { echo "ERROR: not a dir: $BUILD" >&2; exit 1; }
BUILD="$(cd "$BUILD" && pwd)"
OUT="${2:-/tmp/vh_debug_$(basename "$BUILD").txt}"

emit() {  # emit <label> <file> [maxlines]
  local label="$1" f="$2" max="${3:-100000}"
  [ -f "$f" ] || return 0
  echo "===== FILE: $label  ($(wc -l < "$f" 2>/dev/null) lines, $(wc -c < "$f" 2>/dev/null) bytes) ====="
  head -n "$max" "$f"
  echo "===== END: $label ====="
  echo
}

{
  echo "########## VH DEBUG DUMP ##########"
  echo "build: $BUILD"
  echo "host : $(hostname 2>/dev/null)   user: ${USER:-?}"
  for v in "$BUILD/../../skill_tools/VERSION" "$BUILD/../../../skill_tools/VERSION"; do
    [ -f "$v" ] && { echo "VERSION:"; cat "$v"; break; }
  done
  echo "###################################"
  echo

  # export/ -- the actual compiled cell sources (struct + every gathered leaf, incl. div2)
  for f in "$BUILD"/export/*; do [ -f "$f" ] && emit "export/$(basename "$f")" "$f"; done
  # orig/ -- pristine pre-Stage-B originals (diff vs export/ shows what Convert B changed)
  for f in "$BUILD"/orig/*; do [ -f "$f" ] && emit "orig/$(basename "$f")" "$f"; done
  # sim build glue (exact xrun command + -v flags + TB + stubs)
  for f in run.sh setup_env.sh manifest.json sim.tcl ext_libs.list; do
    emit "sim/$f" "$BUILD/sim/$f"
  done
  for f in "$BUILD"/sim/*.vams; do [ -f "$f" ] && emit "sim/$(basename "$f")" "$f"; done
  # manifests + diagnostic
  emit "manifest_A.json" "$BUILD/manifest_A.json"
  emit "manifest_A.txt"  "$BUILD/manifest_A.txt"
  emit "vh_diag.txt"     "$BUILD/vh_diag.txt"

  # referenced external -v libs (PATHS only -- ask for a specific PDK file if truly needed)
  echo "===== referenced -v libs (paths) ====="
  grep -rhoE '/[A-Za-z0-9_./+-]+\.(v|va|vams)' \
    "$BUILD/sim/run.sh" "$BUILD/sim/setup_env.sh" "$BUILD/sim/ext_libs.list" 2>/dev/null \
    | sort -u
  echo "===== END -v libs ====="
  echo

  # xrun.log -- capped (the elaboration + worklib dump near the top is what matters)
  emit "sim/xrun.log [first 500]" "$BUILD/sim/xrun.log" 500
} > "$OUT"

echo "=== wrote $OUT  ($(wc -l < "$OUT") lines, $(du -h "$OUT" 2>/dev/null | cut -f1)) ==="
echo "open it, select ALL, paste it back."
