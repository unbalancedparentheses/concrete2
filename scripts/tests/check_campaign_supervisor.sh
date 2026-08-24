#!/usr/bin/env bash
# THE SUPERVISOR'S DECISION, ATTACKED DIRECTLY.
#
# The mutation campaign publishes qualification from a SUPERVISOR that outlives the child running the
# campaign, because a process cannot safely publish a verdict about its own exit: reconciliation and
# artifact installation used to happen inside the run, before the EXIT trap's final dirty-target
# check, so a target changing after the last reconciliation let the run print and durably store
# `qualified=1` and then exit nonzero. A failed process left a passing artifact behind.
#
# That decision was reachable only by running a full campaign — hours — which means in practice it
# was never attacked. It now lives in lib/campaign_supervise.sh as a pure function, and this gate
# feeds it hostile inputs that are otherwise hard to produce: a child that exits zero after
# corrupting the tree, a truncated candidate, a candidate that claims qualification it did not earn.
#
# EVERY REFUSAL HAS A POSITIVE CONTROL. A gate that only checks refusals passes when the function
# refuses everything, which would be just as broken and far easier to ship.
set -uEo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/tests/lib/campaign_supervise.sh" || { echo "cannot load the decision library" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A well-formed candidate claiming a fully qualified campaign. Every hostile case below is this file
# with exactly one thing wrong, so a refusal is attributable to that one thing.
GOOD="$TMP/good"
cat > "$GOOD" <<'EOF'
completed=1
mode=campaign
discovered=82
selected=82
executed=82
reported=82
killed=82
integrity_ok=1
qualified=1
EOF
H="headsha"; T="trackedsha"; U="untrackedsha"
sed 's/^qualified=1$/qualified=0/' "$GOOD" > "$TMP/unqual"

# expect <label> <expected-substring-or-EMPTY> <args...>
expect() {
  local label="$1" want="$2"; shift 2
  local got; got="$(supervisor_refusals "$@")"
  if [ "$want" = "EMPTY" ]; then
    [ -z "$got" ] && ok "$label" || no "$label — expected no refusal, got '$got'"
  else
    case "$got" in *"$want"*) ok "$label" ;; *) no "$label — expected /$want/, got '${got:-<none>}'" ;; esac
  fi
}

echo "=== positive control: a clean child and an unchanged tree must NOT refuse ==="
expect "a clean run publishes (no refusal)" EMPTY 0 "$GOOD" "$H" "$H" "$T" "$T" "$U" "$U"
[ "$(supervisor_qualification "$GOOD" "")" = "qualified=1" ] \
  && ok "...and its qualified=1 is carried forward" \
  || no "a clean run's qualification was dropped"

echo "=== the child's exit is evidence ==="
expect "a child that exits nonzero refuses"            "child_exit(1)"  1 "$GOOD" "$H" "$H" "$T" "$T" "$U" "$U"
expect "a child killed by a signal refuses"            "child_exit(143)" 143 "$GOOD" "$H" "$H" "$T" "$T" "$U" "$U"

echo "=== the candidate must exist and be a record ==="
expect "a missing candidate refuses" "candidate_missing" 0 "$TMP/nope" "$H" "$H" "$T" "$T" "$U" "$U"
: > "$TMP/empty"
expect "an empty candidate refuses"  "candidate_missing" 0 "$TMP/empty" "$H" "$H" "$T" "$T" "$U" "$U"
# TRUNCATION IS THE REALISTIC CORRUPTION: a partial write parses as a valid record with fields
# missing, and each missing field is named so the diagnosis does not require guessing.
for k in $CAMPAIGN_CANDIDATE_KEYS; do
  grep -v "^$k=" "$GOOD" > "$TMP/miss.$k"
  expect "a candidate missing '$k' refuses by name" "candidate_malformed($k)" 0 "$TMP/miss.$k" "$H" "$H" "$T" "$T" "$U" "$U"
done

