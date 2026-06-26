#!/usr/bin/env bash
# Stage B converts the wreal supply/enable monitor (wmon_buf) to a logic enable gate, then
# xrun verifies OUT = en ? IN : 0 with NO *E,CUNDCM.
#   ./run.sh        # converted driver -> TB PASS
#   ./run.sh raw    # original wreal driver -> shows the *E,CUNDCM boundary it fixes
set -e
cd "$(dirname "$0")"
export XCELIUM_HOME=${XCELIUM_HOME:-/home/yusheng/Program/eda/cadence/XCELIUM1803}
export CDS_LIC_FILE=${CDS_LIC_FILE:-/home/yusheng/Program/eda/cadence/license/license.dat}
export PATH="$XCELIUM_HOME/tools/bin:$PATH"
W=$(mktemp -d /tmp/wmon.XXXX)
cp wmon_buf.vams "$W/"                    # convert a COPY -> candidate lands in $W, dir stays clean
python3 ../../vh_convert.py --src "$W/wmon_buf.vams" --out "$W" >/dev/null 2>&1
if [ "${1:-}" = "raw" ]; then DRV=wmon_buf.vams; else DRV="$W/veriloga_wreal.va"; fi
rm -rf xcelium.d INCA_libs .simvision *.shm *.history xrun.log
xrun -ams -amsvlog_ext .vams,.va "$DRV" wmon_top.vams tb_wmon.vams -top tb -l xrun.log > /dev/null 2>&1 || true
grep -E "=== TB|CUNDCM" xrun.log | head -5 || echo "(no verdict -- see xrun.log)"
