#!/usr/bin/env bash
# Run every gate command the CI workflow runs, locally (ROADMAP #34a).
#
# The fast suite is NOT the CI gate set: golden baselines, proof gates, and
# per-feature check_*.sh gates run only in CI, and twice (2026-06, 2026-07)
# CI stayed red for 14-15 pushes while local fast-suite green was treated as
# done. This script extracts the gate commands FROM the workflow file itself
# (so the list cannot drift) and runs them sequentially, printing only
# failures. Run it before pushing anything that touches the compiler or the
# gates; a full pass takes a while (proof/oracle gates are slow) — that is
# still ~3x faster than one CI round-trip.
#
# Extraction contract: a workflow line invoking
#   [VAR=value ...] [bash|python3|sh] [./]scripts/....(sh|py) [args...]
# is a gate; the full argument list is preserved (fuzz seeds/counts,
# --trust-gate, the grammar path), as are VAR=value env prefixes.
# EXCLUDED on purpose: check_gate_mutation_coverage.sh — a nightly-only gate
# that mutates compiler source files to verify gate coverage; running it as
# a pre-push step would dirty the working tree it is meant to protect.
#
# Usage: scripts/tests/run_ci_gates_local.sh [filter-substring]
#        scripts/tests/run_ci_gates_local.sh --job "<CI job name substring>"
#
# `--job` selects every gate declared inside one CI JOB, instead of guessing at
# gate names. Filtering by name substring is itself a fact restated where it can
# drift: the workflow already says which gates belong to which job, and a
# name filter re-derives that by convention. `proof` selects 6 gates, but the
# "Proof evidence gate" job runs 40 — including `check_operational_vc_auto_discharge.sh`,
# whose NAME contains no "proof". R-0442 changed a Proof-layer API, the hook ran
# the 6, and the 40th broke a Lean fixture that only CI typechecks.

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
WORKFLOW=".github/workflows/lean_action_ci.yml"

# THE WHOLE PASS HOLDS ONE LOCK. Individual gates take it too, but only those that call
# `require_fresh_binary`; a grep-only gate does not, so without this a stray run could interleave
# between this runner's children. Acquiring it here also makes the runner itself refuse to start
# while anything else is working the tree — which is the failure that made an entire 187-gate pass
# reconnaissance-only rather than a verdict.
source "$ROOT_DIR/scripts/tests/lib/fresh.sh"
_gate_lock_acquire || exit 2
[ -x ".lake/build/bin/concrete" ] || { echo "error: build first" >&2; exit 2; }
FILTER="${1:-}"
JOB=""
if [ "$FILTER" = "--job" ]; then
  JOB="${2:-}"; FILTER=""
  [ -n "$JOB" ] || { echo "error: --job needs a CI job name substring" >&2; exit 2; }
fi

# The nightly fuzz steps derive SEED from the date in CI; the extracted fuzz
# commands reference "$SEED", which would trip `set -u` here. Mirror CI.
SEED="${SEED:-$(date -u +%Y%m%d)}"

# Gates are independent processes (each uses its own mktemp -d), so they
# parallelize cleanly, and PARALLEL IS THE DEFAULT: on a multicore box this cuts
# a full pass from ~20min to a few, and CI itself fans out (ten jobs all declare
# `needs: build`), so a sequential local pass is slower than the thing it is
# meant to pre-empt.
#
# What makes a parallel default safe is the sequential RE-RUN of any failure
# below: a contention flake self-corrects, so the verdict does not get noisier as
# JOBS rises. What it costs is interleaved output ordering — failures still print,
# but not in list order. `JOBS=1` restores sequential streaming when a run needs
# to be read live.
#
# The cap lives HERE and nowhere else. The pre-push hook used to compute its own
# `min(cores, 8)` and pass it in, which is the same fact stated in two places —
# the defect class this tree keeps paying for. The hook now just calls the script.
CORES="$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null) || echo 4 )"
# Leave two cores for the OS and the editor; cap at 8 because the heavy gates
# each spawn the compiler over many .con files and contention past that buys
# little while making flakes (and their re-runs) more likely.
# Captured BEFORE defaulting, so closure mode can tell "the operator asked for JOBS=4" from "nobody
# said anything and the default happens to be 4". Refusing the first and silently fixing the second
# is the correct pair of behaviours; without this they are indistinguishable.
JOBS_EXPLICIT=0
[ -n "${JOBS:-}" ] && JOBS_EXPLICIT=1
JOBS_DEFAULT=$(( CORES - 2 ))
[ "$JOBS_DEFAULT" -lt 1 ] && JOBS_DEFAULT=1
[ "$JOBS_DEFAULT" -gt 8 ] && JOBS_DEFAULT=8
JOBS="${JOBS:-$JOBS_DEFAULT}"

