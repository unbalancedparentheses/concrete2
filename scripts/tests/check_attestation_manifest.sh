#!/usr/bin/env bash
# The attestation manifest, measured on the real corpus.
#
# The manifest decides which SUBJECT each evidence-bearing proof table is attested to, and the table
# conversion will be driven by it. So its numbers are pinned here rather than trusted from a run: a
# manifest that silently mapped fewer tables, or excluded a fixture it should have mapped, would
# produce a conversion that looks correct and attests the wrong implementations.
#
# EXACT VALUES, not ratchets. A mapping count rising is not automatically good — it can mean a drift
# fixture stopped being excluded — so every number is asserted and a change must be explained.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source "scripts/tests/lib/fresh.sh"
require_fresh_binary || exit 1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

echo "=== attestation manifest ==="
OUT="$(bash scripts/gen/attestation_manifest.sh 2>/dev/null)"
RC=$?

# The generator REFUSES rather than emitting a partial manifest, so a non-zero exit is a hard failure
# here — not a condition to work around.
if [ "$RC" -eq 0 ]; then
  ok "the manifest generator completes without refusing"
else
  no "the manifest generator REFUSED (exit $RC) — run it directly to read the reasons"
  echo "ATTESTATION-MANIFEST: PASS=$PASS FAIL=$FAIL"; exit 1
fi

field() { printf '%s' "$OUT" | grep -oE "^$1 *= *[0-9]+" | grep -oE '[0-9]+$' || true; }

SCANNED="$(field fixtures_scanned)"
DRIFT_EX="$(field fixtures_excluded_drift)"
ROWS="$(field subject_rows)"
NOID="$(field subjects_no_identity)"
UNTABLED="$(field subjects_without_table)"
MAPPED="$(field table_attestations)"
DUPES="$(field duplicate_mappings)"
COLLAPSE="$(field package_collapse_keys)"
SURPLUS="$(field surplus_tables)"

echo "  scanned=$SCANNED drift_excluded=$DRIFT_EX rows=$ROWS no_identity=$NOID untabled=$UNTABLED mapped=$MAPPED"

# TYPED RECONCILIATION. Every subject row must end in exactly one bucket. This is the property that
# makes the denominator meaningful rather than two counters that happen to agree.
if [ -n "$ROWS" ] && [ "$ROWS" = "$(( NOID + UNTABLED + MAPPED ))" ]; then
  ok "every subject row is accounted for exactly once ($ROWS = $NOID + $UNTABLED + $MAPPED)"
else
  no "subject rows do not reconcile: $ROWS != $NOID + $UNTABLED + $MAPPED"
fi

# THE MEASURED STATE. Exact, because a rise can mean a drift fixture stopped being excluded.
if [ "$ROWS" = "86" ] && [ "$MAPPED" = "48" ] && [ "$UNTABLED" = "38" ] && [ "$NOID" = "0" ]; then
  ok "corpus accounting is exactly rows=86 attested=48 untabled=38 no-identity=0"
else
  no "corpus accounting moved: rows=$ROWS attested=$MAPPED untabled=$UNTABLED no-identity=$NOID (was 86/48/38/0) — say which subjects changed and why"
fi

# NO SILENT DEFECTS. Each of these has been zero since the collapse was closed; a non-zero value is a
# real finding, not noise.
for pair in "duplicate_mappings:$DUPES" "package_collapse_keys:$COLLAPSE" "surplus_tables:$SURPLUS"; do
  k="${pair%%:*}"; v="${pair##*:}"
  if [ "$v" = "0" ]; then ok "$k = 0"; else no "$k = $v — a real defect, not noise"; fi
done

# DRIFT IS EXCLUDED, AND NAMED. "Some fixture was excluded" would stay true if the WRONG one were.
if printf '%s' "$OUT" | grep -q 'excluded = ".*main_drifted.con"'; then
  ok "drift fixtures are excluded by name, not silently filtered"
else
  no "no named drift exclusion in the manifest — the classifier stopped matching"
fi
if [ "$DRIFT_EX" -ge 1 ] 2>/dev/null; then
  ok "$DRIFT_EX drift fixture(s) excluded from attestation"
