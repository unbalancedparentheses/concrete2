#!/usr/bin/env bash
# R-0004 V2 probe, step 1 — V1 body fingerprints are FROZEN.
#
# The V2 body representation is built ALONGSIDE V1, never by modifying it: every
# stored `#[proof_fingerprint]` in the corpus was computed under V1, so a change
# to `bodyFingerprint` would report the whole corpus stale and invite the backfill
# that is forbidden until kernel replay issues a trustworthy receipt.
#
# "V1 is untouched" must therefore be CHECKED, not intended. This records a hash
# per extractable function and fails on any drift. It is the tripwire that has to
# exist before the migration starts changing things.
#
# The hash is `shasum -a 256` of the fingerprint string truncated to 32 hex — the
# same construction as `Concrete.shortHash`, so the golden also cross-validates
# the in-repo SHA-256 against the system one.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
[ -x ".lake/build/bin/concrete" ] || { echo "error: build first" >&2; exit 2; }
CC=".lake/build/bin/concrete"
GOLDEN="tests/golden/v1_body_fingerprints.txt"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

EXAMPLES="constant_time_tag crypto_verify elf_header parse_validate fixed_capacity hmac_sha256 thesis_demo loop_invariant"

emit() {
  for ex in $EXAMPLES; do
    src="examples/$ex/src/main.con"
    [ -f "$src" ] || continue
    # `qual(args)` line, then its `fingerprint:` line. awk pairs them so a
    # function with no fingerprint cannot silently borrow the previous one.
    "$CC" "$src" --report extraction 2>/dev/null | awk -v ex="$ex" '
      /^  [a-z_]+\.[a-zA-Z_0-9]+\(/ { name=$1; sub(/\(.*/, "", name); next }
      /^    fingerprint: / && name != "" {
        line=$0; sub(/^    fingerprint: /, "", line)
        print ex "\t" name "\t" line
        name=""
      }'
  done | while IFS=$'\t' read -r ex name fp; do
    h=$(printf '%s' "$fp" | shasum -a 256 | cut -c1-32)
    printf '%s\t%s\t%s\n' "$ex" "$name" "$h"
  done | LC_ALL=C sort
}

if [ "${1:-}" = "--update" ]; then
  mkdir -p "$(dirname "$GOLDEN")"
  emit > "$GOLDEN"
  echo "wrote $GOLDEN ($(wc -l < "$GOLDEN" | tr -d ' ') entries)"
  echo "NOTE: updating this golden means V1 CHANGED. That is the thing it exists to"
  echo "      prevent — only update it with a recorded reason."
  exit 0
fi

emit > "$TMP/current"
if [ ! -f "$GOLDEN" ]; then
  echo "V1-FINGERPRINT-GOLDEN: no golden at $GOLDEN — run with --update to create it" >&2
  exit 2
fi
n=$(wc -l < "$GOLDEN" | tr -d ' ')
if [ "$n" -lt 1 ]; then
  echo "V1-FINGERPRINT-GOLDEN: golden is EMPTY — a vacuous pass" >&2
  exit 1
fi
if diff -u "$GOLDEN" "$TMP/current" > "$TMP/diff" 2>&1; then
  echo "V1-FINGERPRINT-GOLDEN: $n fingerprints unchanged"
  exit 0
else
  echo "V1-FINGERPRINT-GOLDEN: V1 BODY FINGERPRINTS CHANGED" >&2
  echo "  Every stored #[proof_fingerprint] was computed under V1. A change here" >&2
  echo "  reports the corpus stale and invites a forbidden backfill. V2 must be" >&2
  echo "  built ALONGSIDE V1, not by modifying it." >&2
  head -30 "$TMP/diff" >&2
  exit 1
fi
