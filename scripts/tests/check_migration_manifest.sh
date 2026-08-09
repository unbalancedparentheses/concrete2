#!/usr/bin/env bash
# The migration manifest: every stored proof link joined to the subject it must migrate to.
#
# WHY THIS EXISTS AS A GATE. The measurement "39 of 39 migration subjects digest" was run once
# by hand, from an ad-hoc shell loop, and written into the roadmap as though it were established.
# It was not: nothing reproduced it, nothing would notice if it stopped being true, and a number
# in prose is not a measurement — it is a memory of one. This file is that loop, committed, with
# the join made exact.
#
# TWO DENOMINATORS, RECONCILED. They are different things and quoting either alone misleads:
#
#   * 44 STORED LINKS — `#[proof_fingerprint]` annotations across the selected migration
#     examples. This is what `check_v1_fingerprint_golden.sh` establishes and what the step-7
#     migration must rewrite, one by one.
#   * 64 UNIQUE SUBJECTS — the callables in the files those links live in. The hand-run number
#     recorded in the roadmap was 39, from a narrower file set (`examples/*/src/main.con` only);
#     that is the third way this denominator has been miscounted, and the reason the count now
#     comes from a gate instead of a memory.
#
# A gate that checked only the subject count would miss a link that is dangling (attached to no
# subject) or duplicated; one that checked only the link count would miss a subject whose body is
# refused. So both are asserted, and so is the join between them.
#
# PER SUBJECT, NOT IN AGGREGATE. An earlier version compared totals — "N digested, M refused, T
# total" — which false-greens exactly when it matters: one refused subject wrongly receiving a
# digest while a complete one is missing its own cancels out in a sum. Each subject is checked
# against its own body line.

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/tests/lib/fresh.sh"
source "$ROOT_DIR/scripts/tests/lib/fingerprints.sh"
require_fresh_binary || exit 1

BIN=".lake/build/bin/concrete"
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# The migration set is defined by where links are STORED, not by a directory listing: a fixture
# that never had a link has nothing to migrate, and including it would inflate the denominator
# the same way the raw `grep examples/` count did (53) against the normative one (44).
# The pattern and file set come from `lib/fingerprints.sh`, which is the ONE definition. They
# used to be duplicated text in two gates — same characters, not the same definition, so either
# could drift alone and the two would measure different populations while both reporting a count.
mapfile -t SRCS < <(grep -rlE "$FP_PATTERN" examples/ 2>/dev/null | sort -u)

# Subject IDENTITIES, deduplicated — not a count of report blocks. The same subject can appear
# in more than one file's report (an import surfaces in both), and counting blocks reported it
# twice. "64 unique subjects" was therefore overstated: it was 64 block occurrences.
LINKS=0; DIGESTED=0; REFUSED=0; MISMATCH=""
SEEN_FILE="$(mktemp)"; DIG_FILE="$(mktemp)"; trap 'rm -f "$SEEN_FILE" "$DIG_FILE"' EXIT
for src in "${SRCS[@]}"; do
  n="$(grep -cE "$FP_PATTERN" "$src" || true)"
  LINKS=$((LINKS + n))
  rep="$("$BIN" "$src" --report subject-facts 2>/dev/null || true)"
  # Walk the report block by block: a subject header, then its own bodyV2 and freshness lines.
  # Correlating by position within the block is what makes this per-subject rather than a sum.
  cur=""; body=""; fresh=""
  while IFS= read -r line; do
    case "$line" in
      v1:*)
        if [ -n "$cur" ]; then
          printf '%s\n' "$cur" >> "$SEEN_FILE"
          case "$body" in *REFUSED*) printf '%s\n' "$cur" >> "$DIG_FILE.ref"; [ -n "$fresh" ] && MISMATCH="$MISMATCH $cur(refused-but-digested)" ;;
                          *)          case "$fresh" in "") MISMATCH="$MISMATCH $cur(complete-but-no-digest)" ;; *) printf '%s\n' "$cur" >> "$DIG_FILE" ;; esac ;;
          esac
        fi
        cur="$line"; body=""; fresh="" ;;
      *"shadow bodyV2:"*) body="$line" ;;
      *"subjectFreshness:"*) case "$line" in *"current would be v2:"*) fresh="$line" ;; esac ;;
    esac
  done <<< "$rep"
  if [ -n "$cur" ]; then
    printf '%s\n' "$cur" >> "$SEEN_FILE"
    case "$body" in *REFUSED*) printf '%s\n' "$cur" >> "$DIG_FILE.ref"; [ -n "$fresh" ] && MISMATCH="$MISMATCH $cur(refused-but-digested)" ;;
                    *)          case "$fresh" in "") MISMATCH="$MISMATCH $cur(complete-but-no-digest)" ;; *) printf '%s\n' "$cur" >> "$DIG_FILE" ;; esac ;;
    esac
  fi
done

SUBJECTS="$(sort -u "$SEEN_FILE" 2>/dev/null | wc -l | tr -d ' ')"
DIGESTED="$(sort -u "$DIG_FILE" 2>/dev/null | wc -l | tr -d ' ')"
REFUSED="$(sort -u "$DIG_FILE.ref" 2>/dev/null | wc -l | tr -d ' ')"
BLOCKS="$(wc -l < "$SEEN_FILE" | tr -d ' ')"

echo "=== migration manifest ==="
echo "  subject BLOCKS reported: $BLOCKS (deduplicated to $SUBJECTS identities)"
echo "  examples with stored links: ${#SRCS[@]}"
echo "  stored links: $LINKS   unique subjects: $SUBJECTS"
echo "  subjects with a complete V2 digest: $DIGESTED   structurally refused: $REFUSED"

# The normative link denominator, cross-checked against the V1 golden gate rather than restated.
EXPECT_LINKS=44
[ "$LINKS" = "$EXPECT_LINKS" ] \
  && ok "stored links = $EXPECT_LINKS (matches the V1 golden denominator)" \
  || no "stored links = $LINKS, expected $EXPECT_LINKS — the migration denominator moved; update this gate AND the roadmap together, or one will quote a number the other has abandoned"

# Every subject either digests or is explicitly refused. Silence is the failure mode: a subject
# that is neither would be migrating against nothing.
[ "$((DIGESTED + REFUSED))" = "$SUBJECTS" ] \
  && ok "every subject is accounted for: $DIGESTED digested + $REFUSED refused = $SUBJECTS" \
  || no "$((SUBJECTS - DIGESTED - REFUSED)) subject(s) neither digested nor refused — unaccounted, which is how a link migrates against nothing"

# The per-subject correlation, which the aggregate version could not see.
[ -z "$MISMATCH" ] \
  && ok "no subject disagrees with its own body line (per-subject, not summed)" \
  || no "subject/body disagreement:$MISMATCH"

# The fail-closed body requirement must cost the migration nothing. If this ever fires, some
# link cannot migrate until its construct becomes describable — which is a real blocker and
# should be loud, not discovered during step 7.
[ "$REFUSED" = "0" ] \
  && ok "no migration subject is structurally refused — fail-closed costs this set nothing" \
  || no "$REFUSED migration subject(s) refused: those links cannot migrate until the producer describes their constructs"

echo ""
echo "MIGRATION-MANIFEST: PASS=$PASS FAIL=$FAIL (links=$LINKS subjects=$SUBJECTS)"
[ "$FAIL" -eq 0 ]
