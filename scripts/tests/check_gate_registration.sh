#!/usr/bin/env bash
# EVERY GATE IS REACHABLE FROM CI, OR EXPLICITLY SKIPPED WITH A REASON.
#
# This exists because eight R-0004 gates — the replay producer, receipt issuance and consumption,
# the V2 migration plan, clean-checkout reproducibility, build identity, the Slice 8 adversarial
# suite, the attestation manifest — were written, passed when run by hand, and were absent from
# `.github/workflows/lean_action_ci.yml`. That file is where `run_ci_gates_local.sh` derives its
# gate list, so nothing ever ran them again: not on the next commit, not for anyone else. A fully
# green local pass certified the entire evidence path while executing none of it.
#
# ABSENCE IS QUIETER THAN FAILURE, which is the whole problem. A failing gate is loud and gets
# fixed. A gate nobody runs looks exactly like a gate that passes, and the pass count keeps rising
# while coverage does not. `check_snapshots.sh` sat outside CI long enough to accumulate eleven real
# drifts, visible only as another gate's one-line "snapshot gate failed"; `check_v1_fingerprint_golden.sh`
# was invoked only by the convergence inventory, which discarded its stderr and read the silence as
# "inconclusive".
#
# REACHABILITY IS TRANSITIVE, and it is computed as a real closure rather than assumed to be one or
# two hops. A gate invoked by `run_fast_surface_gates.sh` IS run by CI, because that aggregator is
# itself a workflow step. Demanding a direct entry for each would be noise — about a dozen gates are
# aggregated that way and are perfectly well covered.
#
# The first version of this gate walked ONE level and asserted in its own comment that one level was
# enough for the aggregators this repository has. It was not: `check_roadmap_linear.sh` is reached as
# workflow -> run_fast_surface_gates.sh -> check_docs_drift.sh -> it, and the gate reported a covered
# file as unreachable. A fixpoint costs a few lines and cannot be wrong about depth.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
WORKFLOW=".github/workflows/lean_action_ci.yml"
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

[ -f "$WORKFLOW" ] || { echo "FATAL: $WORKFLOW missing — reachability cannot be determined" >&2; exit 2; }

# DECLARED SKIPS. Each needs a reason, and the reason is checked for existence rather than for
# content — a skip with an empty justification is the thing this list exists to prevent.
declare -A SKIP=(
  ["check_gate_registration.sh"]="this gate; it is the registration rule itself"
)

# Seed the reachable set with everything the workflow names directly, then repeatedly add any script
# invoked by something already reachable, until nothing new appears.
REACHABLE_FILE="$(mktemp)"; trap 'rm -f "$REACHABLE_FILE"' EXIT
for f in scripts/tests/*.sh scripts/ci/*.sh scripts/gen/*.sh; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  grep -q "$b" "$WORKFLOW" && echo "$b" >> "$REACHABLE_FILE"
done
while :; do
  before="$(wc -l < "$REACHABLE_FILE")"
  while IFS= read -r seed; do
    [ -z "$seed" ] && continue
    src="$(ls scripts/tests/"$seed" scripts/ci/"$seed" scripts/gen/"$seed" 2>/dev/null | head -1)"
    [ -n "$src" ] || continue
    for f in scripts/tests/*.sh scripts/ci/*.sh scripts/gen/*.sh; do
      [ -f "$f" ] || continue
      cand="$(basename "$f")"
      [ "$cand" = "$seed" ] && continue
      if grep -q "$cand" "$src" 2>/dev/null && ! grep -qxF "$cand" "$REACHABLE_FILE"; then
        echo "$cand" >> "$REACHABLE_FILE"
      fi
    done
  done < <(sort -u "$REACHABLE_FILE")
  sort -u "$REACHABLE_FILE" -o "$REACHABLE_FILE"
  [ "$(wc -l < "$REACHABLE_FILE")" = "$before" ] && break
done

reachable() { grep -qxF "$1" "$REACHABLE_FILE"; }

echo "=== every gate is reachable from CI or explicitly skipped ==="
TOTAL=0; UNREACHABLE=""
for f in scripts/tests/check_*.sh scripts/ci/*.sh; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  TOTAL=$((TOTAL+1))
  if [ -n "${SKIP[$b]:-}" ]; then continue; fi
  reachable "$b" || UNREACHABLE="$UNREACHABLE $b"
done

# NON-VACUITY. If the enumeration found nothing, every assertion below is trivially satisfied and
# would read exactly like full coverage. The floor is deliberately far below the real count (211 at
# the time of writing) so it catches a broken glob rather than tracking the population.
if [ "$TOTAL" -ge 100 ]; then
  ok "enumerated $TOTAL gate scripts (floor 100 — a broken glob cannot pass as full coverage)"
else
  no "only $TOTAL gate scripts enumerated; the glob is broken and every check below is vacuous"
  echo "GATE-REGISTRATION: PASS=$PASS FAIL=$FAIL"; exit 1
fi

if [ -z "$UNREACHABLE" ]; then
  ok "every enumerated gate is reachable from $WORKFLOW, directly or through an aggregator"
else
  no "gate(s) unreachable from CI:$UNREACHABLE"
  echo "       A gate nobody runs is indistinguishable from one that does not exist. Add a workflow"
  echo "       step, or declare it in this gate's SKIP list with a reason."
fi

# THE SKIP LIST IS ALSO CHECKED, in both directions. A skip for a gate that no longer exists is
# stale and would silently excuse a future file of the same name; a skip with no reason is an
# exemption nobody has to justify.
for b in "${!SKIP[@]}"; do
  if [ ! -f "scripts/tests/$b" ] && [ ! -f "scripts/ci/$b" ]; then
    no "declared skip '$b' names a gate that does not exist — remove it before it excuses a future file"
  elif [ -z "${SKIP[$b]}" ]; then
    no "declared skip '$b' has no reason recorded"
  else
    ok "declared skip '$b' exists and states its reason"
  fi
done

# THE CONTROL. Without it, a `reachable()` that returned 0 unconditionally would satisfy everything
# above and report full coverage forever. A name that is certainly not in the workflow must come
# back unreachable.
if reachable "check_this_gate_does_not_exist_$$.sh"; then
  no "CONTROL FAILED: a non-existent gate reported as reachable — the check is inert and its pass proves nothing"
else
  ok "CONTROL: a gate absent from CI is correctly reported unreachable"
fi

echo "GATE-REGISTRATION: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
