#!/usr/bin/env bash
# WuR-NDIV 32.768 kHz / SDM characterization runner.
#
#   ./run.sh tb_wur32k                       # static 32.768 kHz divide law
#   ./run.sh tb_wur_sdm +PHASE=main +NINT=300 +FNUM=773094 +K=4096 +TAG=n300
#   ./run.sh tb_wur_sdm +PHASE=lat  +MODE=lpbt
#
# Drives the REAL NDIV_TOP_v7_svt_0p5W Stage-A struct.  The struct netlist is proprietary and
# lives OUTSIDE version control: point STRUCT_DIR at a build dir holding
#   export/*.vams   (struct + behavioral cells)   and   ext_stub/*.vams  (COT cell stubs).
# Default = the local gitignored _ref build used to develop these TBs.
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
STRUCT_DIR="${STRUCT_DIR:-$SRC/../_ref/build_sdm}"
TOP="${1:?usage: run.sh <tb_module> [+plusargs...] [xrun args...]}"; shift

# --- xrun on PATH (VH_SITE_ENV, else dev-box fallback) ---
if ! command -v xrun >/dev/null 2>&1; then
  if   [ -n "${VH_SITE_ENV:-}" ] && [ -f "${VH_SITE_ENV}" ]; then . "${VH_SITE_ENV}"
  elif [ -d "/home/yusheng/Program/eda/cadence/XCELIUM1803" ]; then
    export XCELIUM_HOME="/home/yusheng/Program/eda/cadence/XCELIUM1803"
    export CDS_LIC_FILE="${CDS_LIC_FILE:-/home/yusheng/Program/eda/cadence/license/license.dat}"
    export PATH="$XCELIUM_HOME/tools/bin:$PATH"
  fi
fi
command -v xrun >/dev/null 2>&1 || { echo "ERROR: xrun not on PATH (set VH_SITE_ENV=/path/to/cadence_env.sh)"; exit 127; }
[ -d "$STRUCT_DIR/export" ] || { echo "ERROR: no netlist at $STRUCT_DIR/export (set STRUCT_DIR=...)"; exit 2; }
[ -f "$SRC/$TOP.vams" ]     || { echo "ERROR: no TB $SRC/$TOP.vams"; exit 2; }

# private per-TB run dir, so concurrent runs never share an xcelium.d
RUNDIR="${RUNDIR:-$STRUCT_DIR/run_$TOP}"
mkdir -p "$RUNDIR" && cd "$RUNDIR" || exit 2
rm -rf xcelium.d INCA_libs .simvision xrun.log xrun.key 2>/dev/null
echo "RUNDIR=$RUNDIR"

ARGS=(-64bit -ams -timescale 1s/1fs -amsvlog_ext .vams,.va)
for v in "$STRUCT_DIR"/ext_stub/*.vams; do ARGS+=("$v"); done
for f in "$STRUCT_DIR"/export/*.vams;   do ARGS+=("$f"); done
[ -f "$SRC/mash111.vams" ] && ARGS+=("$SRC/mash111.vams")
ARGS+=("$SRC/$TOP.vams" -top "$TOP" -access +rwc +libext+.v+.va+.vams "$@" -l xrun.log)

# license contention: another xrun may hold the AMS licence -> retry for ~10 min
for try in 1 2 3 4 5 6 7 8 9 10 11 12; do
  xrun "${ARGS[@]}"; rc=$?
  if grep -qE "All .* licenses .* in use|Unable to (obtain|check ?out) a license|LICENSE CHECKOUT FAILED" xrun.log 2>/dev/null \
     && ! grep -q "Spectre_AMS" xrun.log; then
    echo "…license busy, retry $try in 50s"; sleep 50; continue
  fi
  break
done

echo "===== RESULT ====="
grep -E "^(PT32K|SDM|ALIGN|AVG|LAT|HIST|PSD|SETUP|NOTE|WARN)|^== |^  (PASS|FAIL)|^=== " xrun.log || tail -25 xrun.log
echo "xrun exit: $rc   (Spectre_AMS* license-checkout lines are BENIGN: pure-digital wreal)"
exit $rc
