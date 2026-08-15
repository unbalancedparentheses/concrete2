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
EXCLUSIONS="Concrete.Proof.elfFns:d7eed9438112e0d817a3a15812018938:validate_header"

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
CONVERTED="Concrete.Proof.cryptoFns Concrete.Proof.elfFns Concrete.Proof.fixedCapacityFns Concrete.Proof.parseValidateFns"

if [ -n "$SITES" ]; then
  ACTUALLY_ATTESTED="$(printf '%s' "$SITES" | grep -vE 'attested=0 ' | awk '{print $2}' | sort | tr '\n' ' ')"
  if [ "$ACTUALLY_ATTESTED" = "$(printf '%s\n' $CONVERTED | sort | tr '\n' ' ')" ]; then
    ok "the converted set is exactly: $CONVERTED"
  else
    no "converted set is [$ACTUALLY_ATTESTED], expected [$CONVERTED] — an unreviewed conversion, or one that was reverted"
  fi

  for tbl in $(printf '%s' "$OUT" | grep ' <- ' | grep -v EXCLUDED | awk '{print $1}' | sort -u); do
    ROWS_T="$(printf '%s' "$OUT" | grep -c "^$tbl <- " || true)"
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
        ok "$tbl has no entries: $ROWS_T manifest row(s) are vacuously attested, nothing to bind"
      else
        no "$tbl has no entries but carries $ATT_T attestation(s) — it is attesting models it does not hold"
      fi
    elif [ "$ATT_T" = "0" ]; then
      ok "$tbl is PENDING conversion (0 of $ROWS_T rows attested; it refuses as legacy, which is honest)"
    elif [ "$FAIL_T" != "0" ]; then
      no "$tbl has $FAIL_T generated reference(s) that failed validation — needs_recheck, not a conversion"
    elif [ "$ROWS_T" = "$(( ATT_T + EXC_T ))" ]; then
      ok "$tbl reconciles: $ROWS_T manifest rows = $ATT_T attested + $EXC_T named exclusion(s)"
    else
      no "$tbl does NOT reconcile: $ROWS_T manifest rows, $ATT_T attested, $EXC_T named exclusion(s) — an unexplained gap is an under-attested table that reads as converted"
    fi
  done
fi

# === THE MANIFEST'S POPULATION IS SUBJECTS; THE JOIN'S POPULATION IS CALLEES ====================
#
# Found while converting `parseValidateFns`, which has EIGHT entries and only THREE manifest rows.
# That is not an under-attested table: the manifest emits a row per SUBJECT — a declaration some
# fixture links a proof to — while correspondence asks about the CALLEES of a subject's body. A
# callee that carries no proof link of its own is a real, matched, `body` edge today and has no
# manifest row, so no generated reference exists and no table entry can be attested to it.
#
# This matters for the flip and for nothing before it: the `CallableId` join matches these edges on
# NAME and reports `usable=yes`. A scoped join that requires an attested entry per callee would stop
# matching them. So the gap is measured here, exactly, rather than discovered when correspondence
# drops — and it is pinned so it cannot grow while attention is elsewhere.
echo "=== subject population vs callee population ==="

printf '%s' "$OUT" | grep ' <- ' | grep -v EXCLUDED \
  | awk -F'[()]' '{src=$(NF-1); split($1,a," "); split(a[3],b,"/"); split(b[2],c,"."); print src"\t"c[2]}' \
  | sort -u > "$TMP/subjects.tsv"

: > "$TMP/callees.tsv"
for src in $(cut -f1 "$TMP/subjects.tsv" | sort -u); do
  "$ROOT_DIR/.lake/build/bin/concrete" "$src" --report subject-facts 2>/dev/null \
    | grep '^  shadow edgeKinds:' \
    | grep -oE 'v1:user:[A-Za-z0-9_]+\.[A-Za-z0-9_]+=body' \
    | sed -E 's/v1:user:[A-Za-z0-9_]+\.([A-Za-z0-9_]+)=body/\1/' \
    | sort -u | sed "s|^|$src\t|" >> "$TMP/callees.tsv"
done

comm -23 <(sort -u "$TMP/callees.tsv") <(sort -u "$TMP/subjects.tsv") > "$TMP/uncovered.tsv"
UNCOVERED="$(grep -c . "$TMP/uncovered.tsv" || true)"
TOTAL_CALLEES="$(sort -u "$TMP/callees.tsv" | grep -c . || true)"

# NON-VACUITY FIRST: if no body-edge callee were found at all, the comparison would report a
# perfect zero gap while measuring nothing.
if [ "$TOTAL_CALLEES" -ge 20 ] 2>/dev/null; then
  ok "$TOTAL_CALLEES distinct (fixture, body-edge callee) pairs measured — the comparison has input"
else
  no "only $TOTAL_CALLEES body-edge callee pairs found — the edge extraction stopped working, so the gap below means nothing"
fi

# EXACT, with the breakdown, because a bare 14 hides which fixture moved.
UNCOV_HMAC="$(grep -c 'hmac_sha256' "$TMP/uncovered.tsv" || true)"
UNCOV_PV="$(grep -c 'parse_validate' "$TMP/uncovered.tsv" || true)"
UNCOV_UNLINKED="$(grep -c 'composition_unlinked_helper' "$TMP/uncovered.tsv" || true)"
if [ "$UNCOVERED" = "14" ] && [ "$UNCOV_HMAC" = "8" ] && [ "$UNCOV_PV" = "5" ] && [ "$UNCOV_UNLINKED" = "1" ]; then
  ok "KNOWN GAP, pinned: $UNCOVERED of $TOTAL_CALLEES body-edge callees have no manifest row (hmac_sha256 8, parse_validate 5, composition_unlinked_helper 1)"
else
  no "the subject/callee gap moved to $UNCOVERED (hmac_sha256 $UNCOV_HMAC, parse_validate $UNCOV_PV, unlinked $UNCOV_UNLINKED), was 14 (8/5/1) — if the manifest population changed, say so; if a fixture changed, say which:"
  sed 's/^/      /' "$TMP/uncovered.tsv" | head -20
fi

# AND THE CONSEQUENCE IS STATED, not left implicit: these edges correspond TODAY. The number is the
# size of the correspondence loss a scoped join would take if it required an attested entry per
# callee and the manifest population were not extended first.
if [ "$UNCOVERED" -gt 0 ] 2>/dev/null; then
  ok "the gap is live (>0), so the flip cannot treat 'every table converted' as 'every edge attestable'"
else
  no "the gap is 0 — either the manifest population was extended (update this) or the measurement broke"
fi

echo "ATTESTATION-MANIFEST: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