# ---------------------------------------------------------------------------
# CLOSURE MODE. `CONCRETE_CLOSURE_RUN=1` (or --closure) makes this run capable of producing a
# completion record. It forces JOBS=1 and refuses anything else.
#
# Why it must be explicit rather than the default: JOBS_DEFAULT is cores-2, so "run the complete gate
# set serially" ran four gates wide for 38 minutes and would have printed an ordinary-looking
# summary. The repository lock did not prevent it and could not — the lock serializes RUNS against
# each other and is deliberately re-entrant within a run, so this runner's own fan-out passes
# straight through it. Verifying that the lock refuses a second run is not verifying serialism.
#
# A parallel pass may still run and report. It simply cannot produce `completed=1`.
CLOSURE=0
[ "${CONCRETE_CLOSURE_RUN:-0}" = "1" ] && CLOSURE=1
if [ "$CLOSURE" = "1" ]; then
  # REFUSE rather than silently override: quietly ignoring an explicit JOBS= is its own defect, and
  # the operator would be told nothing about why their flag did not apply.
  if [ -n "${JOBS+x}" ] && [ "${JOBS_EXPLICIT:-0}" = "1" ] && [ "$JOBS" != "1" ]; then
    echo "error: closure mode requires JOBS=1, but JOBS=$JOBS was given explicitly." >&2
    echo "       Re-run without JOBS, or with JOBS=1." >&2
    exit 2
  fi
  JOBS=1
fi
export SEED

# When --job is given, narrow the workflow text to that job's block first, so
# the gate list comes from the same declaration CI uses.
SRC="$WORKFLOW"
if [ -n "$JOB" ]; then
  SRC="$(mktemp)"; trap 'rm -f "$SRC"' EXIT
  awk -v job="$JOB" '
    # job headers sit at two-space indent under `jobs:`; a name: line at that
    # depth starts a new job block.
    /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { inblock=0 }
    /^    name:/ { inblock = (index($0, job) > 0) }
    inblock { print }
  ' "$WORKFLOW" > "$SRC"
  if ! [ -s "$SRC" ]; then
    echo "error: no CI job matching '$JOB'" >&2; exit 2
  fi
fi

# Extract the gate command list once (same filter as before).
# Strip any trailing REDIRECTION from the extracted command. The character
# class stops at `&`, so a workflow line ending `... --trust-gate 2>&1 | tee
# /tmp/trust-gate.log` was captured as `... --trust-gate 2>` — a redirect with no
# target. `eval` then died of a parse error and the gate was counted FAIL, every
# run, on a clean tree. So the trust gate was never actually EXECUTED locally
# while appearing in the failure list: the loudest possible way to be silent.
# Output is discarded by the runner anyway, so redirections are noise here.
mapfile -t CMDS < <(grep -oE '([A-Z_][A-Z0-9_]*=[^ ;|&]+[[:space:]]+)*((bash|python3|sh)[[:space:]]+)?(\./)?scripts/[^ ;|&]*\.(sh|py)[^;|&]*' "$SRC" \
         | grep -v 'check_gate_mutation_coverage\.sh' \
         | sed 's/[[:space:]][0-9]*[<>].*$//' \
         | sed 's/[[:space:]]*$//' \
         | sort -u)

# Every extracted command must be SYNTACTICALLY VALID before anything is run. A
# truncated command otherwise reports as a failing gate, which reads as "the tree
# is red" rather than "the extractor is broken" — and those demand opposite
# responses. Checked up front so the whole list is trustworthy before a ~20min
# pass, not discovered gate by gate.
bad=0
for cmd in "${CMDS[@]}"; do
  if ! bash -n -c "$cmd" 2>/dev/null; then
    echo "error: extracted gate command is not valid shell: $cmd" >&2
    bad=1
  fi
done
if [ "$bad" -ne 0 ]; then
  echo "error: gate extraction produced unrunnable commands — fix the extractor," >&2
  echo "       not the gates. A truncated command cannot be told from a red gate." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# START-STATE CAPTURE for completion integrity.