else
  no "no drift fixture was excluded — a drifted implementation could be attested"
fi

# REUSE IS REPRESENTED, NOT COLLAPSED.
#
# THE INVARIANT IS THE ONE-TO-ONE MAPPING, not the number. Every consuming fixture must yield exactly
# one scoped package identity, and no two fixtures may share one. That property holds whatever the
# corpus contains: it fails if two programs collapse into a package (the defect closed in b3007c64)
# and it fails if one program splits across several. It is asserted FIRST for that reason.
EMPTY_PKGS="$(printf '%s' "$OUT" | grep '^Concrete.Proof.FnTable.empty <-' | awk '{print $3}' | cut -d/ -f1 | sort -u | grep -c . || true)"
EMPTY_SRCS="$(printf '%s' "$OUT" | grep '^Concrete.Proof.FnTable.empty <-' | sed -E 's/.*\(([^)]*)\)$/\1/' | sort -u | grep -c . || true)"
if [ "$EMPTY_PKGS" = "$EMPTY_SRCS" ] && [ "$EMPTY_SRCS" -gt 1 ]; then
  ok "INVARIANT: a shared table's $EMPTY_SRCS consuming fixtures map one-to-one onto scoped packages"
else
  no "one-to-one broken: $EMPTY_SRCS consuming fixtures, $EMPTY_PKGS package identities — fixtures are collapsing into one package or splitting across several"
fi

# TODAY'S CORPUS DENOMINATOR, which is a different kind of claim. 10 is what this corpus currently
# contains; it is NOT architectural truth, and it moves whenever a fixture is added or removed. It is
# pinned so such a move is stated rather than absorbed — not because 10 means anything by itself.
#
# (It was 8 in my own earlier note, taken from a map built on the `#[proof_by]` population alone;
# `evidence_classes/proved_by_lean` and `hmac_sha256` reach this table through IN-REPO theorems.)
if [ "$EMPTY_PKGS" = "10" ]; then
  ok "corpus denominator: FnTable.empty is attested to 10 packages (today's measurement, not an invariant)"
else
  no "FnTable.empty denominator moved to $EMPTY_PKGS (was 10) — say which fixture was added or removed"
fi

# RECOMPUTED AGAINST CURRENT FACTS. The manifest is derived, not stored, so its identities are only
# as trustworthy as the derivation is REPRODUCIBLE. A second run over the same tree must be
# byte-identical: if identity computation ever became order-dependent, environment-dependent or
# otherwise nondeterministic, the manifest would still look well-formed while attesting different
# identities on different runs — and a conversion driven by one run would disagree with the compiler
# on the next.
OUT2="$(bash scripts/gen/attestation_manifest.sh 2>/dev/null)"
if [ "$OUT" = "$OUT2" ]; then
  ok "a second derivation is byte-identical (identities are reproducible, not merely produced)"
else
  no "two derivations of the manifest DIFFER — identity computation is not deterministic, so no conversion driven by it can be trusted"
fi

# POSITIVE CONTROL FOR LEGITIMATE REUSE. Every refusal above is about rejecting bad mappings, and a
# manifest that rejected everything would satisfy all of them. So: one model, reused across several
# scoped packages, must be ACCEPTED — the same model attested to different implementations is exactly
# what scoped identity exists to permit, and refusing it would reimpose the CallableId collapse.
#
# Asserted on the shared table with the most reuse, and on the manifest completing at all: if reuse
# were being refused, the generator would exit non-zero and this count would be 1.
REUSED_OK="$(printf '%s' "$OUT" | grep -c '^Concrete.Proof.FnTable.empty <-' || true)"
if [ "$REUSED_OK" -ge 10 ] 2>/dev/null; then
  # ROWS, not packages. $EMPTY_PKGS above is the package count; this count is attestation rows, and
  # they differ because a fixture may attest several declarations. Saying "packages" here was a
  # miscount that reached two commit messages and a source comment before it was caught.
  ok "a reused model is ACCEPTED across $REUSED_OK attestation rows / $EMPTY_PKGS scoped packages (reuse is permitted, not refused)"
