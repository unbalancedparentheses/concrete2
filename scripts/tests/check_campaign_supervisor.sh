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
# THE FIXTURE IS BUILT FROM THE SCHEMA, NOT ALONGSIDE IT.
#
# It used to be a hand-written list of twelve fields. When the decoder began requiring the full
# declared key set, every case below started failing on `missing_key(...)` for thirty other fields
# instead of on the one thing it had deliberately broken — so a suite that reported 41/24 was not
# testing what its labels said, and the 65/0 it had reported earlier described a decoder that no
# longer existed. A fixture derived from CAMPAIGN_SCHEMA cannot fall behind it: a new declared key
# appears here automatically, and a key removed from the schema disappears from here too.
#
# Numeric fields default to 0 and freeform ones to a placeholder; the semantic values that the cases
# actually reason about are then set explicitly, so the fixture reads as "a fully qualified campaign"
# and every hostile variant below is this file with exactly one thing wrong.
: > "$GOOD"
for _k in $CAMPAIGN_SCHEMA_NUMERIC;  do echo "$_k=0" >> "$GOOD"; done
for _k in $CAMPAIGN_SCHEMA_FREEFORM; do echo "$_k=fixture" >> "$GOOD"; done
_set() { # key value — replace in place, refusing to invent a key the schema does not declare
  grep -q "^$1=" "$GOOD" || { echo "FIXTURE BUG: '$1' is not a declared schema key" >&2; exit 2; }
  sed -i.bak "s|^$1=.*|$1=$2|" "$GOOD" && rm -f "$GOOD.bak"
}
_set completed 1
_set mode campaign
for _k in discovered selected executed reported killed families_declared families_run evidence_written; do
  _set "$_k" 85
done
_set killed_by_gate 85
_set integrity_ok 1
_set qualified 1
_set refusals ""
# The producer writes exactly `.mutation-evidence/<run_id>`; the fixture must look like the artifact.
_set evidence_dir ".mutation-evidence/fixture"
# PRODUCTION SHAPES, taken from what the publisher actually writes: both are `<n>/<m>`.
# The fixture previously said `yes` and `all`, which no producer emits — a fixture that does not
# look like the artifact cannot test the checks that read the artifact.
_set baseline_gates_green 36/36
_set gates_proven 85/85
# The record must decode cleanly before any case can attribute a refusal to its own mutation.
# THE PINNED POPULATION IS PART OF THE CALL. `candidate_incoherent` takes the family count a
# qualifying campaign must have discharged, and every call here omitted it — so the positive control
# was refused with `qualified_without_a_pinned_population` and the suite could not have been green.
POP=85
# The declared GATE population, distinct from the family population: 85 families target 36 gates.
GATES=36
_fixture_refusals="$(decode_candidate "$GOOD")"
if [ -n "$_fixture_refusals" ]; then
  echo "FIXTURE BUG: the positive control does not decode:$_fixture_refusals" >&2
  exit 2
fi

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
# The population argument is required here too — see POP above.
[ "$(supervisor_qualification "$GOOD" "" "$POP")" = "qualified=1" ] \
  && ok "...and its qualified=1 is carried forward" \
  || no "a clean run's qualification was dropped: $(supervisor_qualification "$GOOD" "" "$POP")"

# AND THE POPULATION MAY NOT BE OMITTED. Every call above passes it, so nothing above would notice
# if the requirement were dropped and an unpinned campaign began qualifying itself.
case "$(candidate_incoherent "$GOOD")" in
  *qualified_without_a_pinned_population*) ok "omitting the pinned population is itself a refusal" ;;
  *) no "a candidate qualified with no population pinned: '$(candidate_incoherent "$GOOD")'" ;;
esac
# A population that disagrees with the record is a refusal, not a rounding difference.
case "$(candidate_incoherent "$GOOD" 84)" in
  ?*) ok "a record discharging 85 families does not qualify against a pinned 84" ;;
  *)  no "population mismatch accepted" ;;
