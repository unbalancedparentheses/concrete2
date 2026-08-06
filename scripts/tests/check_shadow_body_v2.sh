#!/usr/bin/env bash
# SHADOW BODY V2 — the structural body reaches the report, and nothing else.
#
# `--report subject-facts` now prints two shadow lines. They answer different questions and
# the distinction is the whole reason both exist:
#
#   shadow identityUses  digests the flat list of identity REFERENCES. Measured on the
#                        corpus, `p + 1`, `p * 2` and `p - 9` hash identically there — it is
#                        a reference inventory, not a body representation.
#   shadow bodyV2        digests the STRUCTURAL body, where those three differ.
#
# Both are shadow. The authoritative subject digest stays V1-frozen, and this gate asserts
# that it stays that way: structural bytes reaching a STATUS is the thing that must not
# happen by accident.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
fatal() { local rc=$?; echo "FATAL: check_shadow_body_v2 stopped at line ${BASH_LINENO[0]} (exit $rc)" >&2; exit "$rc"; }
trap fatal ERR
PASS=0; FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

BIN=".lake/build/bin/concrete"
[ -x "$BIN" ] || { echo "FATAL: build first (missing $BIN)" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- containment: the structural bytes must not reach anything authoritative -----------
# Exactly two references are expected: the definition, and the report line. A third is not
# automatically wrong, but it must be looked at, which is why this asserts the set rather
# than a count.
refs="$(grep -rln "bodyBytesV2" Concrete/ Main.lean 2>/dev/null | sort | tr '\n' ' ')"
if [ "$refs" = "Concrete/Proof/IdentityUseBytes.lean Concrete/Report/Report.lean " ]; then
  ok "bodyBytesV2 is referenced only by its definition and the shadow report line"
else
  no "bodyBytesV2 reached a new owner ($refs) — if a STATUS now depends on structural bytes, that is the V1 freeze breaking"
fi

if grep -q "bodyBytesV2" Concrete/Proof/SubjectFacts.lean 2>/dev/null; then
  no "SubjectFacts references bodyBytesV2 — structural bytes could enter the canonical subject digest"
else
  ok "the canonical subject digest cannot include structural body bytes"
fi

# --- behaviour: the structural digest SEPARATES bodies the flat digest merges -----------
# This is the property the whole representation exists for. The flat view of these three
# bodies is identical (one binder reference each); only the structural bytes differ.
mk() { printf 'mod m { pub fn f(p: Int) -> Int { return %s; } }\n' "$1" > "$2"; }
mk "p + 1" "$TMP/a.con"
mk "p * 2" "$TMP/b.con"
mk "p - 9" "$TMP/c.con"

# `|| true` at the end: under `set -o pipefail` a non-matching grep makes this return
# non-zero, the ERR trap fires, and the gate DIES instead of reporting "line missing".
# An absent measurement must reach the case statements below as an empty string.
# Anchored on the PREFIX, not `s/.*: //`: the refused form is
# "REFUSED (1 gap(s): desugared for-loop)" and a greedy match strips up to the LAST
# colon, yielding "desugared for-loop)" — which then fails the digest/refusal case
# analysis below for a reason that has nothing to do with the compiler.
line_of() { "$BIN" "$1" --report subject-facts 2>/dev/null | grep "shadow $2:" | head -1 | sed "s/^ *shadow $2: //" || true; }

fa="$(line_of "$TMP/a.con" bodyV2)"; fb="$(line_of "$TMP/b.con" bodyV2)"; fc="$(line_of "$TMP/c.con" bodyV2)"
ua="$(line_of "$TMP/a.con" identityUses)"; ub="$(line_of "$TMP/b.con" identityUses)"

if [ -z "$fa" ] || [ -z "$fb" ] || [ -z "$fc" ]; then
  no "the shadow bodyV2 line is missing — inconclusive, not agreement"
elif [ "$fa" != "$fb" ] && [ "$fb" != "$fc" ] && [ "$fa" != "$fc" ]; then
  ok "structural bytes separate p+1, p*2 and p-9"
else
  no "structural bytes MERGE operator-different bodies (a=$fa b=$fb c=$fc) — the representation is not describing the body"
fi

# The companion fact, asserted so the two lines are never assumed to be redundant. If this
# ever starts differing, the flat digest gained body structure and this gate should say so.
if [ -n "$ua" ] && [ "$ua" = "$ub" ]; then
  ok "the flat identity-use digest still merges them, which is why it is not a body representation"
else
  no "the flat digest now separates p+1 from p*2 ($ua vs $ub) — re-examine what identityUses means before trusting either line"
fi

# --- refusal: a body with gaps prints its REASONS, never a digest -----------------------
# A for-loop is currently unhandled by the producer, so this subject must be refused.
cat > "$TMP/gap.con" <<'CON'
mod m {
  pub fn f(n: Int) -> Int {
    let mut t: Int = 0;
    for (let mut i: Int = 0; i < n; i = i + 1) { t = t + i; }
    return t;
  }
}
CON
g="$(line_of "$TMP/gap.con" bodyV2)"
case "$g" in
  REFUSED*gap*) ok "a body the producer cannot describe is refused with its reasons" ;;
  "")           no "no shadow bodyV2 line for the gap probe — inconclusive" ;;
  ABSENT*)      no "the gap probe threaded no structural body at all ($g) — that is a different fault from a gap" ;;
  *)            no "a body with an unhandled construct produced a DIGEST ($g) — a partial body must not be comparable" ;;