#
# `completed=1` is a claim that this run measured the tree it says it measured. Nothing established
# that before: a run that mutated a source and died, or that ran while someone else edited, produced
# a summary indistinguishable from a clean one. Two contaminations in one day motivated this — a
# 38-minute parallel pass, and a SIGKILL that left Concrete/Elab/Elab.lean holding `declSpan := none`
# while the harness had already exited.
#
# Captured here and re-captured at the end. Any difference names a DIMENSION and suppresses
# completion; the refusal is diagnostic because "completed=0" with no reason is the same failure
# shape as a gate that dies silently.
snapshot_head()      { git rev-parse HEAD 2>/dev/null || echo "no-head"; }
snapshot_tracked()   { git status --porcelain --untracked-files=no 2>/dev/null | LC_ALL=C sort | cksum | cut -d' ' -f1; }
snapshot_untracked() { git status --porcelain --untracked-files=normal 2>/dev/null | grep '^??' | LC_ALL=C sort | cksum | cut -d' ' -f1; }
snapshot_gates()     { printf '%s\n' "${CMDS[@]}" | LC_ALL=C sort | cksum | cut -d' ' -f1; }
snapshot_compiler()  { grep -oE 'buildIdentity : String := "[0-9a-f]+"' Concrete/BuildIdentity.lean 2>/dev/null | grep -oE '[0-9a-f]{32}' | head -1 || echo "none"; }
# Mutation targets specifically: the files any registered mutation names. A leftover mutation is the
# one contamination that no trap can prevent, so it is checked by name rather than folded into the
# tracked-tree hash — the diagnosis "a mutation target was not restored" is far more actionable than
# "the tree changed".
snapshot_muttargets() {
  { grep -hoE '"(Concrete|Main)[A-Za-z0-9/._]*\.lean"' scripts/tests/test_mutation.sh \
      scripts/tests/check_gate_mutation_coverage.sh 2>/dev/null | tr -d '"' | LC_ALL=C sort -u; } \
    | while IFS= read -r f; do [ -f "$f" ] && { git diff --quiet -- "$f" 2>/dev/null || printf '%s ' "$f"; }; done
}
START_HEAD="$(snapshot_head)"
START_TRACKED="$(snapshot_tracked)"
START_UNTRACKED="$(snapshot_untracked)"
START_GATES="$(snapshot_gates)"
START_COMPILER="$(snapshot_compiler)"
START_MUT="$(snapshot_muttargets)"
RUN_INTERRUPTED=1
trap 'RUN_INTERRUPTED=1' INT TERM HUP

PASS=0; FAIL=0; FAILED=""

# A FAILING GATE'S OUTPUT IS KEPT. Discarding it means a failure in a 40-minute pass leaves nothing
# to diagnose but the gate's name — and a gate that passes standalone but fails inside the pass is
# then undiagnosable by construction, because reproducing it means re-running the whole thing. That
# happened to check_clean_checkout on the first closure-candidate run.
#
# Only FAILING gates are kept, so a green pass writes nothing: the point is a diagnosis when one is
# needed, not a transcript nobody reads.
FAILLOG_DIR="$ROOT_DIR/.ci-gate-failures"
rm -rf "$FAILLOG_DIR"; mkdir -p "$FAILLOG_DIR"
faillog_name(){ printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-80; }

if [ "$JOBS" -le 1 ]; then
  for cmd in "${CMDS[@]}"; do
    cmd="${cmd/bash .\//bash }"
    if [ -n "$FILTER" ] && [[ "$cmd" != *"$FILTER"* ]]; then continue; fi
    _out="$FAILLOG_DIR/$(faillog_name "$cmd").log"
    if eval "$cmd" >"$_out" 2>&1; then PASS=$((PASS+1)); rm -f "$_out"
    else FAIL=$((FAIL+1)); FAILED="$FAILED\n  FAIL $cmd"; echo "  FAIL $cmd (output: ${_out#$ROOT_DIR/})"; fi
  done