else
  no "the most-reused table produced only $REUSED_OK attestations — legitimate reuse is being refused, which reimposes the CallableId collapse"
fi

# THE KNOWN MISATTACHMENT REMAINS VISIBLE. `proof_pressure` borrows theorems from two other packages,
# which is the defect correspondence already refuses; the manifest must not quietly normalise it.
PP_TABLES="$(printf '%s' "$OUT" | grep 'proof_pressure' | awk '{print $1}' | sort -u | grep -c . || true)"
if [ "$PP_TABLES" = "2" ]; then
  ok "proof_pressure still attests 2 tables (the borrowed-theorem misattachment stays visible)"
else
  no "proof_pressure attests $PP_TABLES table(s) (expected 2) — if the fixture was repaired, update this; if the manifest normalised it, that is a defect"
fi

# === CONVERSION RECONCILIATION (package 2) ======================================================
#
# The manifest says which attestations a table SHOULD carry; the table sites say which it DOES. Those
# are two producers and nothing has been joining them, so a conversion could attest four of six rows
# and look exactly like a finished one — the table reports `attested`, `scopedEntryEvidence` returns
# rows, every existing probe passes, and the two missing definitions are simply not described.
#
# So the join is asserted here, per table, and every gap must be a NAMED exclusion. This is also what
# keeps the remaining conversions honest: a table nobody has converted yet must report zero, not a
# partial set that reads as progress.
echo "=== conversion reconciliation ==="

cat > "$TMP/attested.lean" <<'LEAN'
import Concrete
import Examples
open Concrete Concrete.Proof

/-- Every `FnTable` in the build, named as the manifest names it. A table missing from this list
    would be silently exempt from the reconciliation below, which is the failure mode the
    one-producer discipline exists to prevent — so the ONE-PRODUCER gate pins the list too. -/
def attestationSites : List (String × FnTable) :=
  [ ("Concrete.Proof.FnTable.empty", FnTable.empty)
  , ("Concrete.Proof.proofFns", proofFns)
  , ("Concrete.Proof.proofFnsExt", proofFnsExt)
  , ("Concrete.Proof.cryptoFns", cryptoFns)
  , ("Concrete.Proof.elfFns", elfFns)
  , ("Concrete.Proof.parseValidateFns", parseValidateFns)
  , ("Concrete.Proof.fixedCapacityFns", fixedCapacityFns)
  , ("Concrete.Proof.ctTagFns", ctTagFns)
  , ("Concrete.Proof.pureCoreFns", pureCoreFns)
  , ("Examples.ProofPatterns.Proofs.combineFns", Examples.ProofPatterns.Proofs.combineFns)
  , ("Examples.HmacSha256.Proofs.shaFns", Examples.HmacSha256.Proofs.shaFns) ]

#eval show IO Unit from do
  for (n, t) in attestationSites do
    IO.println s!"SITE {n} attested={t.attested.size} failures={t.attestationFailures} entries={t.entries.size}"
    -- The identities a site ACTUALLY selected, so a check can ask what was omitted rather than only
    -- what was declared. Package and declaration are enough to name a manifest row.
    for (_, d) in t.attested do
      IO.println s!"BOUND {n} {d.packageIdentity} {d.declarationIdentity}"
LEAN

SITES="$(lake env lean "$TMP/attested.lean" 2>&1)"
if grep -qE "error:|error\(lean" <<<"$SITES"; then
  no "the table-site probe did not elaborate: $(printf '%s' "$SITES" | tr '\n' ' ' | cut -c1-200)"
  SITES=""
else
  ok "every table site reports its attested/entry counts"
fi

site_field() { printf '%s' "$SITES" | grep -E "^SITE $1 " | grep -oE "$2=[0-9]+" | grep -oE '[0-9]+$' || true; }

