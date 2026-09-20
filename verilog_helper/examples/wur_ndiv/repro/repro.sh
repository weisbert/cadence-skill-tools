#!/usr/bin/env bash
# =============================================================================
# repro.sh -- ONE entry point that reproduces every WuR-NDIV simulation of the
#             2026-09 session on any box that has xrun + python3.
#
#   bash repro.sh --struct <dir-with-export/> \
#                 [--ext-libs <ext_libs.list> | --ext-stub <dir>] \
#                 [--out <dir>] [--only 32k,sdm,modes,delay,report|all] \
#                 [--fvco 4800,5000,5800,7000] [--scales 0.5,1,2,3,4,5,6] \
#                 [--fnum <per-band list>] [--models plain|dly|both]
#
# It never writes into --struct: delays are injected into a COPY under
# <out>/export_dly.  Every xrun gets its own run dir, its own -xmlibdirname and
# its own log, so nothing shares an xcelium.d and runs are restartable.
#
# Result: <out>/SUMMARY.md (also printed).  Exit != 0 if an ENFORCED run failed.
#
# Reference results to compare against:
#   ../SDM_32K_RESULTS.md   ../DELAYS.md   ../SPEC_CHECKLIST.md   README_REPRO.md
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VH="$(cd "$HERE/../../.." && pwd)"                 # .../verilog_helper
CHARAC="$VH/examples/wur_ndiv/charac"
TB5="$VH/testbenches/tb_NDIV_TOP_v7_svt_0p5W.vams"
TBDLY="$VH/testbenches/tb_NDIV_TOP_v7_svt_0p5W_dly.vams"
TABLE="$VH/delays/wur_ndiv_delays.json"
MASH="$CHARAC/mash111.vams"

# ---------------------------------------------------------------- defaults
STRUCT=""; EXT_LIBS=""; EXT_STUB=""; OUT=""; ONLY="all"
FVCO="4800,5000,5800,7000"
SCALES="0.5,1,2,3,4,5,6"
FNUM=""                       # per-band FNUM (2^-20 units); default = the 32.768 kHz-exact ones
MODELS="both"                 # plain | dly | both
RETRY="${VH_XRUN_RETRY:-8}"   # license-contention retries

die() { echo "ERROR: $*" >&2; exit 2; }
say() { echo "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --struct)   STRUCT="${2:?}"; shift 2 ;;
    --ext-libs) EXT_LIBS="${2:?}"; shift 2 ;;
    --ext-stub) EXT_STUB="${2:?}"; shift 2 ;;
    --out)      OUT="${2:?}"; shift 2 ;;
    --only)     ONLY="${2:?}"; shift 2 ;;
    --fvco)     FVCO="${2:?}"; shift 2 ;;
    --scales)   SCALES="${2:?}"; shift 2 ;;
    --fnum)     FNUM="${2:?}"; shift 2 ;;
    --models)   MODELS="${2:?}"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown option: $1  (--help)" ;;
  esac
done

[ -n "$STRUCT" ] || die "--struct <dir with export/> is required"
STRUCT="$(cd "$STRUCT" && pwd)" || die "--struct not a directory"
[ -d "$STRUCT/export" ] || die "no $STRUCT/export -- point --struct at the Stage-A build dir"
OUT="${OUT:-$PWD/wur_repro_out}"
mkdir -p "$OUT/runs" || die "cannot create $OUT"
OUT="$(cd "$OUT" && pwd)"
[ -z "$EXT_LIBS" ] || EXT_LIBS="$(cd "$(dirname "$EXT_LIBS")" && pwd)/$(basename "$EXT_LIBS")"
[ -z "$EXT_STUB" ] || EXT_STUB="$(cd "$EXT_STUB" && pwd)"
[ -n "$EXT_LIBS" ] && [ -n "$EXT_STUB" ] && die "--ext-libs and --ext-stub are mutually exclusive"
case "$MODELS" in plain|dly|both) ;; *) die "--models must be plain|dly|both" ;; esac