esac

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
  expect "a candidate missing '$k' refuses by name" "candidate_schema(missing_key($k))" 0 "$TMP/miss.$k" "$H" "$H" "$T" "$T" "$U" "$U"
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
  local got; got="$(candidate_incoherent "$f" "$POP" "$GATES")"
  case "$got" in *"$4"*) ok "$1" ;; *) no "$1 — expected /$4/, got '${got:-<none>}'" ;; esac
  # THE POPULATION IS PASSED HERE TOO. Omitting it made every one of these five second assertions
  # pass for the same irrelevant reason — a missing pinned population already forces qualified=0 —
  # so each would have stayed green with its named field-specific check deleted. A control that
  # cannot distinguish "the field is wrong" from "I forgot an argument" is not a control.
  [ "$(supervisor_qualification "$f" "" "$POP")" = "qualified=0" ] \
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
  got="$(candidate_incoherent "$f" "$POP" "$GATES")"
  case "$got" in *"qualified_with_$v"*) ok "qualified=1 with $v=1 is incoherent" ;;
    *) no "qualified=1 with $v=1 — expected refusal, got '${got:-<none>}'" ;; esac
done

echo "=== a key with two values is not a record ==="
for v in survived qualified killed; do
  f="$TMP/dup.$v"; { cat "$GOOD"; printf '%s=1\n' "$v"; } > "$f"
  expect "a duplicated '$v' is refused as a duplicate, not read as its first value" \
    "candidate_schema(duplicate_key($v))" 0 "$f" "$H" "$H" "$T" "$T" "$U" "$U"
done

# THE POSITIVE CONTROL FOR COHERENCE ITSELF: the good candidate must remain coherent, or every case
# above would pass for the wrong reason.
[ -z "$(candidate_incoherent "$GOOD" "$POP" "$GATES")" ] \
  && ok "a coherent candidate is not refused by the coherence check" \
  || no "the coherence check refuses a well-formed candidate: $(candidate_incoherent "$GOOD" "$POP" "$GATES")"
# ...and a candidate that never claimed qualification is not judged on coherence at all.
[ -z "$(candidate_incoherent "$TMP/unqual" "$POP" "$GATES")" ] \
  && ok "a candidate not claiming qualification is not held to it" \
  || no "an unqualified candidate was judged on qualification coherence"

echo "=== counts must be numbers that reconcile, not strings that match ==="
# String equality accepted five identical NON-NUMERIC values, so a record of five "x" qualified.
for fld in discovered selected executed reported killed; do
  sed "s/^$fld=.*/$fld=x/" "$GOOD" > "$TMP/nn.$fld"
  got="$(candidate_incoherent "$TMP/nn.$fld" "$POP")"
  case "$got" in *nonnumeric*) ok "a non-numeric $fld is refused" ;;
    *) no "a non-numeric $fld was accepted (got '${got:-<none>}')" ;; esac
done
sed 's/=8[0-9]*$/=x/' "$GOOD" > "$TMP/allx"
got="$(candidate_incoherent "$TMP/allx" "$POP")"
[ -n "$got" ] && ok "five identical non-numeric counts do not reconcile" \
  || no "five identical non-numeric counts qualified"
for fld in discovered selected executed reported killed; do sed -i "s/^$fld=.*/$fld=0/" "$TMP/allx"; done
sed -i 's/^qualified=.*/qualified=1/' "$TMP/allx"
got="$(candidate_incoherent "$TMP/allx" "$POP")"
case "$got" in *zero_families*) ok "a campaign that discharged ZERO families does not qualify" ;;
  *) no "zero families qualified (got '${got:-<none>}')" ;; esac

echo "=== a missing disposition is absent evidence, not a zero ==="
for v in invalid survived could_not_apply; do
  grep -v "^$v=" "$GOOD" > "$TMP/nodisp.$v"
  got="$(candidate_incoherent "$TMP/nodisp.$v" "$POP")"
  case "$got" in *"qualified_without_$v"*) ok "a candidate with no '$v' field does not qualify" ;;
    *) no "a missing '$v' was treated as zero (got '${got:-<none>}')" ;; esac
  # ...and it is a mandatory key, so the record is malformed as well as incoherent.
  expect "a candidate missing '$v' is malformed" "candidate_schema(missing_key($v))" \
    0 "$TMP/nodisp.$v" "$H" "$H" "$T" "$T" "$U" "$U"
done

echo "=== the four dispositions must account for the reported families ==="
# Each disposition being zero and killed==reported still leaves the ledger unbalanced if a family is
# reported under NO disposition. This is the identity that makes the four numbers one population.
sed -e 's/^killed=.*/killed=84/' -e 's/^invalid=.*/invalid=0/' "$GOOD" > "$TMP/unbal"
got="$(candidate_incoherent "$TMP/unbal" "$POP")"
case "$got" in *unbalanced_ledger*|*unkilled*) ok "reported families unaccounted by the dispositions is refused" ;;
  *) no "an unbalanced ledger qualified (got '${got:-<none>}')" ;; esac
