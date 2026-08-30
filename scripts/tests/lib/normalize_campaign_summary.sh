#!/usr/bin/env bash
# NORMALISE A PUBLISHED CAMPAIGN ARTIFACT FOR COMPARISON AGAINST A GOLDEN BASELINE.
#
# The artifact is the campaign's authoritative record, and a golden baseline is how a schema change
# becomes visible instead of silent. But a few of its values cannot be equal across two runs of the
# same command: elapsed seconds, a run id built from a timestamp and a pid, the evidence directory
# derived from that id, and an evidence root that digests transcripts containing timestamps and
# temporary paths.
#
# So exactly those values are replaced by <VOLATILE>, and NOTHING ELSE IS TOUCHED. Every count, every
# disposition, every digest of stable content, the key set and its order are all compared byte for
# byte.
#
# THE VOLATILE LIST IS PART OF THE CONTRACT. Widening it is the obvious way to make a failing
# comparison pass, so it lives here in one place, is short enough to read, and changes to it show up
# in review as changes to this file rather than as a baseline that quietly started matching again.
# A key is on this list only because two runs of the SAME producer against the SAME commit cannot
# agree on it — not because it is inconvenient.
set -uo pipefail

VOLATILE_KEYS="secs_total secs_copy secs_build secs_gate secs_other run_id evidence_dir evidence_root"

usage() { echo "usage: normalize_campaign_summary.sh <artifact-path>" >&2; exit 2; }
[ $# -eq 1 ] || usage
[ -s "$1" ] || { echo "error: '$1' is missing or empty" >&2; exit 2; }

# A LINE THAT IS NOT AN ASSIGNMENT IS NOT NORMALISED AWAY. It is passed through unchanged, so a
# malformed artifact fails the comparison instead of being silently tidied into one that matches.
awk -v vol="$VOLATILE_KEYS" '
  BEGIN { n = split(vol, a, " "); for (i = 1; i <= n; i++) isvol[a[i]] = 1 }
  {
    if (match($0, /^[a-z_]+=/)) {
      key = substr($0, 1, RLENGTH - 1)
      if (key in isvol) { print key "=<VOLATILE>"; next }
    }
    print
  }
' "$1"
