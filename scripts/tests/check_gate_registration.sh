#!/usr/bin/env bash
# EVERY GATE IS REACHABLE FROM CI, OR EXPLICITLY SKIPPED WITH A REASON.
#
# This exists because eight R-0004 gates — the replay producer, receipt issuance and consumption,
# the V2 migration plan, clean-checkout reproducibility, build identity, the Slice 8 adversarial
# suite, the attestation manifest — were written, passed when run by hand, and were absent from
# `.github/workflows/lean_action_ci.yml`. That file was where `run_ci_gates_local.sh` derived its
# gate list (it now reads scripts/tests/gates.tsv, which this gate keeps equal to the workflow's
# commands), so nothing ever ran them again: not on the next commit, not for anyone else. A fully
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
source "$(dirname "${BASH_SOURCE[0]}")/lib/gate_env.sh" || exit 2
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
WORKFLOW=".github/workflows/lean_action_ci.yml"
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

[ -f "$WORKFLOW" ] || { echo "FATAL: $WORKFLOW missing — reachability cannot be determined" >&2; exit 2; }

# THE MANIFEST IS THE LIST (scripts/tests/gates.tsv). Every gate script has a row there saying how CI
# reaches it (`via`); run_ci_gates_local.sh runs its via=step rows, and mk/gates.mk and the workflow's
# generated steps are derived from it. This gate checks the manifest is valid and its views fresh
# (gates.py --check: column vocabularies, unique ids and make targets, live spec keys, step rows naming
# a real job and step that runs them), that no check/test/run script lacks a row, that the workflow's
# gate commands are exactly the manifest's (below: the text extraction the local runner used to run
# on), and that each row's `via` matches what the reachability walk sees.
MANIFEST="scripts/tests/gates.tsv"
GATES_PY="scripts/gen/gates.py"
echo "=== the gate manifest is valid, lists every gate script, and its generated views are fresh ==="
if gp_out="$(python3 -I "$GATES_PY" --check 2>&1)"; then
  ok "$GATES_PY --check: $MANIFEST is valid, lists every gate script, and its views are current"
else
  no "$GATES_PY --check failed:"
  printf '       %s\n' "$gp_out" | head -40
fi

# DECLARED SKIPS come from the manifest: a row with via=skip:<reason>. Each needs a reason, and the
# reason is checked for existence rather than for content — a skip with an empty justification is the
# thing this list exists to prevent.
VIA_FILE="$(mktemp)"
if ! python3 -I "$GATES_PY" --list-via > "$VIA_FILE" 2>/dev/null || [ ! -s "$VIA_FILE" ]; then
  echo "FATAL: $GATES_PY --list-via produced nothing — the manifest cannot be read" >&2
  rm -f "$VIA_FILE"; exit 2
fi
declare -A SKIP=()
while IFS=$'\t' read -r vpath vvia; do
  case "$vvia" in skip:*) SKIP["$(basename "$vpath")"]="${vvia#skip:}" ;; esac
done < "$VIA_FILE"