# ...and a BALANCED ledger with real dispositions must not qualify either, since they are nonzero —
# but it must be refused for the disposition, not for the ledger.
sed -e 's/^killed=.*/killed=84/' -e 's/^survived=.*/survived=1/' "$GOOD" > "$TMP/bal"
got="$(candidate_incoherent "$TMP/bal" "$POP")"
case "$got" in *qualified_with_survived*) ok "a balanced ledger with a survivor is refused for the survivor" ;;
  *) no "a balanced ledger with a survivor was misdiagnosed (got '${got:-<none>}')" ;; esac

echo "=== negative, noncanonical and implausible numbers are not numbers ==="
for spec in "discovered=-1:nonnumeric" "killed=007:noncanonical" "reported=1234567:implausible"; do
  fld="${spec%%=*}"; rest="${spec#*=}"; val="${rest%%:*}"; want="${rest##*:}"
  sed "s/^$fld=.*/$fld=$val/" "$GOOD" > "$TMP/num.$fld"
  got="$(candidate_incoherent "$TMP/num.$fld" "$POP")"
  case "$got" in *"$want"*) ok "$fld=$val is refused ($want)" ;;
    *) no "$fld=$val was accepted (got '${got:-<none>}')" ;; esac
done

echo "=== duplicate keys are refused whether they contradict or agree ==="
# An IDENTICAL duplicate is still not a record: it is evidence that two writers produced this file.
for v in qualified killed invalid; do
  val="$(sed -n "s/^$v=//p" "$GOOD" | head -1)"
  { cat "$GOOD"; printf '%s=%s\n' "$v" "$val"; } > "$TMP/dupeq.$v"
  expect "an identical duplicate '$v' is still refused" "candidate_schema(duplicate_key($v))" \
    0 "$TMP/dupeq.$v" "$H" "$H" "$T" "$T" "$U" "$U"
done

echo ""
echo "=== qualification reads every field it publishes, not just the headline counts ==="
# Each case is GOOD with exactly one field falsified, so the refusal is attributable to that field.
# Without these the new checks would be unexercised branches — indistinguishable from deleted ones.
_falsify() { # key value expected-substring label
  sed "s|^$1=.*|$1=$2|" "$GOOD" > "$TMP/fal"
  case "$(candidate_incoherent "$TMP/fal" "$POP" "$GATES")" in
    *"$3"*) ok "$4" ;;
    *) no "$4 — expected /$3/, got '$(candidate_incoherent "$TMP/fal" "$POP" "$GATES")'" ;;
  esac
}
_falsify families_run 0 qualified_with_families_run \
  "a campaign claiming 85 kills while running 0 families is refused"
_falsify evidence_written 0 qualified_with_evidence_written \
  "a campaign that reported 85 families but wrote no evidence is refused"
_falsify killed_by_gate 84 qualified_with_kill_split \
  "kills that do not split into gate and build routes are refused"
_falsify killed_by_gate x qualified_with_nonnumeric_kill_split \
  "a non-numeric kill split is refused rather than coerced"
_falsify baseline_gates_green "" qualified_without_baseline_gates_green \
  "qualification with no baseline-gates result is refused"
_falsify gates_proven "" qualified_without_gates_proven \
  "qualification with no gates-proven result is refused"
# NONEMPTY IS NOT A VALUE. These are the production shapes that are perfectly well-formed and mean
# the opposite of what qualification claims.
_falsify baseline_gates_green 0/36 qualified_with_baseline_gates_red \
  "a campaign qualifying on 0 of 36 green baseline gates is refused"
# SELF-AGREEMENT IS NOT A POPULATION. `1/1` is correct for a single-family run and meaningless for a
# campaign; the denominator must be the number of gates the inventory actually declares.
_falsify baseline_gates_green 1/1 qualified_with_baseline_gate_population \
  "a campaign qualifying on 1 of 1 baseline gates is refused"
_falsify baseline_gates_green 999/999 qualified_with_baseline_gate_population \
  "a self-agreeing ratio over an invented population is refused"
