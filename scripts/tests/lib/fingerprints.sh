#!/usr/bin/env bash
# ONE definition of "a stored proof link", shared by every gate that counts them.
#
# Four different numbers for this denominator have been in circulation — 23, 44, 53, 67 — and
# every one came from a gate or a person writing their own regex over their own file set. Two
# gates that disagree about the denominator cannot both be right about the migration, and the
# disagreement is invisible until someone compares their outputs by hand.
#
# `check_v1_fingerprint_golden.sh` and `check_migration_manifest.sh` previously held the same
# pattern as separate text. Same text is not the same definition: either could be edited alone,
# and the gates would then silently measure different populations while both reporting a count.

# A stored link is an annotation carrying a hex VALUE. `#[proof_fingerprint(` with no value is
# not a stored subject — it is a link waiting to be pinned, which is a different state.
FP_PATTERN='#\[proof_fingerprint\("[a-f0-9]+"\)\]'

# Files under `examples/` containing at least one stored link.
fp_files() { grep -rlE "$FP_PATTERN" examples/ 2>/dev/null | sort -u; }

# Total stored links across those files.
fp_count() { grep -rhoE "$FP_PATTERN" examples/ 2>/dev/null | wc -l | tr -d ' '; }
