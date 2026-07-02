#!/usr/bin/env bash
# Local verification of the LPBT_NDIV_TOP testbench MECHANICS against the
# behavioral good-model (this is NOT the real design -- see README.md).
#
#   ./run.sh                      # smoke: CAL+TEST hard checks, NORM = liveness WARN
#   ./run.sh +define+CHECK_NDIV   # add the post-#28 functional N-divide check
#   ./run.sh +define+CHECK_NDIV +define+BREAK_NDIV     # prove the N check FAILs
#   ./run.sh +define+BREAK_TESTCLK                     # prove the TESTCLK check FAILs
#   ./run.sh +define+HOLLOW       # mimic today's real design (dead mmd_core) -> PASS
#   ./run.sh +define+WAVES        # dump ndiv.shm -> view with:  simvision ndiv.shm
set -e
cd "$(dirname "$0")"
export XCELIUM_HOME=${XCELIUM_HOME:-/home/yusheng/Program/eda/cadence/XCELIUM1803}
export CDS_LIC_FILE=${CDS_LIC_FILE:-/home/yusheng/Program/eda/cadence/license/license.dat}
export PATH="$XCELIUM_HOME/tools/bin:$PATH"
# probing needs read/write/connectivity access; only add it when WAVES is requested
ACCESS=""; case " $* " in *"+define+WAVES"*) ACCESS="-access +rwc";; esac
rm -rf xcelium.d INCA_libs .simvision *.shm *.history xr.log xrun.log 2>/dev/null || true
# the real DUT testbench now lives in the shared testbenches/ library (one canonical copy)
xrun -ams -amsvlog_ext .vams,.va $ACCESS "$@" \
  ../../testbenches/tb_LPBT_NDIV_TOP.vams LPBT_NDIV_TOP_model.vams \
  -top tb_LPBT_NDIV_TOP -l xr.log > /dev/null 2>&1
grep -E "==|PASS|FAIL|WARN|witness|RESULT" xr.log || { echo "no verdict -- see xr.log"; tail -20 xr.log; }
case " $* " in *"+define+WAVES"*) echo "-- waveform db: $(pwd)/ndiv.shm  (view:  simvision ndiv.shm &)";; esac
