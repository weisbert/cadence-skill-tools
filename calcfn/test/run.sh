#!/bin/bash
# usage: run.sh <path/to/file.ocn> [nlines]
#   OCEAN replay with -nograph from the .ocn's own directory; prints CASE/SUMMARY lines and errors.
cd "$(dirname "$1")" || exit 1
f=$(basename "$1"); log="${f%.ocn}.log"; rm -f "$log" "$log.cdslck"
tcsh -c "source ~/.cshrc >& /dev/null; virtuoso -nograph -replay $f -log $log >& /dev/null"
grep -a -E '^.o (CASE|SUMMARY|\[calcfn\])|\*Error\*' "$log" | sed 's/^.o //' | head -${2:-80}