else
  # Parallel pool: each gate writes "OK"/"FAIL <cmd>" to its own result file.
  RES=$(mktemp -d); trap 'rm -rf "$RES"' EXIT
  idx=0
  for cmd in "${CMDS[@]}"; do
    cmd="${cmd/bash .\//bash }"
    if [ -n "$FILTER" ] && [[ "$cmd" != *"$FILTER"* ]]; then continue; fi
    # throttle to JOBS concurrent
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || true; done
    idx=$((idx+1))
    ( if eval "$cmd" >/dev/null 2>&1; then echo "OK" > "$RES/$idx"
      else echo "FAIL $cmd" > "$RES/$idx"; fi ) &
  done
  wait
  # The heavy gates spawn the compiler over many .con files; running JOBS of
  # them at once can OOM/CPU-starve and produce a spurious failure (a clean
  # tree then reads as red — the exact "crying wolf" that erodes trust in
  # this pre-push check). So a parallel FAIL is only a *candidate*: re-run it
  # once, sequentially and unthrottled, and believe that verdict. Genuine
  # failures still fail; contention flakes self-correct.
  RECHECKED=""
  for f in "$RES"/*; do
    [ -f "$f" ] || continue
    if grep -q '^OK$' "$f"; then PASS=$((PASS+1)); continue; fi
    cmd="$(sed 's/^FAIL //' "$f")"
    if eval "$cmd" >/dev/null 2>&1; then
      PASS=$((PASS+1)); RECHECKED="$RECHECKED\n  (contention flake, passed on sequential re-run) $cmd"
    else
      FAIL=$((FAIL+1)); FAILED="$FAILED\n  FAIL $cmd"; echo "  FAIL $cmd"
    fi
  done
  [ -n "$RECHECKED" ] && echo -e "Recovered under sequential re-run:$RECHECKED"
fi

RUN_INTERRUPTED=0

echo
echo "CI-GATES-LOCAL: PASS=$PASS FAIL=$FAIL (JOBS=$JOBS)"
[ -n "$FAILED" ] && echo -e "Failures:$FAILED"

# ---------------------------------------------------------------------------
# COMPLETION INTEGRITY. Each dimension that moved is NAMED, so a suppressed completion says which
# thing changed rather than only that something did.
REFUSALS=""
[ "$JOBS" = "1" ]                              || REFUSALS="$REFUSALS jobs_not_serial(jobs=$JOBS)"
[ "$(snapshot_head)"      = "$START_HEAD" ]      || REFUSALS="$REFUSALS head_changed($START_HEAD->$(snapshot_head))"
[ "$(snapshot_tracked)"   = "$START_TRACKED" ]   || REFUSALS="$REFUSALS tracked_tree_changed($START_TRACKED->$(snapshot_tracked))"
[ "$(snapshot_untracked)" = "$START_UNTRACKED" ] || REFUSALS="$REFUSALS untracked_tree_changed($START_UNTRACKED->$(snapshot_untracked))"
[ "$(snapshot_gates)"     = "$START_GATES" ]     || REFUSALS="$REFUSALS gate_inventory_changed($START_GATES->$(snapshot_gates))"
[ "$(snapshot_compiler)"  = "$START_COMPILER" ]  || REFUSALS="$REFUSALS compiler_identity_changed($START_COMPILER->$(snapshot_compiler))"
# MUTATION TARGETS ARE JUDGED CLEAN, NOT UNCHANGED — and the difference is the whole point.
# Comparing start against end asks "did a mutation appear during this run", which is silent about a
# mutation that was ALREADY THERE when the run began. That is exactly the state a SIGKILLed harness
# leaves behind, and the next run would then measure a mutated compiler and report a clean summary,
# because nothing changed while it watched. Verified by planting `declSpan := none` before a run:
# under the change-comparison it went undetected.
END_MUT="$(snapshot_muttargets)"
[ -z "$START_MUT" ] || REFUSALS="$REFUSALS mutation_target_dirty_at_start($START_MUT)"
[ -z "$END_MUT" ]   || REFUSALS="$REFUSALS mutation_target_not_restored($END_MUT)"
[ "$RUN_INTERRUPTED" = "0" ]                     || REFUSALS="$REFUSALS run_interrupted"

DISCOVERED="${#CMDS[@]}"
EXECUTED=$(( PASS + FAIL ))
[ "$DISCOVERED" = "$EXECUTED" ] || REFUSALS="$REFUSALS discovered_not_executed($DISCOVERED discovered, $EXECUTED executed)"

COMPLETED=0
if [ -z "$REFUSALS" ] && [ "$CLOSURE" = "1" ]; then COMPLETED=1; fi

{
  echo "completed=$COMPLETED"
  echo "mode=$([ "$CLOSURE" = 1 ] && echo closure || echo ordinary)"
  echo "jobs=$JOBS"
  echo "discovered=$DISCOVERED"
  echo "executed=$EXECUTED"
  echo "passed=$PASS"
  echo "failed=$FAIL"
  echo "head=$START_HEAD"
  echo "compiler_identity=$START_COMPILER"
  [ -n "$REFUSALS" ] && echo "refusals=$REFUSALS"
} > "$ROOT_DIR/.ci-gates-summary"

if [ -n "$REFUSALS" ]; then
  echo
  echo "COMPLETION REFUSED:$REFUSALS"
  echo "  This run's summary describes a tree that changed under it, or a run that was not serial."
  echo "  It is reconnaissance, not closure evidence."
elif [ "$CLOSURE" != "1" ]; then
  echo
  echo "NOT A CLOSURE RUN (mode=ordinary). Set CONCRETE_CLOSURE_RUN=1 to produce completed=1."
fi
echo "summary written to $ROOT_DIR/.ci-gates-summary (completed=$COMPLETED)"

[ "$FAIL" -eq 0 ] && [ -z "$REFUSALS" ]