# NAMED EXCLUSIONS: a manifest row that is deliberately NOT attested, one line each, with the reason.
# The arithmetic below refuses any gap that is not on this list, so an exclusion is a decision that
# has to be written down rather than a number that happens to be smaller.
#
#   elfFns / proof_pressure / validate_header — the known misattachment. `proof_pressure` carries
#   `#[proof_by(Examples.ElfHeader.Proofs.validate_header_correct)]`, so the manifest offers the row,
#   but its `validate_header` calls `check_nonce` and `elfFns` does not hold it: this table's model
#   does not model that implementation. Attestation BINDS and does not check faithfulness, so
#   selecting the reference would make the table describe a function it does not describe, and
#   nothing downstream would catch it.
#
#   ctTagFns / evidence_classes/stale_proof / ct_compare — a DRIFTED implementation. Same linked
#   theorem, but the body starts `diff` at 1 instead of 0, and the compiler says so itself:
#   `--report proof-status` reports SPEC DRIFT, "the theorem is about a different function than the
#   source". Attesting it would bind the model to an implementation it does not model, and nothing
#   would catch it — `scopedEntryEvidence` recomputes the digest of the MODEL's body, never the
#   implementation's. The manifest still offers the row (see the drift-classifier check below).
EXCLUSIONS="Concrete.Proof.elfFns:d7eed9438112e0d817a3a15812018938:validate_header
Concrete.Proof.ctTagFns:13c8e4151b399c089fad1a4124686597:ct_compare"

for ex in $EXCLUSIONS; do
  extbl="${ex%%:*}"; rest="${ex#*:}"; expkg="${rest%%:*}"; exdecl="${rest##*:}"
  if printf '%s' "$OUT" | grep -q "^$extbl <- $expkg/[^ ]*\.$exdecl "; then
    ok "declared exclusion $extbl/$exdecl is a REAL manifest row (not a stale entry masking a gap)"
  else
    no "declared exclusion $extbl/$exdecl matches no manifest row — either the fixture was repaired (drop the exclusion) or the manifest stopped offering it"
  fi
done

# CONVERTED SET, EXACT. Converting a table is a deliberate step, so it is stated here; a table that
# starts reporting attestations without this list being updated is an unreviewed conversion.
CONVERTED="Concrete.Proof.cryptoFns Concrete.Proof.ctTagFns Concrete.Proof.elfFns Concrete.Proof.fixedCapacityFns Concrete.Proof.parseValidateFns"

