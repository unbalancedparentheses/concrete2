#!/usr/bin/env bash
# The dead-code ratchet: the compiler does not grow declarations nothing can reach, and the known
# ones only get fewer (cleanup item 15).
#
# A declaration no executable, theorem, proof or tool reaches is code nobody runs and nobody
# proves anything about: it still has to build, be read, be kept total, and be migrated by every
# refactor. This gate holds the set where it is and lets it only shrink:
#
#   1. scripts/tools/dead_code_inventory.lean walks the ELABORATED environment (macro, `deriving`,
#      `match` and `partial` auxiliaries are references a grep cannot see) and computes what is
#      reachable from the roots: the executables' `main`, every user theorem, everything the
#      proof libraries (Examples, DesignExamples) declare, @[export]/@[extern]/initialize/simp/
#      syntax declarations, instances whose types are live, the generated data modules, the
#      identifiers of `#guard`/`#eval`/`example` commands and of the Lean files outside the
#      libraries (scripts/tools/dead_code_ratchet.py roots), and the string-referenced allowlist
#      docs/compiler/dead_code_allowlist.tsv;
#   2. scripts/tools/dead_code_ratchet.py compares the unreachable ones with
#      docs/compiler/dead_code_baseline.tsv, and that baseline with the base revision's:
#      an unreachable declaration not in the baseline FAILS; a baseline row that is reachable or
#      gone FAILS until deleted; a row the base revision's baseline lacks FAILS (the baseline only
#      shrinks); an allowlist row that is not needed (reachable without it), names nothing, or whose
#      file does not mention the name FAILS.
#
# Controls, each must hold or the gate fails:
#   C1  the finder on a known source (--control): exactly the expected reachability, so a planted
#       unused def and its only caller, a dead structure and inductive with their derived
#       instances are unreachable; a def used only by a theorem, only through an equation lemma,
#       only from a `partial def`'s body, only through a `where` helper, only from a `#guard`, or
#       only through the allowlist is reachable;
#   C2  a planted NEW unreachable declaration fails the comparison;
#   C3  a baseline row whose declaration is reachable fails; C4 one whose declaration is gone fails;
#   C5  a baseline row the base revision did not have fails;
#   C6  an allowlist row for a declaration reachable without it fails;
#   C7  an allowlist row whose file does not mention the name fails;
#   C8  two declarations that normalize to one name, one of them unreachable, fail instead of
#       merging (all reachable is harmless: generated and macro-scoped names repeat).
# And the walk is not vacuous: every compiler module that declares anything contributed.
#
# Requires the compiler and proof libraries built (it runs `lake build` first, a no-op when current).
# Usage: scripts/tests/check_dead_code_ratchet.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/gate_env.sh" || exit 2
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TOOL="scripts/tools/dead_code_inventory.lean"
RATCHET="scripts/tools/dead_code_ratchet.py"
# Generated data modules (scripts/gen): roots, since nobody writes their references by hand.
GENERATED=(Concrete.BuildIdentity Concrete.Proof.ClassificationTable Concrete.Proof.GeneratedAttestations)

# Browser.lean (concrete-browser-native) does not build (`Unknown identifier Pipeline.desugar`,
# see check_totality_ratchet.sh), so it cannot be imported: its identifiers enter as text roots.
mapfile -t SRCS < <(git ls-files 'Concrete.lean' 'Concrete/*.lean' 'Main.lean')
MODS=(); for f in "${SRCS[@]}"; do m="${f%.lean}"; MODS+=("${m//\//.}"); done
[ "${#MODS[@]}" -gt 0 ] || { echo "FAIL: no compiler modules found"; exit 1; }

echo "=== build the compiler and the proof libraries (the inventory reads their .olean files) ==="
if lake build "${MODS[@]}" Examples DesignExamples > "$TMP/build.log" 2>&1; then ok "${#MODS[@]} modules and the proof libraries built"
else tail -20 "$TMP/build.log"; no "lake build failed"; echo "DEAD-CODE-RATCHET: PASS=$PASS FAIL=$FAIL"; exit 1; fi

