#!/usr/bin/env bash
# gate.sh -- public-repo isolation gate (plan section 7).
#
# Greps files of this repository for keywords listed in a keyword file that
# lives OUTSIDE the repository. Any hit -> prints file:line:match and exits 1.
# Zero hits -> exits 0. Usage/grep errors -> exit 2. This script itself
# contains no keywords.
#
# Scope (default): everything under relkit/ (tracked, untracked AND ignored),
# plus every file this branch adds/changes relative to the merge-base with
# $RELKIT_GATE_BASE (default: main), plus untracked non-ignored files anywhere.
# Content that was already on the base branch is not re-judged here; use
# --all to scan the whole working tree (only .git/ skipped).
#
#   bash relkit/tools/gate.sh [--all] [<keyword-file>]
#   (keyword file default: $RELKIT_GATE_KEYWORDS, else the private default below)
#
# Keyword file format: one keyword per line, matched as a fixed string,
# case-insensitively; blank lines and lines starting with '#' are ignored.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DEFAULT_KW="C:/code/Circuit_helper/private/references/relstudio/relkit_golden/gate_keywords.txt"
ALL=0
if [ "${1:-}" = "--all" ]; then ALL=1; shift; fi
KW="${1:-${RELKIT_GATE_KEYWORDS:-$DEFAULT_KW}}"
BASE="${RELKIT_GATE_BASE:-main}"

if [ ! -f "$KW" ]; then
  echo "gate: keyword file not found: $KW (set RELKIT_GATE_KEYWORDS)" >&2
  exit 2
fi
case "$(cd "$(dirname "$KW")" && pwd)/" in
  "$REPO"/*) echo "gate: keyword file must live outside the repository" >&2; exit 2 ;;
esac

PATTERNS="$(mktemp)"
trap 'rm -f "$PATTERNS"' EXIT

# Strip CR, comments, blank lines and surrounding whitespace, then turn each
# fixed string into a case-insensitive basic regex, e.g. "ab.c" -> "[aA][bB]\.[cC]".
# (grep -i together with -f/-F aborts in some Git-for-Windows grep builds, so
# case-insensitivity is spelled out instead of relying on -i.)
tr -d '\r' < "$KW" \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | { grep -v -e '^#' -e '^$' || true; } \
  | awk -v specials='.[]*^$\\' '{
      out = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1); lc = tolower(c); uc = toupper(c)
        if (lc != uc)                out = out "[" lc uc "]"
        else if (index(specials, c)) out = out "\\" c
        else                         out = out c
      }
      print out
    }' > "$PATTERNS"

N="$(wc -l < "$PATTERNS" | tr -d ' ')"
if [ "$N" -eq 0 ]; then
  echo "gate: keyword file has no keywords: $KW" >&2
  exit 2
fi

cd "$REPO"
set +e
if [ "$ALL" = 1 ]; then
  SCOPE="whole tree"
  HITS="$(grep -rnIo --exclude-dir=.git -f "$PATTERNS" .)"
  RC=$?
else
  FILES="$(mktemp)"
  trap 'rm -f "$PATTERNS" "$FILES"' EXIT
  {
    find relkit -type f 2>/dev/null
    MB="$(git merge-base HEAD "$BASE" 2>/dev/null)"
    if [ -n "$MB" ]; then
      git diff --name-only --diff-filter=d "$MB"
    else
      echo "gate: warning: no merge-base with $BASE; scanning relkit/ + untracked only" >&2
    fi
    git ls-files -o --exclude-standard
  } | sed 's#^\./##' | sort -u > "$FILES"
  SCOPE="relkit/ + files changed vs $BASE ($(wc -l < "$FILES" | tr -d ' ') files)"
  HITS=""
  RC=1
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    H="$(grep -nIo -f "$PATTERNS" -- "$f")"
    R=$?
    if [ "$R" -gt 1 ]; then RC=$R; break; fi
    if [ "$R" -eq 0 ]; then
      RC=0
      HITS="$HITS$(printf '%s\n' "$H" | sed "s#^#$f:#")
"
    fi
  done < "$FILES"
  HITS="$(printf '%s' "$HITS" | sed '/^$/d')"
fi
set -e
if [ "$RC" -gt 1 ]; then
  echo "gate: grep failed (exit $RC) -- result unknown, treat as FAIL" >&2
  exit 2
fi
if [ -n "$HITS" ]; then
  printf '%s\n' "$HITS"
  echo "gate: FAIL -- $(printf '%s\n' "$HITS" | wc -l | tr -d ' ') hit(s) for $N keywords; scope: $SCOPE" >&2
  exit 1
fi
echo "gate: PASS -- 0 hits for $N keywords; scope: $SCOPE"
