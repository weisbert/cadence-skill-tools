#!/usr/bin/env bash
# Reproduce the xrun/SimVision waveform screenshot at the nominal op point (ndiv=51),
# fully headless: run tb_wave -> ndiv51.shm, launch SimVision under Xvfb, screenshot via PIL.
#   ./grab_sv.sh [out.png] [wait_seconds]
# Needs: Xvfb, python3 with PIL. STRUCT_DIR is passed through to ./run.sh.
set -uo pipefail
cd "$(dirname "$0")"
OUT="${1:-simvision_ndiv51.png}"
WAIT="${2:-40}"
DISP=":99"

./run.sh tb_wave >/dev/null 2>&1 || { echo "tb_wave run failed (see xrun.log)"; exit 1; }
[ -d ndiv51.shm ] || { echo "no ndiv51.shm produced"; exit 1; }

pkill -f "Xvfb $DISP" 2>/dev/null; sleep 1
Xvfb $DISP -screen 0 1920x1080x24 >/tmp/xvfb_charac.log 2>&1 &
XVFB=$!; sleep 3
DISPLAY=$DISP simvision -input sv_wave.tcl ndiv51.shm >sv.log 2>&1 &
SV=$!
echo "waiting ${WAIT}s for SimVision to render ..."
sleep "$WAIT"
DISPLAY=$DISP python3 - "$OUT" <<'PY'
import sys
from PIL import ImageGrab, ImageChops, Image
img = ImageGrab.grab(xdisplay=":99").convert("RGB")
bbox = ImageChops.difference(img, Image.new("RGB", img.size, (0,0,0))).getbbox()
if bbox:
    img = img.crop((0, 0, min(bbox[2]+2, img.width), 300))   # app is top-left; keep the wave strip
img.save(sys.argv[1]); print("saved", sys.argv[1], img.size)
PY
kill $SV 2>/dev/null; sleep 1; kill $XVFB 2>/dev/null
