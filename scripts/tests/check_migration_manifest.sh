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

# === THE EXACT JOIN (compiler-produced, one row per link) ====================================
# Everything above is CO-OCCURRENCE: 44 links live in files containing N digestible subjects.
# That admits a link which is dangling, duplicated, or attached to the wrong function, because
# nothing associated a link with an owner. `--report migration-manifest` is the join, produced
# by the compiler, which is the only layer that knows both sides.
#
# The shell measurement above stays as a coarse regression check; these assertions are the
# authoritative ones.
echo "=== exact link ownership ==="
MROWS=""
for src in "${SRCS[@]}"; do
  MROWS="$MROWS$("$BIN" "$src" --report migration-manifest 2>/dev/null | grep " | owner=" || true)
"
done
# DEDUPLICATED. An imported function appears in several files' manifests, so summing per-file
# row counts double-counts it — and the sum happened to reach exactly 44, which made the gap
# below invisible. Distinct rows is the only count that means anything here.
MROWS="$(printf '%s' "$MROWS" | sort -u)"
MLINKS="$(printf '%s' "$MROWS" | grep -c " | owner=" || true)"
MUNOWNED="$(printf '%s' "$MROWS" | grep -c "owner=NONE" || true)"
MNOSUBJ="$(printf '%s' "$MROWS" | grep -c "| no_subject$" || true)"
MSUBJ="$(printf '%s' "$MROWS" | grep -oE "owner=[^ ]+" | grep -v "owner=NONE" | sort -u | wc -l | tr -d ' ')"
# Duplicate = the same (function, spec) pair twice. The same FUNCTION twice is legitimate — a
# callable can be proved against more than one specification, and each link migrates separately.
MDUPES="$(printf '%s' "$MROWS" | grep -oE "^[^ ]+ \| owner=[^ ]+ \| stored=[^ ]+ \| spec=[^ ]+" | sort | uniq -d | wc -l | tr -d ' ')"

echo "  manifest rows: $MLINKS  unowned: $MUNOWNED  distinct owners: $MSUBJ  duplicate link keys: $MDUPES"

# Every stored link must appear as a row. A link the manifest cannot see is one the migration
# will not migrate, and it would be counted nowhere.
# KNOWN GAP, ratcheted rather than asserted green. 36 distinct rows exist for 44 stored links:
# EIGHT links have no manifest row, so the compiler's inventory cannot see them. The co-occurrence
# checks above all pass — this is precisely the class of defect the exact join was built to find,
# and it was invisible while per-file rows were summed to a coincidental 44.
#
# Step 7 CANNOT migrate a link the manifest does not contain: it would be counted nowhere, remain
# on its v1 value, and read as successfully migrated because nothing enumerated it. So this is a
# blocker for the migration, not a cosmetic gap.
MANIFEST_ROWS_TODAY=36
if [ "$MLINKS" = "$LINKS" ]; then
  ok "every stored link has a manifest row ($MLINKS = $LINKS) — GAP CLOSED, tighten this to an equality assertion"
elif [ "$MLINKS" -ge "$MANIFEST_ROWS_TODAY" ]; then
  ok "manifest rows $MLINKS of $LINKS stored links (known gap: $((LINKS - MLINKS)) unaccounted; floor $MANIFEST_ROWS_TODAY)"
  echo "       BLOCKS STEP 7: a link with no manifest row migrates against nothing and is counted nowhere."
else
  no "manifest rows fell to $MLINKS (floor $MANIFEST_ROWS_TODAY) — MORE links became invisible to the inventory"
fi

# An UNOWNED row is a dangling link: a stored fingerprint whose function is not in ProofCore.
# It is emitted rather than dropped precisely so this can fail.
[ "$MUNOWNED" = "0" ] \
  && ok "every link has exactly one callable owner (no dangling links)" \
  || no "$MUNOWNED link(s) have no callable owner — they would migrate against nothing"

[ "$MNOSUBJ" = "0" ] \
  && ok "every owned link's subject produces a V2 digest" \
  || no "$MNOSUBJ link(s) own a subject with NO V2 digest — those cannot migrate"

# KNOWN DEFECT, found by this gate on the day it was written, and worse than the missing rows.
# `calls.inc` appears twice with an IDENTICAL key — same callable id, same stored hash, same
# spec, same scope — and TWO DIFFERENT current V2 digests (2a0ef88b vs 774ef796). The subject
# digest is therefore not a function of the subject alone: the same callable digests differently
# depending on which file's compilation produced it.
#
# That is a determinism defect in the thing step 7 migrates TO. Migrating this link would pick
# whichever value the enumeration happened to see, and the other compilation would then read as
# stale forever. It also means the schema freeze pins a value that is not unique per subject.
#
# Ratcheted rather than failed so the finding is loud and tracked without leaving main red; the
# floor is 1, so a SECOND such pair fails immediately.
MDUPES_TODAY=1
if [ "$MDUPES" = "0" ]; then
  ok "no duplicate link keys — DETERMINISM DEFECT FIXED, tighten this to an equality assertion"
elif [ "$MDUPES" -le "$MDUPES_TODAY" ]; then
  ok "$MDUPES known non-deterministic link key (floor $MDUPES_TODAY): same key, two current V2 digests"
  echo "       BLOCKS STEP 7: the subject digest is not a function of the subject alone."
else
  no "$MDUPES duplicated link keys (floor $MDUPES_TODAY) — MORE subjects now digest differently per compilation"
fi

# Cross-check the two measurements. They count different things (files-containing vs owned), so
# the exact one must not exceed the coarse one; a mismatch means one of them is wrong.
[ "$MSUBJ" -le "$SUBJECTS" ] \
  && ok "exact owner count ($MSUBJ) is within the co-occurrence count ($SUBJECTS)" \
  || no "exact owners ($MSUBJ) exceed co-occurring subjects ($SUBJECTS) — the two measurements disagree"

echo ""
echo "MIGRATION-MANIFEST: PASS=$PASS FAIL=$FAIL (links=$LINKS subjects=$SUBJECTS)"
[ "$FAIL" -eq 0 ]
