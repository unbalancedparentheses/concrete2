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
# The disposition fields are PRESENT and zero. Omitting them from the fixture entrenched the
# fail-open it was supposed to expose: a truncated record loses exactly the fields that would deny
# qualification, so absent-means-zero qualifies precisely the records that should not.
cat > "$GOOD" <<'EOF'
completed=1
mode=campaign
discovered=85
selected=85
executed=85
reported=85
killed=85
invalid=0
survived=0
could_not_apply=0
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
  # SUBSTITUTED, not appended: appending leaves TWO values for the key and the reader takes the
  # first, so the contradiction reads as the benign value. That is itself a defect, covered below.
  f="$TMP/inc.$v"; sed "s/^$v=.*/$v=1/" "$GOOD" > "$f"
  got="$(candidate_incoherent "$f")"
  case "$got" in *"qualified_with_$v"*) ok "qualified=1 with $v=1 is incoherent" ;;
    *) no "qualified=1 with $v=1 — expected refusal, got '${got:-<none>}'" ;; esac
done

echo "=== a key with two values is not a record ==="
for v in survived qualified killed; do
  f="$TMP/dup.$v"; { cat "$GOOD"; printf '%s=1\n' "$v"; } > "$f"
  expect "a duplicated '$v' is refused as a duplicate, not read as its first value" \
    "candidate_duplicate($v)" 0 "$f" "$H" "$H" "$T" "$T" "$U" "$U"
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

echo "=== counts must be numbers that reconcile, not strings that match ==="
# String equality accepted five identical NON-NUMERIC values, so a record of five "x" qualified.
for fld in discovered selected executed reported killed; do
  sed "s/^$fld=.*/$fld=x/" "$GOOD" > "$TMP/nn.$fld"
  got="$(candidate_incoherent "$TMP/nn.$fld")"
  case "$got" in *nonnumeric*) ok "a non-numeric $fld is refused" ;;
    *) no "a non-numeric $fld was accepted (got '${got:-<none>}')" ;; esac
done
sed 's/=8[0-9]*$/=x/' "$GOOD" > "$TMP/allx"
got="$(candidate_incoherent "$TMP/allx")"
[ -n "$got" ] && ok "five identical non-numeric counts do not reconcile" \
  || no "five identical non-numeric counts qualified"
for fld in discovered selected executed reported killed; do sed -i "s/^$fld=.*/$fld=0/" "$TMP/allx"; done
sed -i 's/^qualified=.*/qualified=1/' "$TMP/allx"
got="$(candidate_incoherent "$TMP/allx")"
case "$got" in *zero_families*) ok "a campaign that discharged ZERO families does not qualify" ;;
  *) no "zero families qualified (got '${got:-<none>}')" ;; esac

echo "=== a missing disposition is absent evidence, not a zero ==="
for v in invalid survived could_not_apply; do
  grep -v "^$v=" "$GOOD" > "$TMP/nodisp.$v"
  got="$(candidate_incoherent "$TMP/nodisp.$v")"
  case "$got" in *"qualified_without_$v"*) ok "a candidate with no '$v' field does not qualify" ;;
    *) no "a missing '$v' was treated as zero (got '${got:-<none>}')" ;; esac
  # ...and it is a mandatory key, so the record is malformed as well as incoherent.
  expect "a candidate missing '$v' is malformed" "candidate_malformed($v)" \
    0 "$TMP/nodisp.$v" "$H" "$H" "$T" "$T" "$U" "$U"
done

echo "=== the four dispositions must account for the reported families ==="
# Each disposition being zero and killed==reported still leaves the ledger unbalanced if a family is
# reported under NO disposition. This is the identity that makes the four numbers one population.
sed -e 's/^killed=.*/killed=84/' -e 's/^invalid=.*/invalid=0/' "$GOOD" > "$TMP/unbal"
got="$(candidate_incoherent "$TMP/unbal")"
case "$got" in *unbalanced_ledger*|*unkilled*) ok "reported families unaccounted by the dispositions is refused" ;;
  *) no "an unbalanced ledger qualified (got '${got:-<none>}')" ;; esac
# ...and a BALANCED ledger with real dispositions must not qualify either, since they are nonzero —
# but it must be refused for the disposition, not for the ledger.
sed -e 's/^killed=.*/killed=84/' -e 's/^survived=.*/survived=1/' "$GOOD" > "$TMP/bal"
got="$(candidate_incoherent "$TMP/bal")"
case "$got" in *qualified_with_survived*) ok "a balanced ledger with a survivor is refused for the survivor" ;;
  *) no "a balanced ledger with a survivor was misdiagnosed (got '${got:-<none>}')" ;; esac

echo "=== negative, noncanonical and implausible numbers are not numbers ==="
for spec in "discovered=-1:nonnumeric" "killed=007:noncanonical" "reported=1234567:implausible"; do
  fld="${spec%%=*}"; rest="${spec#*=}"; val="${rest%%:*}"; want="${rest##*:}"
  sed "s/^$fld=.*/$fld=$val/" "$GOOD" > "$TMP/num.$fld"
  got="$(candidate_incoherent "$TMP/num.$fld")"
  case "$got" in *"$want"*) ok "$fld=$val is refused ($want)" ;;
    *) no "$fld=$val was accepted (got '${got:-<none>}')" ;; esac
done

echo "=== duplicate keys are refused whether they contradict or agree ==="
# An IDENTICAL duplicate is still not a record: it is evidence that two writers produced this file.
for v in qualified killed invalid; do
  val="$(sed -n "s/^$v=//p" "$GOOD" | head -1)"
  { cat "$GOOD"; printf '%s=%s\n' "$v" "$val"; } > "$TMP/dupeq.$v"
  expect "an identical duplicate '$v' is still refused" "candidate_duplicate($v)" \
    0 "$TMP/dupeq.$v" "$H" "$H" "$T" "$T" "$U" "$U"
done

echo ""
echo "CAMPAIGN-SUPERVISOR: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
