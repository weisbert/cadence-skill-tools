#!/usr/bin/env bash
# Characterization runner: drive a charac TB against the REAL LPBT_NDIV_TOP Stage-A struct.
#
#   ./run.sh tb_ndivsweep      # ndiv 14..127 divisor/pulse-width sweep -> SWEEP/SUMMARY lines
#   ./run.sh tb_wave           # short capture at ndiv=51 -> ndiv51.shm (view in SimVision)
#
# The real struct netlist is proprietary and lives OUTSIDE version control. Point STRUCT_DIR at
# any build dir that holds  export/*.vams (struct + cells)  and  ext_libs/*.vams.
#   default: the local gitignored _ref build.  On the red zone, set STRUCT_DIR to the export dir.
set -uo pipefail
cd "$(dirname "$0")"
STRUCT_DIR="${STRUCT_DIR:-../_ref/build_afterfix}"
TOP="${1:?usage: run.sh <tb_module_name>   e.g. tb_ndivsweep | tb_wave}"

# xrun on PATH (VH_SITE_ENV, else dev-box fallback)
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

rm -rf xcelium.d INCA_libs .simvision xrun.log xrun.key 2>/dev/null
ARGS=(-64bit -ams -timescale 1s/1fs -amsvlog_ext .vams,.va)
for v in "$STRUCT_DIR"/ext_libs/*.vams; do ARGS+=(-v "$v"); done
for f in "$STRUCT_DIR"/export/*.vams;  do ARGS+=("$f"); done
ARGS+=("./$TOP.vams" -top "$TOP" -access +rwc +libext+.v+.va+.vams -l xrun.log)
xrun "${ARGS[@]}"
grep -E "^SWEEP|^SUMMARY|^== |witness|RESULT|=== |^   [|+]" xrun.log || tail -20 xrun.log