want() { case ",$ONLY," in *,all,*) return 0 ;; *",$1,"*) return 0 ;; *) return 1 ;; esac; }
for it in ${ONLY//,/ }; do
  case "$it" in all|32k|sdm|modes|delay|report) ;; *) die "--only: unknown item '$it'" ;; esac
done

ROWS="$OUT/.rows"; : > "$ROWS"
NFAIL=0; NRUN=0
T_ALL0=$SECONDS

# ---------------------------------------------------------------- preflight
PF="$OUT/preflight.log"; : > "$PF"
pf() { echo "$*" | tee -a "$PF"; }

say "================= PREFLIGHT ================="
if ! command -v xrun >/dev/null 2>&1; then
  if [ -n "${VH_SITE_ENV:-}" ] && [ -f "${VH_SITE_ENV}" ]; then
    . "${VH_SITE_ENV}"; pf "xrun    : sourced VH_SITE_ENV=$VH_SITE_ENV"
  elif [ -d "/home/yusheng/Program/eda/cadence/XCELIUM1803" ]; then
    export XCELIUM_HOME="/home/yusheng/Program/eda/cadence/XCELIUM1803"
    export CDS_LIC_FILE="${CDS_LIC_FILE:-/home/yusheng/Program/eda/cadence/license/license.dat}"
    export PATH="$XCELIUM_HOME/tools/bin:$PATH"
    pf "xrun    : dev-box fallback env (XCELIUM1803)"
  fi
else
  pf "xrun    : ambient on PATH (the red-zone case -- no env setup needed)"
fi
command -v xrun >/dev/null 2>&1 || die "xrun not on PATH (set VH_SITE_ENV=/path/to/cadence_env.sh)"
XRUN_BIN="$(command -v xrun)"
XRUN_VER="$(xrun -version 2>/dev/null | head -1 | tr -s ' ')"
pf "xrun-bin: $XRUN_BIN"
pf "xrun-ver: ${XRUN_VER:-unknown}"
pf "python3 : $(python3 -V 2>&1)"
if python3 -c "import numpy" >/dev/null 2>&1; then
  HAVE_NUMPY=yes; pf "numpy   : present  (sdm_psd.py uses the numpy backend)"
else
  HAVE_NUMPY=no;  pf "numpy   : ABSENT   (sdm_psd.py falls back to its pure-stdlib Bluestein FFT -- same numbers)"
fi
command -v Xvfb >/dev/null 2>&1 && HAVE_XVFB=yes || HAVE_XVFB=no
python3 -c "import PIL" >/dev/null 2>&1 && HAVE_PIL=yes || HAVE_PIL=no
command -v simvision >/dev/null 2>&1 && HAVE_SV=yes || HAVE_SV=no
pf "report  : Xvfb=$HAVE_XVFB PIL=$HAVE_PIL simvision=$HAVE_SV  (all three needed for the PNGs; report.md needs none)"
pf "struct  : $STRUCT/export ($(ls "$STRUCT"/export/*.vams 2>/dev/null | wc -l) files)"
ls "$STRUCT"/export/NDIV_TOP_v7_svt_0p5W_struct.vams >/dev/null 2>&1 \
  || pf "WARN    : NDIV_TOP_v7_svt_0p5W_struct.vams not found in export/ -- is this the right build?"

# ---- externals: real -v libraries (FUNCTIONAL) or local stubs (SMOKE) ----
EXTA=(); EXTA_DLY=(); RUNKIND="SMOKE"
if [ -n "$EXT_LIBS" ]; then
  [ -f "$EXT_LIBS" ] || die "--ext-libs file not found: $EXT_LIBS"
  n=0
  while IFS= read -r ln; do
    ln="${ln%%#*}"; ln="$(echo "$ln" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$ln" ] && continue
    case "$ln" in
      -y*|+incdir+*|-v*) for tok in $ln; do EXTA+=("$tok"); done ;;
      *)                 EXTA+=(-v "$ln") ;;
    esac
    n=$((n+1))
  done < "$EXT_LIBS"
  [ "$n" -gt 0 ] || die "--ext-libs file is empty: $EXT_LIBS"
  RUNKIND="FUNCTIONAL"
  EXTA_DLY=("${EXTA[@]}")            # real COT cells are NEVER delay-injected
  pf "ext     : $n entry/entries from $EXT_LIBS  -> RUN-KIND: FUNCTIONAL"
