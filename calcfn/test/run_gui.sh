#!/bin/bash
# usage: run_gui.sh <path/to/file.ocn> [nlines]
#   same as run.sh, but with a GUI on a private Xvfb display (Calculator, Maestro).
cd "$(dirname "$1")" || exit 1
f=$(basename "$1"); log="${f%.ocn}.log"; rm -f "$log" "$log.cdslck"
timeout 600 xvfb-run -a -s "-screen 0 1900x1200x24" \
  tcsh -c "source ~/.cshrc >& /dev/null; virtuoso -replay $f -log $log >& /dev/null"
grep -a -E '^.o (CASE|SUMMARY|\[calcfn\])|\*Error\*' "$log" | sed 's/^.o //' | head -${2:-80}