if [ -n "$SITES" ]; then
  # ANCHORED ON `SITE`. Unanchored, this also matched the `BOUND` lines added later — one line per
  # attestation — so every converted table appeared once per attestation and the set comparison
  # failed with a list that looked like corruption. A filter that happens to work because of what
  # the input does not yet contain is a defect waiting for the input to grow, which it did within
  # the hour.
  ACTUALLY_ATTESTED="$(printf '%s' "$SITES" | grep '^SITE ' | grep -vE 'attested=0 ' | awk '{print $2}' | sort | tr '\n' ' ')"
  if [ "$ACTUALLY_ATTESTED" = "$(printf '%s\n' $CONVERTED | sort | tr '\n' ' ')" ]; then
    ok "the converted set is exactly: $CONVERTED"
  else
    no "converted set is [$ACTUALLY_ATTESTED], expected [$CONVERTED] — an unreviewed conversion, or one that was reverted"
  fi

  for tbl in $(printf '%s' "$OUT" | grep ' <- ' | grep -v EXCLUDED | awk '{print $1}' | sort -u); do
    # THE DISTINCT REFERENCE SET, over BOTH populations. A table site selects generated symbols, and
    # a symbol exists per (table, package, module, declaration, implementation) whether the row that
    # produced it was a subject or a dependency. So the load-bearing invariant is that every
    # reference a table has is either BOUND at its site or a NAMED exclusion — an unbound reference
    # is a definition the table could describe exactly and does not.
    #
    # Counting subject rows against attestations was wrong the moment dependency references were
    # bound: `parseValidateFns` holds 8 attestations against 3 subject rows, which is correct.
    ROWS_T="$(printf '%s' "$OUT" | grep "^$tbl <- " | awk '{print $3, $4}' | sort -u | grep -c . || true)"
    SUBJ_T="$(printf '%s' "$OUT" | grep "^$tbl <- " | grep -vc 'binding_role=dependency' || true)"
    DEP_T="$(printf '%s' "$OUT" | grep "^$tbl <- " | grep -c 'binding_role=dependency' || true)"
    ATT_T="$(site_field "$tbl" attested)"
    ENT_T="$(site_field "$tbl" entries)"
    FAIL_T="$(site_field "$tbl" failures)"
    EXC_T="$(printf '%s\n' $EXCLUSIONS | grep -c "^$tbl:" || true)"
    if [ -z "$ATT_T" ]; then
      no "$tbl is in the manifest but not in the table-site list — it would be silently exempt from this reconciliation"
    elif [ "$ENT_T" = "0" ]; then
      # Vacuously attested: no entries, so there is nothing to bind and membership is empty for every
      # callee. The manifest still lists its rows, and they are correctly unattestable — one shared
      # `def` cannot carry one scoped identity per consuming package.
      if [ "$ATT_T" = "0" ]; then
        ok "$tbl has no entries: $ROWS_T reference(s) are vacuously attested, nothing to bind"
      else
        no "$tbl has no entries but carries $ATT_T attestation(s) — it is attesting models it does not hold"
      fi
    elif [ "$ATT_T" = "0" ]; then
      ok "$tbl is PENDING conversion (0 of $ROWS_T references bound; it refuses as legacy, which is honest)"
    elif [ "$FAIL_T" != "0" ]; then
      no "$tbl has $FAIL_T generated reference(s) that failed validation — needs_recheck, not a conversion"
    elif [ "$ROWS_T" = "$(( ATT_T + EXC_T ))" ]; then
      ok "$tbl reconciles: $ROWS_T distinct references ($SUBJ_T subject rows, $DEP_T dependency rows) = $ATT_T bound + $EXC_T named exclusion(s)"
    else
      no "$tbl does NOT reconcile: $ROWS_T distinct references, $ATT_T bound, $EXC_T named exclusion(s) — an unbound reference is a definition the table could describe exactly and does not"
    fi
  done
fi

# EVERY SUBJECT ROW HAS EXACTLY ONE DISPOSITION, and the four add up to the frozen 48. Conversion
# progress was being described in prose as a per-table list, which drifted the moment a table moved:
# a roadmap paragraph read 14 selected / 1 excluded / 13 vacuous / 20 pending after
# `parseValidateFns` landed, when the measurement was 17/1/13/17.
#
# DECIDED PER ROW BY WHAT THE SITE ACTUALLY BOUND, not by comparing counts. Counting attestations
# against subject rows broke as soon as a table bound DEPENDENCY references too: `parseValidateFns`
# holds 8 attestations against 3 subject rows and read as over-attested, which is not a defect but a
# second population. A row's disposition is a property of that row.
SEL=0; EXC=0; VAC=0; PEND=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  rtbl="${row%% <-*}"; rrest="${row#* <- }"; rpkg="${rrest%%/*}"
  rmoddecl="${rrest%% *}"; rmoddecl="${rmoddecl#*/}"; rdecl="${rmoddecl#*.}"
  rent="$(site_field "$rtbl" entries)"
  if [ "${rent:-0}" = "0" ]; then VAC=$((VAC+1))
  elif printf '%s\n' $EXCLUSIONS | grep -qx "$rtbl:$rpkg:$rdecl"; then EXC=$((EXC+1))
  elif printf '%s' "$SITES" | grep -qE "^BOUND $rtbl $rpkg $rdecl$"; then SEL=$((SEL+1))
  else PEND=$((PEND+1)); fi
done <<EOF_ROWS
$(printf '%s' "$OUT" | grep ' <- ' | grep -v EXCLUDED | grep -v 'binding_role=dependency')
EOF_ROWS
if [ "$(( SEL + EXC + VAC + PEND ))" = "$MAPPED" ]; then
  ok "subject-row disposition reconciles: $SEL selected + $EXC excluded + $VAC vacuous + $PEND pending = $MAPPED"
else
  no "subject-row disposition does NOT reconcile: $SEL + $EXC + $VAC + $PEND != $MAPPED — a row has two dispositions or none"