# ...and the count is read from the driver, not restated here.
[ "$(gate_count_from_driver "$ROOT_DIR/scripts/tests/check_gate_mutation_coverage.sh")" = "$GATES" ] \
  && ok "the pinned gate population matches what the driver declares" \
  || no "GATES=$GATES but the driver declares $(gate_count_from_driver "$ROOT_DIR/scripts/tests/check_gate_mutation_coverage.sh")"
_falsify gates_proven 0/85 qualified_with_gates_proven_disagreeing \
  "a campaign qualifying with 0 of 85 gates proven is refused"
_falsify gates_proven 84/85 qualified_with_gates_proven_disagreeing \
  "a gates-proven numerator that disagrees with killed_by_gate is refused"
_falsify gates_proven 85/84 qualified_with_gates_proven_population \
  "a gates-proven denominator that is not the pinned population is refused"
_falsify baseline_gates_green 0/0 qualified_with_no_baseline_gates \
  "a campaign qualifying on zero baseline gates is refused"
_falsify baseline_gates_green x/x qualified_with_unparsable_baseline_gates \
  "a ratio whose halves are equal but are not numbers is refused"
_falsify gates_proven 85/junk/85 qualified_with_unparsable_gates_proven \
  "a three-part value is not a ratio, however its ends compare"

# THE SHAPE A CORRECT CAMPAIGN ACTUALLY PUBLISHES MUST QUALIFY.
#
# Three families are killed by the BUILD rather than by their gate, so a complete campaign publishes
# gates_proven=82/85 — this driver's own header gives 78/81 as the same case. An earlier version of
# this check demanded numerator == denominator and would have REFUSED the qualifying result the whole
# programme exists to produce. A gate that rejects the outcome it is meant to certify is worse than
# no gate, so the honest build-kill shape is a positive control.
sed -e 's/^killed_by_gate=.*/killed_by_gate=82/' -e 's/^killed_by_build=.*/killed_by_build=3/' \
    -e 's|^gates_proven=.*|gates_proven=82/85|' "$GOOD" > "$TMP/buildkills"
[ -z "$(candidate_incoherent "$TMP/buildkills" "$POP" "$GATES")" ] \
  && ok "a campaign with three build-route kills and gates_proven=82/85 qualifies" \
  || no "the honest build-kill shape was refused: $(candidate_incoherent "$TMP/buildkills" "$POP" "$GATES")"
_falsify gates_proven all qualified_with_unparsable_gates_proven \
  "a gates-proven value that is not <n>/<m> is refused rather than accepted as nonempty"
_falsify families_declared 84 qualified_with_families_declared \
  "a record declaring a different population than the pinned one is refused"
_falsify failed 1 qualified_with_failures \
  "a campaign with a failure does not qualify"
# THE FIELDS NOTHING EVER READ. Both are mandatory in the schema and were checked for presence only.
_falsify refusals " fatal_integrity_failure" qualified_with_refusals \
  "a record publishing its own integrity refusals does not qualify"
_falsify evidence_dir ".mutation-evidence/some-other-run" qualified_with_foreign_evidence_dir \
  "a record pointing at another run's evidence does not qualify"
# A SUFFIX TEST ACCEPTED BOTH OF THESE. They end with the run id and name a different tree.
_falsify evidence_dir "foreign-prefix/fixture" qualified_with_foreign_evidence_dir \
  "an evidence path merely ENDING in the run id does not qualify"
_falsify evidence_dir "evilfixture" qualified_with_foreign_evidence_dir \
  "an evidence path whose last component only ends in the run id does not qualify"
_falsify evidence_dir "" qualified_without_evidence_dir \
  "a record naming no evidence directory does not qualify"
# ...and the unfalsified record still qualifies, or the six checks above are just refusing everything.
[ -z "$(candidate_incoherent "$GOOD" "$POP" "$GATES")" ] \
  && ok "the unfalsified record still qualifies (positive control for the six checks above)" \
  || no "the new field checks refuse a well-formed record: $(candidate_incoherent "$GOOD" "$POP" "$GATES")"

echo "=== the evidence directories must BE the declared family set ==="
# Naming the right digest is not the same as HOLDING the right evidence: a candidate could publish
# the correct family digest beside arbitrarily named killed directories and every total would still
# self-agree. This is the comparison the supervisor now makes on the names found on disk.
_declared="$(printf 'famA\nfamB\nfamC\n')"
_dig_declared="$(family_set_digest "$_declared")"
[ "$(family_set_digest "$(printf 'famC\nfamA\nfamB\n')")" = "$_dig_declared" ] \
  && ok "the family-set digest is order-independent (positive control)" \
  || no "the family-set digest depends on order"