elif [ -n "$EXT_STUB" ]; then
  for v in "$EXT_STUB"/*.vams; do [ -f "$v" ] && EXTA+=("$v"); done
  [ "${#EXTA[@]}" -gt 0 ] || die "--ext-stub dir has no *.vams: $EXT_STUB"
  pf "ext     : ${#EXTA[@]} stub file(s) from $EXT_STUB  -> RUN-KIND: SMOKE (dev proxy only)"
else
  pf "ext     : NONE given -- externals will be unresolved; pass --ext-libs (red) or --ext-stub (dev)"
fi
[ "${#EXTA_DLY[@]}" -gt 0 ] || EXTA_DLY=("${EXTA[@]:+${EXTA[@]}}")

# ---------------------------------------------------------- delay injection
SRC_PLAIN="$STRUCT/export"
SRC_DLY="$OUT/export_dly"
DLY_OK=no
if [ "$MODELS" != "plain" ] || want delay || want modes; then
  if [ -f "$TABLE" ]; then
    say "--- injecting delays (table: $(basename "$TABLE")) into a COPY: $SRC_DLY"
    rm -rf "$SRC_DLY"
    if python3 "$VH/vh_delay.py" apply --table "$TABLE" --src "$SRC_PLAIN" --out "$SRC_DLY" \
         > "$OUT/vh_delay_apply.log" 2>&1; then
      DLY_OK=yes
      tail -2 "$OUT/vh_delay_apply.log" | sed 's/^/    /'
    else
      pf "WARN    : vh_delay.py apply FAILED -- see $OUT/vh_delay_apply.log; delayed runs skipped"
      sed 's/^/    /' "$OUT/vh_delay_apply.log" | tail -5
    fi
    # dev only: the local COT *stubs* are injected too, so the sweep scales the whole
    # design.  With real -v libraries (red zone) they carry vendor timing already.
    if [ "$DLY_OK" = yes ] && [ -n "$EXT_STUB" ]; then
      rm -rf "$OUT/ext_stub_dly"
      if python3 "$VH/vh_delay.py" apply --table "$TABLE" --src "$EXT_STUB" --out "$OUT/ext_stub_dly" \
           >> "$OUT/vh_delay_apply.log" 2>&1; then
        EXTA_DLY=(); for v in "$OUT/ext_stub_dly"/*.vams; do EXTA_DLY+=("$v"); done
      else
        EXTA_DLY=("${EXTA[@]}")
      fi
    elif [ -z "$EXT_LIBS" ]; then
      EXTA_DLY=("${EXTA[@]}")
    fi
  else
    pf "WARN    : delay table not found ($TABLE) -- delayed runs skipped"
  fi
fi
say ""

# ---------------------------------------------------------------- run engine
# do_run <name> <models:plain|dly> <enforce:PASS|FAIL|INFO> <src> <top> <tb> <keygrep> [xrun args...]
do_run() {
  local name="$1" mdl="$2" enf="$3" src="$4" top="$5" tb="$6" key="$7"; shift 7
  local rd="$OUT/runs/$name"
  mkdir -p "$rd"; rm -rf "$rd/xcelium.d" "$rd/INCA_libs" "$rd/xrun.log"
  local -a A=(-64bit -ams -timescale 1s/1fs -amsvlog_ext .vams,.va -xmlibdirname "$rd/xcelium.d")
  if [ "$mdl" = dly ]; then
    [ "${#EXTA_DLY[@]}" -gt 0 ] && A+=("${EXTA_DLY[@]}")
  else
    [ "${#EXTA[@]}" -gt 0 ] && A+=("${EXTA[@]}")
  fi
  local f; for f in "$src"/*.vams; do A+=("$f"); done
  case "$top" in tb_wur_sdm) A+=("$MASH") ;; esac
  A+=("$tb" -top "$top" -access +rwc +libext+.v+.va+.vams "$@" -l "$rd/xrun.log")
  printf '%s\n' "xrun ${A[*]}" > "$rd/cmd.txt"

  local t0=$SECONDS rc=1 try
  for try in $(seq 1 "$RETRY"); do
    ( cd "$rd" && xrun "${A[@]}" ) > "$rd/console.log" 2>&1; rc=$?
    if grep -qE "All .* licenses .* in use|Unable to (obtain|check ?out) a license|LICENSE CHECKOUT FAILED" \
         "$rd/xrun.log" 2>/dev/null && ! grep -q "Spectre_AMS" "$rd/xrun.log"; then
      say "    ...license busy, retry $try/$RETRY in 45 s"; sleep 45; continue
    fi
    break
  done
  local el=$((SECONDS - t0))

  local verdict="ERROR"
  if   grep -q "=== TB PASS" "$rd/xrun.log" 2>/dev/null; then verdict="PASS"
  elif grep -q "=== TB FAIL" "$rd/xrun.log" 2>/dev/null; then verdict="FAIL"
  fi
  local keyline=""
  if [ -n "$key" ]; then
    keyline="$(grep -hE "$key" "$rd/xrun.log" 2>/dev/null | head -2 \
               | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/|/;/g' | cut -c1-100 \
               | awk '{printf "%s%s", (NR>1 ? " // " : ""), $0} END{print ""}')"
  fi
  if [ -n "${KEYX:-}" ]; then                     # optional per-item summary hook
    local kx; kx="$(eval "$KEYX" 2>/dev/null)"
    [ -n "$kx" ] && keyline="$kx${keyline:+ // $keyline}"
    KEYX=""
  fi
  [ -n "$keyline" ] || keyline="(see runs/$name/xrun.log)"
  local np nf
  np=$(grep -c '^  PASS' "$rd/xrun.log" 2>/dev/null); np="${np:-0}"
  nf=$(grep -c '^  FAIL' "$rd/xrun.log" 2>/dev/null); nf="${nf:-0}"
  [ $((np + nf)) -gt 0 ] && keyline="$keyline // checks PASS=$np FAIL=$nf"

  local ok="ok"
  case "$enf" in
    PASS) [ "$verdict" = PASS ] || ok="MISMATCH" ;;
    FAIL) [ "$verdict" = FAIL ] || ok="MISMATCH" ;;
    INFO) ;;
  esac
  [ "$ok" = ok ] || NFAIL=$((NFAIL+1))
  NRUN=$((NRUN+1))
  local kind="$RUNKIND"; [ "$mdl" = dly ] && kind="$RUNKIND/1x-delays"
  printf '%s\t%s\t%s\t%s\t%s\t%ss\t%s\n' "$name" "$mdl" "$kind" "$enf" "$verdict" "$el" "$keyline" >> "$ROWS"
  printf '  %-26s %-5s %-7s %-4s %4ss  %s\n' "$name" "$mdl" "$verdict" "$enf" "$el" \
         "$(echo "$keyline" | cut -c1-90)"
  return 0
}

add_row() {   # a non-xrun row (python post-processing)
  printf '%s\t%s\t%s\t%s\t%s\t%ss\t%s\n' "$1" "$2" "-" "$3" "$4" "$5" "$6" >> "$ROWS"
  NRUN=$((NRUN+1)); [ "$4" = "$3" ] || [ "$3" = INFO ] || NFAIL=$((NFAIL+1))
}

model_list() {  # which model sets to use for the charac items
  case "$MODELS" in plain) echo plain ;; dly) echo dly ;; both) echo "plain dly" ;; esac
}
have_dly() { [ "$DLY_OK" = yes ]; }
src_of()   { [ "$1" = dly ] && echo "$SRC_DLY" || echo "$SRC_PLAIN"; }

# per-band SDM operating point: fvco_mhz -> NINT FNUM  (FNUM in 2^-20 units)
band_nint() { case "$1" in 4800) echo 9156 ;; 5000) echo 9537 ;; 5800) echo 11063 ;; 7000) echo 13352 ;;
                           *) echo "" ;; esac; }
band_fnum() {
  if [ -n "$FNUM" ]; then                       # user list, positional against --fvco
    local i=1 f; for f in ${FVCO//,/ }; do
      [ "$f" = "$1" ] && { echo "$FNUM" | cut -d, -f$i; return; }; i=$((i+1)); done
  fi
  case "$1" in 4800) echo 286720 ;; 5000) echo 779264 ;; 5800) echo 652288 ;; 7000) echo 282600 ;;
               *) echo "" ;; esac
}

K_PT32K='^== points='
KEYX=""
# compact "band:integer-ndiv-error" summary of the 9 PT32K points
ppm_summary() {
  awk '/^PT32K/{ fv=""; pp="";
        for (i=1;i<=NF;i++) { if ($i ~ /^fvco=/) fv=substr($i,6);
                              if ($i=="ppm)")    { pp=$(i-1); sub(/^\(/,"",pp) } }
        if (fv!="" && pp!="" && n<4) printf "%s%s=%sppm", (n++?" ":"integer-ndiv err@ "), fv, pp }
      END{ print "" }' "$1"
}
K_SDM='^(ALIGN best|AVG |HIST )'
K_LAT='^LATSUM'
K_MODE='^RPTINFO'
K_HOLD='^HOLD meas'

# ---------------------------------------------------------------- 1. static 32.768 kHz law
if want 32k; then
  say "===== [32k] static 32.768 kHz divide law (9 points incl. 7 GHz) ====="
  for m in $(model_list); do
    [ "$m" = dly ] && { have_dly || continue; }
    KEYX='ppm_summary "$rd/xrun.log"'
    do_run "32k_$m" "$m" PASS "$(src_of $m)" tb_wur32k "$CHARAC/tb_wur32k.vams" "$K_PT32K"
  done
  say ""
fi

# ---------------------------------------------------------------- 2. MASH-111 SDM
if want sdm; then
  say "===== [sdm] MASH 1-1-1 on CLK2DSM: per-cycle law / alignment / average / PSD ====="
  PERR_DIR="$OUT/perr"; mkdir -p "$PERR_DIR"
  for m in $(model_list); do
    [ "$m" = dly ] && { have_dly || continue; }
    S="$(src_of $m)"
    # (a) the 8192-cycle N_int=300 reference run -- this is the PSD record
    do_run "sdm_w300_f7373_$m" "$m" PASS "$S" tb_wur_sdm "$CHARAC/tb_wur_sdm.vams" "$K_SDM" \
           +NINT=300 +FNUM=773094 +KCYC=8192 +ALLY=1 "+TAG=w300_f7373_$m"
    if [ "$m" = dly ]; then
      # SDM_32K_RESULTS.md section 5: the delayed cross-check is a 4-run subset
      hi="$(echo "$FVCO" | tr ',' '\n' | tail -1)"
      ni="$(band_nint "$hi")"; fn="$(band_fnum "$hi")"
      [ -n "$ni" ] && do_run "sdm_w32k_${hi}_$m" "$m" PASS "$S" tb_wur_sdm "$CHARAC/tb_wur_sdm.vams" \
             "$K_SDM" "+FVCO_MHZ=$hi" "+NINT=$ni" "+FNUM=$fn" +KCYC=256 "+TAG=w32k_${hi}_$m"
      do_run "sdm_setup_w300_$m" "$m" PASS "$S" tb_wur_sdm "$CHARAC/tb_wur_sdm.vams" "$K_LAT" \
             +PHLAT=3 +LPBT=0 +NINT=300 +NODUMP=1
      continue
    fi
    # (b) the four real 32.768 kHz bands
    for f in ${FVCO//,/ }; do
      ni="$(band_nint "$f")"; fn="$(band_fnum "$f")"
      [ -n "$ni" ] || { say "  (skip band $f MHz: no NINT known -- give --fnum/--fvco pairs)"; continue; }
      do_run "sdm_w32k_${f}_$m" "$m" PASS "$S" tb_wur_sdm "$CHARAC/tb_wur_sdm.vams" "$K_SDM" \
             "+FVCO_MHZ=$f" "+NINT=$ni" "+FNUM=$fn" +KCYC=256 "+TAG=w32k_${f}_$m"
    done
    # (c) LPBT operating mode
    do_run "sdm_lpbt51_$m" "$m" PASS "$S" tb_wur_sdm "$CHARAC/tb_wur_sdm.vams" "$K_SDM" \
           +LPBT=1 +NINT=51 +FNUM=773094 +KCYC=512 "+TAG=lpbt51_$m"
    # (d1) latency sweep referred to the CLK2DSM edge
    do_run "sdm_lat_lpbt_$m" "$m" PASS "$S" tb_wur_sdm "$CHARAC/tb_wur_sdm.vams" "$K_LAT" \
           +PHLAT=1 +LPBT=1 +NINT=51 +NODUMP=1
    do_run "sdm_lat_w300_$m" "$m" PASS "$S" tb_wur_sdm "$CHARAC/tb_wur_sdm.vams" "$K_LAT" \
           +PHLAT=1 +LPBT=0 +NINT=300 +NODUMP=1
    # (d2) deterministic setup sweep referred to the OUT_NDIV reload edge
    do_run "sdm_setup_w300_$m" "$m" PASS "$S" tb_wur_sdm "$CHARAC/tb_wur_sdm.vams" "$K_LAT" \
           +PHLAT=3 +LPBT=0 +NINT=300 +NODUMP=1
    do_run "sdm_setup_w300_7g_$m" "$m" PASS "$S" tb_wur_sdm "$CHARAC/tb_wur_sdm.vams" "$K_LAT" \
           +PHLAT=3 +LPBT=0 +NINT=300 +FVCO_MHZ=7000 +NODUMP=1
  done
  # (e) noise shaping on every period dump produced above
  find "$OUT/runs" -name 'perr_*.txt' -exec cp {} "$PERR_DIR/" \; 2>/dev/null
  if ls "$PERR_DIR"/perr_*.txt >/dev/null 2>&1; then
    t0=$SECONDS
    python3 "$CHARAC/sdm_psd.py" "$PERR_DIR"/perr_*.txt > "$OUT/psd.log" 2>&1; prc=$?
    el=$((SECONDS - t0))
    sed 's/^/  /' "$OUT/psd.log"
    kp="$(grep -h '^PSD ' "$OUT/psd.log" | sed -e 's/[[:space:]]\+/ /g' | cut -c1-110 | paste -sd' // ' -)"
    add_row "sdm_psd (sdm_psd.py)" "-" PASS "$([ $prc -eq 0 ] && echo PASS || echo FAIL)" "$el" "${kp:-see psd.log}"
  else
    say "  (no perr_*.txt dumps found -- PSD check skipped)"
  fi
  say ""
fi

# ---------------------------------------------------------------- 3. committed 5-mode TB
if want modes; then
  say "===== [modes] committed 5-mode TB (WuR/LPBT/CAL/TEST/POWER-DOWN) per band ====="
  for m in $(model_list); do
    [ "$m" = dly ] && { have_dly || continue; }
    S="$(src_of $m)"
    for f in ${FVCO//,/ }; do
      g="$(awk -v x="$f" 'BEGIN{printf "%.4g", x/1000.0}')"
      do_run "modes_${g}GHz_$m" "$m" PASS "$S" tb "$TB5" "$K_MODE" "+define+FGHZ=$g"
    done
  done
  say ""
fi

# ---------------------------------------------------------------- 4. delay-scale margin sweep
if want delay; then
  if have_dly; then
    say "===== [delay] delay-scale margin sweep (tb_..._dly.vams, +define+VH_TPD_SCALE) ====="
    for f in 5.8 7.0; do
      for s in ${SCALES//,/ }; do
        case "$s" in 1|1.0) enf=PASS ;; *) enf=INFO ;; esac
        do_run "dly_${f}G_wur_s$s"  dly "$enf" "$SRC_DLY" tb "$TBDLY" "$K_HOLD" \
               "+define+FGHZ=$f" "+define+LPBTEN=0" "+define+VH_TPD_SCALE=$s"
        do_run "dly_${f}G_lpbt_s$s" dly "$enf" "$SRC_DLY" tb "$TBDLY" "$K_HOLD" \
               "+define+FGHZ=$f" "+define+LPBTEN=1" "+define+VH_TPD_SCALE=$s"
        do_run "dly_${f}G_pre_s$s"  dly INFO   "$SRC_DLY" tb "$TBDLY" "$K_HOLD" \
               "+define+FGHZ=$f" "+define+LPBTEN=0" "+define+PRELPBT=1" "+define+VH_TPD_SCALE=$s"
      done
    done
    # mechanism isolation (DELAYS.md 3c): pin / force the front-end TSPC divide-by-2 alone
    do_run "dly_iso_tspc_pinned_6x"  dly INFO "$SRC_DLY" tb "$TBDLY" "$K_HOLD" \
           "+define+FGHZ=5.8" "+define+VH_TPD_SCALE=6" "+define+VH_TPD_TSPC_DIV2_PS=5"
    do_run "dly_iso_tspc_only_180ps" dly INFO "$SRC_DLY" tb "$TBDLY" "$K_HOLD" \
           "+define+FGHZ=5.8" "+define+VH_TPD_SCALE=1" "+define+VH_TPD_TSPC_DIV2_PS=180"
    do_run "dly_iso_lpbt_reload_5x"  dly INFO "$SRC_DLY" tb "$TBDLY" "$K_HOLD" \
           "+define+FGHZ=5.8" "+define+LPBTEN=1" "+define+VH_TPD_SCALE=5" "+define+VH_TPD_TSPC_DIV2_PS=6"
  else
    say "===== [delay] SKIPPED -- no delay-injected models (vh_delay.py apply failed?) ====="
  fi
  say ""
fi

# ---------------------------------------------------------------- 5. report + SimVision PNGs
if want report; then
  say "===== [report] vh_wur_report.py (PASS/FAIL table + headless SimVision PNGs) ====="
  RS="$OUT/report_sim"; mkdir -p "$RS"
  RSRC="$SRC_PLAIN"; RM=plain
  if have_dly && [ "$MODELS" != plain ]; then RSRC="$SRC_DLY"; RM=dly; fi
  {
    echo '#!/usr/bin/env bash'
    echo '# generated by repro.sh -- the sim runner vh_wur_report.py drives ("$@" -> xrun)'
    echo 'set -uo pipefail'
    echo 'cd "$(dirname "$0")"'
    echo "export PATH=\"$(dirname "$XRUN_BIN"):\$PATH\""
    [ -n "${CDS_LIC_FILE:-}" ] && echo "export CDS_LIC_FILE=\"${CDS_LIC_FILE}\""
    echo 'rm -rf xcelium.d INCA_libs xrun.log'
    echo 'A=(-64bit -ams -timescale 1s/1fs -amsvlog_ext .vams,.va -xmlibdirname xcelium.d)'
    if [ "$RM" = dly ]; then for v in ${EXTA_DLY[@]+"${EXTA_DLY[@]}"}; do echo "A+=(\"$v\")"; done
    else                     for v in ${EXTA[@]+"${EXTA[@]}"};         do echo "A+=(\"$v\")"; done; fi
    echo "for f in \"$RSRC\"/*.vams; do A+=(\"\$f\"); done"
    echo "A+=(\"$TB5\" -top tb -access +rwc +libext+.v+.va+.vams \"\$@\" -l xrun.log)"
    echo 'xrun "${A[@]}"'
    echo 'rc=$?; echo "RUN-KIND: '"$RUNKIND"'"; echo "xrun exit code: $rc"; exit $rc'
  } > "$RS/run.sh"
  chmod +x "$RS/run.sh" 2>/dev/null
  t0=$SECONDS
  python3 "$VH/vh_wur_report.py" --sim "$RS" > "$OUT/report.log" 2>&1; rrc=$?
  el=$((SECONDS - t0))
  tail -6 "$OUT/report.log" | sed 's/^/  /'
  npng=$(ls "$RS"/report/*.png 2>/dev/null | wc -l)
  vr=PASS; grep -q "=== TB PASS" "$RS/xrun.log" 2>/dev/null || vr=FAIL
  add_row "report (vh_wur_report.py)" "$RM" PASS "$vr" "$el" \
          "report.md + $npng PNG(s) in $RS/report/ ; models=$RM"
  say ""
fi

# ---------------------------------------------------------------- SUMMARY.md
T_ALL=$((SECONDS - T_ALL0))
SUM="$OUT/SUMMARY.md"
{
  echo "# WuR NDIV — repro SUMMARY"
  echo
  echo "| field | value |"
  echo "|---|---|"
  echo "| date | $(date '+%Y-%m-%d %H:%M:%S') |"
  echo "| host | $(hostname 2>/dev/null) |"
  echo "| xrun | \`$XRUN_BIN\` — ${XRUN_VER:-unknown} |"
  echo "| python3 | $(python3 -V 2>&1) — numpy: $HAVE_NUMPY |"
  echo "| struct | \`$STRUCT/export\` |"
  echo "| externals | $( [ -n "$EXT_LIBS" ] && echo "\`$EXT_LIBS\` (real \`-v\` libs)" || { [ -n "$EXT_STUB" ] && echo "\`$EXT_STUB\` (local stubs — dev proxy)" || echo "none"; } ) |"
  echo "| RUN-KIND | **$RUNKIND** |"
  echo "| delay models | $( [ "$DLY_OK" = yes ] && echo "\`$SRC_DLY\` (1× table, injected into a COPY)" || echo "not built" ) |"
  echo "| items | \`--only $ONLY\` · fvco=$FVCO · scales=$SCALES · models=$MODELS |"
  echo "| out | \`$OUT\` |"
  echo "| runs / failures | $NRUN / $NFAIL |"
  echo "| wall | ${T_ALL}s |"
  echo
  echo "\`RUN-KIND: FUNCTIONAL\` + \`=== TB PASS ===\` is the only authoritative result (RED_ZONE.md)."
  echo "\`expect\`: **PASS/FAIL** = enforced (a mismatch fails this kit); **INFO** = sweep point,"
  echo "recorded but never enforced — its break point is expected to move with real cell timing."
  echo
  echo "| run | models | verdict | expect | kind | elapsed | key numbers |"
  echo "|---|---|:--:|:--:|---|--:|---|"
  awk -F'\t' '{
      mark = ($5==$4 || $4=="INFO") ? "" : " ⚠";
      printf "| `%s` | %s | **%s**%s | %s | %s | %s | %s |\n", $1,$2,$5,mark,$4,$3,$6,$7 }' "$ROWS"
  echo
  echo "Per-run artefacts: \`runs/<name>/{cmd.txt,xrun.log,console.log}\` · preflight: \`preflight.log\`"
  echo "Compare against: \`../SDM_32K_RESULTS.md\`, \`../DELAYS.md\`, \`../SPEC_CHECKLIST.md\`, \`README_REPRO.md\`."
} > "$SUM"

say "================== SUMMARY =================="
cat "$SUM"
say ""
say "SUMMARY written to: $SUM"
if [ "$NFAIL" -gt 0 ]; then
  say "RESULT: $NFAIL of $NRUN enforced run(s) did NOT match expectation."
  exit 1
fi
say "RESULT: all $NRUN run(s) matched expectation.  RUN-KIND: $RUNKIND"
exit 0