# Seed the reachable set with everything the workflow names directly, then repeatedly add any script
# invoked by something already reachable, until nothing new appears.
REACHABLE_FILE="$(mktemp)"
# A MENTION IS NOT AN INVOCATION.
#
# Reachability was `grep -q "$b" "$file"`: the gate's NAME appearing anywhere counted, including in
# a comment. `check_classification_freshness.sh` was certified reachable solely because
# check_dependency_edges.sh contains the prose line "Table freshness lives in
# check_classification_freshness.sh, NOT here" — a sentence saying the gate runs somewhere else read
# as proof that it runs. Measured at 0df0d264: four gates had no non-comment reference anywhere,
# three of them were RED, and CI had never executed any while this gate reported full reachability.
#
# A reference counts only from a comment-stripped line carrying an execution context. The direction
# is deliberately CONSERVATIVE: a gate invoked in a form this cannot see is reported unreachable and
# must be registered or skipped explicitly, which demands clarity rather than granting a silent pass.
#
# A '#' is only a comment when it starts a word. Stripping every '#' destroyed the real invocation
# `nix develop .#provers --command bash ./scripts/tests/check_bv_certificates.sh`, whose flake
# selector contains one, and reported a registered gate as unreachable.
#
# ONE SCAN PER FILE, NOT ONE PER PAIR. Testing each (file, candidate) pair separately meant two
# processes for each of ~220x220 pairs per fixpoint round; the gate went from a second to being
# killed at five minutes. The adjacency is built once — each file scanned for every gate name in a
# single pass — and the fixpoint then walks it with no further subprocesses.
# scripts/tools/*.sh are containers too: checker_acceptance_evidence.sh is the only run of five gates
# (R-0546), so the edge from the workflow to those gates passes through it.
NAMES_FILE="$(mktemp)"; EDGES_FILE="$(mktemp)"
PLANT_DIR="$(mktemp -d)"
trap 'rm -f "$REACHABLE_FILE" "$NAMES_FILE" "$EDGES_FILE" "$VIA_FILE"; rm -rf "$PLANT_DIR"' EXIT
# A check_*.py in scripts/tests is a gate too (bug 252: the Markdown-link checker was one, reached only
# from the Makefile, and this enumeration of shell files never saw it).
for f in scripts/tests/*.sh scripts/ci/*.sh scripts/gen/*.sh scripts/tools/*.sh scripts/tests/check_*.py; do
  [ -f "$f" ] || continue; basename "$f"
done | sort -u > "$NAMES_FILE"

_exec_lines() { # path -> comment-stripped lines that INVOKE something
  # Two forms count, because this repository dispatches gates both ways.
  #
  #   1. a literal interpreter/exec/source/./ invocation;
  #   2. DATA-DRIVEN DISPATCH: a gate named as a quoted argument, which is how the mutation
  #      campaign runs the gate each family declares — `add "fam" "File.lean" "check_foo.sh"` — and
  #      how test_mutation.sh does it via `gate_for_last "scripts/tests/check_foo.sh"`. CI runs the
  #      full campaign (workflow step "Gate mutation coverage ... heavy; rebuilds per mutation"), so
  #      those gates genuinely execute in CI. Ignoring this form reported three registered gates as
  #      unreachable — a false alarm is as damaging here as a false pass, because it trains the
  #      reader to ignore the gate.
  #
  # Comments are stripped first, so the prose that caused the original defect — "Table freshness
  # lives in check_classification_freshness.sh, NOT here" — cannot satisfy either form.
  sed -E 's/(^|[[:space:]])#.*$/\1/' "$1" 2>/dev/null \
    | grep -E '(^|[[:space:];&|(=])(bash|sh|zsh|exec|source|python3|python|\./)([[:space:]]|/|$)|["'"'"'][^"'"'"']*check_[A-Za-z0-9_]+\.sh["'"'"']'
}

# edges: "<container> <invoked-gate>", container "" meaning the workflow itself
_exec_lines "$WORKFLOW" | grep -oFf "$NAMES_FILE" 2>/dev/null | sort -u \
  | while IFS= read -r n; do [ -n "$n" ] && echo "WORKFLOW $n"; done > "$EDGES_FILE"
# A script that sources scripts/tests/suite/ (run_tests.sh: each block's code units) runs what those
# unit files invoke, so their lines count as its own.
_exec_lines_with_units() {
  _exec_lines "$1"
  if _exec_lines "$1" | grep -E '(^|[[:space:];&|])(source|\.)[[:space:]].*scripts/tests/suite/' >/dev/null; then
    local u; for u in scripts/tests/suite/*.sh; do [ -f "$u" ] && _exec_lines "$u"; done
  fi
}
for f in scripts/tests/*.sh scripts/ci/*.sh scripts/gen/*.sh scripts/tools/*.sh; do
  [ -f "$f" ] || continue
  src="$(basename "$f")"
  _exec_lines_with_units "$f" | grep -oFf "$NAMES_FILE" 2>/dev/null | sort -u \
    | while IFS= read -r n; do
        [ -n "$n" ] && [ "$n" != "$src" ] && echo "$src $n"
      done >> "$EDGES_FILE"
done

# A MANIFEST STEP ROW IS A WORKFLOW EDGE. gates.py --check (above) parsed the YAML and confirmed that
# each via=step / via=ci-only row's step runs its cmd, which the text scan cannot always see: it does
# not count `./scripts/tests/run_tests.sh` (no interpreter word) or the fuzz_*.py drivers.
while IFS=$'\t' read -r vpath vvia; do
  case "$vvia" in step|ci-only:*) echo "WORKFLOW $(basename "$vpath")" ;; esac
done < "$VIA_FILE" >> "$EDGES_FILE"
awk '$1=="WORKFLOW"{print $2}' "$EDGES_FILE" | sort -u > "$REACHABLE_FILE"
while :; do
  before="$(wc -l < "$REACHABLE_FILE")"
  awk 'NR==FNR{r[$0]=1;next} ($1 in r){print $2}' "$REACHABLE_FILE" "$EDGES_FILE" \
    >> "$REACHABLE_FILE"
  sort -u "$REACHABLE_FILE" -o "$REACHABLE_FILE"
  [ "$(wc -l < "$REACHABLE_FILE")" = "$before" ] && break
done

reachable() { grep -qxF "$1" "$REACHABLE_FILE"; }

echo "=== every gate is reachable from CI or explicitly skipped ==="
TOTAL=0; UNREACHABLE=""
for f in scripts/tests/check_*.sh scripts/tests/check_*.py scripts/ci/*.sh; do
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
  echo "       step, or give it a via=skip:<reason> row in scripts/tests/gates.tsv."
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

echo "=== the workflow's gate commands are exactly the manifest's step rows ==="
# THE EXTRACTION, KEPT AS THE CROSS-CHECK. run_ci_gates_local.sh used to regex-extract its list from
# the workflow text; it now reads the manifest. This is that extractor, run against the whole
# workflow: every command it finds must be a via=step or via=ci-only row and every such row must be
# found, so a workflow step added without a row (which the local run would silently skip) or a row
# whose step was removed is a failure. Only the workflow's non-gate helpers are left out (the lake
# seeder under scripts/dev/ and the mutation-shard aggregator under scripts/tests/lib/); the CI-only
# gate runs are compared too, as via=ci-only rows, so a new mode of one cannot slip in unlisted.
#
# Strip any trailing REDIRECTION from the extracted command. The character class stops at `&`, so a
# workflow line ending `... --trust-gate 2>&1 | tee /tmp/trust-gate.log` was captured as
# `... --trust-gate 2>` — a redirect with no target, which the runner then failed to parse.
_extract_cmds() { # workflow text file -> gate commands, raw spelling, LC_ALL=C sorted unique
  grep -oE '([A-Z_][A-Z0-9_]*=[^ ;|&]+[[:space:]]+)*((bash|python3|sh)[[:space:]]+)?(\./)?scripts/[^ ;|&]*\.(sh|py)[^;|&]*' "$1" \
    | grep -v -E '(^|[[:space:]/])scripts/(dev|tests/lib)/' \
    | sed 's/[[:space:]][0-9]*[<>].*$//' \
    | sed 's/[[:space:]]*$//' \
    | LC_ALL=C sort -u
}
_manifest_step_cmds() { # manifest -> the cmd of every via=step and via=ci-only row, LC_ALL=C sorted unique
  awk -F'\t' '/^#/ || $1 == "id" { next } NF == 15 && ($5 == "step" || $5 ~ /^ci-only:/) { print $2 }' "$1" | LC_ALL=C sort -u
}
_wf_vs_manifest() { # workflow manifest -> diff lines (< workflow only, > manifest only); empty = agree
  diff <(_extract_cmds "$1") <(_manifest_step_cmds "$2") | grep -E '^[<>]' || true
}
wf_diff="$(_wf_vs_manifest "$WORKFLOW" "$MANIFEST")"
n_wf="$(_extract_cmds "$WORKFLOW" | grep -c . || true)"
if [ -z "$wf_diff" ] && [ "$n_wf" -ge 100 ]; then
  ok "the workflow's $n_wf extracted gate commands are exactly the manifest's via=step and via=ci-only rows"
else
  no "the workflow's gate commands ($n_wf) and the manifest's step/ci-only rows differ (< workflow only, > manifest only):"
  printf '       %s\n' "$wf_diff" | head -20
fi
printf '      - name: Planted\n        run: bash scripts/tests/check_planted_unlisted_step.sh\n' \
  | cat "$WORKFLOW" - > "$PLANT_DIR/wf.yml"
case "$(_wf_vs_manifest "$PLANT_DIR/wf.yml" "$MANIFEST")" in
  *"< bash scripts/tests/check_planted_unlisted_step.sh"*) ok "CONTROL: a workflow step whose command has no manifest row is reported" ;;
  *) no "CONTROL: a workflow step with no manifest row passed the cross-check — the local run would skip it silently" ;;
esac
printf '      - name: Planted\n        run: bash scripts/tests/check_gate_mutation_coverage.sh --planted-mode\n' \
  | cat "$WORKFLOW" - > "$PLANT_DIR/wf.yml"
case "$(_wf_vs_manifest "$PLANT_DIR/wf.yml" "$MANIFEST")" in
  *"< bash scripts/tests/check_gate_mutation_coverage.sh --planted-mode"*) ok "CONTROL: a new mode of a CI-only gate with no manifest row is reported" ;;
  *) no "CONTROL: an unlisted CI-only gate invocation passed the cross-check" ;;
esac
grep -vF 'run: bash scripts/tests/check_gate_lock.sh' "$WORKFLOW" > "$PLANT_DIR/wf.yml"
case "$(_wf_vs_manifest "$PLANT_DIR/wf.yml" "$MANIFEST")" in
  *"> bash scripts/tests/check_gate_lock.sh"*) ok "CONTROL: a manifest step row whose workflow step is gone is reported" ;;
  *) no "CONTROL: a step row with no workflow step passed the cross-check" ;;
esac

echo "=== each manifest row's via agrees with the reachability walk ==="
# step / ci-only: checked against the YAML by gates.py --check (the step exists and runs the cmd).
# agg:<s> / tool:<s>: <s> invokes it and CI reaches <s>. skip:<reason>: CI does NOT reach it — a
# skip that has become false is stale, and would hide the next time the gate silently drops out of CI.
_edge() { awk -v a="$1" -v b="$2" '$1==a && $2==b {f=1} END {exit !f}' "$EDGES_FILE"; }
_via_problems() { # via-list file ("<path>\t<via>") -> one line per disagreement
  local vpath vvia b agg
  while IFS=$'\t' read -r vpath vvia; do
    b="$(basename "$vpath")"
    case "$vvia" in
      step|ci-only:*) ;;
      agg:*|tool:*)
        agg="${vvia#*:}"
        if ! _edge "$agg" "$b"; then echo "$vpath: via=$vvia, but $agg does not invoke $b"
        elif ! reachable "$agg"; then echo "$vpath: via=$vvia, but CI does not reach $agg"; fi ;;
      skip:*)
        reachable "$b" && echo "$vpath: via=skip, but CI reaches $b — the skip is stale; record how CI runs it" ;;
      *) echo "$vpath: unknown via '$vvia'" ;;
    esac
  done < "$1"
}
via_bad="$(_via_problems "$VIA_FILE")"
if [ -z "$via_bad" ]; then
  ok "every row's via ($(grep -c . "$VIA_FILE") rows) matches the walk: steps invoked by the workflow, aggregated gates by their reached aggregator, skips unreached"
else
  no "manifest via disagrees with the reachability walk:"
  printf '       %s\n' "$via_bad"
fi
# CONTROLS: a stale skip (a gate CI runs, declared skipped), an aggregator that does not invoke the
# gate, and a step the workflow does not run must each be reported.
printf 'scripts/tests/check_gate_hygiene.sh\tskip:planted\n' > "$PLANT_DIR/via"
[ -n "$(_via_problems "$PLANT_DIR/via")" ] \
  && ok "CONTROL: a skip row for a gate CI reaches is reported stale" \
  || no "CONTROL: a stale skip row passed the via cross-check"
printf 'scripts/tests/check_gate_hygiene.sh\tagg:run_fast_surface_gates.sh\n' > "$PLANT_DIR/via"
[ -n "$(_via_problems "$PLANT_DIR/via")" ] \
  && ok "CONTROL: an agg row naming an aggregator that does not invoke the gate is reported" \
  || no "CONTROL: an agg row with the wrong aggregator passed the via cross-check"
printf 'scripts/tests/check_rocksdb_slice1.sh\tagg:check_gate_hygiene.sh\n' > "$PLANT_DIR/via"
[ -n "$(_via_problems "$PLANT_DIR/via")" ] \
  && ok "CONTROL: an agg row for a script nothing in CI invokes is reported" \
  || no "CONTROL: an agg row for an uninvoked script passed the via cross-check"

echo "=== negative controls: gates.py --check refuses each defect in a planted copy ==="
# A copy of the inputs gates.py reads, with scripts/tests a directory of links so a script can be
# planted without touching the tree. Each control mutates one thing and must be refused, naming it.
_plant() {
  rm -rf "$PLANT_DIR/r"; mkdir -p "$PLANT_DIR/r/scripts/tests" "$PLANT_DIR/r/.github/workflows" \
    "$PLANT_DIR/r/.githooks" "$PLANT_DIR/r/docs/spec" "$PLANT_DIR/r/docs/bugs"
  local f
  for f in scripts/tests/*; do ln -s "$ROOT_DIR/$f" "$PLANT_DIR/r/$f"; done
  rm -f "$PLANT_DIR/r/$MANIFEST"
  cp "$MANIFEST" "$PLANT_DIR/r/$MANIFEST"
  mkdir -p "$PLANT_DIR/r/mk"; cp Makefile "$PLANT_DIR/r/Makefile"; cp mk/gates.mk "$PLANT_DIR/r/mk/gates.mk"
  for f in scripts/ci scripts/tools scripts/gen; do ln -s "$ROOT_DIR/$f" "$PLANT_DIR/r/$f"; done
  cp "$WORKFLOW" "$PLANT_DIR/r/$WORKFLOW"
  cp .githooks/pre-push "$PLANT_DIR/r/.githooks/pre-push"
  ln -s "$ROOT_DIR/docs/spec/ids.tsv" "$PLANT_DIR/r/docs/spec/ids.tsv"
  ln -s "$ROOT_DIR/docs/bugs/area_map.tsv" "$PLANT_DIR/r/docs/bugs/area_map.tsv"
}
_gp() { python3 -I "$GATES_PY" --check --root "$PLANT_DIR/r" > "$PLANT_DIR/out" 2>&1; }
# _mut <awk program over the manifest's data rows>: rewrite the planted manifest in place.
_mut() {
  awk -F'\t' -v OFS='\t' "/^#/ || /^id\t/ {print; next} $1" "$PLANT_DIR/r/$MANIFEST" > "$PLANT_DIR/m" \
    && mv "$PLANT_DIR/m" "$PLANT_DIR/r/$MANIFEST"
}
# _refused <label> <text the refusal must contain>
_refused() {
  local rc=$?
  if [ "$rc" = 1 ] && grep -qF -- "$2" "$PLANT_DIR/out"; then ok "CONTROL: $1 is refused"
  else no "CONTROL: $1 was not refused (rc=$rc; expected exit 1 naming '$2')"; sed 's/^/       /' "$PLANT_DIR/out" | head -5; fi
}
_plant
if _gp; then ok "CONTROL BASE: the unmodified planted copy passes, so each refusal below is the mutation's"
else no "CONTROL BASE: the unmodified planted copy fails — every control below is meaningless"; sed 's/^/       /' "$PLANT_DIR/out" | head -5; fi
_plant; printf '#!/usr/bin/env bash\nexit 0\n' > "$PLANT_DIR/r/scripts/tests/check_planted_unlisted.sh"
_gp; _refused "a planted check_ script with no manifest row" "check_planted_unlisted.sh has no row"
_plant; printf '#!/usr/bin/env bash\nexit 0\n' > "$PLANT_DIR/r/scripts/tests/test_planted_unlisted.sh"
_gp; _refused "a planted test_ script with no manifest row" "test_planted_unlisted.sh has no row"
_plant; _mut '{print} END {print}'
_gp; _refused "a duplicate id (the last row twice)" "duplicate id"
_plant; _mut '$1=="check-gate-hygiene" {$11="test-ssa"} {print}'
_gp; _refused "a make target on two rows" "make target 'test-ssa' is also on line"
_plant; _mut '$1=="check-gate-hygiene" {$9="sometimes"} {print}'
_gp; _refused "a tier outside the vocabulary" "tier 'sometimes' is not one of"
_plant; _mut '$1=="check-gate-hygiene" {$6="Backend"} {print}'
_gp; _refused "an area outside area_map.tsv's stages" "area 'Backend' is not a stage"
_plant; _mut '$1=="check-gate-hygiene" {$10="NOT-A-KEY@9"} {print}'
_gp; _refused "a spec key that is not live in ids.tsv" "spec key 'NOT-A-KEY@9' is not live"
_plant; _mut '$1=="check-gate-hygiene" {$5="sometimes"} {print}'
_gp; _refused "a via outside the vocabulary" "via 'sometimes' is not"
_plant; _mut '$1=="check-totality-ratchet" {$4="No such step"} {print}'
_gp; _refused "a hand-written step row naming a step its job does not have" "has no step named 'No such step'"
_plant; sed 's|bash ./scripts/tests/test_ssa.sh|bash ./scripts/tests/test_ssa.sh --planted|' mk/gates.mk > "$PLANT_DIR/r/mk/gates.mk"
_gp; _refused "a hand-edited recipe in the generated mk/gates.mk" "mk/gates.mk is stale"
_plant; printf '\ntest-ssa: build ## planted\n\t@true\n' >> "$PLANT_DIR/r/Makefile"
_gp; _refused "a manifest make target also written by hand in the Makefile" "test-ssa is also written by hand"
_plant; grep -vx 'include mk/gates.mk' Makefile > "$PLANT_DIR/r/Makefile"
_gp; _refused "a Makefile that no longer includes mk/gates.mk" "does not have the line 'include mk/gates.mk'"
_plant; _mut '$1=="test-ssa" {$2="./scripts/tests/test_ssa.sh"} {print}'
_gp; _refused "a make row whose cmd has no interpreter (no recipe can be generated)" "so no recipe is generated"
_plant; sed 's|^\( *run: \)bash scripts/tests/check_totality_ratchet.sh$|\1true # bash scripts/tests/check_totality_ratchet.sh|' "$WORKFLOW" > "$PLANT_DIR/r/$WORKFLOW"
_gp; _refused "a hand-written step row whose command the workflow names only in a comment" "does not run 'bash scripts/tests/check_totality_ratchet.sh'"
_plant; sed 's|^SEL+=(--first "bash scripts/tests/check_gate_hygiene.sh")$|  &|' .githooks/pre-push > "$PLANT_DIR/r/.githooks/pre-push"
_gp; _refused "a prepush row whose hook line is no longer unconditional (indented)" "has no unconditional line"
_plant; _mut '$1=="check-totality-ratchet" {$2=$2" --planted"} {print}'
_gp; _refused "a hand-written step row whose cmd is not what its step runs" "does not run 'bash scripts/tests/check_totality_ratchet.sh --planted'"
# Generated workflow blocks: a hand edit inside one is stale, and a gen=y row no block reaches is refused.
_plant; sed 's|^\(      - name: \)Gate lock (a lock is refused|\1Gate lock EDITED (a lock is refused|' "$WORKFLOW" > "$PLANT_DIR/r/$WORKFLOW"
_gp; _refused "a hand edit inside a generated workflow block" "lean_action_ci.yml is stale"
_plant; _mut '$1=="check-multi-kernel" {$14="y"} {print}'
_gp; _refused "a gen=y row that no generated block of its job reaches" "no generated block of job multi-kernel reaches it"
_plant; _mut '$1=="check-gate-lock" {$2=$2" && true"} {print}'
_gp; _refused "a gen=y row whose cmd is more than one command" "is not one plain command"
echo "=== a CI gate the host cannot run is a named skip in run_ci_gates_local.sh, never a pass ==="
# The Examples job runs check_example_outputs.sh under EXAMPLE_VALGRIND=1; macOS has no valgrind.
# run_ci_gates_local.sh classifies such commands with scripts/tests/lib/host_tools.sh, lists them
# as SKIP, and keeps the run PARTIAL with completed=0 (host_tool_missing). These legs check the
# classifier on controlled PATHs, that the table matches the workflow, and that the runner wires it.
HT_LIB="scripts/tests/lib/host_tools.sh"
if ! source "$HT_LIB" 2>/dev/null || ! command -v host_tool_missing >/dev/null 2>&1; then
  no "$HT_LIB does not load — the runner would refuse every run"
else
  vg_cmd="EXAMPLE_VALGRIND=1 bash ./scripts/tests/check_example_outputs.sh"
  ht_empty="$(mktemp -d)"; ht_stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 0\n' > "$ht_stub/valgrind"; chmod +x "$ht_stub/valgrind"
  got="$(PATH="$ht_empty" host_tool_missing "$vg_cmd")"; rc=$?
  { [ "$rc" = 0 ] && [ "$got" = "valgrind" ]; } \
    && ok "CONTROL: without valgrind on PATH the valgrind run is classified host-skipped (valgrind)" \
    || no "CONTROL: without valgrind the valgrind run was not classified missing (rc=$rc, got '$got') — the runner would run it and report a misleading FAIL"
  PATH="$ht_stub" host_tool_missing "$vg_cmd" >/dev/null \
    && no "CONTROL: with valgrind on PATH the command was still skipped — CI-capable hosts would never run it" \
    || ok "CONTROL: with valgrind on PATH the valgrind run is runnable"
  PATH="$ht_empty" host_tool_missing "bash ./scripts/tests/check_example_outputs.sh" >/dev/null \
    && no "CONTROL: a command needing no host tool was classified missing" \
    || ok "CONTROL: the plain command needs no host tool"
  # elan is asked the way check_external_checker.sh asks: an executable $ELAN_HOME/bin/lake, on PATH
  # or not. The gate host keeps elan off its ssh PATH, and a PATH probe skipped a gate it could run.
  ec_cmd="bash scripts/tests/check_external_checker.sh"
  mkdir -p "$ht_stub/elan/bin"; printf '#!/bin/sh\nexit 0\n' > "$ht_stub/elan/bin/lake"; chmod +x "$ht_stub/elan/bin/lake"
  got="$(PATH="$ht_empty" ELAN_HOME="$ht_empty" host_tool_missing "$ec_cmd")"; rc=$?
  { [ "$rc" = 0 ] && [ "$got" = "elan" ]; } \
    && ok "CONTROL: without \$ELAN_HOME/bin/lake the external-checker gate is classified host-skipped (elan)" \
    || no "CONTROL: without \$ELAN_HOME/bin/lake the external-checker gate was not classified missing (rc=$rc, got '$got')"
  PATH="$ht_empty" ELAN_HOME="$ht_stub/elan" host_tool_missing "$ec_cmd" >/dev/null \
    && no "CONTROL: an elan lake at \$ELAN_HOME (not on PATH) still skipped the external-checker gate" \
    || ok "CONTROL: an elan lake at \$ELAN_HOME runs the external-checker gate, PATH notwithstanding"
  rm -rf "$ht_empty" "$ht_stub"
  # The table must match the workflow: every row names something CI actually runs (a dead row is a
  # stale exemption), and the valgrind spelling CI uses is covered.
  plan="$(bash scripts/tests/run_ci_gates_local.sh --plan 2>/dev/null)"
  for row in "${HOST_TOOL_TABLE[@]}"; do
    pat="${row%%|*}"
    case "$plan" in
      *"$pat"*) ok "host-tool row '${row}' matches a workflow command" ;;
      *) no "host-tool row '${row}' matches no workflow command — remove it or fix the spelling" ;;
    esac
  done
  if grep -q 'EXAMPLE_VALGRIND=1' <<<"$plan"; then
    vg_plan="$(grep 'EXAMPLE_VALGRIND=1' <<<"$plan" | head -1)"
    [ "$(host_tool_required "$vg_plan")" = "valgrind" ] \
      && ok "the workflow's valgrind command requires valgrind per the table" \
      || no "the workflow's valgrind command ($vg_plan) is not covered by $HT_LIB"
  else
    no "no EXAMPLE_VALGRIND=1 command in the workflow plan — update $HT_LIB and these legs together"
  fi
  # The runner must use the classifier and let the skip block completion (comments stripped, so a
  # mention in prose does not count).
  runner_code="$(sed -E 's/(^|[[:space:]])#.*$/\1/' scripts/tests/run_ci_gates_local.sh)"
  case "$runner_code" in *'lib/host_tools.sh'*host_tool_missing*) ok "run_ci_gates_local.sh classifies commands with the shared host-tool table" ;;
    *) no "run_ci_gates_local.sh does not use $HT_LIB" ;; esac
  case "$runner_code" in *'ALL_REFUSALS="$REFUSALS$SCOPE_NOTES$MODE_NOTES$HOST_NOTES"'*) ok "a host skip is part of the completion-blocking notes (PARTIAL, completed=0)" ;;
    *) no "HOST_NOTES is not in ALL_REFUSALS — a host-skipped run could be recorded completed=1" ;; esac

  echo "=== a verdict deferred to CI is declared, judged on CI, and never a pass (bug 315) ==="
  # host_tools.sh's HOST_DEFERRED_TABLE names the gates whose exit GATE_DEFERRED_RC the runner records
  # as deferred. Each must be a gate CI runs unconditionally (else nothing judges it), with a known
  # judged_on, and must itself use that exit status.
  if [ "${#HOST_DEFERRED_TABLE[@]}" -eq 0 ] || ! command -v gate_deferral >/dev/null 2>&1; then
    no "$HT_LIB declares no deferral table or no gate_deferral — the runner could not accept a deferral"
  else
    for row in "${HOST_DEFERRED_TABLE[@]}"; do
      name="${row%%|*}"; on="${row#*|}"
      case "$on" in ci-counted) ok "deferral row '$row' has a known judged_on ($on)" ;;
        *) no "deferral row '$row': judged_on '$on' is not one this file defines" ;; esac
      if why="$(gate_deferral "bash scripts/tests/$name")"; then
        ok "deferral row '$row': CI runs $name as an unconditional step, so the deferred verdict is made there"
      else
        no "deferral row '$row': $why"
      fi
    done
    # The scaling gate's own exit for "not judged here" is the runner's deferral status.
    grep -qx "NOT_JUDGED_RC = $GATE_DEFERRED_RC" scripts/tests/lib/compile_scaling.py \
      && ok "compile_scaling.py exits $GATE_DEFERRED_RC (GATE_DEFERRED_RC) when it did not judge" \
      || no "compile_scaling.py's NOT_JUDGED_RC is not GATE_DEFERRED_RC ($GATE_DEFERRED_RC)"
    # CONTROLS: an undeclared gate, and a declared gate whose CI step is conditional, are refused.
    gate_deferral "bash scripts/tests/check_this_gate_does_not_exist_$$.sh" >/dev/null \
      && no "CONTROL: gate_deferral accepted an undeclared gate — every exit 77 would read as deferred" \
      || ok "CONTROL: gate_deferral refuses an undeclared gate"
    df_gate="scripts/tests/${HOST_DEFERRED_TABLE[0]%%|*}"
    gate_deferral "bash ./$df_gate" >/dev/null && gate_deferral "bash $df_gate --shape x" >/dev/null \
      && ok "gate_deferral accepts the declared gate as ./path and with plain arguments" \
      || no "gate_deferral refused a plain invocation of the declared gate"
    for df_cmd in "bash scripts/tests/check_gate_lock.sh $df_gate" "bash $df_gate; bash scripts/tests/check_x.sh" \
                  "bash $df_gate || true" "bash $df_gate | tee x" "bash $df_gate \$(echo x)" \
                  "X=x;(exit\${IFS}77);# bash $df_gate" $'true\nbash '"$df_gate" "X=\$(false) bash $df_gate" \
                  "BASH_ENV=defer.sh bash $df_gate" "ENV=defer.sh sh $df_gate" "FOO=1 bash $df_gate"; do
      gate_deferral "$df_cmd" >/dev/null \
        && no "CONTROL: gate_deferral accepted '$df_cmd', which is not the declared gate's own exit" \
        || ok "CONTROL: gate_deferral refuses '$df_cmd' (the gate as an argument, or in a compound command)"
    done
    df_wf="$(mktemp)"
    printf 'jobs:\n  j:\n    runs-on: x\n    steps:\n      - if: false\n        run: bash scripts/tests/%s\n' \
      "${HOST_DEFERRED_TABLE[0]%%|*}" > "$df_wf"
    gate_deferral "bash scripts/tests/${HOST_DEFERRED_TABLE[0]%%|*}" "$df_wf" >/dev/null \
      && no "CONTROL: a declared gate whose only CI step is conditional was accepted as deferred" \
      || ok "CONTROL: a declared gate whose CI step is conditional cannot defer (nothing would judge it)"
    rm -f "$df_wf"
  fi
  case "$runner_code" in *gate_deferral*GATE_DEFERRED_RC*gate_deferral*) ok "run_ci_gates_local.sh classifies exit GATE_DEFERRED_RC with gate_deferral (sequential and pool)" ;;
    *) no "run_ci_gates_local.sh does not classify GATE_DEFERRED_RC with gate_deferral in both paths" ;; esac
  case "$runner_code" in *'HOST_NOTES="$HOST_NOTES$DEFER_NOTES"'*) ok "a deferral is part of the completion-blocking notes (PARTIAL, completed=0)" ;;
    *) no "DEFER_NOTES is not in HOST_NOTES — a deferred run could be recorded completed=1" ;; esac
  case "$runner_code" in *'EXECUTED=$(( PASS + FAIL + DEFERRED ))'*) ok "a deferral counts as executed, not passed" ;;
    *) no "EXECUTED does not count deferrals apart from passes" ;; esac
fi

echo "GATE-REGISTRATION: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
