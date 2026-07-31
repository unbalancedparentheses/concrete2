#!/usr/bin/env bash
# R-0004 step 5 — migrating the nine hand-written FnTables, with DUAL COMPARISON.
#
# A hand-written table becomes evidence-bearing by gaining `entries`. That is only
# sound if its hand-written spec is genuinely the compiler's extraction — otherwise
# the migration mints a root over a body the program does not have, and every proof
# resting on it describes something else.
#
# So each migrated table is compared against a FRESH GENERATION from its example:
#   * the identity the compiler mints, field for field;
#   * the body, via `sourceBodyDigestV1` over `pexprCanonical` — the committed
#     table's spec must hash to what the compiler computes from source;
#   * declared keys resolve, and an UNDECLARED key still resolves to none (control,
#     so "resolves" cannot be an artifact of a total function);
#   * the key -> identity mapping is the one evaluation uses (`dispatchResolves`);
#   * the table is evidence-bearing and has a root;
#   * kernel replay of that example's proofs still succeeds.
#
# The inventory leg at the end is the one that makes this a migration rather than a
# collection of migrations: it counts tables that are STILL legacy, so finishing is
# a measurable state and a forgotten table cannot pass as done.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
[ -x ".lake/build/bin/concrete" ] || { echo "error: build first" >&2; exit 2; }
CC=".lake/build/bin/concrete"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# lean <label> <expected> <body>
lean_probe() {
  local label="$1" want="$2" body="$3"
  cat > "$TMP/p.lean" <<LEAN
import Concrete
open Concrete Concrete.Proof
$body
LEAN
  local out; out="$(lake env lean "$TMP/p.lean" 2>&1 || true)"
  if grep -qF -- "$want" <<<"$out"; then ok "$label"
  else no "$label — got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; fi
}

# migrated <table> <example-path> <declName> <module> <undeclared-key>
migrated() {
  local tbl="$1" ex="$2" decl="$3" mod="$4" absent="$5"
  echo "--- $tbl (from $mod) ---"

  # 1. EVIDENCE-BEARING WITH A ROOT. Both were false before migration.
  lean_probe "$tbl is evidence-bearing" "true" "#eval $tbl.isEvidenceBearing"
  lean_probe "$tbl has a root"          "true" "#eval $tbl.root.isSome"
  # 2. The root's key map is the one evaluation uses.
  lean_probe "$tbl dispatch resolves its own keys" "true" "#eval $tbl.dispatchResolves"
  # 3. Declared key resolves; UNDECLARED key does not (control).
  lean_probe "$tbl resolves the declared key '$decl'" "true" "#eval ($tbl.globals \"$decl\").isSome"
  lean_probe "$tbl returns none for an undeclared key" "false" "#eval ($tbl.globals \"$absent\").isSome"
  # 4. Identity lookup, by CallableId rather than by name.
  lean_probe "$tbl resolves $decl by identity" "true" \
    "#eval ($tbl.lookupById (CallableId.ofUser \"$mod\" \"$decl\")).isSome"

  # 5. DUAL COMPARISON against a fresh generation: same identity, same body digest.
  "$CC" "$ex" --report lean-stubs > "$TMP/gen.lean" 2>/dev/null
  if grep -q "defModule := \"$mod\", declName := \"$decl\"" "$TMP/gen.lean"; then
    ok "the compiler mints the same identity for $mod.$decl"
  else
    no "the compiler's identity for $mod.$decl differs from the migrated table's"
  fi
  local gendig
  gendig="$(grep -A4 "declName := \"$decl\"" "$TMP/gen.lean" \
            | grep -o 'value := "[a-f0-9]*"' | head -1 | grep -o '[a-f0-9]\{32\}' || true)"
  if [ -z "$gendig" ]; then
    no "no generated body digest found for $decl — cannot compare bodies"
  else
    # The committed spec must hash to the compiler's digest. This is the leg that
    # makes the migration sound rather than merely type-correct.
    lean_probe "the committed spec for $decl hashes to the compiler's digest" "true" \
      "#eval ($tbl.entries.toList.find? (fun d => d.operationalKey == \"$decl\")).any
         (fun d => Concrete.shortHash (pexprCanonical d.body) == \"$gendig\")"
  fi

  # 6. Kernel replay of that example's proofs must still succeed.
  local rep; rep="$("$CC" "$ex" --report check-proofs 2>&1 || true)"
  if grep -qE "0 failed" <<<"$rep"; then ok "$tbl's example still kernel-replays with 0 failed"
  else no "$tbl's example no longer replays: $(grep -E 'Summary|failed' <<<"$rep" | head -1)"; fi
}

echo "=== migrated tables (dual comparison) ==="
migrated ctTagFns examples/constant_time_tag/src/main.con ct_compare constant_time_tag no_such_fn

echo ""
echo "=== inventory: how many of the nine are still legacy? ==="
# A legacy table has EMPTY entries: it evaluates and has no root, so it mints
# nothing. Counting them makes "step 5 is finished" a measurable claim.
lean_probe "the migrated tables report their own count" "1" \
'#eval ([ctTagFns].filter (fun t => !t.entries.isEmpty)).length'
lean_probe "the not-yet-migrated tables are still exactly 8" "8" \
'#eval ([proofFns, proofFnsExt, cryptoFns, elfFns, parseValidateFns,
        fixedCapacityFns, Examples.ProofPatterns.Proofs.combineFns,
        Examples.HmacSha256.Proofs.shaFns].filter (fun t => t.entries.isEmpty)).length'

echo ""
echo "TABLE-MIGRATION: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