fi

# === A DRIFTED IMPLEMENTATION MUST NEVER BE ATTESTED ============================================
#
# The manifest excludes drift fixtures by GREPPING THEIR HEADERS for "DRIFTED variant". That is a
# second, weaker producer of a fact the compiler already computes, and it has a live miss:
# `examples/evidence_classes/stale_proof` declares "the body has DRIFTED", does not match the
# pattern, and its row IS offered for attestation. Attesting it would bind a model to an
# implementation it does not model — and no downstream check would catch that, because
# `scopedEntryEvidence` recomputes the digest of the MODEL's body, never the implementation's.
#
# So the verdict is re-derived from the compiler here: any manifest row whose fixture reports SPEC
# DRIFT must be a DECLARED exclusion at its table site. This does not repair the manifest's
# classifier — that is a package-1 decision — it stops the conversion path from consuming its miss.
echo "=== drifted implementations are never attested ==="

DRIFTED_SRCS=""
for src in $(printf '%s' "$OUT" | grep ' <- ' | grep -v EXCLUDED | sed -E 's/.*\(([^)]*)\)$/\1/' | sort -u); do
  # CAPTURE FIRST, THEN GREP. `if binary … | grep -q` reads correctly and is WRONG under
  # `set -o pipefail`: the compiler exits non-zero on a fixture with a proof defect — which is
  # every fixture this check is looking for — so pipefail returns that failure and the branch is
  # never taken. The first version of this check reported "no fixture reports spec drift" while the
  # same grep matched by hand. A check that answers "nothing found" because it stopped looking is
  # exactly the defect this gate was written for, one level up.
  ps_out="$("$ROOT_DIR/.lake/build/bin/concrete" "$src" --report proof-status 2>&1)"
  case "$ps_out" in *"spec drift"*) DRIFTED_SRCS="$DRIFTED_SRCS $src" ;; esac
done

if [ -n "$DRIFTED_SRCS" ]; then
  ok "the compiler reports spec drift for:$DRIFTED_SRCS (so this check has a live case)"
else
  no "no manifest fixture reports spec drift — either the corpus lost its drift fixture or the report changed, and this check is now vacuous"
fi

for src in $DRIFTED_SRCS; do
  while read -r row; do
    [ -n "$row" ] || continue
    rtbl="${row%% <-*}"; rrest="${row#* <- }"; rpkg="${rrest%%/*}"
    rmoddecl="${rrest%% *}"; rmoddecl="${rmoddecl#*/}"; rdecl="${rmoddecl#*.}"
    # DECLARED and OMITTED are different facts, and only the second is the one that matters. An
    # earlier version of this check asked only whether the row appeared in EXCLUSIONS, which a table
    # could satisfy while ALSO selecting the reference — declared excluded and bound anyway. So the
    # binding is read from the table site itself.
    if printf '%s' "$SITES" | grep -qE "^BOUND $rtbl $rpkg $rdecl$"; then
      no "drifted row $rtbl/$rdecl ($src) IS BOUND at the table site — the model is attested to an implementation the compiler says it does not describe"
    elif printf '%s\n' $EXCLUSIONS | grep -qx "$rtbl:$rpkg:$rdecl"; then
      ok "drifted row $rtbl/$rdecl ($src) is omitted at the table site AND declared as an exclusion"
    else
      no "drifted row $rtbl/$rdecl ($src) is unbound but undeclared — say why it is excluded, or the next conversion will silently pick it up"
    fi
  done <<EOF_ROWS
$(printf '%s' "$OUT" | grep ' <- ' | grep -v EXCLUDED | grep -F "($src)")
EOF_ROWS
done

