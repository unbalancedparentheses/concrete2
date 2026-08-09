#!/usr/bin/env bash
# Is the checked-in classification table still what the live environment says?
#
# SEPARATE FROM check_dependency_edges.sh because it is SLOW: verifying freshness means running
# the generator, which classifies every linked theorem and digests each proof term. A per-commit
# gate that costs minutes is one people start skipping, and a skipped gate protects nothing.
#
# What it protects: `Concrete/Proof/ClassificationTable.lean` is generated data the compiler
# TRUSTS to type dependency edges. Nothing else in R-0004 rests on a value nobody re-derives,
# and this must not be the exception. A stale row types edges from a theorem that has since been
# reproved, restated, or replaced by a different theorem of the same name — and every downstream
# check passes, because the row is structurally valid. Only re-derivation catches it.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/tests/lib/fresh.sh"
require_fresh_binary || exit 1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# === THE CHECKED-IN TABLE MUST NOT BE STALE (slice 6, blocker b) =============================
# `ClassificationTable.lean` is generated data the compiler trusts. Nothing else in R-0004 rests
# on a value nobody re-derives, and this must not be the exception: a stale table types edges
# from a theorem that has since been reproved, restated, or replaced by a different theorem of
# the same name — and every downstream check would pass, because the row is structurally valid.
#
# So the table is re-derived from the LIVE environment and compared. A stale table is a gate
# failure, not a silent wrong answer.
# THE NAME INVENTORY IS REDISCOVERED HERE, not taken from the generator. `classifications.lean`
# carries a GENERATED `sourceLinkedThms` list, so running it proves the table matches that list —
# not that the list matches the source. A new `#[proof_by]` annotation omitted from the list would
# leave the gate green while its theorem was never classified, which is exactly the gap that made
# `main.verify_message` proved-with-a-refusing-root.
#
# So: re-extract from source and compare against what the generator will actually ask about.
echo "=== theorem-name inventory is exhaustive ==="
grep -rhoE '#\[(proof_by|ensures_proof)\(([A-Za-z0-9_.]+)\)\]' examples/ \
  | sed -E 's/.*\(([^)]*)\)\]/\1/' | sort -u > "$TMP/src_names.txt"
grep -oE '`[A-Za-z0-9_.]+' scripts/gen/classifications.lean | sed 's/^`//' | sort -u > "$TMP/gen_names.txt"
MISSING="$(comm -23 "$TMP/src_names.txt" "$TMP/gen_names.txt" || true)"
if [ -z "$MISSING" ]; then
  ok "every source-linked proof name is in the generator's inventory ($(wc -l < "$TMP/src_names.txt") names)"
else
  no "source-linked proof(s) missing from the generator inventory — run scripts/gen/refresh_classifications.sh:"
  printf '%s\n' "$MISSING" | head -5 | sed 's/^/      /'
fi

echo "=== classification table freshness ==="
FRESH="$TMP/fresh_rows.txt"
if lake env lean scripts/gen/classifications.lean > "$FRESH" 2>&1; then
  # Compare the (theorem, edge, digest) triples, order-insensitively: the generator emits in
  # request order, and the checked-in file may have been reordered by hand without meaning
  # anything. Content is what must agree.
  CHECKED="$(grep -oE '\("[^"]+", "[^"]+", "[^"]+"\)' Concrete/Proof/ClassificationTable.lean | sort || true)"
  LIVE="$(grep -oE '\("[^"]+", "[^"]+", "[^"]+"\)' "$FRESH" | sort || true)"
  if [ -z "$LIVE" ]; then
    no "the generator produced no rows — cannot establish table freshness, which is not the same as the table being fresh"
  elif [ "$CHECKED" = "$LIVE" ]; then
    ok "the checked-in classification table matches a fresh derivation ($(printf '%s\n' "$LIVE" | wc -l) rows)"
  else
    no "STALE classification table — regenerate with scripts/gen/refresh_classifications.sh. A row whose theorem digest moved types edges from a theorem that no longer exists."
    diff <(printf '%s\n' "$CHECKED") <(printf '%s\n' "$LIVE") | head -6 | sed 's/^/      /'
  fi
else
  no "the classification generator failed to run — table freshness is unverified"
fi


echo ""
echo "CLASSIFICATION-FRESHNESS: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
