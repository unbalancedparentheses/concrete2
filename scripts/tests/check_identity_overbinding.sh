#!/usr/bin/env bash
# IDENTITY OVER-BINDING — the entrance gate for the five-way separation.
#
# This gate PINS A DEFECT. Every leg below asserts what identity does TODAY, which is the wrong
# thing, so that the migration cannot land quietly: when the separation is implemented these legs
# FAIL, and that failure is the signal to convert each one into its positive form. Same discipline as
# the 059/060 tripwires, which asserted the wrong verdict on purpose until the fix arrived.
#
# WHAT IS WRONG. `PackageIdentity` binds the complete dependency closure, which dependency roots
# already model, AND it scopes `DefinitionIdentity` by package CONTENT. So:
#
#   * editing a std module moves the identity of packages that never mention it, because std is
#     auto-injected everywhere. MEASURED by control 1 below: a two-line code edit to
#     std/src/base64.con moves 7 of 21 package identities and rewrites 168 of the surface's lines.
#     On 2026-08-19 the same edit demoted three proved subjects to `dependency closure unjustified`.
#     Not ALL 21 move — one package is unaffected — and the gate reports the measured ratio rather
#     than a round claim, because "every" was what I wrote first and it was wrong.
#   * editing one function renames the attestation symbol of a DIFFERENT function in the same
#     package, whose module, declaration and implementation digest are all unchanged
#
# FAIL-SAFE, NOT UNSOUND. The failure mode is demotion and renaming, never a proof credited to a body
# it does not describe. That is why this is an entrance gate for a migration rather than a bug fix.
#
# NO BUILD REQUIRED: package identity is computed from source content at REPORT time, so editing a
# copy and running the existing binary against it is sufficient. The copy means the working tree is
# never touched.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
BIN="$ROOT_DIR/.lake/build/bin/concrete"
[ -x "$BIN" ] || { echo "error: build first ($BIN missing)" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

W="$TMP/repo"; mkdir -p "$W"
cp -a "$ROOT_DIR/." "$W/" 2>/dev/null || { echo "error: could not copy the repository" >&2; exit 2; }

# pkgid <root> <example> — the package identity the compiler reports for that example's subjects.
pkgid() {
  "$BIN" "$1/examples/$2/src/main.con" --report attestation-join 2>/dev/null \
    | awk -F'\t' '$1 == "subject" {print $3; exit}'
}
# declid <root> <example> <decl> — the implementation digest for one declaration.
declid() {
  "$BIN" "$1/examples/$2/src/main.con" --report attestation-join 2>/dev/null \
    | awk -F'\t' -v d="$3" '$1 == "subject" && $5 == d {print $6; exit}'
}

BASE_PKG="$(pkgid "$W" crypto_verify)"
BASE_TAG="$(declid "$W" crypto_verify compute_tag)"
if [ -n "$BASE_PKG" ] && [ -n "$BASE_TAG" ]; then
  ok "baseline read: crypto_verify package $BASE_PKG, compute_tag impl $BASE_TAG"
else
  no "could not read a baseline identity (pkg='$BASE_PKG' impl='$BASE_TAG') — every leg below would be vacuous"
  echo "IDENTITY-OVERBINDING: PASS=$PASS FAIL=$FAIL"; exit 1
fi

echo ""
echo "=== control 1: editing a std module moves other packages' identities ==="
# MEASURED THROUGH THE GENERATOR, not through a per-fixture `--report attestation-join`. Those two
# disagree: the direct report on one example keeps returning the same package identity after a std
# edit, while regenerating the attestation surface moves it. The generator is the authority here
# because it is what produces the symbols proofs actually select, so it is what a stale identity
# breaks. (The disagreement itself is worth a look during the migration — two paths answering the
# same question differently is the defect class this project keeps paying for — but the gate must
# measure the one that matters.)
GEN="$W/Concrete/Proof/GeneratedAttestations.lean"
cp "$GEN" "$TMP/gen.before"
perl -0pi -e 's/if v == 62 \{ return 43; \}/if v == 62 { return 43; } if v == 63 { return 47; }/' "$W/std/src/base64.con" 2>/dev/null
( cd "$W" && bash scripts/gen/attestation_refs.sh >/dev/null 2>&1 )
ids_of(){ grep -oE 'of\? "[0-9a-f]{32}"' "$1" | sort -u; }
MOVED="$(comm -23 <(ids_of "$TMP/gen.before") <(ids_of "$GEN") | grep -c . || true)"
TOTAL="$(ids_of "$TMP/gen.before" | grep -c . || true)"
CHANGED_LINES="$(diff "$TMP/gen.before" "$GEN" | grep -c '^[<>]' || true)"
git -C "$W" checkout -- std/src/base64.con Concrete/Proof/GeneratedAttestations.lean 2>/dev/null || true

if [ "${TOTAL:-0}" -lt 10 ]; then
  no "only $TOTAL package identities parsed — the measurement is broken, not the scheme"
elif [ "${MOVED:-0}" -gt 0 ]; then
  ok "DEFECT PINNED: a two-line std code edit moved $MOVED of $TOTAL package identities and rewrote $CHANGED_LINES lines of the attestation surface. std is auto-injected, so packages that never mention it are rescoped by it. Under the separation, dependency content belongs to ResolutionContextIdentity and must not reach PackageScopeIdentity — convert this leg then."
else
  no "a std edit no longer moves any package identity — if the separation has landed, convert this leg to its positive form; if not, the measurement has broken"
fi

echo ""
echo "=== control 2: editing an unrelated module in the SAME package ==="
# The sibling case. `proof_pressure` holds several functions; editing one must not move the identity
# under which a DIFFERENT one is attested. Today it does, because the package's identity is a digest
# over its whole content and every declaration is scoped by it.
SIB="$W/examples/proof_pressure/src/main.con"
if [ -f "$SIB" ]; then
  BASE_PP="$(pkgid "$W" proof_pressure)"
  BASE_CN="$(declid "$W" proof_pressure check_nonce)"
  printf '\n// transient probe: sibling-edit identity coupling\n' >> "$SIB"
  AFTER_PP="$(pkgid "$W" proof_pressure)"
  AFTER_CN="$(declid "$W" proof_pressure check_nonce)"
  git -C "$W" checkout -- examples/proof_pressure/src/main.con 2>/dev/null || true
  if [ "$AFTER_CN" = "$BASE_CN" ]; then
    ok "check_nonce's implementation digest survives a sibling edit ($BASE_CN)"
  else
    no "a comment-only sibling edit moved check_nonce's IMPLEMENTATION digest — the body digest is reading file text"
  fi
  if [ "$AFTER_PP" != "$BASE_PP" ]; then
    ok "DEFECT PINNED: a sibling edit moved the package identity ($BASE_PP -> $AFTER_PP) that check_nonce is attested under, though its own module, declaration and implementation are unchanged. This is what renames its generated symbol and breaks every proof selecting it."
  else
    no "a sibling edit no longer moves the package identity — if the separation has landed, convert this leg; if not, the measurement has broken"
  fi
else
  no "examples/proof_pressure/src/main.con is missing — control 2 could not run"
fi

echo ""
echo "=== control 3: editing the SUBJECT's own implementation ==="
# The leg that must keep passing in BOTH schemes, and the reason the other two are defects rather
# than the price of doing business: a real change to the body being attested must move that
# declaration's identity. If this ever fails, identity has stopped tracking what it names.
SUBJ="$W/examples/crypto_verify/src/main.con"
if grep -q 'return key \* message + nonce;' "$SUBJ" 2>/dev/null; then
  perl -0pi -e 's/return key \* message \+ nonce;/return key * message + nonce + 1;/' "$SUBJ"
  EDIT_TAG="$(declid "$W" crypto_verify compute_tag)"
  git -C "$W" checkout -- examples/crypto_verify/src/main.con 2>/dev/null || true
  if [ -n "$EDIT_TAG" ] && [ "$EDIT_TAG" != "$BASE_TAG" ]; then
    ok "editing the subject's own body moves its implementation digest ($BASE_TAG -> $EDIT_TAG)"
  else
    no "editing compute_tag's body did NOT move its implementation digest — identity has stopped tracking the thing it names"
  fi
else
  no "the compute_tag body anchor is gone from crypto_verify — control 3 could not run"
fi

echo ""
echo "=== controls not yet representable ==="
# Stated rather than silently omitted. Two rows of the agreed matrix cannot be measured while the
# scheme is unsplit, and saying so is the difference between a gap and an oversight:
#
#   * "editing a REACHABLE std definition moves the affected dependency roots and receipts" needs
#     roots and receipts to be separable from package identity, which is the migration itself
#   * "changing publisher/origin moves all scoped definitions" needs a publisher/origin component,
#     which does not exist until PackageScopeIdentity does
ok "2 matrix rows deferred to the migration (reachable-std, publisher/origin) — recorded, not skipped"

echo ""
echo "IDENTITY-OVERBINDING: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
