#!/usr/bin/env bash
# CLEAN-CHECKOUT REPRODUCIBILITY AND COMPILER PROVENANCE (R-0004 package 3).
#
# `check_evidence_reproducibility.sh` establishes PATH independence: the same program at a different
# absolute path yields identical evidence. That is necessary and it is not sufficient. Two runs can
# be equally path-independent and still disagree about WHICH COMPILER produced them, or agree for the
# wrong reason because both read the same working tree.
#
# This gate covers what path independence does not:
#
#   * a genuinely CLEAN CHECKOUT — `git clone` into a fresh directory, no build artifacts, no
#     untracked files — produces the same evidence as the working tree;
#   * invocation from the REPOSITORY ROOT and from the PROJECT ROOT agree;
#   * the compiler identity a receipt binds is the CONTENT OF THE EXECUTABLE THAT RAN, not the
#     repository's state at report time.
#
# THE COMPILER-IDENTITY LEG IS THE LOAD-BEARING ONE. Two earlier identities were wrong in both
# directions: `-dirty` from `git status` (any untracked file invalidated every receipt, and a binary
# built dirty then cleaned reported clean), and `git rev-parse HEAD` (a binary built from commit A
# claims B once the checkout moves, and a binary built from uncommitted sources claims whatever is
# checked out). Digesting the executable answers all three of the cases that matter:
#
#   built from A while the checkout points at B  -> identity unchanged; it describes the binary
#   built from uncommitted sources               -> content no committed build has -> distinct
#   substituted executable at the same commit    -> different content -> different identity
set -uo pipefail
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "${GATE_DONE:-0}" -ne 1 ]; then
  echo "FATAL: unexpected shell failure (exit $rc) — the verdict below is not trustworthy" >&2; exit "$rc"; fi' ERR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source "scripts/tests/lib/fresh.sh"
require_fresh_binary || exit 1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$ROOT_DIR/.lake/build/bin/concrete"

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# The evidence surface. Captured rather than piped: these fixtures exit non-zero when they carry
# proof defects, and a pipeline exit code must not be allowed to decide the comparison.
evidence_of() {
  {
    "$BIN" "$1" --report proof-status    2>/dev/null | grep -E '^-- |proof matches' || true
    "$BIN" "$1" --report subject-facts    2>/dev/null | grep -E 'defIdentity|depRoot|correspondence' || true
    "$BIN" "$1" --report attestation-join 2>/dev/null | grep -E '^(subject|dependency)' || true
  }
}

echo "=== a clean checkout reproduces the working tree's evidence ==="

# A REAL CLONE, not a copy: `git clone` takes only committed content, so build artifacts, untracked
# files and local edits cannot leak into the comparison. That is the difference between "the same
# bytes somewhere else" and "what someone else would get".
if git clone --quiet --no-hardlinks "$ROOT_DIR" "$TMP/clone" 2>/dev/null; then
  ok "cloned the repository into a fresh directory"
else
  no "could not clone the repository — every assertion below would be vacuous"
  GATE_DONE=1; echo "CLEAN-CHECKOUT: PASS=$PASS FAIL=$FAIL"; exit 1
fi
# Any uncommitted work would make the clone legitimately differ, so the comparison is only meaningful
# from a clean tree. Reported rather than silently skipped.
DIRTY="$(git status --porcelain | grep -vc '^?? ' || true)"
if [ "$DIRTY" = "0" ]; then
  ok "the working tree has no uncommitted tracked changes, so the clone is comparable"
else
  no "$DIRTY uncommitted tracked change(s): the clone cannot be compared against the working tree"
fi

for fixture in elf_header crypto_verify proof_patterns/composition; do
  HERE="$(evidence_of "examples/$fixture/src/main.con")"
  THERE="$(evidence_of "$TMP/clone/examples/$fixture/src/main.con")"
  if [ -z "$HERE" ]; then
    no "$fixture produced no evidence — the comparison would be vacuous"
  elif [ "$HERE" = "$THERE" ]; then
    ok "$fixture: a clean checkout yields byte-identical evidence"
  else
    no "$fixture: evidence DIFFERS in a clean checkout — something outside committed content is reaching it"
    diff <(printf '%s' "$HERE") <(printf '%s' "$THERE") | head -6 | sed 's/^/      /'
  fi