echo "=== the supervisor's own reconciliation ==="
expect "HEAD moving under the run refuses"       "supervisor_head_changed"      0 "$GOOD" "$H" "other" "$T" "$T" "$U" "$U"
expect "a tracked change under the run refuses"  "supervisor_tracked_changed"   0 "$GOOD" "$H" "$H" "$T" "other" "$U" "$U"
expect "an untracked change under the run refuses" "supervisor_untracked_changed" 0 "$GOOD" "$H" "$H" "$T" "$T" "$U" "other"

echo "=== an unreadable tree state is not an unchanged tree ==="
# Two unavailable values compare EQUAL, so a naive reconciliation agrees with itself and publishes.
expect "TREESTATE-UNAVAILABLE refuses even when both sides match" "supervisor_tree_state_unavailable" \
  0 "$GOOD" "TREESTATE-UNAVAILABLE:head" "TREESTATE-UNAVAILABLE:head" "$T" "$T" "$U" "$U"
expect "an empty tree state refuses even when both sides match" "supervisor_tree_state_empty" \
  0 "$GOOD" "" "" "$T" "$T" "$U" "$U"

echo "=== qualification is the supervisor's to grant ==="
[ "$(supervisor_qualification "$GOOD" "supervisor_tracked_changed")" = "qualified=0" ] \
  && ok "a refused run cannot publish qualified=1" \
  || no "a refused run kept its qualification"
[ "$(supervisor_qualification "$TMP/nope" "")" = "qualified=0" ] \
  && ok "a missing candidate cannot publish qualified=1" \
  || no "a missing candidate produced a qualification"
[ "$(supervisor_qualification "$TMP/unqual" "")" = "qualified=0" ] \
  && ok "a candidate that did not claim qualification is not granted one" \
  || no "qualification was invented for a candidate that did not claim it"

echo "=== a candidate must JUSTIFY its own qualification, not merely declare it ==="
# Key presence was the only check, so a record that contradicts itself qualified. Each case below is
# the good candidate with exactly one field made incoherent, so the refusal is attributable.
inc() { # label field value expected-substring
  local f="$TMP/inc.$2"; sed "s/^$2=.*/$2=$3/" "$GOOD" > "$f"
  local got; got="$(candidate_incoherent "$f")"
  case "$got" in *"$4"*) ok "$1" ;; *) no "$1 — expected /$4/, got '${got:-<none>}'" ;; esac
  [ "$(supervisor_qualification "$f" "")" = "qualified=0" ] \
    && ok "...and it cannot publish qualified=1" || no "$1 — it published qualification anyway"
}
inc "qualified=1 with completed=0 is incoherent"       completed 0     qualified_without_completed
inc "qualified=1 with integrity_ok=0 is incoherent"    integrity_ok 0  qualified_without_integrity
inc "qualified=1 in single-family mode is incoherent"  mode single     qualified_in_single_mode
inc "qualified=1 with counts that do not reconcile"    reported 81     qualified_with_counts
inc "qualified=1 with unkilled families"               killed 80       qualified_with_unkilled

for v in survived invalid could_not_apply; do
  f="$TMP/inc.$v"; { cat "$GOOD"; printf '%s=1\n' "$v"; } > "$f"
  got="$(candidate_incoherent "$f")"
  case "$got" in *"qualified_with_$v"*) ok "qualified=1 with $v=1 is incoherent" ;;
    *) no "qualified=1 with $v=1 — expected refusal, got '${got:-<none>}'" ;; esac
done

# THE POSITIVE CONTROL FOR COHERENCE ITSELF: the good candidate must remain coherent, or every case
# above would pass for the wrong reason.
[ -z "$(candidate_incoherent "$GOOD")" ] \
  && ok "a coherent candidate is not refused by the coherence check" \
  || no "the coherence check refuses a well-formed candidate: $(candidate_incoherent "$GOOD")"
# ...and a candidate that never claimed qualification is not judged on coherence at all.
[ -z "$(candidate_incoherent "$TMP/unqual")" ] \
  && ok "a candidate not claiming qualification is not held to it" \
  || no "an unqualified candidate was judged on qualification coherence"

echo ""
echo "CAMPAIGN-SUPERVISOR: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