echo "=== C1: the finder sees what it must on a known source ==="
lake env lean --run "$TOOL" --control > "$TMP/control.tsv" 2> "$TMP/control.err"
grep '	' "$TMP/control.tsv" | cut -f1,5,6 | LC_ALL=C sort > "$TMP/control.got"
LC_ALL=C sort > "$TMP/control.want" <<'EOF'
DeadS	0	0
DeadT	0	0
LiveS	1	1
allowOnly	0	1
deadCaller	0	0
deadLeaf	0	0
guardOnly	1	1
instBEqDeadS	0	0
instDecidableEqDeadT	0	0
instReprDeadS	0	0
instReprLiveS	1	1
liveLeaf	1	1
main	1	1
onlyEqLemma	1	1
partialLive	1	1
partialLive.twinOnly	1	1
readsField	1	1
usedByAllow	0	1
usedByTheorem	1	1
EOF
if cmp -s "$TMP/control.got" "$TMP/control.want"; then
  ok "control source: unused def/caller/structure/inductive/instances unreachable; theorem/eq-lemma/partial/where/#guard/allowlist uses reachable"
else
  no "the finder's control output changed (< want, > got):"; diff "$TMP/control.want" "$TMP/control.got" | head -20
  head -5 "$TMP/control.err"
fi

echo "=== the compiler's reachability against the baseline ==="
python3 "$RATCHET" roots > "$TMP/roots.txt" || no "could not extract the text roots"
python3 "$RATCHET" allow-names > "$TMP/allow.txt" || no "could not read the allowlist"
ARGS=(--roots "$TMP/roots.txt" --allow "$TMP/allow.txt")
for g in "${GENERATED[@]}"; do ARGS+=(--root-module "$g"); done
# TWO WALKS. Main and Concrete.Pipeline.PipelineTest both declare `main`, so one environment cannot
# import them together. The second walk imports PipelineTest alone; a declaration is reachable when
# either walk reaches it (dead_code_ratchet.py merges them).
SEPARATE="Concrete.Pipeline.PipelineTest"
MAIN_MODS=(); for m in "${MODS[@]}"; do [ "$m" = "$SEPARATE" ] || MAIN_MODS+=("$m"); done
inventory_failed() { head -5 "$1"; no "the inventory tool failed"; echo "DEAD-CODE-RATCHET: PASS=$PASS FAIL=$FAIL"; exit 1; }
lake env lean --run "$TOOL" "${ARGS[@]}" "${MAIN_MODS[@]}" Examples DesignExamples > "$TMP/w1.tsv" 2> "$TMP/w1.err" || inventory_failed "$TMP/w1.err"
lake env lean --run "$TOOL" "${ARGS[@]}" "$SEPARATE" > "$TMP/w2.tsv" 2> "$TMP/w2.err" || inventory_failed "$TMP/w2.err"
WALKS=(--walk "$TMP/w1.tsv" --walk "$TMP/w2.tsv")
missing=""
for i in "${!MODS[@]}"; do
  grep -qE '^(private |protected |noncomputable |partial |unsafe |@\[[^]]*\] )*(def|theorem|structure|inductive|abbrev|instance|class|opaque|axiom) ' "${SRCS[$i]}" || continue
  grep -qxF -- "$(printf 'visited\t%s' "${MODS[$i]}")" <(cut -f1,2 "$TMP/w1.err" "$TMP/w2.err") || missing="$missing ${MODS[$i]}"
done
[ -z "$missing" ] && ok "the walk saw declarations from every declaring module (${#MODS[@]} asked for)" \
  || no "modules that declare things contributed nothing to the walk:$missing"

# THE BASELINE ONLY SHRINKS, against the base revision (the same rule as check_totality_ratchet.sh):
#   DEAD_CODE_BASE  set by CI on a push to the revision before the push (github.event.before); an
#                   all-zero value (a new ref) falls back to the merge-base.
#   no base given   merge-base(HEAD, origin/main); HEAD~1 when HEAD is already on origin/main;
#                   FAIL without origin/main rather than guess.
BASE="${DEAD_CODE_BASE:-}"
case "$BASE" in *[!0]*) ;; *) BASE="" ;; esac
BASE_ERR=""
if [ -z "$BASE" ]; then
  MB="$(git merge-base HEAD origin/main 2>/dev/null || true)"
  if [ -z "$MB" ]; then BASE_ERR="no merge-base with origin/main (fetch it, or set DEAD_CODE_BASE)"
  elif [ "$MB" != "$(git rev-parse HEAD)" ]; then BASE="$MB"
  else BASE="HEAD~1"; fi
fi
BASE_ARGS=()
if [ -n "$BASE_ERR" ]; then
  no "$BASE_ERR"
elif ! git rev-parse --verify -q "$BASE^{commit}" >/dev/null; then
  no "base revision '$BASE' does not resolve: fetch history (CI: fetch-depth 0) or set DEAD_CODE_BASE"