# === SUBJECT ROWS AND DEPENDENCY REQUESTS =======================================================
#
# The manifest carries TWO populations, kept apart by `binding_role`. `subject` rows are declarations
# a fixture links a proof to; `dependency` rows are the requested BODY-edge callees of those
# subjects — the population correspondence actually joins over, which is not the same set.
#
# THE SUBJECT SECTION IS FROZEN AND BYTE-STABLE. Dependency rows have their own counters and must
# never reach `table_attestations`, or the 86/48 denominator stops meaning anything.
#
# THIS REPLACED A SECOND PRODUCER. An earlier version re-derived the callee population in shell, by
# running the compiler per fixture and grepping `shadow edgeKinds` — the two-answers defect the
# manifest generator exists to avoid, one layer up. It also keyed on (fixture, callee), which is too
# weak: `proof_pressure.check_nonce` has a good identity under `cryptoFns` while the theorem claiming
# `validate_header` requests `elfFns`, so a row elsewhere read as satisfying this request. The key is
# now (consumer, table, callee) and the compiler produces it.
echo "=== subject rows and dependency requests ==="

DEPREQ="$(field dependency_requests)"
DEPATT="$(field dependency_attestations)"
DEPREF="$(field dependency_refusals)"
DEPDUP="$(field dependency_duplicate_mappings)"
DEPCON="$(field dependency_conflicts)"
DEPNOID="$(field dependency_without_identity)"

if [ -n "$DEPREQ" ] && [ "$DEPREQ" -gt 0 ] 2>/dev/null; then
  ok "$DEPREQ dependency requests emitted (the population is live, not an empty section)"
else
  no "no dependency requests — the compiler stopped emitting the dependency role, or the role split broke"
fi

# TYPED RECONCILIATION, exactly as for subject rows: every request ends attested or NAMED-refused.
if [ "$DEPREQ" = "$(( DEPATT + DEPREF ))" ]; then
  ok "every dependency request is accounted for exactly once ($DEPREQ = $DEPATT attested + $DEPREF refused)"
else
  no "dependency requests do not reconcile: $DEPREQ != $DEPATT + $DEPREF — a request was dropped"
fi

if [ "$DEPREQ" = "42" ] && [ "$DEPATT" = "41" ] && [ "$DEPREF" = "1" ]; then
  ok "dependency population is exactly 42 requests = 41 attested + 1 refused"
else
  no "dependency population moved: $DEPREQ = $DEPATT + $DEPREF, was 42 = 41 + 1 — say which edge appeared or disappeared"
fi

# MEMBERSHIP PROVENANCE, THE HONEST VERSION. "Attested" is one word for three different claims, and
# the weakest of them — an exact identity whose table could not be read at all — must not be reported
# with the same word as membership verified against a table the compiler holds and recomputed.
#
# `unresolved` is 0 TODAY because `shaFns` was added to the classification generator's external
# tables, so every table a theorem names can now answer membership. That is a real improvement rather
# than a typed excuse: the ignorance was removed instead of being labelled. The path itself stays
# controlled by the unknown-table probes in `check_dependency_edges.sh`, which is where a synthetic
# unreadable table lives — this gate measures the corpus, and the corpus no longer has one.
DEPVC="$(field dependency_membership_verified_compiler)"
DEPVG="$(field dependency_membership_verified_asserted)"
DEPUN="$(field dependency_membership_unresolved)"
if [ "$DEPATT" = "$(( DEPVC + DEPVG + DEPUN ))" ]; then
  ok "every attestation carries a membership state ($DEPATT = $DEPVC compiler-linked + $DEPVG generator-asserted + $DEPUN unresolved)"
else
  no "attestations do not reconcile by membership state: $DEPATT != $DEPVC + $DEPVG + $DEPUN"
fi
if [ "$DEPVC" = "18" ] && [ "$DEPVG" = "23" ] && [ "$DEPUN" = "0" ]; then
  ok "membership states are exactly 18 compiler-linked / 23 generator-asserted / 0 unresolved"
else
  no "membership states moved: $DEPVC / $DEPVG / $DEPUN, was 18/23/0 — a table changed provenance, or one stopped being readable"
fi
# BOTH VERIFIED KINDS MUST BE LIVE. If generator-asserted fell to zero the distinction would be
# untested; if compiler-linked did, the strongest evidence class would have quietly disappeared.
if [ "$DEPVC" -gt 0 ] 2>/dev/null && [ "$DEPVG" -gt 0 ] 2>/dev/null; then
  ok "both membership provenances are live, so the distinction is exercised rather than declared"