done

echo "=== repository root and project root agree ==="

# `lake` finds its workspace by walking up from wherever it is invoked, and a verdict that depended
# on where the caller stood is exactly what slice 4 removed. Asserted from BOTH directions rather
# than assumed from the resolver's code.
FROM_REPO="$(evidence_of "examples/elf_header/src/main.con")"
FROM_PROJ="$(cd examples/elf_header && evidence_of "src/main.con")"
if [ -z "$FROM_REPO" ]; then
  no "no evidence from the repository root — the comparison would be vacuous"
elif [ "$FROM_REPO" = "$FROM_PROJ" ]; then
  ok "invoking from the repository root and from the project root give identical evidence"
else
  no "evidence depends on the invoking directory"
  diff <(printf '%s' "$FROM_REPO") <(printf '%s' "$FROM_PROJ") | head -6 | sed 's/^/      /'
fi

echo "=== the compiler identity is the executable that ran ==="

REPORTED="$("$BIN" examples/elf_header/src/main.con --report receipts 2>/dev/null \
            | grep -oE 'exe:[0-9a-f]+' | head -1 | cut -d: -f2)"
ACTUAL="$(sha256sum "$BIN" | cut -c1-16)"
if [ -n "$REPORTED" ] && [ "$REPORTED" = "$ACTUAL" ]; then
  ok "the reported identity ($REPORTED) is the sha256 of the running executable"
else
  no "reported identity '$REPORTED' is not the executable's digest '$ACTUAL' — a receipt names a compiler that did not run"
fi

# THE SUBSTITUTION CASE, made concrete. A different executable has different content, so it cannot
# report this identity — demonstrated by digesting a modified copy rather than asserted from the
# construction. (The copy is not executed: a byte-appended binary need not run, and the property
# under test is that its IDENTITY differs.)
cp "$BIN" "$TMP/substituted"
printf 'x' >> "$TMP/substituted"
SUB="$(sha256sum "$TMP/substituted" | cut -c1-16)"
if [ "$SUB" != "$ACTUAL" ]; then
  ok "a substituted executable has a different identity ($SUB), so it cannot claim this one"
else
  no "a modified executable digests identically — substitution would be undetectable"
fi

# THE CHECKOUT-MOVES CASE. Receipts minted now must survive the repository moving underneath them,
# because the identity describes the binary and not the tree. The clone is at a different commit-ish
# state only if the tree is dirty, so this uses an untracked file — the exact noise that used to
# invalidate everything through `-dirty`.
"$BIN" examples/elf_header/src/main.con --report receipts --out "$TMP/r.txt" >/dev/null 2>&1
tally(){ "$BIN" examples/elf_header/src/main.con --report proof-status --receipts "$1" 2>/dev/null \
         | grep -oE '[0-9]+ current, [0-9]+ not current' | head -1; }
BEFORE="$(tally "$TMP/r.txt")"
NOISE="$ROOT_DIR/.clean-checkout-noise"; rm -rf "$NOISE"; mkdir -p "$NOISE"
printf 'untracked\n' > "$NOISE/f.txt"
AFTER="$(tally "$TMP/r.txt")"
rm -rf "$NOISE"
if [ "$BEFORE" != "5 current, 0 not current" ]; then
  no "the checkout-moves control had no current receipts to start from — it would be vacuous"
elif [ "$AFTER" = "$BEFORE" ]; then
  ok "receipts survive the working tree changing around them ($AFTER)"
else
  no "repository state moved receipt currency ($BEFORE -> $AFTER) — the identity is not the binary's"
fi

echo "=== an unidentifiable compiler mints nothing ==="

# The refusal exists so an unknown identity is never recorded: "unknown" compares equal to another
# "unknown", which is how receipts from two different compilers would agree. Asserted by reading the
# refusal path's own message rather than by simulating an unreadable /proc, which is not portable.
if grep -q 'executable_unlocatable' Main.lean && grep -q 'executable_undigestible' Main.lean \
   && grep -q 'would compare equal to one produced by any other compiler' Main.lean; then
  ok "issuance refuses, with a named reason, when the compiler cannot be identified"
else
  no "the unidentifiable-compiler refusal is gone — an unknown identity could be recorded"
fi

GATE_DONE=1
echo "CLEAN-CHECKOUT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