esac

# The reasons must NAME the construct. The nine gap codes are stable and few, so a tally of
# codes says "statements and expressions" — true and useless. The detail is what drives the
# remaining producer work.
case "$g" in
  *"for-loop"*) ok "the refusal names the construct, not just its gap code" ;;
  *)            no "the refusal does not name the unhandled construct ($g)" ;;
esac

# --- ratchet: corpus coverage must not regress ------------------------------------------
# Measured 2026-08-05: 292 of 432 subjects digest, 0 absent.
#
# The corpus is NAMED and its existence asserted. The first version of this gate passed
# `tests/valid_programs examples proofs` to find with stderr silenced; the first does not
# exist and the third holds no .con files, so it measured `examples/` alone while its own
# message claimed three corpora. A ratchet over a silently smaller corpus is the
# green-for-the-wrong-reason failure — the floor stays satisfied precisely because the
# subjects that would break it were never measured.
#
# The missing directory also made `find` exit non-zero inside a process substitution, which
# tripped the ERR trap and printed FATAL while the gate went on to report PASS=9 FAIL=0.
CORPORA=(examples)
for d in "${CORPORA[@]}"; do
  if [ -d "$d" ]; then
    ok "corpus directory present: $d"
  else
    no "corpus directory $d is MISSING — the coverage floor below would be measured over less than it claims"
  fi
done

: > "$TMP/all.txt"
# No `| head -N`. `head` closes the pipe, `find` takes SIGPIPE, and under `set -o pipefail`
# that kills the gate mid-measurement — which reads as a failure of the thing measured.
while IFS= read -r f; do
  "$BIN" "$f" --report subject-facts 2>/dev/null | grep "shadow bodyV2:" >> "$TMP/all.txt" || true
done < <(find "${CORPORA[@]}" -type f -name '*.con' | sort)

total="$(wc -l < "$TMP/all.txt" | tr -d ' ')"
digested="$(grep -cv 'REFUSED\|ABSENT' "$TMP/all.txt" || true)"
absent="$(grep -c 'ABSENT' "$TMP/all.txt" || true)"

if [ "$total" -lt 400 ]; then
  no "only $total subjects measured — the corpus shrank or the report changed shape; a smaller corpus makes the ratchet below meaningless"
else
  ok "corpus measured: $total subjects across ${CORPORA[*]}"
fi

# ABSENT is a different fault from REFUSED: it means no structural body was threaded at
# all, so the producer never ran rather than declining to describe something.
if [ "$absent" -eq 0 ]; then
  ok "every subject has a structural body threaded (0 absent)"
else
  no "$absent subjects have NO structural body — the body is not reaching ProofCore for them"
fi

FLOOR=292
if [ "$digested" -ge "$FLOOR" ]; then
  ok "structural coverage $digested/$total (floor $FLOOR)"
else
  no "structural coverage REGRESSED to $digested/$total, below the $FLOOR floor — a construct the producer used to describe now yields a gap"
fi

echo "SHADOW-BODY-V2: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