[ "$(family_set_digest "$(printf 'famA\nfamB\nfamX\n')")" != "$_dig_declared" ] \
  && ok "a one-for-one family substitution changes the set digest" \
  || no "substituting a family left the set digest unchanged"
[ "$(family_set_digest "$(printf 'famA\nfamB\n')")" != "$_dig_declared" ] \
  && ok "a missing family changes the set digest" \
  || no "dropping a family left the set digest unchanged"
[ "$(family_set_digest "")" != "$_dig_declared" ] \
  && ok "an empty evidence tree does not digest as the declared set" \
  || no "the empty set digests as the declared set"

echo "=== the candidate must be THIS run's candidate ==="
sed 's|^run_id=.*|run_id=THIS-RUN|' "$GOOD" | sed 's|^head=.*|head=THIS-HEAD|' > "$TMP/bound"
[ -z "$(candidate_run_binding "$TMP/bound" THIS-RUN THIS-HEAD)" ] \
  && ok "a candidate from this run against this head binds (positive control)" \
  || no "a correctly bound candidate was refused: $(candidate_run_binding "$TMP/bound" THIS-RUN THIS-HEAD)"
case "$(candidate_run_binding "$TMP/bound" OTHER-RUN THIS-HEAD)" in
  *candidate_from_other_run*) ok "a candidate left by an EARLIER run cannot answer for this one" ;;
  *) no "a stale candidate was accepted" ;;
esac
case "$(candidate_run_binding "$TMP/bound" THIS-RUN OTHER-HEAD)" in
  *candidate_head_mismatch*) ok "a candidate describing another commit is refused" ;;
  *) no "a candidate for a different head was accepted" ;;
esac
case "$(candidate_run_binding "$TMP/bound" THIS-RUN "")" in
  *supervisor_head_unreadable*) ok "an unreadable supervisor head is not a matching head" ;;
  *) no "an empty observed head was treated as agreement" ;;
esac
case "$(candidate_run_binding "$TMP/nonexistent" THIS-RUN THIS-HEAD)" in
  *candidate_missing*) ok "an absent candidate is refused, not silently bound" ;;
  *) no "an absent candidate passed the binding check" ;;
esac

echo "=== a lock is released only when the group is PROVEN empty ==="
supervisor_must_hold_lock empty \
  && no "a proven-empty group held the lock" \
  || ok "a proven-empty group releases the lock"
supervisor_must_hold_lock no_child_launched \
  && no "an early failure before any child stranded the lock" \
  || ok "an early failure with no child launched releases the lock"
for _st in nonempty permission_denied error:13 unexpected_value ""; do
  supervisor_must_hold_lock "$_st" \
    && ok "state '${_st:-<empty>}' holds the lock rather than admitting the next run" \
    || no "state '${_st:-<empty>}' released the lock while work may survive"
done

echo "=== the evidence root binds records to the family that produced them ==="
# A root that digests every line and then sorts globally attests that some evidence exists
# somewhere. What must be attested is that THIS family was killed by THIS transcript, so the
# strongest attack is the one that preserves the multiset of lines: swap two families' contents.
_EV="$TMP/ev"; mkdir -p "$_EV/famA" "$_EV/famB"
printf 'family=famA\ndisposition=killed\n' > "$_EV/famA/record"
printf 'family=famB\ndisposition=killed\n' > "$_EV/famB/record"
_r_before="$(evidence_root_digest "$_EV")"
mv "$_EV/famA/record" "$_EV/.swap" && mv "$_EV/famB/record" "$_EV/famA/record" && mv "$_EV/.swap" "$_EV/famB/record"
_r_after="$(evidence_root_digest "$_EV")"
[ -n "$_r_before" ] && [ -n "$_r_after" ] || no "the evidence-root producer failed; the swap control proves nothing"
[ "$_r_before" != "$_r_after" ] \
  && ok "swapping two families' complete contents moves the evidence root" \
  || no "the root is blind to which family produced which record"