else
  no "one membership provenance has no case ($DEPVC compiler-linked, $DEPVG generator-asserted) — the distinction is untested"
fi

for pair in "dependency_duplicate_mappings:$DEPDUP" "dependency_conflicts:$DEPCON" "dependency_without_identity:$DEPNOID"; do
  k="${pair%%:*}"; v="${pair##*:}"
  if [ "$v" = "0" ]; then ok "$k = 0"; else no "$k = $v — a real defect, not noise"; fi
done

# THE ONE REFUSAL IS THE ONE THAT MUST STAY. `elfFns` resolves and holds no `check_nonce` model, so
# `proof_pressure.validate_header`'s request cannot be satisfied by ANY identity — and specifically
# not by the perfectly good `check_nonce` row that exists under `cryptoFns`. If this ever reads
# `attested`, the request key collapsed back to something weaker than (consumer, table, callee).
if printf '%s' "$OUT" | grep -q '^Concrete.Proof.elfFns !! .*check_nonce.*refusal=tableModelMissing.*requested by main.validate_header'; then
  ok "the table/model mismatch is a NAMED refusal (a cryptoFns row cannot satisfy an elfFns request)"
else
  no "the elfFns/check_nonce request is no longer a named tableModelMissing refusal — either the fixture was repaired, or the request key weakened"
fi

# AND AN EXACT REFERENCE IS NOT A JUSTIFICATION. `composition_unlinked_helper`'s `calls.dbl` IS
# attested — exact implementation selection is available to an unlinked helper — while its subject
# must keep refusing, because selection says which implementation an edge points at and never that
# the edge is justified.
if printf '%s' "$OUT" | grep -q 'combineFns <- .*calls.dbl.*binding_role=dependency'; then
  ok "an unlinked helper's callee DOES receive exact selection (identity is available to it)"
else
  no "composition_unlinked_helper/calls.dbl has no dependency attestation — this control lost its case"
fi
PP_SUBJECT_FACTS="$("$ROOT_DIR/.lake/build/bin/concrete" examples/proof_pressure/src/main.con --report subject-facts 2>/dev/null || true)"
if printf '%s' "$PP_SUBJECT_FACTS" | grep -q 'shadow correspondence: matched=0 missing=1'; then
  ok "exact dependency selection did NOT make the misattached subject correspond (identity is not justification)"
else
  no "proof_pressure/validate_header changed disposition after dependency references were added — an identity was taken for a justification"
fi

# EVERY ATTESTATION ROW IS SELECTABLE. References are generated from BOTH attestation sections and
# deduped on (table, package, module, declaration, implementation), so the emitted symbol count must
# equal the number of distinct keys. A shorter file means some row has no reference an author could
# select — the silent gap the generated surface exists to prevent — and a longer one means the
# dedupe is dropping a real distinction.
KEYS="$(printf '%s' "$OUT" | grep ' <- ' | grep -v EXCLUDED | awk '{print $1, $3, $4}' | sort -u | grep -c . || true)"
REFS="$(grep -c '^def ' Concrete/Proof/GeneratedAttestations.lean || true)"
if [ "$REFS" = "$KEYS" ]; then
  ok "generated references cover every distinct (table, package, module, decl, implementation) key: $REFS"
else
  no "generated references are $REFS but the manifest has $KEYS distinct keys — regenerate scripts/gen/attestation_refs.sh"
fi
# NON-VACUITY of the dedupe: the two populations DO overlap, so refs must be fewer than rows. If they
# were equal, either nothing is shared (and the dedupe is untested) or the dedupe stopped running.
ROWS_BOTH="$(printf '%s' "$OUT" | grep -c ' <- ' || true)"
if [ "$KEYS" -lt "$ROWS_BOTH" ] 2>/dev/null; then
  ok "the populations overlap as expected: $ROWS_BOTH attestation rows collapse to $KEYS distinct references"
else
  no "no overlap between subject and dependency attestations ($ROWS_BOTH rows, $KEYS keys) — the dedupe is untested"
fi

echo "ATTESTATION-MANIFEST: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
