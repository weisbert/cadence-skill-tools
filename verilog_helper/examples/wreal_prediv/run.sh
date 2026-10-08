#!/usr/bin/env bash
# Stage B converts the supply-DIFFERENCE-gated TSPC prediv (sdiv2: `(VDD-VSS)>k` rail check)
# to a clean /2 logic divider, then xrun verifies CLKOUT = fromVCO/4 with the divider LIVE.
#   ./run.sh        # converted prediv -> === TB PASS === (CLKOUT = VCO/4)
#   ./run.sh raw    # original wreal prediv -> CLKOUT dead (rails float -> gate false)
set -e
cd "$(dirname "$0")"
export XCELIUM_HOME=${XCELIUM_HOME:-/home/yusheng/Program/eda/cadence/XCELIUM1803}
export CDS_LIC_FILE=${CDS_LIC_FILE:-/home/yusheng/Program/eda/cadence/license/license.dat}
export PATH="$XCELIUM_HOME/tools/bin:$PATH"
W=$(mktemp -d /tmp/wprediv.XXXX)
cp sdiv2.vams "$W/"                       # convert a COPY -> candidate lands in $W, dir stays clean
python3 ../../vh_convert.py --src "$W/sdiv2.vams" --out "$W" >/dev/null 2>&1
if [ "${1:-}" = "raw" ]; then DRV=sdiv2.vams; else DRV="$W/veriloga_wreal.va"; fi
rm -rf xcelium.d INCA_libs .simvision *.shm xr.log    # fresh worklib (stale lib hides the fix)
xrun -ams -amsvlog_ext .vams,.va "$DRV" sdiv2_top.vams tb_prediv.vams -top tb_prediv -l xr.log >/dev/null 2>&1 || true
grep -E "=== TB|PASS|FAIL" xr.log | head -5 || echo "(no verdict -- see xr.log)"