# A SYMLINK IS NOT EVIDENCE. `find -type f` did not match one, but every consumer of this evidence
# follows it — so a verdict could be replaced by a link to content outside the tree, be read as
# authoritative, and never appear in the digest meant to detect exactly that.
mkdir -p "$_EV/famC"
ln -s /etc/hostname "$_EV/famC/record" 2>/dev/null || ln -s /dev/null "$_EV/famC/record"
_sym_out="$(evidence_root_digest "$_EV" 2>/dev/null)"; _sym_rc=$?
{ [ "$_sym_rc" != "0" ] && case "$_sym_out" in *symlink*) true ;; *) false ;; esac; } \
  && ok "a symlink in the evidence tree is refused with its own status, not silently omitted" \
  || no "a symlinked record was accepted (rc=$_sym_rc out='$_sym_out')"
rm -rf "$_EV/famC"
# THE FAMILY DIRECTORY AND THE RUN ROOT ARE LINKS TOO. `-d`, the `*/` glob and `cd` all follow one,
# so `find .` starts inside the target and never sees what it walked through. Neither refusal had a
# control; the only symlink test put a link INSIDE a real directory.
mkdir -p "$TMP/outside"; printf 'family=famD\n' > "$TMP/outside/record"
ln -s "$TMP/outside" "$_EV/famD"
_symd_out="$(evidence_root_digest "$_EV" 2>&1)"; _symd_rc=$?
{ [ "$_symd_rc" != "0" ] && case "$_symd_out" in *family-is-symlink*) true ;; *) false ;; esac; } \
  && ok "a family DIRECTORY that is a symlink is refused" \
  || no "a linked family directory was accepted (rc=$_symd_rc out='$_symd_out')"
rm -f "$_EV/famD"
ln -s "$_EV" "$TMP/linkedroot"
_symr_out="$(evidence_root_digest "$TMP/linkedroot" 2>&1)"; _symr_rc=$?
{ [ "$_symr_rc" != "0" ] && case "$_symr_out" in *root-is-symlink*) true ;; *) false ;; esac; } \
  && ok "an evidence ROOT that is a symlink is refused" \
  || no "a linked evidence root was accepted (rc=$_symr_rc out='$_symr_out')"
rm -f "$TMP/linkedroot"

# ...and the same bytes in the same places still agree with themselves, or the digest is just noise.
mv "$_EV/famA/record" "$_EV/.swap" && mv "$_EV/famB/record" "$_EV/famA/record" && mv "$_EV/.swap" "$_EV/famB/record"
[ "$(evidence_root_digest "$_EV")" = "$_r_before" ] \
  && ok "restoring the contents restores the root" \
  || no "the root is not a function of the evidence"

echo "=== a record that contradicts itself is refused whether or not it claims qualification ==="
# This exact shape was published once: a single-family run wearing a full-campaign label. It carries
# qualified=0, so a coherence check that returns early for unqualified records accepts it.
sed -e 's/^selected=85$/selected=1/' -e 's/^executed=85$/executed=1/' -e 's/^reported=85$/reported=1/' \
    -e 's/^qualified=1$/qualified=0/' "$GOOD" > "$TMP/subset"
case "$(candidate_incoherent "$TMP/subset" "$POP" "$GATES")" in
  *campaign_mode_selected_subset*) ok "mode=campaign with selected<discovered is refused at qualified=0" ;;
  *) no "a single-family run may still describe itself as a campaign: '$(candidate_incoherent "$TMP/subset" "$POP" "$GATES")'" ;;
esac
sed -e 's/^mode=campaign$/mode=single/' -e 's/^selected=85$/selected=85/' "$GOOD" > "$TMP/badsingle"
case "$(candidate_incoherent "$TMP/badsingle" "$POP" "$GATES")" in
  *single_mode_selected*) ok "mode=single claiming 85 selected is refused" ;;
  *) no "single mode accepted an 85-family selection" ;;
esac
sed -e 's/^qualified=1$/qualified=0/' -e 's/^reported=85$/reported=86/' "$GOOD" > "$TMP/overreport"
case "$(candidate_incoherent "$TMP/overreport" "$POP" "$GATES")" in
  *reported_exceeds_executed*) ok "reporting more families than were executed is refused" ;;
  *) no "an invented report was accepted" ;;
esac
# The honest unqualified record must still pass, or the check above is just refusing everything.
[ -z "$(candidate_incoherent "$TMP/unqual" "$POP" "$GATES")" ] \
  && ok "an honest unqualified campaign is not refused by the coherence check" \
  || no "unconditional coherence refuses a well-formed unqualified record"