elif git show "$BASE:docs/compiler/dead_code_baseline.tsv" > "$TMP/base_baseline.tsv" 2>/dev/null; then
  BASE_ARGS=(--base-baseline "$TMP/base_baseline.tsv")
  ok "comparing the baseline with the base revision $(git rev-parse --short "$BASE")"
else
  ok "the base revision $(git rev-parse --short "$BASE") has no baseline: this change introduces it"
fi

if python3 "$RATCHET" check "${WALKS[@]}" "${BASE_ARGS[@]}" > "$TMP/check.out"; then
  ok "$(tail -1 "$TMP/check.out")"
else
  cat "$TMP/check.out"; no "the dead-code ratchet found the findings above"
fi

# A planted input must make the comparison fail with the named finding.
expect_fail() {  # $1 = label, $2 = substring the finding must contain, rest = extra check args
  local label="$1" want="$2"; shift 2
  if python3 "$RATCHET" check "$@" > "$TMP/neg.out" 2>&1; then
    no "$label: the ratchet accepted it"
  elif grep -qF -- "$want" "$TMP/neg.out"; then ok "$label"
  else no "$label: failed, but without '$want'"; head -5 "$TMP/neg.out"; fi
}
echo "=== negative controls on planted inputs ==="
printf 'Concrete.deadCodePlantedControl\tdef\tConcrete.IR.Lower\t1\t0\t0\n' > "$TMP/c2.tsv"
expect_fail "C2 a planted unused def fails" "NEW unreachable declaration: def Concrete.deadCodePlantedControl" \
  "${WALKS[@]}" --walk "$TMP/c2.tsv"
first="$(grep -v '^#' docs/compiler/dead_code_baseline.tsv | grep -v '^decl	' | head -1)"
if [ -n "$first" ]; then
  d="$(cut -f1 <<<"$first")"; f="$(cut -f3 <<<"$first")"; m="${f%.lean}"; m="${m//\//.}"
  printf '%s\t%s\t%s\t1\t1\t1\n' "$d" "$(cut -f2 <<<"$first")" "$m" > "$TMP/c3.tsv"
  expect_fail "C3 a baseline row whose declaration is reachable fails" "is reachable now" "${WALKS[@]}" --walk "$TMP/c3.tsv"
  { cat "$TMP/w1.tsv" "$TMP/w2.tsv"; } | awk -F'\t' -v d="$d" -v m="$m" '!($1 == d && $3 == m)' > "$TMP/c4.tsv"
  expect_fail "C4 a baseline row whose declaration is gone fails" "no longer exists" --walk "$TMP/c4.tsv"
  { grep '^#' docs/compiler/dead_code_baseline.tsv; grep -v '^#' docs/compiler/dead_code_baseline.tsv | grep -vxF -- "$first"; } > "$TMP/c5_base.tsv"
  expect_fail "C5 a baseline row the base revision did not have fails" "baseline row ADDED" \
    "${WALKS[@]}" --base-baseline "$TMP/c5_base.tsv"
else
  no "C3-C5 need a baseline row to plant against (the baseline is empty: make these controls synthetic)"
fi
live="$(awk -F'\t' '$5 == 1 && $2 == "def" {print $1; exit}' "$TMP/w1.tsv")"
{ cat docs/compiler/dead_code_allowlist.tsv; printf '%s\t%s\tplanted\n' "$live" "scripts/tools/dead_code_ratchet.py"; } > "$TMP/c6_allow.tsv"
expect_fail "C6 an allowlist row for a reachable declaration fails" "reachable without the allowlist" \
  "${WALKS[@]}" --allowlist "$TMP/c6_allow.tsv"
dead="$(awk -F'\t' '$6 == 0 {print $1; exit}' "$TMP/w1.tsv")"
{ cat docs/compiler/dead_code_allowlist.tsv; printf '%s\t%s\tplanted\n' "$dead" "LICENSE"; } > "$TMP/c7_allow.tsv"
expect_fail "C7 an allowlist row whose file does not mention the name fails" "does not mention" \
  "${WALKS[@]}" --allowlist "$TMP/c7_allow.tsv"
# C8: a reachable declaration and an unreachable one under one key cannot be told apart.
dup="$(awk -F'\t' -v OFS='\t' '$6 == 1 {$5 = 0; $6 = 0; print; exit}' "$TMP/w1.tsv")"
{ cat "$TMP/w1.tsv"; printf '%s\n' "$dup"; } > "$TMP/c8.tsv"
expect_fail "C8 two declarations sharing a normalized name, one unreachable, are refused" "share the name" --walk "$TMP/c8.tsv" --walk "$TMP/w2.tsv"

echo "DEAD-CODE-RATCHET: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
