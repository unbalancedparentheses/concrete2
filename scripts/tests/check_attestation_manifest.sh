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

# THE KNOWN MISATTACHMENT REMAINS VISIBLE. `proof_pressure` borrows theorems from two other packages,
# which is the defect correspondence already refuses; the manifest must not quietly normalise it.
PP_TABLES="$(printf '%s' "$OUT" | grep 'proof_pressure' | awk '{print $1}' | sort -u | grep -c . || true)"
if [ "$PP_TABLES" = "2" ]; then
  ok "proof_pressure still attests 2 tables (the borrowed-theorem misattachment stays visible)"
else
  no "proof_pressure attests $PP_TABLES table(s) (expected 2) — if the fixture was repaired, update this; if the manifest normalised it, that is a defect"
fi

echo "ATTESTATION-MANIFEST: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
