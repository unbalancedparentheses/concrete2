#!/usr/bin/env bash
# SHELL-GATE HYGIENE — a gate must parse, must not stop early, and must not disagree with itself.
#
# WHY THIS EXISTS. `check_clean_checkout.sh` reported `PASS=11 FAIL=0` and exited 1 for two days.
# Both facts had one cause: a stray `exit 1` sat immediately before an orphan `fi`. Bash executes a
# script incrementally, so the exit ran before the parser ever reached the invalid token — the
# syntax error was CONCEALED BY the statement that truncated the gate, and 17 of its 37 assertions
# never ran. The summary said one thing, the exit status said another, and the two were believed
# separately by a human reading output and a runner reading `$?`.
#
# Every control here is static: no builds, no gate execution, no lock. It runs in seconds on every
# push, which is the point — the expensive checks are the ones nobody runs when it matters.
#
# THE CONTROLS ARE SELF-TESTED against deliberately malformed fixtures at the end. A lint that
# cannot fail is the same defect class it exists to catch, and this one is specifically about
# defects that hide from casual inspection.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

mapfile -t GATES < <(ls scripts/tests/check_*.sh scripts/tests/run_*.sh scripts/ci/*.sh 2>/dev/null | LC_ALL=C sort -u)

# NON-VACUITY FIRST. Every control below iterates this list, so an empty or truncated list makes all
# of them pass while checking nothing — and would read exactly like a clean corpus.
if [ "${#GATES[@]}" -ge 100 ]; then
  ok "enumerated ${#GATES[@]} shell gates (floor 100 — a broken glob cannot pass as a clean corpus)"
else
  no "only ${#GATES[@]} gates enumerated; the glob is broken and every control below is vacuous"
  echo "GATE-HYGIENE: PASS=$PASS FAIL=$FAIL"; exit 1
fi

# ---------------------------------------------------------------------------
echo "=== 1. every gate parses ==="
# `bash -n` over the whole corpus, not just files someone happened to edit. The incident file had
# been syntactically invalid on main for two days; I ran `bash -n` religiously on files I edited by
# script that week and never on the one I edited by hand.
BAD=""
for g in "${GATES[@]}"; do bash -n "$g" 2>/dev/null || BAD="$BAD $g"; done
if [ -z "$BAD" ]; then
  ok "all ${#GATES[@]} gates parse under bash -n"
else
  no "gate(s) do not parse:$BAD"
fi

# ---------------------------------------------------------------------------
echo "=== 2. no unconditional early exit strands later assertions ==="
# The precise shape of the incident: a top-level `exit N` with assertions after it. Restricted to
# COLUMN ZERO so the many legitimate early exits — inside `if`/`else`/`case`, indented — are not
# flagged. A gate that means to bail on a precondition does so inside a conditional; one that exits
# unconditionally mid-file is either debugging residue or dead code below.
STRANDED=""
for g in "${GATES[@]}"; do
  line="$(grep -nE '^(exit [0-9]+|GATE_DONE=1; echo [^;]*; exit [0-9]+)$' "$g" | head -1 | cut -d: -f1 || true)"
  [ -z "$line" ] && continue
  total="$(wc -l < "$g")"
  [ "$line" -ge "$((total - 2))" ] && continue   # a trailing exit is the normal ending
  after="$(awk -v n="$line" 'NR>n' "$g" | grep -cE '^\s*(ok|no) "' || true)"
  [ "${after:-0}" -gt 0 ] && STRANDED="$STRANDED $(basename "$g"):line$line(+${after}_assertions)"
done
if [ -z "$STRANDED" ]; then
  ok "no gate has an unconditional top-level exit with assertions after it"
else
  no "unconditional early exit strands assertions:$STRANDED"
fi

# ---------------------------------------------------------------------------
echo "=== 3. a summary line and the exit status cannot disagree ==="
# A gate printing `FAIL=0` must not exit non-zero. Checked structurally: a gate that emits a
# `PASS=.. FAIL=..` summary should end by deriving its status from that count — `[ "$FAIL" -eq 0 ]`
# or an equivalent — rather than by a literal `exit 1` that ignores it.
DISAGREE=""
for g in "${GATES[@]}"; do
  grep -qE 'echo "[A-Z0-9-]+: *PASS=' "$g" || continue          # only gates with a summary
  tail_5="$(tail -5 "$g")"
  grep -qE '\[ "\$FAIL" -(eq|ne) 0 \]|exit \$\(\( *FAIL|\[ "\$\{FAIL' <<<"$tail_5" && continue
  grep -qE '^exit [1-9]' <<<"$tail_5" && DISAGREE="$DISAGREE $(basename "$g")"
done
if [ -z "$DISAGREE" ]; then
  ok "every gate with a PASS/FAIL summary derives its exit status from that count"
else
  no "gate(s) end in a literal non-zero exit despite printing a summary:$DISAGREE"
fi

# ---------------------------------------------------------------------------
echo "=== the controls are tested against deliberately broken fixtures ==="
# Without this, every control above is satisfiable by an implementation that never reports anything,
# and the corpus being clean is indistinguishable from the lint being inert.
mkfix(){ printf '%s\n' "$2" > "$TMP/$1"; }

mkfix parse_bad.sh 'PASS=0
if [ 1 = 1 ]; then echo hi
fi
fi'
bash -n "$TMP/parse_bad.sh" 2>/dev/null \
  && no "CONTROL: a syntactically invalid fixture parsed cleanly — control 1 is inert" \
  || ok "CONTROL: control 1 rejects a fixture with an unbalanced fi"

# The fixture's `exit` is assembled rather than written literally: a bare `exit 1` at column zero
# in THIS file is indistinguishable to control 2 from the defect it looks for, and the lint duly
# flagged itself on first run. Exempting the file would have been the easy fix and the wrong one —
# a lint that cannot be applied to itself is one fewer gate under the rule.
EXIT_TOKEN="$(printf %s exit) 1"
mkfix early_exit.sh "PASS=0
ok(){ :; }
${EXIT_TOKEN}
ok \"this assertion can never run\"
ok \"nor this one\"
echo \"X: PASS=0 FAIL=0\""
el="$(grep -nE '^exit [0-9]+$' "$TMP/early_exit.sh" | head -1 | cut -d: -f1)"
ea="$(awk -v n="$el" 'NR>n' "$TMP/early_exit.sh" | grep -cE '^\s*(ok|no) "')"
if [ "${ea:-0}" -gt 0 ]; then
  ok "CONTROL: control 2 sees $ea assertions stranded after an unconditional exit"
else
  no "CONTROL: control 2 did not detect stranded assertions — it is inert"
fi

mkfix disagree.sh 'FAIL=0
echo "X: PASS=3 FAIL=$FAIL"
exit 1'
dt="$(tail -5 "$TMP/disagree.sh")"
if grep -qE '^exit [1-9]' <<<"$dt" && ! grep -qE '\[ "\$FAIL" -(eq|ne) 0 \]' <<<"$dt"; then
  ok "CONTROL: control 3 sees a summary contradicted by a literal non-zero exit"
else
  no "CONTROL: control 3 did not detect a summary/exit contradiction — it is inert"
fi

# ...and the converse, so the controls are not simply always-true.
mkfix wellformed.sh 'FAIL=0
echo "X: PASS=3 FAIL=$FAIL"
[ "$FAIL" -eq 0 ]'
wt="$(tail -5 "$TMP/wellformed.sh")"
if grep -qE '\[ "\$FAIL" -eq 0 \]' <<<"$wt"; then
  ok "CONTROL: a well-formed gate is NOT flagged by control 3"
else
  no "CONTROL: control 3 flags a well-formed gate — it would fail the whole corpus"
fi

echo "GATE-HYGIENE: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
