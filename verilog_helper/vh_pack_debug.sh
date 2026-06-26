#!/usr/bin/env bash
# vh_pack_debug.sh -- bundle a verilog_helper BUILD dir into one tarball for off-site debug,
# so a dead/failed run can be mirrored + reproduced locally instead of pasting logs back and
# forth. Bundles the gathered sources, the sim build (run.sh/manifests/logs), Stage-A manifest
# + diag, and a LIST of the external -v libs the run references (paths only, not the PDK files
# -- ask for a specific one if it's actually needed). Regenerable libs (xcelium.d / INCA_libs)
# are excluded.
#
#   bash vh_pack_debug.sh <build-dir> [out.tgz]
#
# e.g.  bash vh_pack_debug.sh /data/.../workarea/verilogBox/LPBT_NDIV
# -> writes /tmp/vh_debug_LPBT_NDIV.tgz ; send that ONE file back.
set -u
BUILD="${1:?usage: bash vh_pack_debug.sh <build-dir> [out.tgz]}"
[ -d "$BUILD" ] || { echo "ERROR: not a dir: $BUILD" >&2; exit 1; }
BUILD="$(cd "$BUILD" && pwd)"
OUT="${2:-/tmp/vh_debug_$(basename "$BUILD").tgz}"
STAGE="$(mktemp -d)"; PKG="$STAGE/vh_debug"; mkdir -p "$PKG"

# 1. export/ + orig/  (the compiled source set + pristine originals -- the actual cells)
for d in export orig _work; do
  [ -d "$BUILD/$d" ] && cp -r "$BUILD/$d" "$PKG/"
done

# 2. sim/ build, minus the regenerable compiled libs
if [ -d "$BUILD/sim" ]; then
  mkdir -p "$PKG/sim"
  find "$BUILD/sim" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.vams' -o -name '*.va' \
    -o -name '*.v' -o -name '*.json' -o -name '*.tcl' -o -name '*.log' \
    -o -name 'ext_libs.list' \) -exec cp {} "$PKG/sim/" \; 2>/dev/null
fi

# 3. Stage-A/B manifests + the diagnostic report at the build root
for f in manifest_A.json manifest_A.txt manifest_B.txt vh_diag.txt; do
  [ -f "$BUILD/$f" ] && cp "$BUILD/$f" "$PKG/"
done

# 4. external -v libs: record the referenced PATHS (+ sizes) but do NOT copy the PDK files.
#    (Reproduction usually only needs one small external; ask for it by name if so.)
: > "$PKG/vlibs_referenced.txt"
grep -rhoE '/[A-Za-z0-9_./+-]+\.(v|va|vams)' \
  "$BUILD/sim/run.sh" "$BUILD/sim/setup_env.sh" "$BUILD/sim/ext_libs.list" 2>/dev/null \
  | sort -u | while read -r f; do
      if [ -f "$f" ]; then printf '%-10s %s\n' "$(du -h "$f" 2>/dev/null | cut -f1)" "$f"
      else printf '%-10s %s (NOT FOUND)\n' "?" "$f"; fi
    done >> "$PKG/vlibs_referenced.txt"

# 5. provenance: tool version + what was packed
{ echo "build : $BUILD"
  echo "host  : $(hostname 2>/dev/null)"
  echo "user  : ${USER:-?}"
  for v in "$BUILD/../../skill_tools/VERSION" "$BUILD/../../../skill_tools/VERSION"; do
    [ -f "$v" ] && { echo "--- skill_tools/VERSION ---"; cat "$v"; break; }
  done
} > "$PKG/PACK_INFO.txt"

tar -czf "$OUT" -C "$STAGE" vh_debug
rm -rf "$STAGE"
echo "=== packaged -> $OUT  ($(du -h "$OUT" 2>/dev/null | cut -f1)) ==="
echo "contents:"; tar -tzf "$OUT" | sed 's/^/    /' | head -60
echo "send that ONE file back."