echo "=== family identity: the label and the experiment are separable ==="
# The driver is the producer of both, so it is asked rather than reimplemented here. Copies live in
# a scratch tree whose ROOT_DIR still resolves to this repository, so no gate writes the real tree.
_DRV="$ROOT_DIR/scripts/tests/check_gate_mutation_coverage.sh"
# The copy derives its own ROOT_DIR from its location, so the sandbox needs the same shape: a
# scripts/tests holding the driver and a lib/ it can source. Symlinking the real lib keeps the
# controls exercising the production decision library rather than a stale duplicate of it.
_SB="$TMP/sb/scripts/tests"; mkdir -p "$_SB"
ln -s "$ROOT_DIR/scripts/tests/lib" "$_SB/lib" 2>/dev/null || { echo "cannot build the identity sandbox" >&2; exit 2; }
_spec() { local out rc; out="$(bash "$1" --spec "$2" 2>/dev/null)"; rc=$?
          { [ "$rc" = "0" ] && [ -n "$out" ]; } || return 1; printf '%s' "$out"; }
cp "$_DRV" "$_SB/base.sh"
sed 's/^add "corecheck-unsafe-op"/add "corecheck-unsafe-op-RENAMED"/' "$_DRV" > "$_SB/renamed.sh"
sed '0,\|^add "corecheck-unsafe-op" "Concrete/Check/CoreCheck.lean"|s||add "corecheck-unsafe-op" "Concrete/Check/Elsewhere.lean"|' "$_DRV" > "$_SB/mutated.sh"
sed '0,/^add "copy-predicate"/s//add "corecheck-unsafe-op"/' "$_DRV" > "$_SB/dupe.sh"
_base="$(_spec "$_SB/base.sh" corecheck-unsafe-op)" || _base=""
_ren="$(_spec "$_SB/renamed.sh" corecheck-unsafe-op-RENAMED)" || _ren=""
_mut="$(_spec "$_SB/mutated.sh" corecheck-unsafe-op)" || _mut=""
if [ -z "$_base" ] || [ -z "$_ren" ] || [ -z "$_mut" ]; then
  no "the --spec producer failed; the identity controls below would prove nothing (base='$_base' ren='$_ren' mut='$_mut')"
else
  [ "$_base" = "$_ren" ] && ok "a renamed family keeps its mutation spec" \
                         || no "renaming changed the spec: $_base -> $_ren"
  [ "$_base" != "$_mut" ] && ok "a family that changed what it mutates gets a new spec" \
                          || no "the spec is blind to the mutation it names"
fi
_spec "$_SB/renamed.sh" corecheck-unsafe-op >/dev/null 2>&1 \
  && no "the pre-rename name still resolves" \
  || ok "the pre-rename name no longer names a family"
# The underscore prefix is reserved for run-level evidence, and the supervisor's evidence check
# SKIPS those directories — so a family able to take that prefix would be silently exempt from
# evidence reconciliation. The reservation is enforced, and here it is attacked.
sed '0,/^add "copy-predicate"/s//add "_sneaky"/' "$_DRV" > "$_SB/reserved.sh"
_res_out="$(bash "$_SB/reserved.sh" --spec corecheck-unsafe-op 2>&1)"; _res_rc=$?
{ [ "$_res_rc" = "2" ] && printf '%s' "$_res_out" | grep -q "may not begin with '_'"; } \
  && ok "a family claiming the reserved underscore prefix is refused" \
  || no "a family named '_sneaky' was accepted (rc=$_res_rc)"

_dupe_out="$(bash "$_SB/dupe.sh" --spec corecheck-unsafe-op 2>&1)"; _dupe_rc=$?
{ [ "$_dupe_rc" = "2" ] && printf '%s' "$_dupe_out" | grep -q 'duplicate names'; } \
  && ok "a duplicated family name is refused, not silently resolved to the first match" \
  || no "duplicate names accepted (rc=$_dupe_rc): $_dupe_out"

echo "=== qualification has ONE authority, not two ==="
# supervisor_qualification calls candidate_incoherent a second time to decide the published
# `qualified=` line. It was omitting the gate count, so a `1/1` baseline the first call refused could
# still be written as qualified=1 by the second. Production was safe only because the first call's
# refusal short-circuited this one — an ordering coincidence, not a property.
sed 's|^baseline_gates_green=.*|baseline_gates_green=1/1|' "$GOOD" > "$TMP/onegate"
[ "$(supervisor_qualification "$TMP/onegate" "" "$POP" "$GATES")" = "qualified=0" ] \
  && ok "a 1/1 baseline cannot be published as qualified even with no prior refusal" \
  || no "the qualification call qualified a 1/1 baseline: $(supervisor_qualification "$TMP/onegate" "" "$POP" "$GATES")"
