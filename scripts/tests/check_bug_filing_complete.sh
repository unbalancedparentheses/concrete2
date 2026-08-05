#!/usr/bin/env bash
# A filed bug requires THREE artifacts, and this gate is what makes that a rule rather
# than a remembered procedure:
#
#   1. docs/bugs/NNN_*.md          — the document
#   2. an entry in audit_bug_corpus.sh — BUG_TEST_MAP (a fixture) or SKIP_BUGS (a
#                                        rationale naming the coverage)
#   3. coverage that actually exists  — the fixture file, or a named gate script
#
# Bug 066 shipped with 1 and 3 but not 2, and main went red on the CI-only trust gate.
# This runs in seconds so the FIRST local push catches it; the trust gate stays in CI
# as the broader backstop.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
fatal() { local rc=$?; echo "FATAL: check_bug_filing_complete stopped at line ${BASH_LINENO[0]} (exit $rc)" >&2; exit "$rc"; }
trap fatal ERR
PASS=0; FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

AUDIT="scripts/tests/audit_bug_corpus.sh"
[ -f "$AUDIT" ] || { echo "error: $AUDIT missing" >&2; exit 2; }

docs=0; missing=""
for f in docs/bugs/[0-9][0-9][0-9]_*.md; do
  [ -e "$f" ] || continue
  docs=$((docs+1))
  n="$(basename "$f" | cut -c1-3)"
  # Entry in either map. Both are `[NNN]=` keyed, so one grep covers them.
  if ! grep -qE "^\s*\[$n\]=" "$AUDIT"; then
    missing="$missing $n"
  fi
done

if [ "$docs" -eq 0 ]; then
  no "no bug documents found — the scan pattern is wrong, so every leg below is vacuous"
else
  ok "scanned $docs bug documents"
fi

if [ -z "$missing" ]; then
  ok "every bug document has a corpus entry"
else
  no "bug documents with NO entry in $AUDIT:$missing (add to BUG_TEST_MAP with a fixture, or SKIP_BUGS with a rationale naming the coverage)"
fi

# The reverse direction: an entry naming a fixture whose file does not exist is a map
# that claims coverage it does not have — the same defect pointing the other way.
absent=""
while IFS= read -r line; do
  n="$(sed -E 's/^[[:space:]]*\[([0-9]+)\]=.*/\1/' <<<"$line")"
  val="$(sed -E 's/^[[:space:]]*\[[0-9]+\]="?([^"]*)"?.*/\1/' <<<"$line")"
  case "$val" in *.con*) ;; *) continue ;; esac
  for cand in $val; do
    case "$cand" in *.con) ;; *) continue ;; esac
    [ -e "tests/programs/$cand" ] || [ -e "$cand" ] || absent="$absent $n:$cand"
  done
done <<< "$(awk '/declare -A BUG_TEST_MAP/,/^\)/' "$AUDIT" | grep -E '^\s*\[[0-9]+\]=')"
if [ -z "$absent" ]; then
  ok "every fixture named in BUG_TEST_MAP exists on disk"
else
  no "BUG_TEST_MAP names fixtures that do not exist:$absent"
fi

# A SKIP_BUGS rationale must NAME its coverage, or "skip" degrades into "untested".
vague=""
while IFS= read -r line; do
  n="$(sed -E 's/^[[:space:]]*\[([0-9]+)\]=.*/\1/' <<<"$line")"
  if ! grep -qE "\.con|\.sh|OPEN|HALF CLOSED" <<<"$line"; then
    vague="$vague $n"
  fi
done <<< "$(awk '/declare -A SKIP_BUGS/,/^\)/' "$AUDIT" | grep -E '^\s*\[[0-9]+\]=')"
# RATCHET, not a bar. Six historical entries name a commit or a prose rationale rather
# than a fixture or gate; retrofitting them is separate work and blocking every push on
# it would be the wrong trade. What must not happen is a NEW one, so the count may fall
# and must never rise.
VAGUE_BASELINE=6
n_vague=$(printf '%s' "$vague" | wc -w | tr -d ' ')
if [ "$n_vague" -le "$VAGUE_BASELINE" ]; then
  if [ "$n_vague" -lt "$VAGUE_BASELINE" ]; then
    ok "SKIP_BUGS entries naming no concrete coverage: $n_vague (below baseline $VAGUE_BASELINE — lower it)"
  else
    ok "no NEW SKIP_BUGS entry without concrete coverage ($n_vague at baseline)"
  fi
else
  no "a SKIP_BUGS entry names no fixture, gate or OPEN status ($n_vague > baseline $VAGUE_BASELINE):$vague"
fi

echo "BUG-FILING-COMPLETE: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