[ "$(supervisor_qualification "$GOOD" "" "$POP" "$GATES")" = "qualified=1" ] \
  && ok "...and the honest record still qualifies through the same call (positive control)" \
  || no "the qualification call refused a well-formed record"
# The two authorities must agree on every record, not just this one.
for _f in "$GOOD" "$TMP/onegate" "$TMP/buildkills"; do
  _inc="$(candidate_incoherent "$_f" "$POP" "$GATES")"
  _qual="$(supervisor_qualification "$_f" "" "$POP" "$GATES")"
  case "$_inc:$_qual" in
    ":qualified=1"|?*":qualified=0") ;;
    *) no "the two qualification authorities disagree on $(basename "$_f"): incoherent='$_inc' published='$_qual'"; continue ;;
  esac
  ok "both authorities agree on $(basename "$_f")"
done

echo "=== an early failure releases the repository lock ==="
# The driver takes the lock, snapshots itself and re-execs — and `exec` CLEARS TRAPS. Every failure
# between the re-exec and the supervisor's own trap therefore exited holding the lock, and the next
# run refused to start against a repository where nothing was running. This is registered because I
# fixed it once already and confirmed the fix with a control that looked for the wrong lock filename.
# THE SANDBOX'S LOCK, NOT THE REPOSITORY'S.
#
# The copy derives ROOT_DIR from its own location, so it locks $TMP/sb — checking the repository's
# lock here observed a file this control never creates, and passed identically with the fix reverted.
# It is also the safe path: a control must not compete for the real repository lock.
_LOCK="$TMP/sb/.gate.lock"
if [ -e "$_LOCK" ]; then
  no "a lock is already present before this control runs; skipping rather than deleting it"
else
  cp "$_DRV" "$_SB/lockfail.sh"
  # The sandbox copy resolves ROOT_DIR to this repository, so it takes the REAL lock — which is
  # exactly what must be released. Injected failure: the decision library cannot be loaded.
  sed -i 's|scripts/tests/lib/campaign_supervise.sh" 2>/dev/null|scripts/tests/lib/NO_SUCH_LIBRARY.sh" 2>/dev/null|' "$_SB/lockfail.sh"
  _lf_out="$(bash "$_SB/lockfail.sh" 2>&1)"; _lf_rc=$?
  # THE STATUS IS ASSERTED, NOT PRINTED. This checked the message and the lock and never that the
  # run FAILED, so a driver that printed the expected fatal line, released its lock and exited zero
  # satisfied both assertions — a control about refusal that never checked for one.
  case "$_lf_rc:$_lf_out" in
    0:*) no "the injected failure exited 0; a control about refusing must require a refusal" ;;
    *"cannot load the campaign decision library"*)
      ok "a driver that cannot load its decision library refuses (rc=$_lf_rc)" ;;
    *) no "the injected failure did not occur, so the lock control proves nothing: $_lf_out" ;;
  esac
  if [ -e "$_LOCK" ]; then
    no "the failed run STRANDED its lock: $(cat "$_LOCK/owner" 2>/dev/null | tr '\n' ' ')"
    rm -rf "$_LOCK"
  else
    ok "...and it released the lock rather than stranding it"
  fi
fi

# THE POPULATION IS PINNED, NOT JUST THE FAILURE COUNT.
#
# Exiting on FAIL==0 alone means DELETING a control is indistinguishable from passing it: the gate
# reports fewer assertions and still exits green. This harness has already been bitten by exactly
# that — 240 probes were silently lost from another gate the same way — and this round's review
# found controls here that had been inert for rounds without anyone noticing. Changing the count is
# a deliberate act, recorded in the same commit as the control that changed it.
EXPECTED_CONTROLS=130
_total=$((PASS + FAIL))
if [ "$_total" -ne "$EXPECTED_CONTROLS" ]; then
  echo "  FAIL this gate ran $_total controls, expected $EXPECTED_CONTROLS — one was added or removed"
  echo "       without updating EXPECTED_CONTROLS in the same commit."
  FAIL=$((FAIL + 1))
fi

echo "CAMPAIGN-SUPERVISOR: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
